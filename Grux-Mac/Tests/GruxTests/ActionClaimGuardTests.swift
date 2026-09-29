import XCTest
@testable import Grux

/// A18: on the local route a reply may not say an action happened unless a
/// tool ran in the same turn. Measured 2026-09-27 on qwen2.5:7b, keyless: the
/// ask `ship the groceries tomorrow` got `Shipped the groceries for tomorrow at
/// 3 PM. Track it in the Workflows tab.` with no tool call in wake.log.
@MainActor
final class ActionClaimGuardTests: XCTestCase {

    /// The logged example, word for word.
    func testTheLoggedGroceriesClaimBecomesAnOffer() {
        let reply = "Shipped the groceries for tomorrow at 3 PM. Track it in the Workflows tab."
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [])
        XCTAssertTrue(out.replaced)
        XCTAssertEqual(out.text, ActionClaimGuard.offer)
        XCTAssertEqual(ActionClaimGuard.offer, "I have not done that. Want me to?")
    }

    func testFirstPersonPastTenseClaimsAreCaught() {
        for reply in [
            "I've added it to your calendar for Friday.",
            "I have scheduled the meeting with Sam.",
            "Done! I sent the email to Maria.",
            "Sure. I just created a note called Groceries.",
            "Added to your calendar: dentist at 7:30 PM.",
            "Your reminder has been set for tomorrow.",
            "The event has been added to your calendar.",
            "I went ahead and booked the table.",
            "All done.",
            // Live on the installed build of a80f37ad, 6:53 PM, no tool call:
            "I've noted your grocery run for tomorrow. Should I add this to your calendar now?",
            "I made a note of it.",
            "I jotted that down for you.",
            // Live on the installed build of 7a6dcc60, 8:29 PM, no tool call and
            // no task stored: an interjection before the claim hid it.
            "Sure, I've added \"draft the Grux 3.0 release notes\" to your tasks. Focus on that next?",
            "Okay, I scheduled it for Friday.",
            "Got it, I've saved that.",
            "Of course! I added it.",
            // Live on the installed build of 96fa46fb, 1:34 AM, no tool call: the
            // thread held raw `ok: ...` tool lines and the model copied their shape.
            "ok: noted \"loop replycopy probe groceries\" as a reminder. Anything else?",
            "ok: saved fact 'Trip mentioned'. Anything else you need to remember?",
            "pending: 'create_note' is waiting in Approvals.",
            // Live on the installed build of 6cca5ffe, 4:44 AM, no tool call and
            // no task stored: the assent was joined by a hyphen, not a comma.
            "Got it - I've added \"Write down your thoughts\" to your tasks. When you're ready, just focus on that.",
            "Sure: I scheduled it for Friday.",
            "Okay \u{2013} I saved that.",
            "Absolutely \u{2014} I've booked the table.",
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [])
            XCTAssertTrue(out.replaced, "missed a claim: \(reply)")
            XCTAssertEqual(out.text, ActionClaimGuard.offer, reply)
        }
    }

    /// A tool result in the same turn that says the action completed is what
    /// may back a claim.
    func testAClaimBackedByACompletedResultInTheSameTurnStands() {
        for (reply, results) in [
            ("I've added it to your calendar for Friday.",
             [("create_event", ["title": "Dentist"] as [String: Any],
               "ok: created 'Dentist' Fri Oct 2 3:00 PM to 4:00 PM in calendar 'Home' id=ABC")]),
            ("I've added \"Call Sam\" to your tasks.",
             [("list_tasks", [:], "(no active tasks)"), ("add_task", ["title": "Call Sam"], "ok: added 'Call Sam' (NEXT)")]),
            ("Opened Chrome.", [("open_app", ["name": "Chrome"], "ok: opened Google Chrome")]),
        ] as [(String, [ActionClaimGuard.ToolResult])] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: results)
            XCTAssertFalse(out.replaced, reply)
            XCTAssertEqual(out.text, reply)
        }
    }

    /// RV12: a tool CALL is not a completed action. A write that is waiting in
    /// Approvals licenses nothing; the person reads what did happen.
    func testAQueuedWriteDoesNotLicenseTheClaim() {
        for pending in [JaxToolGate.pendingResult(goesOutAs: nil),
                        "pending: 'create_note' is waiting in the Jax HQ approval queue for the user's one-tap approval. Nothing was sent or changed."] {
            let queued: [ActionClaimGuard.ToolResult] = [("create_note", ["title": "Groceries"], pending)]
            for reply in ["I've saved your note.", "Saved your note \"Groceries\".", "Your note has been saved."] {
                let out = ActionClaimGuard.vet(reply: reply, route: "local", results: queued)
                XCTAssertTrue(out.replaced, "a queued note licensed: \(reply)")
                XCTAssertEqual(out.text, "Your note is waiting for your OK in Approvals. Nothing is saved until you tap it.")
            }
        }
    }

    /// RV12: a read (a search, a listing) says nothing was done.
    func testAReadOnlyResultDoesNotLicenseTheClaim() {
        for results in [
            [("documents_list", ["query": "groceries"] as [String: Any], "(no documents matched)")],
            [("list_tasks", [:], "- [NEXT] Call Sam")],
            [("search_memory", ["query": "groceries"], "ok: 3 memories")],
        ] as [[ActionClaimGuard.ToolResult]] {
            let out = ActionClaimGuard.vet(reply: "I've saved your note.", route: "local", results: results)
            XCTAssertTrue(out.replaced, "a read licensed a claim: \(results[0].tool)")
            XCTAssertEqual(out.text, ActionClaimGuard.offer)
        }
    }

    /// RV12: a write that failed or was refused did not happen either.
    func testAFailedOrRefusedWriteDoesNotLicenseTheClaim() {
        let failed = ActionClaimGuard.vet(
            reply: "I've added it to your calendar.", route: "local",
            results: [("create_event", ["title": "Dentist"], "error: calendar access not granted.")])
        XCTAssertTrue(failed.replaced)
        XCTAssertEqual(failed.text, "That did not go through: Calendar access not granted.")
        let refused = ActionClaimGuard.vet(
            reply: "Done! I sent the email to Maria.", route: "local",
            results: [("slack_send", ["channel": "#general"], "refused: posting outside the house list is off. Nothing was sent or changed.")])
        XCTAssertTrue(refused.replaced)
        XCTAssertTrue(refused.text.hasPrefix("I did not do that."), refused.text)
        let missed = ActionClaimGuard.vet(
            reply: "I've removed it.", route: "local",
            results: [("remove_task", ["match": "cables"], "error: no active task matched 'cables'")])
        XCTAssertEqual(missed.text, "I did not find a task called \"cables\".")
        for out in [failed, refused, missed] {
            XCTAssertEqual(ToolReplyCopy.problems(in: out.text), [], out.text)
        }
    }

    /// Integrated review, P1: a dry run held `open_app`, and `I've opened
    /// Safari` passed because the held line did not open on a not-done word.
    /// The person reads that nothing happened, never a done sentence.
    func testAHeldToolInADryRunDoesNotLicenseTheClaim() {
        let held = JaxToolGate.heldForDryRun(name: "open_app", input: ["name": "Safari"])
        XCTAssertFalse(ActionClaimGuard.completed(held), held)
        for (reply, tool, input) in [
            ("I've opened Safari.", "open_app", ["name": "Safari"]),
            ("Saved your note \"buy milk\".", "create_note", ["title": "buy milk"]),
            ("I've added it to your calendar.", "create_event", ["title": "Dentist"]),
        ] as [(String, String, [String: Any])] {
            let result = JaxToolGate.heldForDryRun(name: tool, input: input)
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [(tool, input, result)])
            XCTAssertTrue(out.replaced, "a held \(tool) licensed: \(reply)")
            XCTAssertTrue(out.text.contains("because this is a dry run"), out.text)
            XCTAssertFalse(ActionClaimGuard.claimsAnAction(out.text), "the guard put back a done sentence: \(out.text)")
            XCTAssertEqual(ToolReplyCopy.problems(in: out.text), [], out.text)
        }
    }

    /// Every tool the gate waves through is sorted into "only looks" or "does
    /// something", so a new safe tool cannot license a claim by being missed.
    func testEverySafeToolIsSortedIntoReadOrAction() {
        let safe = JaxToolGate.safeReadOnlyTools
        XCTAssertGreaterThan(safe.count, 50, "control: the safe list did not load")
        let unsorted = safe.subtracting(ActionClaimGuard.readOnlyTools).subtracting(ActionClaimGuard.localActions)
        XCTAssertEqual(unsorted.sorted(), [], "safe tools with no read or action decision")
        XCTAssertEqual(ActionClaimGuard.readOnlyTools.intersection(ActionClaimGuard.localActions).sorted(), [])
        let stale = ActionClaimGuard.readOnlyTools.union(ActionClaimGuard.localActions).subtracting(safe)
        XCTAssertEqual(stale.sorted(), [], "names that are not on the gate's safe list")
    }

    /// The ruling is for the local route. Cloud replies are untouched.
    func testOtherRoutesAreUntouched() {
        let reply = "Shipped the groceries for tomorrow at 3 PM."
        for route in ["anthropic", "openrouter", ""] {
            let out = ActionClaimGuard.vet(reply: reply, route: route, results: [])
            XCTAssertFalse(out.replaced, route)
            XCTAssertEqual(out.text, reply)
        }
    }

    /// Ordinary answers, offers and questions must pass unchanged.
    func testPlainAnswersOffersAndQuestionsPass() {
        for reply in [
            "Two plus two is four.",
            "Today is Sunday, September 27, 2026.",
            "Want me to add it to your calendar?",
            "I can schedule that for you. Should I?",
            "Have you sent the invoice yet?",
            "I think the meeting was scheduled by Sam last week, based on what you told me.",
            "Set a timer for ten minutes and step away.",
            "If you added the file, the build should pass.",
            "I have not done that. Want me to?",
            "Okay.",
            "Sure, I can add that to your tasks. Want me to?",
            "Okay, I have not added anything yet.",
            "Got it - I can add that to your tasks. Want me to?",
            "Sure: I have not scheduled anything yet.",
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [])
            XCTAssertFalse(out.replaced, "flagged a plain reply: \(reply)")
            XCTAssertEqual(out.text, reply)
        }
    }

    /// The wiring: send() runs the guard on the final text, before the reply is
    /// stored, and holds local speech until the check has run (streamed
    /// sentences would already be spoken by then).
    func testSendRunsTheGuardBeforeTheReplyIsStoredAndSpoken() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let guardSite = try XCTUnwrap(src.range(of: "ActionClaimGuard.vet("), "send() never calls the guard")
        let stored = try XCTUnwrap(src.range(of: "state.appendChat(ChatMessage(role: .assistant, content: finalText))"))
        XCTAssertTrue(guardSite.lowerBound < stored.lowerBound, "the guard runs after the reply is stored")
        XCTAssertTrue(src.contains("guard speakAloud, !holdSpeechForClaimCheck else { return }"),
                      "local replies still stream speech before the claim check")
    }
}
