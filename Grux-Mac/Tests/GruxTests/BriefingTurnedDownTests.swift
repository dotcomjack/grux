import XCTest
@testable import Grux

/// D169, sense pass 21 (`s21-shots/home-page1.png`, `jaxHQ-page1.png` beside
/// `approvals-2.png`): the briefing said "3 things are waiting for your OK: Save
/// your note ..., Start a self-upgrade cycle, and 1 more." while the tray held
/// Approve on that cycle ("Self-upgrade is off, so this would be turned down").
/// The briefing asked for an OK the tray will not take. A queued card the tray
/// would turn down (`CannotRunNow.cardLine`, the tray's own rule) is never
/// counted as waiting for an OK; the briefing names it as turned down.
@MainActor
final class BriefingTurnedDownTests: XCTestCase {

    private let note = "Save your note \"The gate code is on the fridge\"."
    private let cycle = "Start a self-upgrade cycle."

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("d169-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("approvals.json")
    }

    private func card(_ summary: String, tool: String) -> PendingApproval {
        PendingApproval(action: ProposedAction(kind: .other, summary: summary, target: tool,
                                               detail: ["tool": tool, "__replay_tool": tool,
                                                        "__replay_input": "{\"action\":\"start\"}"]),
                        urgent: false, reason: DecisionGate.asksFirstReason)
    }

    func testTheQueueSplitsWhatCanBeApprovedFromWhatWouldBeTurnedDown() {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        var on = false
        queue.foundryEnabled = { on }
        _ = queue.enqueue(card(note, tool: "create_note"))
        _ = queue.enqueue(card(cycle, tool: "foundry_upgrade_cycle"))
        XCTAssertEqual(JaxApprovalCount.titles(in: queue), [note])
        XCTAssertEqual(JaxApprovalCount.turnedDownTitles(in: queue), [cycle])
        on = true
        XCTAssertEqual(JaxApprovalCount.titles(in: queue), [note, cycle])
        XCTAssertEqual(JaxApprovalCount.turnedDownTitles(in: queue), [])
    }

    func testATurnedDownCardIsItsOwnRowAndNeverWaitingForAnOK() throws {
        let items = BriefingEngine.waitingItems(approvals: [note], turnedDown: [cycle], proposals: ["Open chat faster"])
        XCTAssertEqual(items.map(\.kind), [.approvalPending, .approvalTurnedDown, .proposalPending])
        let row = try XCTUnwrap(items.first { $0.kind == .approvalTurnedDown })
        XCTAssertEqual(row.title, "1 would be turned down if approved now")
        XCTAssertEqual(row.count, 1)
        XCTAssertEqual(row.names, [cycle])
        let lines = BriefingEngine.sourceLines(items, connected: true)
        XCTAssertTrue(lines.contains("- 1 would be turned down if approved now:\n  - Start a self-upgrade cycle"), lines)
    }

    /// On, under and over: no card, one, two and three turned down.
    func testTheComposedBriefingAsksOnlyForOKsThatCanBeGiven() {
        let spoken = BriefingEngine.fallbackSpoken(slot: .morning, items:
            BriefingEngine.waitingItems(approvals: [note], turnedDown: [cycle], proposals: ["Open chat faster"]))
        XCTAssertTrue(spoken.contains("1 thing is waiting for your OK in Approvals: Save your note \"The gate code is on the fridge\". 1 self-upgrade proposal is waiting for your review in Self-Upgrade: Open chat faster."), spoken)
        XCTAssertTrue(spoken.contains("Start a self-upgrade cycle is in Approvals too, but it would be turned down if approved now; its card says why."), spoken)
        XCTAssertFalse(spoken.contains("3 things"), spoken)

        let none = BriefingEngine.fallbackSpoken(slot: .morning, items:
            BriefingEngine.waitingItems(approvals: [note], turnedDown: [], proposals: []))
        XCTAssertFalse(none.contains("turned down"), none)
        let two = BriefingEngine.fallbackSpoken(slot: .morning, items:
            BriefingEngine.waitingItems(approvals: [], turnedDown: [cycle, "Start a deep self-upgrade cycle."], proposals: []))
        XCTAssertTrue(two.contains("Start a self-upgrade cycle and Start a deep self-upgrade cycle are in Approvals, but they would be turned down if approved now; their cards say why."), two)
        XCTAssertFalse(two.contains("waiting for your OK"), two)
        let three = BriefingEngine.fallbackSpoken(slot: .morning, items:
            BriefingEngine.waitingItems(approvals: [], turnedDown: ["A.", "B.", "C."], proposals: []))
        XCTAssertTrue(three.contains("A, B, and 1 more are in Approvals, but they would be turned down if approved now; their cards say why."), three)
    }
}
