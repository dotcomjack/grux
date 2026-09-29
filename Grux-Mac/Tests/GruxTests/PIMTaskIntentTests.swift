import XCTest
@testable import Grux

// Pins the task intent on the deterministic PIM path (A28). On the local
// route the model answered "add a task: X" with a made-up "I've added it"
// instead of calling add_task whenever the thread had any earlier turn
// (0 of 4 with one harmless prior pair, 4 of 4 tool calls with none), so a
// plain task ask never reached the task stack. The words have one reading,
// so they take the same card, undo window and dispatchTool path as a note.
final class PIMTaskIntentTests: XCTestCase {

    func test_addATaskColon() {
        let m = PIMIntents.match("add a task: water the office plants")
        XCTAssertEqual(m?.kind, .addTask)
        XCTAssertEqual(m?.slots.title, "water the office plants")
    }

    func test_addATaskTo() {
        XCTAssertEqual(PIMIntents.match("add a task to water the plants")?.slots.title, "water the plants")
        XCTAssertEqual(PIMIntents.match("add a new task, draft the release notes")?.slots.title,
                       "draft the release notes")
    }

    func test_remindMeTo() {
        let m = PIMIntents.match("remind me to call the plumber")
        XCTAssertEqual(m?.kind, .addTask)
        XCTAssertEqual(m?.slots.title, "call the plumber")
    }

    func test_addThingToMyTasks() {
        for u in ["add review the loop ledger to my tasks",
                  "put review the loop ledger on my to-do list",
                  "add review the loop ledger to my task list"] {
            let m = PIMIntents.match(u)
            XCTAssertEqual(m?.kind, .addTask, u)
            XCTAssertEqual(m?.slots.title, "review the loop ledger", u)
        }
    }

    func test_preambleIsStripped() {
        XCTAssertEqual(PIMIntents.match("hey grux, can you add a task: back up the Mini")?.slots.title,
                       "back up the Mini")
    }

    func test_notTaskAsks() {
        for u in ["remind me what I was doing",
                  "what tasks do I have",
                  "add a task",
                  "add a task:",
                  "remind me to",
                  "did you add a task to water the plants?",
                  "can I add a task to water the plants?",
                  "I need to add a task to water the plants at some point"] {
            XCTAssertNotEqual(PIMIntents.match(u)?.kind, .addTask, "should not be a task: \(u)")
        }
    }

    func test_otherKindsKeepTheirWords() {
        XCTAssertEqual(PIMIntents.match("add lunch with Sarah to my calendar Friday at 1pm")?.kind, .addToCalendar)
        XCTAssertEqual(PIMIntents.match("take a note to remind me to call the bank")?.kind, .takeNote)
    }

    func test_planDispatchesAddTask() throws {
        let plan = try XCTUnwrap(PIMIntents.plan(for: "add a task: water the office plants"))
        XCTAssertEqual(plan.toolName, "add_task")
        XCTAssertEqual(plan.toolInput?["title"] as? String, "Water the office plants")
        XCTAssertEqual(plan.toolInput?["priority"] as? String, "next")
        XCTAssertTrue(plan.requiresUndoWindow)
        XCTAssertEqual(plan.cardTitle, "Water the office plants")
        XCTAssertEqual(plan.spokenAck, "Added to your tasks: water the office plants.")
        XCTAssertEqual(plan.kind.cardKindLabel, "TASK")
    }

    func test_chatRouteTakesIt() {
        XCTAssertEqual(ChatIntentClassifier.pimRoute(utterance: "add a task: water the office plants")?.kind, .addTask)
    }

    func test_addTaskNeedsNoApproval() {
        // The card is the one confirmation; add_task must not also queue in Jax.
        XCTAssertTrue(JaxToolGate.safeReadOnlyTools.contains("add_task"))
    }
}
