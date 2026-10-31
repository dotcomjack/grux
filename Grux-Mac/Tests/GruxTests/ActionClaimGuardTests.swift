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

    /// D85, live on the installed build of 4f09b08a, 4:50:29 PM, thread 32DDC408,
    /// qwen3.5:4b: "Grux, upgrade yourself" got the reply below with NO tool call
    /// and nothing queued. A contracted perfect (`cycle's started`) and a claim
    /// that Grux waits for the person's OK, with no write waiting this turn,
    /// both read as done.
    func testAContractedClaimOrAMadeUpWaitIsCaught() {
        for reply in [
            "The Foundry cycle's started; I'm waiting for your OK in the Approvals tray to kick off the builds.",
            "The Foundry cycle's started.",
            "I'm waiting for your OK in the Approvals tray to kick off the builds.",
            "It's been added to your tasks.",
            "Your note's been saved.",
            "They've been sent.",
            "Your email's sent to Maria.",
            "The upgrade's just kicked off.",
            "The build's queued.",
            "I am now waiting on your approval to run it.",
            "Okay, I\u{2019}m waiting for your go-ahead in Approvals.",
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [])
            XCTAssertTrue(out.replaced, "missed a claim: \(reply)")
            XCTAssertEqual(out.text, ActionClaimGuard.offer, reply)
        }
        // With the write really waiting, Grux names it in its own words.
        let input: [String: Any] = [:]
        let waiting = ActionClaimGuard.vet(
            reply: "The Foundry cycle's started; I'm waiting for your OK in the Approvals tray.",
            route: "local",
            results: [("foundry_upgrade_cycle", input, "pending: this is waiting for your OK in Approvals")])
        XCTAssertTrue(waiting.replaced)
        XCTAssertFalse(waiting.text.contains("cycle's started"), waiting.text)
        XCTAssertFalse(ActionClaimGuard.claimsAnAction(waiting.text), "the guard put back a done sentence: \(waiting.text)")
    }

    /// The new forms stay narrow: a contraction that is "is" (what's, here's,
    /// it's), a stative participle (`is scheduled`), or the queue read back from
    /// what Grux was told, is an answer, not a claim.
    func testContractionsThatAnswerPass() {
        for reply in [
            "Here's what's scheduled for today: the dentist at 7:30 PM.",
            "That's started to look better.",
            "There's nothing queued.",
            "Your dentist appointment's scheduled for 3 PM on Friday.",
            "The meeting's saved in your Meetings tab.",
            "It's sent from your work address by default.",
            "Your note \"The gate code is on the fridge\" is waiting for your OK in Approvals.",
            "You have 1 approval waiting for your OK.",
            "Want me to start it? I'll wait for your OK.",
            "Let's get started.",
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [])
            XCTAssertFalse(out.replaced, "flagged a plain reply: \(reply)")
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
    private let upgradeLine = "The self-upgrade cycle is waiting for your OK in Approvals. Nothing happens until you tap it."
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
        // Three writes that all read "that request" (the self-upgrade cycle has its own name since D86).
        let swarm: ActionClaimGuard.ToolResult = ("agent_swarm_start", ["goal": "z"], JaxToolGate.pendingResult(goesOutAs: nil))
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Got it.", route: "local", results: [swarm, research, render]).text,
                       after("Got it.", "That request is waiting for your OK in Approvals. Nothing happens until you tap it.",
                             "That request and 1 more like it are also waiting for your OK in Approvals."))
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Got it.", route: "local", results: [upgrade, research]).text,
                       after("Got it.", upgradeLine, "That request is waiting for your OK in Approvals. Nothing happens until you tap it."))
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

    /// Wave 20 round 1: what a read tool brings back is reported in the third
    /// person ("Maria's sent you two emails"), and the D85 forms read those
    /// reports as claims. After a read this turn, a third-person sentence is a
    /// report; a first-person claim ("I've sent it") still needs a write.
    func testAReadBackAfterAReadToolIsAnAnswer() {
        let reads: [[ActionClaimGuard.ToolResult]] = [
            [("list_inbox", [:], "3 unread: Maria (2), Amazon (1)")],
            [("list_events", [:], "Today: 3:00 PM Design review")],
            [("list_tasks", [:], "2 active tasks")],
        ]
        for results in reads {
            for reply in [
                "Here's what's been added to your tasks this week.",
                "Here's what's been scheduled this week.",
                "Nothing's been added since Monday.",
                "You've been invited to Maria's party on Saturday.",
                "You've been added to the design channel, per the Slack email.",
                "Maria's sent you two emails today.",
                "Nobody's sent you anything today.",
                "Your Amazon order's shipped, according to the email from Amazon.",
                "Your 3 PM meeting's started.",
                "Your blog post's published.",
                "The design review has started.",
            ] {
                let out = ActionClaimGuard.vet(reply: reply, route: "local", results: results)
                XCTAssertFalse(out.replaced, "a read back read as a claim after \(results[0].tool): \(reply)")
            }
            // A first-person claim after a read is still a claim.
            for reply in ["I've sent it to Maria.", "We've started the Foundry cycle."] {
                XCTAssertTrue(ActionClaimGuard.vet(reply: reply, route: "local", results: results).replaced, reply)
            }
        }
        // With no tool at all the D85 passive keeps its answers too.
        for reply in ["Here's what's been added to your tasks this week.", "Nothing's been added since Monday.",
                      "You've been invited to Maria's party on Saturday.",
                      "I'm still waiting on your approval for the email to Maria, from earlier."] {
            XCTAssertFalse(ActionClaimGuard.vet(reply: reply, route: "local", results: []).replaced, reply)
        }
    }

    /// Wave 20 round 1: the same claims as D85's, in the forms its patterns
    /// missed, with no tool run and nothing queued.
    func testTheUncontractedAndShortFormsOfTheD85ClaimAreCaught() {
        for reply in [
            "The Foundry cycle has started.",
            "The email has gone out.",
            "The upgrade has just kicked off.",
            "We've started the Foundry cycle.",
            "We have queued the builds.",
            "Okay, it's sent.",
            "It's started.",
            "It\u{2019}s queued for tonight.",
            "That's queued.",
            "Done, it's sent.",
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [])
            XCTAssertTrue(out.replaced, "missed a claim: \(reply)")
        }
    }

    /// Wave 20 round 2 (1): a read and then a write that failed is the usual
    /// shape of "move / remove / play X" on a Mac with no permission granted.
    /// The read does not make the claim a report: the person reads what failed.
    func testAReadThenAFailedWriteStillCorrectsTheClaim() {
        for (reply, results) in [
            ("Your dentist appointment's been moved to 4 PM.",
             [("list_events", [:] as [String: Any], "Dentist Thu 3 PM"),
              ("create_event", ["title": "Dentist"] as [String: Any], "error: calendar access not granted.")]),
            ("The cables task's been removed.",
             [("list_tasks", [:], "1 active task"), ("remove_task", ["title": "cables"], "error: no active task matched 'cables'")]),
            ("Your playlist's started.",
             [("list_library_tracks", [:], "3 tracks"), ("play_music_track", ["name": "x"], "refused: headless")]),
        ] as [(String, [ActionClaimGuard.ToolResult])] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: results, ask: "Do it now")
            XCTAssertTrue(out.replaced, "a failed write after a read let the claim stand: \(reply)")
            XCTAssertNotEqual(out.text, reply)
        }
    }

    /// Wave 20 round 2 (2): the written-out passive is a read back after a
    /// read, as its contraction is.
    func testTheWrittenOutPassiveAfterAReadIsAnAnswer() {
        let read: [ActionClaimGuard.ToolResult] = [("list_inbox", [:], "2 unread")]
        for reply in ["Your Amazon order has been shipped.",
                      "You have been invited to the team offsite on Friday.",
                      "Two new emails have been sent to you since this morning."] {
            XCTAssertFalse(ActionClaimGuard.vet(reply: reply, route: "local", results: read).replaced, reply)
        }
        // With nothing read, asked to act, it is still a claim.
        XCTAssertTrue(ActionClaimGuard.vet(reply: "Your order has been shipped.", route: "local", results: [],
                                           ask: "ship my order").replaced)
    }

    /// Wave 20 round 2 (3): with no tool this turn, a third-person sentence
    /// answers a QUESTION from what an earlier turn did or read ("Did it
    /// send?" "Not yet, it's queued for your approval."). It is a claim only
    /// when the person asked Grux to act, as in D85's "Grux, upgrade yourself".
    func testAThirdPersonAnswerToAQuestionIsAnAnswer() {
        for (ask, reply) in [
            ("Did it send?", "Not yet, it's queued for your approval in the Approvals tray."),
            ("did the email go", "Your email to Maria's queued in Approvals."),
            ("anything from Maria?", "Maria's sent you two emails today."),
            ("Grux, is the design review on?", "Yes, the design review has started."),
            ("What's new in my tasks", "Here's what's been added: call Sam."),
        ] {
            // Kept whole; a third-person sentence gets the plain fact after it
            // (wave 20 round 4), a plain read back gets nothing.
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
            XCTAssertTrue(out.text.hasPrefix(reply), "\(ask) -> \(out.text)")
            XCTAssertNotEqual(out.text, ActionClaimGuard.offer, "\(ask) -> \(reply)")
        }
        for (ask, reply) in [
            ("Grux, upgrade yourself", "The Foundry cycle's started; I'm waiting for your OK in the Approvals tray to kick off the builds."),
            ("Grux, upgrade yourself", "The Foundry cycle's started."),
            ("Can you upgrade yourself?", "The Foundry cycle has started."),
            ("could you send it to Maria", "It's sent."),
            ("Hey Grux, please send the email?", "Your email's sent to Maria."),
            ("Will you queue the builds?", "The builds have been queued."),
        ] {
            XCTAssertTrue(ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask).replaced,
                          "\(ask) -> \(reply)")
        }
        // A first-person claim is a claim whatever was asked.
        XCTAssertTrue(ActionClaimGuard.vet(reply: "I've sent it.", route: "local", results: [], ask: "Did it send?").replaced)
    }

    /// Wave 20 round 2 P3: "we" claims as "I" does, with or without "'ve".
    func testWeStartedIsAClaimAsIStartedIs() {
        for reply in ["Okay, we started the Foundry cycle.", "We just started the cycle."] {
            XCTAssertTrue(ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: "upgrade yourself").replaced, reply)
        }
    }

    func testAQuestionIsToldFromARequest() {
        for ask in ["Did it send?", "anything from Maria?", "Grux, what's on today", "is it done", "Hey Grux, did Maria write?",
                    "Do I have meetings today", "have you sent it"] {
            XCTAssertTrue(ActionClaimGuard.asksAQuestion(ask), ask)
        }
        for ask in ["Grux, upgrade yourself", "Can you send it?", "could you send it to Maria", "please send it?",
                    "Will you queue the builds?", "send the email", "", "  ", "Do it now", "Do it now?", "Have it sent to Maria",
                    // A trailing "?" alone is not a question (wave 20 round 3).
                    "Grux\u{2019}s queue?"] {
            XCTAssertFalse(ActionClaimGuard.asksAQuestion(ask), ask)
        }
    }

    /// Wave 20 round 3 (1): a request with a greeting, a thanks or a tag in
    /// front is still a request, and its third-person claim is still caught.
    func testARequestWithAnythingInFrontIsStillARequest() {
        for ask in ["Hello Grux, can you upgrade yourself?", "Thanks! Can you send it to Maria too?",
                    "Great, now can you queue the builds?", "Hi there, could you start the upgrade?",
                    "Hey Grux - can you upgrade yourself?", "Also, can you send it?", "Yes, can you send it?",
                    "Grux, upgrade yourself, ok?", "Send it to Maria, please?", "Any chance you can send it?",
                    "Is it possible to start the upgrade?", "Grux, do your upgrade cycle", "Do my weekly review",
                    "Don't forget to start the cycle", "Did you send it? If not, can you send it?",
                    "Send the email. Did Maria reply?", "upgrade yourself?"] {
            XCTAssertFalse(ActionClaimGuard.asksAQuestion(ask), ask)
            for reply in ["The Foundry cycle's started.", "Sure! The Foundry cycle has started.", "Yes, it's sent."] {
                XCTAssertTrue(ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask).replaced,
                              "\(ask) -> \(reply)")
            }
        }
    }

    /// Wave 20 round 3 (2): a write that ran and did not complete this turn
    /// keeps the claim checked, however the person asked.
    func testAFailedWriteIsCheckedEvenAfterAQuestion() {
        let results: [ActionClaimGuard.ToolResult] = [
            ("list_events", [:], "Dentist Thu 3 PM"),
            ("create_event", ["title": "Dentist"], "error: calendar access not granted."),
        ]
        for ask in ["Move my dentist appointment to 4 PM?", "Did you move my dentist to 4 PM?"] {
            let out = ActionClaimGuard.vet(reply: "Your dentist appointment's been moved to 4 PM.", route: "local",
                                           results: results, ask: ask)
            XCTAssertTrue(out.replaced, ask)
        }
    }

    /// Wave 20 round 3 (3): questions that open on "Have" or "Do" before a
    /// noun, and the other shapes a person types.
    func testQuestionsOpeningOnHaveDoOrAFillerAreQuestions() {
        for ask in ["Have the builds started?", "Have the emails been sent?", "Do the builds need my approval?",
                    "Has the cycle started?", "Will the cycle start soon?", "and did it send",
                    "hello grux, did maria write", "Good morning Grux, did it send", "Thanks! Did it send?"] {
            XCTAssertTrue(ActionClaimGuard.asksAQuestion(ask), ask)
        }
        // The true answer is kept (with the plain fact after it, wave 20 round 4).
        let answer = ActionClaimGuard.vet(reply: "Yes, the emails have been sent.", route: "local", results: [],
                                          ask: "Have the emails been sent?")
        XCTAssertTrue(answer.text.hasPrefix("Yes, the emails have been sent."), answer.text)
        XCTAssertNotEqual(answer.text, ActionClaimGuard.offer)
    }

    /// Wave 20 round 4 (1): polite requests that open on a question word are
    /// requests.
    func testPoliteRequestsThatOpenOnAQuestionWordAreRequests() {
        for ask in ["Why don't you send it to Maria?", "Why not start the upgrade now?",
                    "How about you start the upgrade cycle?", "How about sending it to Maria too?",
                    "What about sending it to Maria too?", "When you get a chance, send it to Maria.",
                    "When you're free, start the Foundry cycle", "Do you mind sending it to Maria?",
                    "Do you think you could start the upgrade?", "Are you able to send it to Maria?",
                    "Is there a way to start the upgrade now?", "Is it ok to send it now?",
                    "Is it done? I'd like you to send it if not."] {
            XCTAssertFalse(ActionClaimGuard.asksAQuestion(ask), ask)
            XCTAssertEqual(ActionClaimGuard.vet(reply: "The Foundry cycle's started.", route: "local", results: [],
                                                ask: ask).text, ActionClaimGuard.offer, ask)
        }
    }

    /// Wave 20 round 4 (2): a question followed by a request is a request.
    func testAQuestionThenARequestIsARequest() {
        for ask in ["Did the email go out? If not, send it.", "Did you send it? If not, send it now.",
                    "Has the cycle started? If not, start it.", "Is the cycle started? If not start it",
                    "What's on today? Also add dentist at 3.", "Any update on the build? Start it if not."] {
            XCTAssertFalse(ActionClaimGuard.asksAQuestion(ask), ask)
        }
        // A question with only thanks after it is still a question.
        XCTAssertTrue(ActionClaimGuard.asksAQuestion("Did Maria write? Thanks!"))
    }

    /// Wave 20 round 4: no word rule tells every request from every question,
    /// so a third-person sentence after a message read as a question, with no
    /// tool run, is kept and followed by the one fact Grux knows for sure. A
    /// request the rule misses then never reads as done unchallenged.
    func testAThirdPersonSentenceAfterAQuestionGetsThePlainFact() {
        for ask in ["Did it send?", "Is it sent yet? Thanks", "Have the builds started?"] {
            let reply = "The Foundry cycle's started."
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
            XCTAssertTrue(out.replaced, ask)
            XCTAssertEqual(out.text, reply + "\n\n" + ActionClaimGuard.nothingDoneNote, ask)
        }
        // Not after a clean read, and not for a reply with no claim shape.
        XCTAssertFalse(ActionClaimGuard.vet(reply: "Maria's sent you two emails today.", route: "local",
                                            results: [("list_inbox", [:], "2 unread")], ask: "Did Maria write?").replaced)
        XCTAssertFalse(ActionClaimGuard.vet(reply: "Berlin.", route: "local", results: [], ask: "What is the capital of Germany?").replaced)
        // Inside an open code fence the fact still lands outside it.
        let fenced = ActionClaimGuard.vet(reply: "```\nThe build's queued.", route: "local", results: [], ask: "Did it queue?")
        XCTAssertTrue(fenced.text.hasSuffix("```\n\n" + ActionClaimGuard.nothingDoneNote), fenced.text)
    }

    /// W20-P3 (2): a model that copies an earlier corrected reply from the thread
    /// brings the note with it; the person reads the note once, at the end.
    func testTheNoteIsNeverDoubled() {
        let note = ActionClaimGuard.nothingDoneNote
        let claim = "The Foundry cycle's started."
        for reply in [claim + "\n\n" + note, claim + " " + note, note + "\n\n" + claim,
                      claim + "\n\n" + note + "\n\n" + note, "  " + claim + "\n\n" + note + "\n"] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: "Did it start?")
            XCTAssertEqual(out.text, claim + "\n\n" + note, reply)
            XCTAssertEqual(out.text.components(separatedBy: note).count - 1, 1, reply)
        }
        // A reply that is only the copied note still reads as the note.
        XCTAssertEqual(ActionClaimGuard.vet(reply: note, route: "local", results: [], ask: "Did it start?").text, note)
    }

    /// D90, live on qwen3.5:4b (10:07 PM Oct 30): "Did the Foundry build start?"
    /// got the simple past with no tool run and no note. The note is true by
    /// construction, so after a question it follows any sentence that says
    /// something happened, in whatever tense.
    func testASimplePastAnswerToAQuestionGetsTheNote() {
        let note = ActionClaimGuard.nothingDoneNote
        for reply in ["Yes, the Foundry cycle started earlier.", "The email went out this morning.",
                      "It was sent an hour ago.", "The build kicked off at 9.", "Yes, it got queued.",
                      "The upgrade began a few minutes ago."] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: "Did the Foundry build start?")
            XCTAssertEqual(out.text, reply + "\n\n" + note, reply)
        }
        // A plain answer with nothing happening in it is left alone.
        XCTAssertFalse(ActionClaimGuard.vet(reply: "It is 9 PM.", route: "local", results: [], ask: "What time is it?").replaced)
    }

    /// D90: "It's still waiting for your OK in the Approvals tray" when nothing of
    /// the kind waits. Grux knows what Approvals holds, so a reply that says
    /// something waits on the person is followed by what really waits there.
    func testAWaitOnThePersonIsCheckedAgainstApprovals() {
        let live = "Yes, the Foundry cycle started earlier. It\u{2019}s still waiting for your OK in the Approvals tray to kick off the builds."
        let note = ActionClaimGuard.nothingDoneNote
        let ask = "Did the Foundry build start?"
        let saved = "Save your note \"The gate code is on the fridge\"."
        let one = ActionClaimGuard.vet(reply: live, route: "local", results: [], ask: ask, approvals: [saved])
        XCTAssertEqual(one.text, live + "\n\n" + note + "\n\n" + "In Approvals right now: Save your note \"The gate code is on the fridge\".")
        let none = ActionClaimGuard.vet(reply: live, route: "local", results: [], ask: ask, approvals: [])
        XCTAssertEqual(none.text, live + "\n\n" + note + "\n\n" + ActionClaimGuard.nothingWaitsLine)
        let three = ActionClaimGuard.vet(reply: "It's waiting for your approval.", route: "local", results: [],
                                         ask: "Is the upgrade done?", approvals: ["Send the email to Maria.", "Save your note.", "Pay $5."])
        XCTAssertTrue(three.replaced)
        XCTAssertTrue(three.text.hasSuffix("In Approvals right now: Send the email to Maria, and 2 more."), three.text)
        // Every shape of the wait, after a request too.
        for reply in ["That one needs your OK.", "It's awaiting your approval.", "You'll find it in Approvals.",
                      "The cycle is waiting on your go-ahead."] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: "What about the upgrade?", approvals: [])
            XCTAssertTrue(out.text.hasSuffix(ActionClaimGuard.nothingWaitsLine), reply)
        }
        // Not when the queue is unknown, not without a wait in the reply, not twice.
        XCTAssertEqual(ActionClaimGuard.vet(reply: "It's waiting for your OK.", route: "local", results: [], ask: ask).text,
                       "It's waiting for your OK.")
        XCTAssertFalse(ActionClaimGuard.vet(reply: "Berlin.", route: "local", results: [], ask: "Capital of Germany?", approvals: []).replaced)
        let copied = "It's waiting for your OK.\n\n" + ActionClaimGuard.nothingWaitsLine
        XCTAssertEqual(ActionClaimGuard.vet(reply: copied, route: "local", results: [], ask: "Is it waiting?", approvals: []).text
                        .components(separatedBy: ActionClaimGuard.nothingWaitsLine).count - 1, 1)
        // A write waiting this turn is named by its own paragraph, never this line.
        let held = ActionClaimGuard.vet(reply: "It's waiting for your OK.", route: "local",
                                        results: [("create_note", ["title": "x"], "pending: queued for your approval")],
                                        ask: "Save a note x", approvals: [saved])
        XCTAssertFalse(held.text.contains("In Approvals right now"), held.text)
        // The cloud route is not vetted.
        XCTAssertEqual(ActionClaimGuard.vet(reply: live, route: "anthropic", results: [], ask: ask, approvals: []).text, live)
    }

    /// Wave 21 round 1: a copied Approvals line inside a paragraph stayed, so the reply
    /// said one thing waits and Grux's line under it said nothing does. Every copy goes,
    /// cut at its own sentence end, and a reply that carries one gets the true line.
    func testACopiedApprovalsLineIsReplacedWhereverItSits() {
        let ask = "Is it waiting?"
        let inline = "It's waiting for your OK. In Approvals right now: Save your note."
        XCTAssertEqual(ActionClaimGuard.vet(reply: inline, route: "local", results: [], ask: ask, approvals: []).text,
                       "It's waiting for your OK.\n\n" + ActionClaimGuard.nothingWaitsLine)
        let followed = "In Approvals right now: Save your note \"The gate code is on the fridge\". Want me to check again?"
        XCTAssertEqual(ActionClaimGuard.vet(reply: followed, route: "local", results: [], ask: ask,
                                            approvals: ["Send the email to Maria.", "Pay $5."]).text,
                       "Want me to check again?\n\nIn Approvals right now: Send the email to Maria, and 1 more.")
        let counted = "Sure. In Approvals right now: Send the email to Maria, and 2 more. Anything else?"
        XCTAssertEqual(ActionClaimGuard.vet(reply: counted, route: "local", results: [], ask: ask, approvals: []).text,
                       "Sure. Anything else?\n\n" + ActionClaimGuard.nothingWaitsLine)
        // No wait wording, a stale copy: still replaced by what Approvals holds.
        let stale = "The cycle started.\n\nIn Approvals right now: Save your note."
        let out = ActionClaimGuard.vet(reply: stale, route: "local", results: [], ask: "Did it start?", approvals: [])
        XCTAssertFalse(out.text.contains("Save your note"), out.text)
        XCTAssertTrue(out.text.hasSuffix(ActionClaimGuard.nothingWaitsLine), out.text)
        // Round 2: a summary with its own full stops ("Dr. Lee", "e.g. the orb", "Wait... what")
        // is cut whole, never leaving a piece of the old line behind.
        for title in ["Lunch with Dr. Lee", "Ideas, e.g. the orb", "Wait... what"] {
            let summary = "Add your event \"\(title)\" to your calendar."
            let copy = "It's waiting for your OK.\n\nIn Approvals right now: " + summary
            let kept = ActionClaimGuard.vet(reply: copy, route: "local", results: [], ask: ask, approvals: [summary])
            XCTAssertEqual(kept.text, copy, title)
            XCTAssertFalse(kept.replaced, title)
            XCTAssertEqual(ActionClaimGuard.vet(reply: copy, route: "local", results: [], ask: ask, approvals: []).text,
                           "It's waiting for your OK.\n\n" + ActionClaimGuard.nothingWaitsLine, title)
            let inline = "Sure. In Approvals right now: \(summary) Anything else?"
            XCTAssertEqual(ActionClaimGuard.vet(reply: inline, route: "local", results: [], ask: ask, approvals: []).text,
                           "Sure. Anything else?\n\n" + ActionClaimGuard.nothingWaitsLine, title)
        }
        // A copy that is still true is said once.
        let same = "It's waiting for your OK.\n\nIn Approvals right now: Save your note."
        XCTAssertEqual(ActionClaimGuard.vet(reply: same, route: "local", results: [], ask: ask, approvals: ["Save your note."]).text,
                       same)
    }

    /// Wave 20 round 4 P3: a read that found nothing is not a clean read.
    func testAFailedReadDoesNotSwitchTheCheckOff() {
        let out = ActionClaimGuard.vet(reply: "The email's been sent to Maria.", route: "local",
                                       results: [("lookup_contact", ["name": "Maria"], "not_found: no contact named Maria")],
                                       ask: "Email Maria the notes")
        XCTAssertEqual(out.text, ActionClaimGuard.offer)
    }
}
