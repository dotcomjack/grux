import XCTest
@testable import Grux

/// Measured 2026-09-27 on the installed build: "hey Grux what is two plus two"
/// went to Chat and was answered, while decisions.jsonl recorded
/// `voice.intent=not_a_command 1.00` for it. The ledger held the provider's
/// answer and never the router's own rule (said by name, a reply inside the
/// follow-up window), so the orb hover, the Usage card and the briefing all
/// said Grux ignored words it had answered.
@MainActor
final class VoiceLedgerVerdictTests: XCTestCase {
    private func router(_ ledger: DecisionLedger, recentReply: (age: TimeInterval, text: String)? = nil) -> VoiceCommandRouter {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: ledger)
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { recentReply }
        return r
    }

    func test_wordsSaidByName_areRecordedAsSentToChat() async {
        let ledger = DecisionLedger(storeURL: nil)
        let r = router(ledger)
        var rowsWhenChatStarted: [String] = []
        r.sendToChat = { _ in rowsWhenChatStarted = ledger.recent.map(\.summary) }
        let e = await r.consider(chunk: "hey grux what is two plus two")
        await r.chatHandOff?.value
        XCTAssertEqual(e?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertEqual(ledger.last?.surface, "voice")
        XCTAssertTrue(ledger.last?.summary.contains("voice.intent=say:chat") == true,
                      "the ledger's last word must be what Grux did: \(ledger.recent.map(\.summary))")
        XCTAssertTrue(rowsWhenChatStarted.contains { $0.contains("voice.intent=say:chat") },
                      "recorded before the reply is awaited, not 25 s later")
    }

    func test_aReplyInsideTheFollowUpWindow_isRecordedAsSentToChat() async {
        let ledger = DecisionLedger(storeURL: nil)
        let r = router(ledger, recentReply: (age: 10, text: "Want me to draft it?"))
        r.sendToChat = { _ in }
        let e = await r.consider(chunk: "yes please do that for tomorrow")
        XCTAssertEqual(e?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertTrue(ledger.last?.summary.contains("voice.intent=say:chat") == true, "\(ledger.recent.map(\.summary))")
    }

    /// No rule overrode the provider: one row, as before.
    func test_aDecisionTheRouterKept_isRecordedOnce() async {
        let ledger = DecisionLedger(storeURL: nil)
        let r = router(ledger)
        r.navigate = { _ in }
        _ = await r.consider(chunk: "open my calendar")
        _ = await r.consider(chunk: "so anyway I was thinking about lunch")
        XCTAssertEqual(ledger.recent.count, 2, "\(ledger.recent.map(\.summary))")
        XCTAssertTrue(ledger.recent[0].summary.contains("voice.intent=tab:calendar"))
        XCTAssertTrue(ledger.recent[1].summary.contains("voice.intent=not_a_command"))
    }
}
