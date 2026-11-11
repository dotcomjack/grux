import XCTest
@testable import Grux

/// D194, live on grux-local:2b (D193's proof): the model wrote no text before a held
/// `deep_research` call and the reply read "Okay. / Not done yet: that request is
/// waiting for your OK in Approvals.", so Grux seemed to agree to something it had not
/// done. An empty reply with a write waiting this turn is Grux's waiting line alone.
@MainActor
final class EmptyReplyBeforeAWaitTests: XCTestCase {

    private let pending = "pending: this is waiting for your OK in Approvals. Nothing is sent or changed until you approve it."
    private let research: ActionClaimGuard.ToolResult =
        ("deep_research", ["question": "What is the history of espresso machines?"], "pending: this is waiting for your OK in Approvals. Nothing is sent or changed until you approve it.")

    /// The live turn, through the local claim check as ChatService runs it.
    func testTheEspressoTurnOpensOnWhatWaits() {
        let empty = ActionClaimGuard.emptyReply(results: [research])
        let line = ToolReplyCopy.forPerson(tool: research.tool, input: research.input, result: research.result)
        XCTAssertEqual(empty, line)
        XCTAssertFalse(empty.lowercased().hasPrefix("okay"), empty)
        let vetted = ActionClaimGuard.vet(reply: empty, route: "local", results: [research],
                                          ask: "Run a deep research report on the history of espresso machines.",
                                          approvals: ["Start an in-depth research report."])
        XCTAssertEqual(vetted.text, line, "the claim check keeps the line alone, said once")
    }

    /// The cloud route is not vetted, so the line must already be there.
    func testTheCloudRouteGetsTheLineToo() {
        let empty = ActionClaimGuard.emptyReply(results: [research])
        XCTAssertEqual(ActionClaimGuard.vet(reply: empty, route: "anthropic", results: [research]).text, empty)
        XCTAssertTrue(empty.contains("waiting for your OK in Approvals"), empty)
    }

    /// Two different writes waiting: both named, as the claim check names them.
    func testEveryWaitingWriteIsNamed() {
        let note: ActionClaimGuard.ToolResult = ("create_note", ["title": "x"], pending)
        let results = [note, research]
        let empty = ActionClaimGuard.emptyReply(results: results)
        XCTAssertEqual(empty, ActionClaimGuard.waitingLines(results).joined(separator: " "))
        XCTAssertEqual(ActionClaimGuard.vet(reply: empty, route: "local", results: results).text, empty)
    }

    /// Nothing waiting: the empty reply is unchanged, on both sides of the line.
    func testNoWaitKeepsTodaysEmptyReply() {
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: []), "Okay.")
        let read: ActionClaimGuard.ToolResult = ("list_tasks", [:], "pending: water the ferns")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [read]), "Okay.", "a read is never a wait")
        let done: ActionClaimGuard.ToolResult = ("create_note", ["title": "x"], "ok: saved")
        // D209: a done write is said ("Saved your note ..."), no longer "Okay.".
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [done]), "Saved your note \"x\".")
    }

    /// ChatService takes its empty reply from here, not a literal of its own.
    func testChatServiceUsesIt() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("finalText = \"Okay.\""))
        XCTAssertTrue(source.contains("ActionClaimGuard.emptyReply(results: toolResultsThisTurn)"))
    }
}
