import Foundation

// JSON-on-disk store for chat threads. Mirrors MeetingStore's layout: one
// record per file in ~/Library/Application Support/Grux/chat-threads/ plus
// a compact index.json for fast listings. Migrates the legacy single-file
// chat.json into the first thread on first launch so no messages are lost.
@MainActor
final class ChatThreadStore {
    static let shared = ChatThreadStore()

    private(set) var index: [ChatThreadIndexEntry] = []
    private let indexLock = NSLock()

    private init() {
        _ = Persistence.chatThreadsDir
        loadIndex()
        reindexIfDriftDetected()
        migrateLegacyIfNeeded()
    }

    // Self-heal: if the on-disk JSON file count doesn't match the cached
    // index size, trigger a full rebuild. Catches manual edits, failed
    // writes from older versions, and dropped-in threads from tests so
    // every real file ends up represented in the sidebar.
    private func reindexIfDriftDetected() {
        let dir = Persistence.chatThreadsDir
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let diskCount = items.filter {
            $0.lastPathComponent != "index.json" && $0.pathExtension == "json"
        }.count
        let indexCount = index.count
        if diskCount != indexCount {
            reindex()
        }
    }

    // MARK: - Write path

    @discardableResult
    func create(title: String = "New chat", starred: Bool = false) -> ChatThread {
        let thread = ChatThread(title: title, starred: starred)
        save(thread)
        reindex()
        return thread
    }

    func save(_ thread: ChatThread) {
        var t = thread
        t.updatedAt = Date()
        Persistence.save(t, to: url(for: t.id))
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        reindex()
    }

    // MARK: - Read path

    func load(id: UUID) -> ChatThread? {
        let fallback = ChatThread(id: UUID())
        let loaded = Persistence.load(ChatThread.self, from: url(for: id), fallback: fallback)
        return loaded.id == fallback.id ? nil : loaded
    }

    func list() -> [ChatThreadIndexEntry] {
        indexLock.lock()
        defer { indexLock.unlock() }
        // Sort: starred first, then most-recently-updated.
        return index.sorted { a, b in
            if a.starred != b.starred { return a.starred }
            return a.updatedAt > b.updatedAt
        }
    }

    // MARK: - Mutations used by AppState

    @discardableResult
    func rename(id: UUID, title: String) -> ChatThread? {
        guard var thread = load(id: id) else { return nil }
        thread.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifEmpty(fallback: "Untitled chat")
        save(thread)
        reindex()
        return thread
    }

    @discardableResult
    func toggleStar(id: UUID) -> ChatThread? {
        guard var thread = load(id: id) else { return nil }
        thread.starred.toggle()
        save(thread)
        reindex()
        return thread
    }

    @discardableResult
    func setSummary(id: UUID, summary: String?) -> ChatThread? {
        guard var thread = load(id: id) else { return nil }
        thread.summary = summary
        save(thread)
        reindex()
        return thread
    }

    // Append one message and persist atomically. Fast-path: no index rebuild
    // when the index row's message count / preview / updatedAt would just
    // float forward by one - we patch the row in place instead of walking
    // every thread on disk.
    @discardableResult
    func append(id: UUID, message: ChatMessage) -> ChatThread? {
        guard var thread = load(id: id) else { return nil }
        thread.messages.append(message)
        thread.updatedAt = Date()
        save(thread)
        patchIndexRow(for: thread)
        return thread
    }

    // Replace the entire message list (used by `clearChat` and after
    // compaction). Rewrites the file and the matching index row.
    @discardableResult
    func replaceMessages(id: UUID, messages: [ChatMessage], summary: String? = nil) -> ChatThread? {
        guard var thread = load(id: id) else { return nil }
        thread.messages = messages
        if let summary { thread.summary = summary }
        thread.updatedAt = Date()
        save(thread)
        patchIndexRow(for: thread)
        return thread
    }

    // MARK: - Index helpers

    private func url(for id: UUID) -> URL {
        Persistence.chatThreadsDir.appendingPathComponent("\(id.uuidString).json")
    }

    private var indexURL: URL {
        Persistence.chatThreadsDir.appendingPathComponent("index.json")
    }

    private func loadIndex() {
        indexLock.lock()
        defer { indexLock.unlock() }
        index = Persistence.load([ChatThreadIndexEntry].self, from: indexURL, fallback: [])
    }

    func reindex() {
        let fm = FileManager.default
        let dir = Persistence.chatThreadsDir
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var rebuilt: [ChatThreadIndexEntry] = []
        let sentinel = UUID()
        for item in items where item.lastPathComponent != "index.json" && item.pathExtension == "json" {
            let fallback = ChatThread(id: sentinel)
            let thread = Persistence.load(ChatThread.self, from: item, fallback: fallback)
            if thread.id == sentinel { continue }
            rebuilt.append(entryFrom(thread: thread))
        }
        rebuilt.sort { $0.updatedAt > $1.updatedAt }
        indexLock.lock()
        self.index = rebuilt
        indexLock.unlock()
        Persistence.save(rebuilt, to: indexURL)
    }

    private func patchIndexRow(for thread: ChatThread) {
        let entry = entryFrom(thread: thread)
        indexLock.lock()
        if let idx = index.firstIndex(where: { $0.id == thread.id }) {
            index[idx] = entry
        } else {
            index.append(entry)
        }
        index.sort { $0.updatedAt > $1.updatedAt }
        let snapshot = index
        indexLock.unlock()
        Persistence.save(snapshot, to: indexURL)
    }

    private func entryFrom(thread: ChatThread) -> ChatThreadIndexEntry {
        ChatThreadIndexEntry(
            id: thread.id,
            title: thread.title,
            starred: thread.starred,
            updatedAt: thread.updatedAt,
            createdAt: thread.createdAt,
            messageCount: thread.messages.count,
            preview: thread.previewLine,
            hasSummary: (thread.summary?.isEmpty == false)
        )
    }

    // MARK: - Legacy migration

    // If the user upgraded from a pre-threading Grux build, their chat lives
    // in chat.json (a flat `[ChatMessage]`). Fold it into a brand-new thread
    // titled "Previous chat" so no history is lost. Only runs when the
    // threads dir is empty - never re-migrates on subsequent launches.
    private func migrateLegacyIfNeeded() {
        indexLock.lock()
        let hasThreads = !index.isEmpty
        indexLock.unlock()
        if hasThreads { return }

        let legacyURL = Persistence.chatURL
        let legacyMessages = Persistence.load([ChatMessage].self, from: legacyURL, fallback: [])
        guard !legacyMessages.isEmpty else { return }

        let migrated = ChatThread(
            title: "Previous chat",
            createdAt: legacyMessages.first?.timestamp ?? Date(),
            updatedAt: legacyMessages.last?.timestamp ?? Date(),
            messages: legacyMessages
        )
        save(migrated)
        reindex()

        // Rename the legacy file (don't delete - losing chat history is worse
        // than keeping a stale copy around, and we can always re-migrate if
        // something went wrong).
        let archive = legacyURL.deletingLastPathComponent()
            .appendingPathComponent("chat.legacy.json")
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.moveItem(at: legacyURL, to: archive)
    }
}

private extension String {
    func ifEmpty(fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
