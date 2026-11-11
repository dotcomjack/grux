import XCTest
@testable import Grux

/// D209 (sense pass 31, live on grux-local:2b, thread 4F88B967): "Thanks! Can
/// you remember that I prefer short answers?" called remember_slang and
/// remember_fact on five hops in a row (the same two calls, ten seconds), and
/// the bubble read "Okay.", so nobody could tell what was kept.
@MainActor
final class RepeatedDoneWritesTests: XCTestCase {

    private let slang: [String: Any] = ["term": "short answers", "meaning": "prefers concise responses"]
    private let fact: [String: Any] = ["fact": "Sam prefers short answers."]

    /// The live turn, hop by hop: hop 3 repeats hop 1's save, so it is not done
    /// again and the turn ends there instead of running to the hop limit.
    func testTheShortAnswersTurnEndsOnTheFirstRepeat() {
        var calls = RepeatedPendingCalls()
        XCTAssertFalse(calls.isRepeat(tool: "remember_slang", input: slang))
        calls.record(tool: "remember_slang", input: slang, result: "ok: saved slang 'short answers' = prefers concise responses")
        XCTAssertFalse(calls.closeHop())
        XCTAssertFalse(calls.isRepeat(tool: "remember_fact", input: fact))
        calls.record(tool: "remember_fact", input: fact, result: "ok: saved fact 'Sam prefers short answers.'")
        XCTAssertFalse(calls.closeHop())
        XCTAssertTrue(calls.isRepeat(tool: "remember_slang", input: ["meaning": "prefers concise responses", "term": "short answers"]))
        XCTAssertEqual(calls.foldedResult(tool: "remember_slang", input: slang), RepeatedPendingCalls.doneResult)
        XCTAssertTrue(calls.closeHop(), "a hop that only repeats done work ends the turn")
    }

    /// The fold reads as done, not as waiting, so no guard calls it a wait.
    func testTheDoneFoldReadsAsDone() {
        XCTAssertTrue(RepeatedPendingCalls.doneResult.hasPrefix("ok:"))
        XCTAssertTrue(ActionClaimGuard.completed(RepeatedPendingCalls.doneResult))
        XCTAssertTrue(ActionClaimGuard.waitingLines([("remember_fact", fact, RepeatedPendingCalls.doneResult)]).isEmpty)
    }

    /// A waiting call keeps its own fold, and two at once in one hop are both done (D46).
    func testWaitingFoldAndSameHopAreUnchanged() {
        var calls = RepeatedPendingCalls()
        _ = calls.isRepeat(tool: "deep_research", input: ["question": "q"])
        calls.record(tool: "deep_research", input: ["question": "q"], result: "pending: waiting for your OK")
        XCTAssertFalse(calls.isRepeat(tool: "add_task", input: ["title": "Buy beans"]))
        calls.record(tool: "add_task", input: ["title": "Buy beans"], result: "ok: added 'Buy beans' (NEXT)")
        XCTAssertFalse(calls.isRepeat(tool: "add_task", input: ["title": "Buy beans"]), "same hop is never folded")
        _ = calls.closeHop()
        XCTAssertTrue(calls.isRepeat(tool: "deep_research", input: ["question": "q"]))
        XCTAssertEqual(calls.foldedResult(tool: "deep_research", input: ["question": "q"]), RepeatedPendingCalls.repeatResult)
        XCTAssertTrue(calls.isRepeat(tool: "add_task", input: ["title": "Buy beans"]))
        XCTAssertEqual(calls.foldedResult(tool: "add_task", input: ["title": "Buy beans"]), RepeatedPendingCalls.doneResult)
    }

    /// A refused or failed write, a read, and every not-done opening run again when asked again.
    func testOnlyAFinishedWriteIsFoldedAsDone() {
        for (tool, result) in [("add_task", "refused: offline mode is on."), ("add_task", "error: the disk is full"),
                               ("add_task", "skipped: stage is disabled"), ("add_task", "unconfirmed: no change seen"),
                               ("add_task", "busy"), ("list_tasks", "ok: 3 tasks"), ("search_notes", "(no notes matched x)")] {
            var calls = RepeatedPendingCalls()
            _ = calls.isRepeat(tool: tool, input: ["title": "x"])
            calls.record(tool: tool, input: ["title": "x"], result: result)
            _ = calls.closeHop()
            XCTAssertFalse(calls.isRepeat(tool: tool, input: ["title": "x"]), "\(tool) \(result)")
        }
    }

    /// The model wrote nothing after saving: the person reads what was kept, once.
    func testAnEmptyReplyAfterASaveSaysWhatWasKept() {
        let results: [ActionClaimGuard.ToolResult] = [
            ("remember_slang", slang, "ok: saved slang 'short answers' = prefers concise responses"),
            ("remember_fact", fact, "ok: saved fact 'Sam prefers short answers.'"),
            ("remember_slang", slang, RepeatedPendingCalls.doneResult),
        ]
        let empty = ActionClaimGuard.emptyReply(results: results)
        XCTAssertEqual(empty, "Got it, I will remember: Sam prefers short answers.")
        XCTAssertEqual(ActionClaimGuard.vet(reply: empty, route: "local", results: results,
                                            ask: "Thanks! Can you remember that I prefer short answers?").text, empty)
        XCTAssertEqual(ToolReplyCopy.problems(in: empty), [], empty)
    }

    func testEachDoneWriteIsSaidOnce() {
        let task: ActionClaimGuard.ToolResult = ("add_task", ["title": "Buy beans"], "ok: added 'Buy beans' (NEXT)")
        let note: ActionClaimGuard.ToolResult = ("create_note", ["title": "Trip"], "ok: saved")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [task, task, note]),
                       "Added \"Buy beans\" to your tasks. Saved your note \"Trip\".")
    }

    /// A wait still comes first; a write with no sentence of its own, a read, and nothing at all keep "Okay.".
    func testOtherEmptyRepliesAreUnchanged() {
        let pending: ActionClaimGuard.ToolResult = ("create_note", ["title": "y"],
            "pending: this is waiting for your OK in Approvals. Nothing is sent or changed until you approve it.")
        let done: ActionClaimGuard.ToolResult = ("remember_fact", fact, "ok: saved fact 'Sam prefers short answers.'")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [done, pending]),
                       ActionClaimGuard.waitingLines([pending]).joined(separator: " "))
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [("remember_slang", slang, "ok: saved slang 'x' = y")]), "Okay.")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: [("list_tasks", [:], "(no active tasks)")]), "Okay.")
        XCTAssertEqual(ActionClaimGuard.emptyReply(results: []), "Okay.")
    }

    /// Every tool named as saying what was done has its own sentence in forPerson.
    func testEveryNamedToolHasItsOwnSentence() {
        for tool in ToolReplyCopy.saysWhatWasDone {
            let line = ToolReplyCopy.forPerson(tool: tool, input: ["title": "Zed", "fact": "Zed", "start": "2026-11-10T09:00:00"],
                                               result: "ok: saved 'Zed'")
            XCTAssertNotEqual(line, ToolReplyCopy.forPerson(tool: "some_other_tool", input: [:], result: "ok: saved 'Zed'"), tool)
        }
    }

    /// The chat loop answers a fold with what the fold says, not a fixed text.
    func testTheChatLoopUsesTheFoldedResult() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        XCTAssertTrue(chat.contains("raw = repeats.foldedResult(tool: use.name, input: use.input)"))
        XCTAssertFalse(chat.contains("raw = RepeatedPendingCalls.repeatResult"))
        XCTAssertTrue(chat.contains("Never for a preference or a fact about the person"))
    }
}
