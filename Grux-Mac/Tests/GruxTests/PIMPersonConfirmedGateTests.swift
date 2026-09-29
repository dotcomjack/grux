import XCTest
@testable import Grux

// Operator ruling A10b: a note or calendar event the person just asked for
// needs ONE confirmation, the card with its 5 s undo. Before, the card ran
// and then the universal Jax gate queued the same tool for a second approval
// ("Run tool 'create_event' (unclassified side effect)."). What an agent or a
// schedule started must still wait in the queue, and the pass the card uses
// must be good for that one dispatch only.
@MainActor
final class PIMPersonConfirmedGateTests: XCTestCase {

    private let note: [String: Any] = ["title": "PIMPersonConfirmedGateTests", "body": "buy oat milk"]

    override func tearDown() async throws {
        for item in ApprovalQueue.shared.items where item.state == .pending
            && item.action.detail["__replay_input"]?.contains("PIMPersonConfirmedGateTests") == true {
            ApprovalQueue.shared.skip(item.id)
        }
        try await super.tearDown()
    }

    private func gateSays(_ name: String, _ input: [String: Any]) async -> Bool {
        if case .proceed = await JaxToolGate.evaluate(name: name, input: input) { return true }
        return false
    }

    /// Asks the gate, from inside the card's dispatch, what it would do.
    private func proceedsThroughCard(_ name: String, personAsked: Bool) async -> Bool {
        var proceeded = false
        _ = await PIMConfirmationController.dispatch(
            name: name, input: note, personAsked: personAsked,
            via: { n, i in
                proceeded = await self.gateSays(n, i)
                return "ok"
            })
        return proceeded
    }

    func test_personAsked_noteAndEvent_runWithoutASecondApproval() async {
        let noteRuns = await proceedsThroughCard("create_note", personAsked: true)
        XCTAssertTrue(noteRuns, "the card was the confirmation; the note must not queue again")
        let eventRuns = await proceedsThroughCard("create_event", personAsked: true)
        XCTAssertTrue(eventRuns, "the card was the confirmation; the event must not queue again")
    }

    func test_agentAsked_stillWaitsForApproval() async {
        let runs = await proceedsThroughCard("create_event", personAsked: false)
        XCTAssertFalse(runs, "an agent's calendar event must still wait in the approval queue")
    }

    func test_thePassIsGoodForOneDispatchOnly() async {
        var seen: [String: Any] = [:]
        _ = await PIMConfirmationController.dispatch(
            name: "create_event", input: note, personAsked: true,
            via: { _, i in seen = i; return "ok" })
        let replayed = await gateSays("create_event", seen)
        XCTAssertFalse(replayed, "the same input replayed after the dispatch must be gated again")
        let forged = await gateSays("create_event", note.merging(["__approved_id": UUID().uuidString]) { a, _ in a })
        XCTAssertFalse(forged, "a made-up token must never pass")
    }
}
