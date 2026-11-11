import XCTest
@testable import Grux

/// Wave 67 round 1 P2-4: with offline mode on, `deep_research` came back refused,
/// the model wrote nothing, and the bubble read "Okay." with nothing started and
/// no reason. An empty reply after a call that was refused or failed, with nothing
/// waiting and no write done, says what happened instead.
@MainActor
final class EmptyReplyAfterARefusalTests: XCTestCase {
    private let refused: ActionClaimGuard.ToolResult = ("deep_research", ["question": "espresso machines"],
        "refused: Not searching: offline mode is on, and deep research sends your question to Brave Search.")

    func testARefusedCallIsNamed() {
        let empty = ActionClaimGuard.emptyReply(results: [refused])
        XCTAssertEqual(empty, ToolReplyCopy.forPerson(tool: refused.tool, input: refused.input, result: refused.result))
        XCTAssertTrue(empty.contains("offline mode is on"), empty)
        XCTAssertFalse(empty.lowercased().hasPrefix("okay"), empty)
        XCTAssertEqual(ActionClaimGuard.vet(reply: empty, route: "local", results: [refused],
                                            ask: "Run a deep research report on espresso machines.").text, empty)
        XCTAssertEqual(ActionClaimGuard.vet(reply: empty, route: "anthropic", results: [refused]).text, empty)
    }

    func testAFailedCallIsNamedReadOrWrite() {
        for r: ActionClaimGuard.ToolResult in [("create_note", ["title": "x"], "error: the disk is full"),
                                               ("search_web", ["query": "x"], "error: the request timed out")] {
            let empty = ActionClaimGuard.emptyReply(results: [r])
            XCTAssertEqual(empty, ToolReplyCopy.forPerson(tool: r.tool, input: r.input, result: r.result), r.tool)
            XCTAssertNotEqual(empty, "Okay.", r.tool)
        }
    }

    /// Wave 67 round 2 P2-2: every result that says nothing was done is named,
    /// whatever its case, not only "refused:" and "error:".
    func testEveryNotDoneResultIsNamed() {
        let screen: ActionClaimGuard.ToolResult = ("control_screen", ["action": "click"],
            "skipped: screen control is off. Ask the user to turn on Screen control in Settings.")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [screen]), "I did not do that: screen control is off.")
        let music: ActionClaimGuard.ToolResult = ("music_play", [:], "ERROR: Music.app is not running - launch it first.")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [music]),
                       ToolReplyCopy.forPerson(tool: music.tool, input: music.input, result: "error: Music.app is not running - launch it first."))
        let busy: ActionClaimGuard.ToolResult = ("compact_thread", [:], "busy")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [busy]), "That is already running. Try again in a moment.")
        let unconfirmed: ActionClaimGuard.ToolResult = ("control_screen", [:],
            "unconfirmed: clicked Send, but I could not confirm the effect: no change seen. Do NOT blindly repeat this action")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [unconfirmed]), "I tried that, but I could not confirm it worked.")
        for raw in ["miss: 'x' not in the local owned library.", "noop: a compaction is already running",
                    "not_found: no workday log saved for 2026-11-08", "unmatched: nothing in Mail matched Send.",
                    "skipped: classifier unavailable (missing key or LLM error) - left folder unchanged",
                    "skipped: stage is disabled in settings (config.stageEnabled = false)", "failed: no", "(no result)"] {
            let r: ActionClaimGuard.ToolResult = ("some_tool", [:], raw)
            XCTAssertEqual(ActionClaimGuard.emptyReply(results: [r]), "That did not happen, so nothing was changed.", raw)
        }
    }

    /// Wave 67 round 3 P2-2: a lookup that ran and found nothing did happen; it
    /// keeps today's reply. Only a read's failure or refusal is named.
    func testALookupThatFoundNothingIsNotANonEvent() {
        for r: ActionClaimGuard.ToolResult in [("list_tasks", [:], "(no active tasks)"),
                                               ("read_workday_log", [:], "not_found: no workday log saved for 2026-11-08"),
                                               ("get_current_activity", [:], "unknown (no prior app seen)"),
                                               ("search_notes", ["query": "x"], "(no notes matched x)"),
                                               ("list_events", [:], "(no events between today and tomorrow)")] {
            XCTAssertEqual(ActionClaimGuard.emptyReply(results: [r]), "Okay.", r.result)
        }
        let failed: ActionClaimGuard.ToolResult = ("search_web", ["query": "x"], "error: the request timed out")
        XCTAssertNotEqual(ActionClaimGuard.emptyReply(results: [failed]), "Okay.")
    }

    /// The same refusal on every hop is one line.
    func testARepeatedRefusalIsSaidOnce() {
        let empty = ActionClaimGuard.emptyReply(results: [refused, refused, refused])
        XCTAssertEqual(empty, ToolReplyCopy.forPerson(tool: refused.tool, input: refused.input, result: refused.result))
    }

    /// A wait still comes first, and a write that was done keeps today's reply.
    func testAWaitOrADoneWriteKeepsItsReply() {
        let pending: ActionClaimGuard.ToolResult = ("create_note", ["title": "y"],
            "pending: this is waiting for your OK in Approvals. Nothing is sent or changed until you approve it.")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [refused, pending]),
                       ActionClaimGuard.waitingLines([pending]).joined(separator: " "))
        let done: ActionClaimGuard.ToolResult = ("create_note", ["title": "z"], "ok: saved")
        // D209: a done write is said ("Saved your note ..."), no longer "Okay.".
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [refused, done]), "Saved your note \"z\".")
        let read: ActionClaimGuard.ToolResult = ("list_tasks", [:], "error: water the ferns")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [("list_tasks", [:], "pending: water the ferns")]), "Okay.")
        XCTAssertNotEqual(ActionClaimGuard.emptyReply(results: [read]), "Okay.")
    }
}
