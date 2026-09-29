import XCTest
@testable import Grux

/// Found live 2026-09-27 (ledger A8): words said to Grux went to Chat and the
/// decision (banner, voice event, inject result) landed only after the model
/// had answered, 25 s for a 3 ms decision. Handing words to Chat is the
/// decision's effect; the reply is Chat's own business.
@MainActor
final class VoiceChatHandOffTests: XCTestCase {
    private func router() -> VoiceCommandRouter {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        return r
    }

    func test_theDecisionIsReportedBeforeChatAnswers() async {
        let r = router()
        var sent: [String] = []
        var chatFinished = false
        var bannerBeforeReply: Bool?
        r.sendToChat = { text in
            sent.append(text)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            chatFinished = true
        }
        r.banner = { _ in bannerBeforeReply = !chatFinished }

        let started = Date()
        let e = await r.consider(chunk: "hey grux what is two plus two")
        let waited = Date().timeIntervalSince(started)

        XCTAssertEqual(e?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(e?.action, "sent to chat")
        XCTAssertLessThan(waited, 1.0, "the decision waited \(String(format: "%.1f", waited)) s for Chat's reply")
        XCTAssertEqual(bannerBeforeReply, true, "the banner waited for Chat's reply")
        XCTAssertEqual(r.events.last?.commandId, VoiceCommandRouter.sayToChat)
        XCTAssertFalse(chatFinished)

        await r.chatHandOff?.value
        XCTAssertEqual(sent, ["what is two plus two"], "the words never reached Chat")
        XCTAssertTrue(chatFinished)
    }

    /// Two quick sentences reach Chat in the order they were said.
    func test_handOffsKeepTheOrderTheyWereSaidIn() async {
        let r = router()
        var sent: [String] = []
        r.sendToChat = { text in
            sent.append(text)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        _ = await r.consider(chunk: "hey grux first question please")
        _ = await r.consider(chunk: "hey grux second question please")
        await r.chatHandOff?.value
        XCTAssertEqual(sent, ["first question please", "second question please"])
    }

    func test_aDryRunHandsNothingToChat() async {
        let r = router()
        r.sendToChat = { _ in XCTFail("a dry run reached Chat") }
        let e = await r.consider(chunk: "hey grux what is two plus two", dryRun: .everything)
        XCTAssertEqual(e?.action, "dry run: would send to chat")
        XCTAssertNil(r.chatHandOff)
    }
}
