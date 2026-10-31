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

    /// D28, live 2026-10-28 on qwen3.5:4b: "Grux, upgrade yourself" called
    /// foundry_upgrade_cycle, the gate queued it, and the reply was "Got it.
    /// You're good to go." while it sat waiting. The claim check runs as it always
    /// did; then every write still waiting is named by Grux in its own paragraph,
    /// opening "Not done yet", and the model's text is otherwise left alone.
    private let upgrade: ActionClaimGuard.ToolResult =
        ("foundry_upgrade_cycle", ["action": "start"], JaxToolGate.pendingResult(goesOutAs: nil))
    private let upgradeLine = "That request is waiting for your OK in Approvals. Nothing happens until you tap it."
    private let noteLine = "Your note is waiting for your OK in Approvals. Nothing is saved until you tap it."
    private let emailLine = "Your email to sam@example.com is waiting for your OK in Approvals. Nothing is sent until you tap it."
    private let note: ActionClaimGuard.ToolResult =
        ("create_note", ["title": "Groceries"], JaxToolGate.pendingResult(goesOutAs: nil))
    private let email: ActionClaimGuard.ToolResult =
        ("compose_email", ["to": "sam@example.com"], JaxToolGate.pendingResult(goesOutAs: nil))
    private let milk: ActionClaimGuard.ToolResult = ("add_task", ["title": "milk"], "ok: added task 'milk' id=1")

    /// "Not done yet: " and the line with its first letter lowered, as a paragraph.
    private func after(_ reply: String, _ lines: String...) -> String {
        let joined = lines.joined(separator: " ")
        return reply + "\n\nNot done yet: " + joined.prefix(1).lowercased() + joined.dropFirst()
    }

    func testAWaitingWriteIsNamedWhateverTheReplySays() {
        for reply in ["Got it. You're good to go.", "Sure thing!", "Okay.", "On it"] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [upgrade])
            XCTAssertTrue(out.replaced, reply)
            XCTAssertEqual(out.text, after(reply, upgradeLine), reply)
        }
        XCTAssertEqual(ActionClaimGuard.vet(reply: "  ", route: "local", results: [upgrade]).text, upgradeLine)
    }

    /// No wording skips the paragraph (review rounds 4 and 5 found each of these
    /// standing under a wording rule), and the model's words are not touched.
    func testNoWordingSkipsTheWaitingLine() {
        let cases: [(String, ActionClaimGuard.ToolResult, String)] = [
            ("Got your OK, it's on its way to Sam.", email, emailLine),
            ("Approved. You're good to go.", upgrade, upgradeLine),
            ("Done, no approval needed.", note, noteLine),
            ("No need to approve it, it's on its way to Sam.", email, emailLine),
            ("Nothing is waiting in Approvals, your email to Sam went out.", email, emailLine),
            ("- Saved your note \"Groceries\".", note, noteLine),
            ("The Eiffel Tower was opened in 1889.", note, noteLine),
        ]
        for (reply, result, line) in cases {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [result])
            XCTAssertTrue(out.replaced, reply)
            XCTAssertEqual(out.text, after(reply, line), reply)
        }
    }

    /// Rounds 6 and 7: the paragraph is never inside a code block, with fences read
    /// the way the renderer reads them (a line that starts with three backticks).
    func testTheLineIsNeverInsideACodeBlock() {
        let shell: ActionClaimGuard.ToolResult = ("shell_run", ["command": "make"], JaxToolGate.pendingResult(goesOutAs: nil))
        let line = "The command `make` is waiting for your OK in Approvals. Nothing happens until you tap it."
        let cases: [(String, String)] = [
            ("I'll run this:\n```\nmake\n```", "I'll run this:\n```\nmake\n```"),
            ("I'll run this:\n```\nmake", "I'll run this:\n```\nmake\n```"),
            ("```\nmake```", "```\nmake```\n```"),
            ("Type ``` to start a code block.", "Type ``` to start a code block."),
        ]
        for (reply, body) in cases {
            XCTAssertEqual(ActionClaimGuard.vet(reply: reply, route: "local", results: [shell]).text, after(body, line), reply)
        }
    }

    /// Rounds 6 and 7: different writes that would read the same are all accounted for.
    func testDifferentWritesThatReadTheSameAreAllNamed() {
        let errands: ActionClaimGuard.ToolResult = ("create_note", ["title": "Errands"], JaxToolGate.pendingResult(goesOutAs: nil))
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Got it.", route: "local", results: [note, errands]).text,
                       after("Got it.", noteLine, "Your note \"Errands\" is also waiting for your OK in Approvals."))
        let research: ActionClaimGuard.ToolResult = ("deep_research", ["q": "x"], JaxToolGate.pendingResult(goesOutAs: nil))
        let render: ActionClaimGuard.ToolResult = ("creative_render_image", ["p": "y"], JaxToolGate.pendingResult(goesOutAs: nil))
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Got it.", route: "local", results: [upgrade, research, render]).text,
                       after("Got it.", upgradeLine, "That request and 1 more like it are also waiting for your OK in Approvals."))
    }

    /// A reply that already carries Grux's own line word for word gets nothing added.
    func testTheLineIsNotAddedTwice() {
        let out = ActionClaimGuard.vet(reply: "Okay. \(noteLine)", route: "local", results: [note])
        XCTAssertFalse(out.replaced)
        XCTAssertEqual(out.text, "Okay. \(noteLine)")
    }

    /// Round 2 P1: a claim no result backs is the claim check's, as before: the
    /// person gets the waiting line in its place, once. One it cannot see is
    /// followed by the "Not done yet" paragraph.
    func testAClaimWhileTheWriteWaitsIsCorrected() {
        for reply in ["I've saved your note. You'll find it in Approvals.",
                      "approved: saved your note",
                      "Queued. Approve it when you're ready."] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [note])
            XCTAssertTrue(out.replaced, reply)
            XCTAssertEqual(out.text, noteLine, reply)
        }
        XCTAssertEqual(ActionClaimGuard.vet(reply: "I've sent your email. It was approved.", route: "local", results: [email]).text,
                       emailLine)
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Your email was sent.", route: "local", results: [email]).text,
                       after("Your email was sent.", emailLine))
    }

    /// Rounds 3, 6, 7 and 8: beside a completed write the reply is kept whole (an
    /// answer, the completed write's own words) and "Not done yet" names what waits.
    func testBesideACompletedWriteNotDoneYetNamesWhatWaits() {
        let reply = "Added \"milk\" to your tasks and saved your note. You'll find both in Approvals."
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [milk, note])
        XCTAssertTrue(out.replaced)
        XCTAssertEqual(out.text, after(reply, noteLine))

        let events: ActionClaimGuard.ToolResult = ("list_events", [:], "Dentist Thu 3 PM")
        let answer = "You have the dentist at 3 PM on Thursday. I've added milk to your tasks."
        XCTAssertEqual(ActionClaimGuard.vet(reply: answer, route: "local", results: [events, milk, note]).text,
                       after(answer, noteLine))
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Here you go.", route: "local", results: [milk, note]).text,
                       after("Here you go.", noteLine))
    }

    /// Round 7: a tool's model-facing output never becomes the reply.
    func testToolOutputNeverBecomesTheReply() {
        let focus: ActionClaimGuard.ToolResult = ("run_focus_check_now", [:],
            "fresh check complete (just now)\nverdict: on task\napp: Xcode\nwindow: Grux\nrationale: editing")
        let reply = "You're on task in Xcode. I've saved your note."
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [focus, note])
        XCTAssertEqual(out.text, after(reply, noteLine))
        XCTAssertFalse(out.text.contains("verdict:"))
    }

    /// Every waiting write is named once, in order; the same write twice is one wait.
    func testEveryWaitingWriteIsNamedOnce() {
        let out = ActionClaimGuard.vet(reply: "Got it.", route: "local", results: [note, email, note])
        XCTAssertEqual(out.text, after("Got it.", noteLine, emailLine))
    }

    /// Round 5: what else happened in the turn is kept: a failed write said in the
    /// reply, a read's answer, and a waiting command named by its subject.
    func testWhatElseHappenedIsKept() {
        let laundry: ActionClaimGuard.ToolResult = ("complete_task", ["match": "laundry"], "error: no active task matched 'laundry'")
        XCTAssertEqual(ActionClaimGuard.vet(reply: "I couldn't find laundry.", route: "local", results: [laundry, email]).text,
                       after("I couldn't find laundry.", emailLine))
        let events: ActionClaimGuard.ToolResult = ("list_events", [:], "Dentist Thu 3 PM")
        XCTAssertEqual(ActionClaimGuard.vet(reply: "You have the dentist at 3 PM on Thursday.", route: "local", results: [events, note]).text,
                       after("You have the dentist at 3 PM on Thursday.", noteLine))
        let shell: [ActionClaimGuard.ToolResult] = [
            ("add_task", ["title": "milk"], "ok: added 'milk' (NEXT)"),
            ("shell_run", ["command": "make"], JaxToolGate.pendingResult(goesOutAs: nil))]
        let make = "The command `make` is waiting for your OK in Approvals. Nothing happens until you tap it."
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Added milk.", route: "local", results: shell).text, after("Added milk.", make))
    }

    /// Round 2 P2: a read whose CONTENT starts with "pending" is not a waiting write.
    func testAReadThatSaysPendingIsNotAWait() {
        for body in ["pending: renew passport", "Pending: renew passport before May"] {
            let read: [ActionClaimGuard.ToolResult] = [("fs_read", ["path": "todo.txt"], body)]
            let out = ActionClaimGuard.vet(reply: "Your list says to renew your passport.", route: "local", results: read)
            XCTAssertFalse(out.replaced, body)
            XCTAssertEqual(out.text, "Your list says to renew your passport.")
        }
    }

    /// Round 9 P2: a read whose text starts "pending:" (any case) is the person's
    /// own text, never "waiting for your OK", on every path: the person line, and
    /// the echo of it a model hands back as its whole reply.
    func testAReadThatSaysPendingIsShownAsWritten() {
        for body in ["Pending: renew passport before May", "pending: renew passport"] {
            let line = ToolReplyCopy.forPerson(tool: "fs_read", input: ["path": "todo.txt"], result: body)
            XCTAssertFalse(line.contains("waiting for your OK"), line)
            XCTAssertTrue(line.lowercased().contains("renew passport"), line)
            let echo = ToolReplyCopy.replacingEcho(reply: body, results: [("fs_read", ["path": "todo.txt"], body)])
            XCTAssertFalse(echo.contains("waiting for your OK"), echo)
        }
        // A write's pending status, in either case, is still the waiting line.
        XCTAssertEqual(ToolReplyCopy.forPerson(tool: "create_note", input: ["title": "Groceries"], result: "Pending: queued"),
                       noteLine)
    }

    /// The cloud route is left alone, waiting write or not.
    func testTheCloudRouteIsUntouchedWithAWaitingWrite() {
        let out = ActionClaimGuard.vet(reply: "Got it.", route: "anthropic", results: [note])
        XCTAssertFalse(out.replaced)
        XCTAssertEqual(out.text, "Got it.")
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
