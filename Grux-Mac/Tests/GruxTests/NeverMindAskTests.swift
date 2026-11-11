import XCTest
@testable import Grux

/// D170 item 6: "Actually never mind" waited 9.5 s on Grux Local 2B and came
/// back "I hear you. What's up?" (sense pass 21, 12:29 AM Nov 5).
@MainActor
final class NeverMindAskTests: XCTestCase {

    func testTakingAnAskBackIsAnsweredAtOnce() {
        for text in [
            "Actually never mind", "never mind", "Nevermind.", "nvm", "Forget it", "Oh, forget that",
            "Scratch that.", "Don\u{2019}t worry about it", "Okay never mind then", "No, cancel that",
            "Grux, never mind", "never mind, thanks", "Ignore that", "Sorry, disregard that", "No need", "No need, thanks",
        ] {
            XCTAssertEqual(NeverMindAsk.reply(for: text, waiting: []), NeverMindAsk.reply, text)
        }
    }

    func testAMessageThatAsksSomethingElseIsLeftAlone() {
        for text in [
            "Never mind the weather, what's on my calendar?", "forget it and add milk to my list",
            "Never mind what I said, tell me a joke", "cancel my 3 PM meeting", "cancel", "mind the gap",
            "I never mind helping", "forget", "Actually", "never", "",
        ] {
            XCTAssertNil(NeverMindAsk.reply(for: text, waiting: []), text)
        }
    }

    /// What an earlier ask left in Approvals is named, so the person can turn it down.
    func testWhatStillWaitsIsNamed() {
        let waiting = ["Save a note \"Milk, eggs and bread\"", "Add an event"]
        XCTAssertEqual(NeverMindAsk.reply(for: "Actually never mind", waiting: waiting),
                       NeverMindAsk.reply + "\n\n" + ActionClaimGuard.approvalsLine(waiting))
    }

    /// W57-FIX 2: inside a card's 5 s undo window "never mind" is an undo. The
    /// reply says what was cancelled; it never says Grux left a thing it is
    /// about to do.
    func testInsideTheUndoWindowTheReplyNamesWhatWasCancelled() {
        XCTAssertEqual(NeverMindAsk.reply(for: "Actually never mind", waiting: [], cancelled: "Milk"),
                       "Okay, I cancelled \u{201C}Milk\u{201D} before it ran.")
        let waiting = ["Add an event"]
        XCTAssertEqual(NeverMindAsk.reply(for: "never mind", waiting: waiting, cancelled: "Milk"),
                       "Okay, I cancelled \u{201C}Milk\u{201D} before it ran.\n\n" + ActionClaimGuard.approvalsLine(waiting))
        XCTAssertNil(NeverMindAsk.reply(for: "cancel my 3 PM meeting", waiting: [], cancelled: "Milk"))
    }

    func testTheControllerCancelsOnlyAPendingCard() throws {
        let c = PIMConfirmationController.shared
        c.dismiss(animated: false)
        XCTAssertNil(c.cancelPending(), "nothing pending, nothing cancelled")
        let plan = try XCTUnwrap(PIMIntents.plan(for: "add a task: water the office plants"))
        let model = PIMConfirmationModel(plan: plan, personAsked: true, dryRun: false)
        c.hold(model)
        XCTAssertEqual(c.cancelPending(), plan.cardTitle)
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(c.cancelPending(), "a cancelled card is not cancelled twice")
        let ran = PIMConfirmationModel(plan: plan, personAsked: true, dryRun: false)
        ran.phase = .executing
        c.hold(ran)
        XCTAssertNil(c.cancelPending(), "a card already running cannot be taken back")
        XCTAssertEqual(ran.phase, .executing)
        c.dismiss(animated: false)
    }

    /// Chat's never-mind answer cancels a pending card, and only once the
    /// message is a never-mind: any other message leaves the card running.
    func testChatCancelsThePendingCardOnlyForANeverMind() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let gate = try XCTUnwrap(source.range(of: "if imageData == nil, NeverMindAsk.matches(trimmed),"))
        let reply = try XCTUnwrap(source.range(of: "NeverMindAsk.reply(for: trimmed", range: gate.upperBound..<source.endIndex))
        let call = source[reply.lowerBound...].prefix(260)
        XCTAssertTrue(call.contains("cancelled: PIMConfirmationController.shared.cancelPending())"), String(call))
        XCTAssertEqual(source.components(separatedBy: "cancelPending()").count, 2, "one call site, behind the gate")
    }

    /// Chat answers it before any model is asked.
    func testChatAnswersItBeforeTheModel() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let fast = try XCTUnwrap(source.range(of: "NeverMindAsk.reply(for: trimmed"))
        let pim = try XCTUnwrap(source.range(of: "// PIM fast-path: confident calendar"))
        XCTAssertLessThan(fast.lowerBound, pim.lowerBound)
    }
}
