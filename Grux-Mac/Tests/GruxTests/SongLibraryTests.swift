import XCTest
@testable import Grux

// Unit tests for SongLibraryStore. Every test points the store at its own
// throwaway temp directory via the init(storageURL:) test seam, so the real
// ~/Library/Application Support/Grux/songs.json is never read or written.
//
// The behaviour under test is the one that regressed: load() used to fall
// through to a hardcoded nine-track seed and save() it, so a brand new install
// arrived carrying one person's music taste and created songs.json before the
// user had asked for anything. These tests fail if a seed comes back.
@MainActor
final class SongLibraryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-song-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    private var storeURL: URL { tempDir.appendingPathComponent("songs.json") }

    // MARK: - Absent file

    func testAbsentFileYieldsEmptyLibrary() throws {
        let store = SongLibraryStore(storageURL: storeURL)
        store.load()
        XCTAssertTrue(store.songs.isEmpty, "a fresh install starts with no songs, never a seed list")
    }

    func testLoadWritesNothingToDisk() throws {
        let store = SongLibraryStore(storageURL: storeURL)
        store.load()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path),
            "load() must not create songs.json; personal data is written only when you ask for it"
        )
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contents.isEmpty, "load() must leave the storage directory untouched, found \(contents)")
    }

    // MARK: - Existing file

    func testLoadDoesNotRewriteAnExistingFile() throws {
        let saved = [SavedSong(song: "Track A", artist: "Artist A")]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let original = try enc.encode(saved)
        try original.write(to: storeURL)

        let store = SongLibraryStore(storageURL: storeURL)
        store.load()

        XCTAssertEqual(store.songs, saved)
        let afterLoad = try Data(contentsOf: storeURL)
        XCTAssertEqual(
            afterLoad, original,
            "load() is read only, so the bytes on disk are identical afterwards"
        )
    }

    func testUnreadableFileYieldsEmptyLibraryRatherThanASeed() throws {
        let garbage = Data("not json".utf8)
        try garbage.write(to: storeURL)

        let store = SongLibraryStore(storageURL: storeURL)
        store.load()

        XCTAssertTrue(store.songs.isEmpty, "a corrupt file degrades to empty, never to somebody else's songs")
        let afterLoad = try Data(contentsOf: storeURL)
        XCTAssertEqual(
            afterLoad, garbage,
            "a failed decode must not overwrite whatever is on disk"
        )
    }

    // MARK: - Empty is a real state

    func testDeletingTheLastSongStaysEmptyAcrossReload() throws {
        // The old load() only accepted a decoded array when it was non-empty,
        // so emptying the library resurrected the whole seed list on the next
        // launch. An empty library is a real choice and must survive a reload.
        let first = SongLibraryStore(storageURL: storeURL)
        first.load()
        let added = try XCTUnwrap(first.add(song: "Track A", artist: "Artist A"))
        first.delete(id: added.id)
        XCTAssertTrue(first.songs.isEmpty)

        let second = SongLibraryStore(storageURL: storeURL)
        second.load()
        XCTAssertTrue(second.songs.isEmpty, "an emptied library reloads empty, it does not re-seed")
    }

    // MARK: - Writing on an explicit user action

    func testAddWritesOnlyWhatYouAskedFor() throws {
        // The other half of the contract: the file appears the moment you save
        // a song, and it holds that song and nothing else.
        let store = SongLibraryStore(storageURL: storeURL)
        store.load()
        store.add(song: "Track A", artist: "Artist A")

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        let reloaded = SongLibraryStore(storageURL: storeURL)
        reloaded.load()
        XCTAssertEqual(reloaded.songs.count, 1)
        XCTAssertEqual(reloaded.songs.first?.song, "Track A")
        XCTAssertEqual(reloaded.songs.first?.artist, "Artist A")
    }
}
