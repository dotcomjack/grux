import Foundation

// JSON-on-disk store for quick notes. Mirrors InboxStore's shape:
// @MainActor singleton, @Published items, atomic JSON writes via the
// Persistence helpers. Saves are debounced (scheduleSave) so live typing
// in the editor collapses into one disk write instead of one per keystroke.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [GruxNote] = []

    private let storageURL: URL
    private var saveTask: Task<Void, Never>?

    // Tests inject a temp URL; the app uses the shared singleton.
    init(storageURL: URL = Persistence.notesURL) {
        self.storageURL = storageURL
        load()
    }

    func load() {
        notes = Persistence.load([GruxNote].self, from: storageURL, fallback: [])
    }

    // MARK: - CRUD

    @discardableResult
    func create(title: String = "", body: String = "", tags: [String] = [], pinned: Bool = false) -> GruxNote {
        let note = GruxNote(
            title: title,
            body: body,
            tags: Self.normalizeTags(tags),
            pinned: pinned
        )
        notes.insert(note, at: 0)
        scheduleSave()
        return note
    }

    @discardableResult
    func update(
        id: UUID,
        title: String? = nil,
        body: String? = nil,
        tags: [String]? = nil,
        pinned: Bool? = nil
    ) -> GruxNote? {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return nil }
        // Skip no-op updates: programmatic editor syncs echo values back
        // unchanged, and bumping updatedAt for those would churn the
        // most-recently-updated ordering just from browsing the list.
        let normalizedTags = tags.map(Self.normalizeTags)
        let changed =
            (title != nil && title != notes[idx].title) ||
            (body != nil && body != notes[idx].body) ||
            (normalizedTags != nil && normalizedTags != notes[idx].tags) ||
            (pinned != nil && pinned != notes[idx].pinned)
        guard changed else { return notes[idx] }
        if let title { notes[idx].title = title }
        if let body { notes[idx].body = body }
        if let normalizedTags { notes[idx].tags = normalizedTags }
        if let pinned { notes[idx].pinned = pinned }
        notes[idx].updatedAt = Date()
        scheduleSave()
        return notes[idx]
    }

    // Append text to an existing note's body (used by the update_note tool
    // so Claude can add to a note without round-tripping the whole body).
    @discardableResult
    func appendToBody(id: UUID, text: String) -> GruxNote? {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return notes[idx] }
        if notes[idx].body.isEmpty {
            notes[idx].body = t
        } else {
            notes[idx].body += "\n\n" + t
        }
        notes[idx].updatedAt = Date()
        scheduleSave()
        return notes[idx]
    }

    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        scheduleSave()
    }

    @discardableResult
    func togglePin(id: UUID) -> GruxNote? {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return nil }
        notes[idx].pinned.toggle()
        notes[idx].updatedAt = Date()
        scheduleSave()
        return notes[idx]
    }

    // MARK: - Read

    func note(id: UUID) -> GruxNote? {
        notes.first { $0.id == id }
    }

    // Pinned first, then most-recently-updated.
    var ordered: [GruxNote] {
        notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }

    func search(_ query: String) -> [GruxNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ordered }
        return ordered.filter { $0.matches(query: q) }
    }

    // Resolve a hint to a note: UUID first, then exact title, then substring,
    // then fuzzy token match (same matcher chat tools use everywhere else).
    func resolve(_ hint: String) -> GruxNote? {
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if let id = UUID(uuidString: h), let n = note(id: id) { return n }
        let lower = h.lowercased()
        if let exact = ordered.first(where: { $0.title.lowercased() == lower }) { return exact }
        if let sub = ordered.first(where: { $0.title.lowercased().contains(lower) }) { return sub }
        return ordered.first { ChatService.fuzzyMatches($0.title + " " + $0.body, query: lower) }
    }

    // MARK: - Persistence

    // Debounced write: collapses bursts of edits into one disk write
    // roughly 0.4s after the last mutation.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = notes
        let url = storageURL
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            Persistence.save(snapshot, to: url)
        }
    }

    // Force a synchronous write (tests, app termination paths).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Persistence.save(notes, to: storageURL)
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in tags {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .lowercased()
            guard !t.isEmpty, !seen.contains(t) else { continue }
            seen.insert(t)
            out.append(t)
        }
        return out
    }
}
