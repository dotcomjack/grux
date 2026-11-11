import XCTest
@testable import Grux

/// D193: one research ask on grux-local:2b made five identical approval cards,
/// because the model called `deep_research` again on every hop after reading
/// "pending". A later hop's repeat of a call already waiting makes no new card.
@MainActor
final class RepeatedPendingCallsTests: XCTestCase {

    private let pending = "pending: this is waiting for your OK in Approvals. Nothing is sent or changed until you approve it."
    private let question: [String: Any] = ["question": "What is the history of espresso machines?"]

    /// The live turn, hop by hop: one card, and the second hop ends the turn.
    func testTheEspressoTurnMakesOneCard() {
        var calls = RepeatedPendingCalls()
        XCTAssertFalse(calls.isRepeat(tool: "deep_research", input: question))
        calls.record(tool: "deep_research", input: question, result: pending)
        XCTAssertFalse(calls.closeHop(), "the first hop asked something new")
        XCTAssertTrue(calls.isRepeat(tool: "deep_research", input: question))
        XCTAssertTrue(calls.closeHop(), "a hop of only repeats ends the turn")
    }

    func testKeyOrderDoesNotMakeANewCall() {
        var calls = RepeatedPendingCalls()
        _ = calls.isRepeat(tool: "compose_email", input: ["to": "sam@example.com", "body": "hi"])
        calls.record(tool: "compose_email", input: ["to": "sam@example.com", "body": "hi"], result: pending)
        _ = calls.closeHop()
        XCTAssertTrue(calls.isRepeat(tool: "compose_email", input: ["body": "hi", "to": "sam@example.com"]))
    }

    /// Two at once in one hop were both asked for: neither is folded.
    func testTwoIdenticalCallsInOneHopAreBothDispatched() {
        var calls = RepeatedPendingCalls()
        XCTAssertFalse(calls.isRepeat(tool: "compose_email", input: ["to": "sam@example.com"]))
        calls.record(tool: "compose_email", input: ["to": "sam@example.com"], result: pending)
        XCTAssertFalse(calls.isRepeat(tool: "compose_email", input: ["to": "sam@example.com"]))
        calls.record(tool: "compose_email", input: ["to": "sam@example.com"], result: pending)
        XCTAssertFalse(calls.closeHop())
    }

    func testADifferentInputOrToolIsNewWork() {
        var calls = RepeatedPendingCalls()
        _ = calls.isRepeat(tool: "deep_research", input: question)
        calls.record(tool: "deep_research", input: question, result: pending)
        _ = calls.closeHop()
        XCTAssertFalse(calls.isRepeat(tool: "deep_research", input: ["question": "Who made the first espresso machine?"]))
        XCTAssertFalse(calls.isRepeat(tool: "create_note", input: question))
        XCTAssertFalse(calls.closeHop())
    }

    /// One repeat beside one new call: the new call runs and the turn goes on.
    func testARepeatBesideNewWorkDoesNotEndTheTurn() {
        var calls = RepeatedPendingCalls()
        _ = calls.isRepeat(tool: "deep_research", input: question)
        calls.record(tool: "deep_research", input: question, result: pending)
        _ = calls.closeHop()
        XCTAssertTrue(calls.isRepeat(tool: "deep_research", input: question))
        XCTAssertFalse(calls.isRepeat(tool: "add_task", input: ["title": "Buy beans"]))
        XCTAssertFalse(calls.closeHop())
    }

    /// Only a call that waits is folded as waiting: a refused or failed call, and
    /// a read whose text happens to start "pending:", run again when asked again.
    /// D209: a done write is folded too, as done (`RepeatedDoneWritesTests`).
    func testOnlyAWaitingWriteIsFolded() {
        var done = RepeatedPendingCalls()
        _ = done.isRepeat(tool: "add_task", input: question)
        done.record(tool: "add_task", input: question, result: "ok: added 'Buy beans' (NEXT)")
        _ = done.closeHop()
        XCTAssertTrue(done.isRepeat(tool: "add_task", input: question))
        XCTAssertEqual(done.foldedResult(tool: "add_task", input: question), RepeatedPendingCalls.doneResult)
        for (tool, result) in [("deep_research", "refused: offline mode is on."),
                               ("deep_research", "error: Brave Search API key not set"),
                               ("list_tasks", "pending: call the plumber")] {
            var calls = RepeatedPendingCalls()
            _ = calls.isRepeat(tool: tool, input: question)
            calls.record(tool: tool, input: question, result: result)
            _ = calls.closeHop()
            XCTAssertFalse(calls.isRepeat(tool: tool, input: question), "\(tool) \(result)")
        }
    }

    /// A refused call beside a repeat is still counted, so the model hears the refusal.
    func testEveryCallInTheHopIsCounted() {
        var calls = RepeatedPendingCalls()
        _ = calls.isRepeat(tool: "deep_research", input: question)
        calls.record(tool: "deep_research", input: question, result: pending)
        _ = calls.closeHop()
        XCTAssertFalse(calls.isRepeat(tool: "not_offered_here", input: [:]))
        XCTAssertTrue(calls.isRepeat(tool: "deep_research", input: question))
        XCTAssertFalse(calls.closeHop())
    }

    /// No calls at all is not "only repeats".
    func testAnEmptyHopDoesNotEndAnything() {
        var calls = RepeatedPendingCalls()
        XCTAssertFalse(calls.closeHop())
    }

    /// The fold reads as pending everywhere a pending result is read.
    func testTheRepeatResultReadsAsPending() {
        XCTAssertTrue(RepeatedPendingCalls.repeatResult.hasPrefix("pending:"))
        XCTAssertEqual(ToolReplyCopy.forPerson(tool: "deep_research", input: question, result: RepeatedPendingCalls.repeatResult),
                       ToolReplyCopy.forPerson(tool: "deep_research", input: question, result: pending))
    }

    /// The chat loop asks before it dispatches, records what came back, and
    /// ends the turn on a hop of only repeats.
    func testTheChatLoopUsesIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let loop = try XCTUnwrap(chat.range(of: "hopLoop: while hops < maxToolHops"))
        let body = String(chat[loop.lowerBound...].prefix(9000))
        let ask = try XCTUnwrap(body.range(of: "repeats.isRepeat(tool: use.name, input: use.input)"))
        let notOffered = try XCTUnwrap(body.range(of: "Self.notOfferedRefusal(use.name, offered: tools)"))
        XCTAssertLessThan(ask.lowerBound, notOffered.lowerBound, "every call is counted, offered or not")
        let dispatch = try XCTUnwrap(body.range(of: "await Self.dispatchTool(name: use.name, input: use.input)"))
        XCTAssertLessThan(ask.lowerBound, dispatch.lowerBound)
        XCTAssertTrue(body.contains("repeats.record(tool: use.name, input: use.input, result: raw)"))
        XCTAssertTrue(body.contains("if repeats.closeHop()"))
    }
}
