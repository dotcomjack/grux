import XCTest
@testable import Grux

// Pin the threshold gate. The numbers themselves can move (CompactionPolicy
// owns them); these tests pin the SHAPE, both gates must trip, both are
// strictly greater-than, and ChatThread.approximateTokens stays roughly in
// the chars/4 ballpark we depend on.
final class CompactionPolicyTests: XCTestCase {

    // MARK: - shouldAutoCompact

    func test_doesNotFireBelowMessageThreshold() {
        XCTAssertFalse(CompactionPolicy.shouldAutoCompact(
            messageCount: CompactionPolicy.messagesThreshold,
            approximateTokens: CompactionPolicy.approximateTokensThreshold + 10_000
        ))
    }

    func test_doesNotFireBelowTokenThreshold() {
        XCTAssertFalse(CompactionPolicy.shouldAutoCompact(
            messageCount: CompactionPolicy.messagesThreshold + 100,
            approximateTokens: CompactionPolicy.approximateTokensThreshold
        ))
    }

    func test_firesOnlyWhenBothGatesPass() {
        XCTAssertTrue(CompactionPolicy.shouldAutoCompact(
            messageCount: CompactionPolicy.messagesThreshold + 1,
            approximateTokens: CompactionPolicy.approximateTokensThreshold + 1
        ))
    }

    func test_strictGreaterThan_notGreaterOrEqual() {
        // Right at the boundary on either gate must NOT fire, auto-compact
        // is a strict overflow signal, not a "we're approaching the cap" one.
        XCTAssertFalse(CompactionPolicy.shouldAutoCompact(
            messageCount: CompactionPolicy.messagesThreshold,
            approximateTokens: CompactionPolicy.approximateTokensThreshold
        ))
    }

    func test_keepLastN_smallerThanMessageThreshold() {
        // Sanity: if keepLastN ever creeps above the message threshold,
        // compactActiveThread's `> keepLastN + 4` guard will reject calls
        // that should have fired.
        XCTAssertLessThan(CompactionPolicy.keepLastN, CompactionPolicy.messagesThreshold)
    }

    // MARK: - ChatThread.approximateTokens (the value the gate consumes)

    func test_approximateTokens_isCharsOverFour() {
        let m = ChatMessage(role: .user, content: String(repeating: "x", count: 400))
        let thread = ChatThread(messages: [m])
        // 400 chars / 4 chars-per-token = 100 tokens.
        XCTAssertEqual(thread.approximateTokens, 100)
    }

    func test_approximateTokens_sumsAcrossMessages() {
        let a = ChatMessage(role: .user, content: String(repeating: "a", count: 200))
        let b = ChatMessage(role: .assistant, content: String(repeating: "b", count: 200))
        let thread = ChatThread(messages: [a, b])
        XCTAssertEqual(thread.approximateTokens, 100)
    }

    func test_approximateTokens_emptyThread() {
        let thread = ChatThread(messages: [])
        XCTAssertEqual(thread.approximateTokens, 0)
    }
}
