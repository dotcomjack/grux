import Foundation

// A single quick note. Markdown body, lightweight tags, pin-to-top.
// Persisted as one JSON array at ~/Library/Application Support/Grux/notes.json
// (InboxStore-style single file; notes are small and low-churn compared to
// chat threads, so per-file storage would be overkill).
struct GruxNote: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var body: String           // markdown
    var tags: [String]
    var pinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        tags: [String] = [],
        pinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Title for list rows: explicit title, else the first non-empty body
    // line, else a placeholder.
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let first = firstBodyLine { return String(first.prefix(60)) }
        return "Untitled note"
    }

    // One-line preview for the list row under the title.
    var previewLine: String {
        guard let first = firstBodyLine else { return "" }
        return String(first.prefix(90))
    }

    private var firstBodyLine: String? {
        body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // Case-insensitive search across title, body, and tags.
    func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) { return true }
        if body.lowercased().contains(q) { return true }
        return tags.contains { $0.lowercased().contains(q) }
    }
}

extension Persistence {
    static var notesURL: URL { supportDir.appendingPathComponent("notes.json") }
}
