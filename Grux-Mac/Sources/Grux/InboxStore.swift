import Foundation

// Structured inbox of things the user told Grux to "remember this" about.
// Written by Claude's capture_memory tool (and the remember_this macro as a
// passive fallback). Claude reads PENDING_MEMORIES from the volatile system
// block on every turn so the inbox can't rot - if there are unreviewed items,
// Grux will naturally surface them.
//
// Mirrors ~/.grux/inbox.md as a human-readable companion file so nothing gets
// locked up inside a proprietary format.

struct InboxItem: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var text: String
    var capturedAt: Date
    var reviewedAt: Date?
    var surfaceCount: Int           // how many times Grux has been told this already this session
    var lastSurfacedAt: Date?

    init(id: UUID = UUID(), text: String, capturedAt: Date = Date(),
         reviewedAt: Date? = nil, surfaceCount: Int = 0, lastSurfacedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.reviewedAt = reviewedAt
        self.surfaceCount = surfaceCount
        self.lastSurfacedAt = lastSurfacedAt
    }
}

@MainActor
final class InboxStore: ObservableObject {
    static let shared = InboxStore()

    @Published private(set) var items: [InboxItem] = []
    private var loaded = false

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("inbox.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("inbox.md")
    }

    func load() {
        guard !loaded else { return }
        loaded = true

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: jsonURL),
           let arr = try? dec.decode([InboxItem].self, from: data) {
            items = arr
        }
    }

    // Append a new captured memory. Updates the JSON store AND mirrors to
    // inbox.md as a timestamped bullet. Returns the new item.
    @discardableResult
    func capture(text: String) -> InboxItem? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let item = InboxItem(text: t)
        items.append(item)
        save()
        appendToMarkdown(item)
        return item
    }

    // Mark the best fuzzy match as reviewed. Returns whether we hit anything.
    @discardableResult
    func markReviewed(match: String) -> InboxItem? {
        let q = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        guard let idx = items.firstIndex(where: {
            $0.reviewedAt == nil && ChatService.fuzzyMatches($0.text, query: q)
        }) else { return nil }
        items[idx].reviewedAt = Date()
        save()
        return items[idx]
    }

    // Called by ChatService when it injects an item into the prompt so we can
    // rate-limit repeat resurfacing - each item only pops up once per hour by
    // default so the user isn't nagged every turn.
    func noteSurfaced(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let now = Date()
        var changed = false
        for id in ids {
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].surfaceCount += 1
                items[idx].lastSurfacedAt = now
                changed = true
            }
        }
        if changed { save() }
    }

    // Items ready to resurface in the next turn. Rules:
    //   - Not yet marked reviewed
    //   - Never surfaced, OR last surfaced > cooldown ago
    //   - Newest unreviewed first (limit to 5 so the prompt doesn't balloon)
    func pendingForResurface(cooldown: TimeInterval = 60 * 60, limit: Int = 5) -> [InboxItem] {
        let now = Date()
        let pending = items.filter { item in
            guard item.reviewedAt == nil else { return false }
            guard let last = item.lastSurfacedAt else { return true }
            return now.timeIntervalSince(last) >= cooldown
        }
        return Array(pending.sorted { $0.capturedAt > $1.capturedAt }.prefix(limit))
    }

    func activeCount() -> Int {
        items.filter { $0.reviewedAt == nil }.count
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        // Guarded write: inbox.json lives in the backed-up-and-restored
        // supportDir tree, so a capture during/after a restore must not
        // overwrite the restored file with pre-restore in-memory items.
        Persistence.write(data, to: jsonURL)
    }

    private func appendToMarkdown(_ item: InboxItem) {
        guard !Persistence.writesSuspended else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = .current
        let stamp = df.string(from: item.capturedAt)
        let entry = "\n## \(stamp)\n- \(item.text)\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: mdURL.path) {
            let header = "# Grux Inbox\n\nCaptured via `remember this` / `capture_memory`. Grux will resurface these until you mark them reviewed.\n"
            try? header.write(to: mdURL, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: mdURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = entry.data(using: .utf8) {
                _ = try? handle.write(contentsOf: data)
            }
        }
    }
}
