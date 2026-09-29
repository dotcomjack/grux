import XCTest
@testable import Grux

/// A spoken command that asks first does what was said once it is approved.
///
/// Measured live 2026-09-27: "Grux, calendar, show it open" (said by name,
/// 0.60 against a 0.70 bar) queued `You said: open calendar` in Approvals.
/// Approving it answered "Nothing executable was attached to that one, so
/// your answer is recorded and nothing was performed", and the window stayed
/// on Home. The card carried no replay, so every asked-first voice command,
/// tab, app, macro or mute, was a question whose yes did nothing.
@MainActor
final class VoiceAskFirstReplayTests: XCTestCase {

    private var savedNavigate: (@MainActor (String) -> Void)?

    override func setUp() async throws {
        savedNavigate = VoiceCommandRouter.shared.navigate
    }

    override func tearDown() async throws {
        if let savedNavigate { VoiceCommandRouter.shared.navigate = savedNavigate }
    }

    private func tempQueue() -> ApprovalQueue {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-first-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let q = ApprovalQueue(storeURL: dir.appendingPathComponent("approvals.json"))
        q.judgeRisk = nil
        return q
    }

    private func router(macros: [Macro] = []) -> VoiceCommandRouter {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.99 }, macros: { macros })
        r.recentReply = { nil }
        return r
    }

    /// The live case end to end: heard by name below the bar, asked first,
    /// approved, and the tab opens.
    func test_approvingAnAskedFirstTabOpensIt() async throws {
        let r = router()
        var asked: VoiceCommand?
        r.askFirst = { asked = $0 }
        let e = await r.consider(chunk: "grux open my calendar")
        XCTAssertEqual(e?.outcome, .askedFirst)
        let cmd = try XCTUnwrap(asked)

        var opened: [String] = []
        VoiceCommandRouter.shared.navigate = { opened.append($0) }
        let queue = tempQueue()
        let item = queue.enqueue(VoiceCommandRouter.askFirstAction(cmd))
        XCTAssertTrue(opened.isEmpty, "asking first does nothing yet")

        let result = await queue.approveAndExecute(item.id)
        XCTAssertEqual(opened, ["calendar"], "approving the card opens what was said")
        XCTAssertTrue(result.hasPrefix("ok"), result)
        XCTAssertEqual(queue.items.first { $0.id == item.id }?.state, .approved)
    }

    /// The card still reads as what was said, and the replay names only the
    /// command, never the words, so it cannot be steered by what was heard.
    func test_theCardCarriesTheCommandAndNothingElse() throws {
        let cmd = VoiceCommand(id: "tab:calendar", phrases: ["open calendar"], klass: .onTheSpot, run: { "" })
        let action = VoiceCommandRouter.askFirstAction(cmd)
        XCTAssertEqual(action.summary, "You said: open calendar")
        XCTAssertEqual(action.detail["__replay_tool"], VoiceCommandRouter.replayTool)
        let input = try XCTUnwrap(ApprovalQueue.decodeInput(action.detail["__replay_input"] ?? ""))
        XCTAssertEqual(input as? [String: String], ["id": "tab:calendar"])
    }

    /// A macro that may never run by voice stays refused even when a card for
    /// it is approved, and a command that is gone is an error, not a silent yes.
    func test_approvalNeverRunsWhatVoiceMayNeverRun() async {
        var ran = false
        let shell = Macro(name: "loop_cleanup", triggers: ["loop cleanup"], description: "",
                          rawActions: [.runShell(command: "true")])
        let r = router(macros: [shell])
        r.runMacro = { _ in ran = true; return "ran" }
        let refused = await r.runApproved(id: "macro:loop_cleanup")
        XCTAssertTrue(refused.hasPrefix("refused"), refused)
        XCTAssertFalse(ran)

        let gone = await r.runApproved(id: "macro:deleted_since")
        XCTAssertTrue(gone.hasPrefix("error"), gone)
        let chat = await r.runApproved(id: VoiceCommandRouter.sayToChat)
        XCTAssertTrue(chat.hasPrefix("error"), "dictation is never a card to replay: \(chat)")
    }

    /// An allowed macro runs through the same seam the spoken one uses.
    func test_approvingAnOnTheSpotMacroRunsIt() async {
        var ran: [String] = []
        let hello = Macro(name: "loop_hello", triggers: ["loop hello"], description: "",
                          rawActions: [.speak(text: "hello")])
        let r = router(macros: [hello])
        r.runMacro = { ran.append($0); return "spoke" }
        let result = await r.runApproved(id: "macro:loop_hello")
        XCTAssertEqual(ran, ["loop_hello"])
        XCTAssertEqual(result, "ok: spoke")
    }
}
