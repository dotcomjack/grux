import XCTest
@testable import Grux

/// What a brand-new install must do with an absent roadmap.json.
///
/// This store used to answer "no file on disk" by writing 14 compiled-in rows
/// of one person's private product plan into Application Support. A stranger
/// opening the Roadmap tab therefore read somebody else's build plan as their
/// own, complete with tiers promising delivery dates nobody had agreed to, and
/// the app created a personal-data file before onboarding had asked for
/// anything at all.
///
/// These tests pin the two halves of the fix that a refactor could quietly
/// undo: the absent-file branch returns EMPTY, and loading is not a write. They
/// assert on behaviour rather than on the absence of a `seedItems` symbol,
/// because a seed reintroduced under any other name still fails
/// `testAbsentFileLoadsEmptyAndWritesNothing`, while a grep for one name would
/// not.
///
/// Every case points the store at its own temp directory. Reading the real
/// ~/Library/Application Support/Grux/roadmap.json would make the result depend
/// on whoever ran the suite, and writing it would be the exact bug.
@MainActor
final class RoadmapStoreTests: XCTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-roadmap-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func entries(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: - The regression

    /// The whole bug in one assertion pair: no file means no items, and
    /// reading leaves the disk exactly as it found it.
    func testAbsentFileLoadsEmptyAndWritesNothing() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try entries(of: dir), [], "precondition: the directory starts empty")

        let store = RoadmapStore(storageURL: dir.appendingPathComponent("roadmap.json"))
        store.load()

        XCTAssertTrue(store.items.isEmpty,
                      "a fresh install must open on an empty board, not on a compiled-in plan")
        XCTAssertEqual(try entries(of: dir), [],
                       "load() wrote to disk. Reading an absent roadmap must create nothing, "
                       + "least of all a file of personal data the user never typed.")
    }

    /// The numbers the Roadmap header and the empty state read. An empty board
    /// is a supported state, so nothing here may be a divide by zero or a
    /// fabricated total.
    func testEmptyBoardReportsZeroProgressInEveryTier() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RoadmapStore(storageURL: dir.appendingPathComponent("roadmap.json"))
        store.load()

        let overall = store.progress()
        XCTAssertEqual(overall.total, 0)
        XCTAssertEqual(overall.done, 0)
        XCTAssertEqual(overall.inProgress, 0)

        for tier in RoadmapTier.allCases {
            XCTAssertTrue(store.items(in: tier).isEmpty,
                          "Tier \(tier.rawValue) must start empty")
            XCTAssertEqual(store.progress(in: tier).total, 0)
        }
    }

    /// An emptied board must STAY empty across a relaunch. The old load()
    /// treated a decoded-but-empty array as "nothing on disk" and re-seeded, so
    /// a user who deleted every item got all 14 back on next launch. This is
    /// the case a partial fix (returning empty without removing the
    /// empty-array condition) would still get wrong.
    func testEmptiedBoardStaysEmptyAcrossReload() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("roadmap.json")

        let store = RoadmapStore(storageURL: url)
        store.load()
        store.add(tier: .S, title: "Temporary")
        guard let id = store.items.first?.id else { return XCTFail("add(tier:title:) did not land") }
        store.delete(id: id)

        let reloaded = RoadmapStore(storageURL: url)
        reloaded.load()
        XCTAssertTrue(reloaded.items.isEmpty,
                      "an emptied board reloaded non-empty, which means something re-seeded it")
    }

    // MARK: - Reading is read-only

    /// The owner's case. A real file loads, and comes back byte for byte
    /// untouched, because load() has no business writing.
    func testExistingFileLoadsAndIsNotRewritten() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("roadmap.json")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try enc.encode([
            RoadmapItem(tier: .A, order: 1, title: "Ship the thing", subtitle: "one line of why")
        ])
        try bytes.write(to: url)

        let store = RoadmapStore(storageURL: url)
        store.load()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.title, "Ship the thing")
        XCTAssertEqual(store.items.first?.tier, .A)
        XCTAssertEqual(try Data(contentsOf: url), bytes,
                       "load() rewrote a file it only had to read")
    }

    /// A file we cannot decode is far likelier to be a bug in us than garbage
    /// in the user's data, so it is left exactly as found. The old code
    /// overwrote it with the seed, which turned an unreadable roadmap into a
    /// destroyed one.
    func testUndecodableFileLeavesTheBoardEmptyAndTheFileIntact() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("roadmap.json")

        let garbage = Data("{ this was never a roadmap".utf8)
        try garbage.write(to: url)

        let store = RoadmapStore(storageURL: url)
        store.load()

        XCTAssertTrue(store.items.isEmpty,
                      "a file we cannot decode is not a licence to invent items")
        XCTAssertEqual(try Data(contentsOf: url), garbage,
                       "load() overwrote a file it failed to decode, destroying its contents")
    }

    // MARK: - Writing still works

    /// The fix must not have bought an empty first launch at the cost of
    /// persistence: the file appears on the first WRITE, and survives a reload.
    func testFirstAddCreatesTheFileAndPersists() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("roadmap.json")

        let store = RoadmapStore(storageURL: url)
        store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.add(tier: .S, title: "My first item", subtitle: "typed by me")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the file must appear on the first write, not on the first read")

        let reloaded = RoadmapStore(storageURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.items.map(\.title), ["My first item"])
        XCTAssertEqual(reloaded.items(in: .S).count, 1)
        XCTAssertEqual(reloaded.progress().total, 1)
    }
}
