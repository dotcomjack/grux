import Foundation

// Single source of truth for rolling-summarization thresholds. Pulled out of
// AppState so the numbers are testable, swappable, and explicit instead of
// buried magic at the call site.
enum CompactionPolicy {
    // Don't fire compaction below this message count - short threads stay
    // raw so the model has every word verbatim.
    static let messagesThreshold: Int = 40

    // Belt-and-suspenders gate so a thread of 50 four-word messages doesn't
    // round-trip Haiku just to "summarize" 200 tokens. Roughly 4 chars/token.
    static let approximateTokensThreshold: Int = 3000

    // Number of trailing messages we keep verbatim after compaction. Anything
    // older gets folded into the rolling summary.
    static let keepLastN: Int = 12

    // Pure threshold check - auto-compaction skips unless BOTH gates pass.
    // Kept as a pure function so unit tests can pin the boundary behavior
    // without standing up an AppState or ChatThreadStore.
    static func shouldAutoCompact(messageCount: Int, approximateTokens: Int) -> Bool {
        return messageCount > messagesThreshold && approximateTokens > approximateTokensThreshold
    }
}
