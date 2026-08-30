import Foundation

// Persistent chat thread. Embeds messages inline like MeetingRecord embeds
// utterances - one JSON file per thread on disk. `summary` is a rolling
// LLM-generated compaction of older turns that the chat service prepends
// as a system block so long threads don't blow the context window.
struct ChatThread: Codable, Identifiable {
    let id: UUID
    var title: String
    var summary: String?
    var starred: Bool
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    // When true, ChatThreadStore will compact this thread automatically once
    // it crosses the message-count threshold. Off by default for a thread the
    // user manually marked as "keep everything raw".
    var autoCompact: Bool
    // Active conversational intake (e.g. the ship-ios-app pre-workflow Q&A).
    // ChatService routes the next user reply through IntakeHandler when this
    // is non-nil, instead of falling through to V2 fast-path or Claude. Cleared
    // when the workflow fires or the user cancels.
    var intake: ChatIntakeState?

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        summary: String? = nil,
        starred: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        autoCompact: Bool = true,
        intake: ChatIntakeState? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.starred = starred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.autoCompact = autoCompact
        self.intake = intake
    }

    enum CodingKeys: String, CodingKey {
        case id, title, summary, starred, createdAt, updatedAt, messages, autoCompact, intake
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? (try c.decode(Date.self, forKey: .createdAt))
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        autoCompact = try c.decodeIfPresent(Bool.self, forKey: .autoCompact) ?? true
        intake = try c.decodeIfPresent(ChatIntakeState.self, forKey: .intake)
    }

    // Last non-empty assistant or user line - shown in the sidebar row under
    // the title. Kept short (120 chars) because the sidebar is narrow.
    var previewLine: String? {
        if let last = messages.reversed().first(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return String(last.content.prefix(120))
        }
        return nil
    }

    // Approximate token budget - used to decide if compaction should fire.
    // Cheap 4-chars-per-token approximation is plenty for a threshold gate.
    var approximateTokens: Int {
        let total = messages.reduce(0) { $0 + $1.content.count }
        return total / 4
    }
}

// Light projection written to `chat-threads/index.json`. Thread picker reads
// this, not the full per-thread files, so opening the picker stays snappy
// even at thousands of threads.
struct ChatThreadIndexEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var starred: Bool
    var updatedAt: Date
    var createdAt: Date
    var messageCount: Int
    var preview: String?
    var hasSummary: Bool

    init(
        id: UUID,
        title: String,
        starred: Bool,
        updatedAt: Date,
        createdAt: Date,
        messageCount: Int,
        preview: String?,
        hasSummary: Bool
    ) {
        self.id = id
        self.title = title
        self.starred = starred
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.messageCount = messageCount
        self.preview = preview
        self.hasSummary = hasSummary
    }
}
