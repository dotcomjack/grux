import XCTest
@testable import Grux

// Pins the task actions on the deterministic PIM path (A28b). A28 moved
// "add a task" off the local model; the same measurement on the other task
// tools (qwen2.5:7b, the captured 30-message thread) gave 0 of 9 tool calls
// for "mark X as done", "delete the task X" and "focus on the task X": the
// model answered "Marked as complete" and nothing changed. These words have
// one reading, so they take the card, the undo window and dispatchTool.
final class PIMTaskActionIntentTests: XCTestCase {

    func test_completeAsks() {
        for (u, title) in [("mark water the office plants as done", "water the office plants"),
                           ("mark water the office plants complete", "water the office plants"),
                           ("mark the task \"back up the Mini\" as finished", "back up the Mini"),
                           ("check off water the office plants", "water the office plants"),
                           ("cross off the task back up the Mini", "back up the Mini"),
                           ("complete the task water the office plants", "water the office plants"),
                           ("hey grux, please mark back up the Mini done", "back up the Mini")] {
            let m = PIMIntents.match(u)
            XCTAssertEqual(m?.kind, .completeTask, u)
            XCTAssertEqual(m?.slots.title, title, u)
        }
    }

    func test_removeAsks() {
        for (u, title) in [("delete the task water the office plants", "water the office plants"),
                           ("remove task back up the Mini", "back up the Mini"),
                           ("scratch the task water the office plants", "water the office plants"),
                           ("remove water the office plants from my tasks", "water the office plants"),
                           ("take back up the Mini off my to-do list", "back up the Mini"),
                           ("drop water the office plants from the task list", "water the office plants")] {
            let m = PIMIntents.match(u)
            XCTAssertEqual(m?.kind, .removeTask, u)
            XCTAssertEqual(m?.slots.title, title, u)
        }
    }

    func test_focusAsks() {
        for (u, title) in [("focus on the task water the office plants", "water the office plants"),
                           ("make back up the Mini my top priority", "back up the Mini"),
                           ("make the task water the office plants my current focus", "water the office plants")] {
            let m = PIMIntents.match(u)
            XCTAssertEqual(m?.kind, .focusTask, u)
            XCTAssertEqual(m?.slots.title, title, u)
        }
    }

    func test_notTaskActions() {
        for u in ["did you mark water the office plants as done?",
                  "is back up the Mini done",
                  "mark my words",
                  "mark as done",
                  "focus on the release",
                  "remove lunch from my calendar",
                  "delete the task",
                  "I should remove water the office plants from my tasks at some point",
                  "can I check off water the office plants?",
                  "focus",
                  "mark it as done",
                  "delete that task"] {
            let kind = PIMIntents.match(u)?.kind
            XCTAssertFalse([PIMIntentKind.completeTask, .removeTask, .focusTask].contains(kind),
                           "should not be a task action: \(u) -> \(String(describing: kind))")
        }
    }

    func test_otherKindsKeepTheirWords() {
        XCTAssertEqual(PIMIntents.match("take a note to mark the invoice as done")?.kind, .takeNote)
        XCTAssertEqual(PIMIntents.match("add a task: check off the audit items")?.kind, .addTask)
    }

    func test_plansDispatchTheTaskTools() throws {
        let done = try XCTUnwrap(PIMIntents.plan(for: "mark water the office plants as done"))
        XCTAssertEqual(done.toolName, "complete_task")
        XCTAssertEqual(done.toolInput?["match"] as? String, "water the office plants")
        XCTAssertEqual(done.cardTitle, "Water the office plants")
        XCTAssertEqual(done.spokenAck, "Marking done: water the office plants.")

        let gone = try XCTUnwrap(PIMIntents.plan(for: "delete the task water the office plants"))
        XCTAssertEqual(gone.toolName, "remove_task")
        XCTAssertEqual(gone.toolInput?["match"] as? String, "water the office plants")
        XCTAssertEqual(gone.spokenAck, "Removing from your tasks: water the office plants.")

        let now = try XCTUnwrap(PIMIntents.plan(for: "focus on the task back up the Mini"))
        XCTAssertEqual(now.toolName, "focus_on_task")
        XCTAssertEqual(now.toolInput?["match"] as? String, "back up the Mini")
        XCTAssertEqual(now.spokenAck, "Focusing on: back up the Mini.")

        for plan in [done, gone, now] {
            XCTAssertTrue(plan.requiresUndoWindow, plan.kind.rawValue)
            XCTAssertEqual(plan.kind.cardKindLabel, "TASK", plan.kind.rawValue)
            XCTAssertEqual(plan.kind.rawValue, plan.toolName, "kind names its tool")
            // The card is the one confirmation (A10b): no second approval in Jax.
            XCTAssertTrue(JaxToolGate.safeReadOnlyTools.contains(plan.toolName ?? ""), plan.kind.rawValue)
        }
    }

    func test_chatRouteTakesThem() {
        XCTAssertEqual(ChatIntentClassifier.pimRoute(utterance: "mark water the office plants as done")?.kind, .completeTask)
        XCTAssertEqual(ChatIntentClassifier.pimRoute(utterance: "delete the task water the office plants")?.kind, .removeTask)
        XCTAssertEqual(ChatIntentClassifier.pimRoute(utterance: "focus on the task water the office plants")?.kind, .focusTask)
    }
}
