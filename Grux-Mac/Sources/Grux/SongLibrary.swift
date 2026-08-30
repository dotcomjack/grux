import Foundation

// Persistent library of "quick select" songs for the playMusic action editor.
// A dropdown, so you do not retype song+artist every time.
// Saved entries live at ~/Library/Application Support/Grux/songs.json.
//
// The compiled-in default is EMPTY. A fresh install starts with no songs and
// writes no file until you save one. Empty is a supported state, not a broken
// one: SongPicker renders it as "Pick saved" with a line telling you to type a
// song and save it, so nothing has to be seeded to keep the UI coherent.

struct SavedSong: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var song: String
    var artist: String

    init(id: UUID = UUID(), song: String, artist: String) {
        self.id = id
        self.song = song
        self.artist = artist
    }

    var displayTitle: String {
        artist.isEmpty ? song : "\(song) - \(artist)"
    }
}

@MainActor
final class SongLibraryStore: ObservableObject {
    static let shared = SongLibraryStore()

    @Published private(set) var songs: [SavedSong] = []
    private var loaded = false

    private let storageURL: URL

    // Injectable so a test can exercise the absent-file branch against a temp
    // directory instead of the real Application Support library. Same shape as
    // NotesStore(storageURL:).
    init(storageURL: URL = Persistence.supportDir.appendingPathComponent("songs.json")) {
        self.storageURL = storageURL
    }

    // Loading is READ ONLY. An absent, unreadable or undecodable file yields an
    // empty library and touches nothing on disk.
    //
    // This used to fall through to a hardcoded list of nine tracks and save()
    // it, which meant a brand new install wrote one person's music taste into
    // Application Support before the user had asked for anything, and a
    // stranger editing a "Play music" action was offered songs they never
    // chose. Do not reintroduce a seed here.
    //
    // A decoded empty array is honoured rather than treated as "missing". The
    // old code required a non-empty array before accepting the file, so
    // deleting your last saved song silently resurrected the whole seed list on
    // the next launch.
    func load() {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: storageURL),
              let arr = try? JSONDecoder().decode([SavedSong].self, from: data) else { return }
        songs = arr
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(songs) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    // Add a song by value. Dedupes by (song, artist) case-insensitive so
    // "save current" on an already-saved combo is a no-op.
    @discardableResult
    func add(song: String, artist: String) -> SavedSong? {
        let s = song.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let existing = songs.first(where: {
            $0.song.caseInsensitiveCompare(s) == .orderedSame &&
            $0.artist.caseInsensitiveCompare(a) == .orderedSame
        }) {
            return existing
        }
        let new = SavedSong(song: s, artist: a)
        songs.append(new)
        save()
        return new
    }

    func delete(id: UUID) {
        songs.removeAll(where: { $0.id == id })
        save()
    }

    func rename(id: UUID, song: String, artist: String) {
        guard let idx = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[idx].song = song
        songs[idx].artist = artist
        save()
    }
}
