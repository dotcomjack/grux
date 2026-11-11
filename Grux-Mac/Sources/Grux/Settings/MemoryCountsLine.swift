import Foundation

/// D200 item 17 (sense pass 28): Settings, Persistent memory read "0 chats"
/// for the first seconds after launch, before the memory files were read
/// (1,803 once they were), so a person saw an empty memory that was not. The
/// counts are shown only once read; until then the pane says it is counting.
enum MemoryCountsLine {
    static let counting = "Counting what Grux remembers..."
    static let notRead = "Grux has not finished reading its memory yet. Open this pane again in a moment to see the counts."

    /// The stats row, or nil while the counts are not read.
    static func stats(_ counts: [SemanticMemoryKind: Int]?) -> [(label: String, count: Int)]? {
        guard let c = counts else { return nil }
        return [("chats", (c[.chatUser] ?? 0) + (c[.chatAssistant] ?? 0)),
                ("ambient", c[.ambient] ?? 0), ("focus", c[.focus] ?? 0), ("web", c[.web] ?? 0)]
    }
}
