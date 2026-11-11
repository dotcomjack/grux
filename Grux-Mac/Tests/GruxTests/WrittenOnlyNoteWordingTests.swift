import XCTest
@testable import Grux

/// D179 item 3 (sense pass 22, `chat-1.png`): under every bio the line read
/// "I only wrote this. I did not save, send or add anything just now.", which
/// reads as Grux defending itself after doing what was asked. The line stays
/// true by construction (it is said only when no write ran, W57-FIX), names the
/// three things a made-up claim says happened, and opens on the writing being
/// ready instead of on a denial. Threads written before the change carry the
/// old words, and a small model copies its last reply, so the old line is
/// still recognised and taken out wherever the current one is.
@MainActor
final class WrittenOnlyNoteWordingTests: XCTestCase {

    private let note = ActionClaimGuard.writtenOnlyNote
    /// The words every thread before D179 item 3 holds, written out here so the
    /// test does not lean on the source's own list.
    private let older = "I only wrote this. I did not save, send or add anything just now."

    func testTheNoteOpensOnTheWritingNotOnADenial() {
        XCTAssertFalse(note.hasPrefix("I "), note)
        XCTAssertFalse(note.contains("I only"), note)
        XCTAssertFalse(note.contains("I did not"), note)
        XCTAssertFalse(note.contains("just now"), note)
        // Still names what a made-up claim would say happened.
        for word in ["saved", "sent", "added"] {
            XCTAssertTrue(note.contains(word), word)
        }
        XCTAssertLessThanOrEqual(note.count, 60, note)
    }

    func testTheBioReadsWithTheNewNote() {
        let reply = "I started my first bakery in 2010 and opened a second in 2018."
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: "Write a short bio for my website")
        XCTAssertEqual(out.text, reply + "\n\n" + note)
    }

    /// A model copying its last reply from an older thread brings the old line;
    /// the turn says the current one, once.
    func testAnOlderNoteCopiedIntoAWritingTurnIsSaidOnceInTheNewWords() {
        // Wave 66 round 2 P3: the wording one private build said for a day too.
        for old in [older, "Ready for you to use. Nothing was saved, sent or added."] {
            let reply = "I started my first bakery in 2010.\n\n" + old
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: "Write a short bio for my website").text
            XCTAssertFalse(out.contains(old), out)
            XCTAssertEqual(out, "I started my first bakery in 2010.\n\n" + note)
        }
    }

    func testAnOlderNoteGoesWhenAWriteRan() {
        let added: [ActionClaimGuard.ToolResult] = [("add_task", ["title": "Poem"], "ok: added")]
        let out = ActionClaimGuard.vet(reply: "Added the poem to your tasks.\n\n" + older, route: "local",
                                       results: added, ask: "Add it to my tasks").text
        XCTAssertEqual(out, "Added the poem to your tasks.")
    }

    func testAnOlderNoteBesideAWaitingWriteIsOnlyRemoved() {
        let held: [ActionClaimGuard.ToolResult] = [("create_event", ["title": "Follow-up"], "pending: queued for your approval")]
        let out = ActionClaimGuard.vet(reply: "Here is the plan.\n\n" + older, route: "local", results: held,
                                       ask: "Put the follow-up on my calendar for Friday", approvals: []).text
        XCTAssertFalse(out.contains(older), out)
        XCTAssertFalse(out.contains(note), out)
        XCTAssertTrue(out.contains("waiting for your OK in Approvals"), out)
    }

    func testAnOlderNoteAfterAKeeperBecomesTheNothingDoneNote() {
        let kept: [ActionClaimGuard.ToolResult] = [("summarize_meeting", ["id": "m1"], "ok: resummarized")]
        let out = ActionClaimGuard.vet(reply: "We agreed to launch in May.\n\n" + older, route: "local", results: kept,
                                       ask: "Write a summary of my meeting with Sam").text
        XCTAssertFalse(out.contains(older), out)
        XCTAssertFalse(out.contains(note), out)
    }

    /// The invented-facts check reads only the writing, not a line Grux added
    /// after it, in either wording.
    func testTheInventedFactsCheckStopsAtEitherNote() {
        let bio = "Write a short bio about me for my coffee cart website"
        for line in [note, older] {
            XCTAssertNil(InventedFacts.check(reply: "I opened my coffee cart in [year].\n\n" + line, ask: bio, grounded: bio), line)
        }
    }
}

/// Wave 66 round 1 P2: "Ready for you to use." was said where there was nothing
/// to use: after a pasted text the local model sent back word for word (with the
/// line saying it did not change it), and after a reply that was only a made-up
/// claim. The note says only what is true in every branch that adds it.
@MainActor
final class WrittenOnlyNoteTruthTests: XCTestCase {

    func testAnUnchangedRewriteIsNotCalledReady() {
        let text = "Your order has shipped and we sent the tracking number."
        let ask = "Rewrite this to sound friendlier: " + text
        let echoed = ActionClaimGuard.appending(DraftAsk.unchangedLine, to: text)
        let out = ActionClaimGuard.vet(reply: echoed, route: "local", results: [], ask: ask).text
        XCTAssertTrue(out.contains(DraftAsk.unchangedLine), out)
        XCTAssertFalse(out.lowercased().contains("ready"), out)
        XCTAssertFalse(out.lowercased().contains("to use"), out)
    }

    func testAReplyThatIsOnlyAMadeUpClaimIsNotCalledReady() {
        let out = ActionClaimGuard.vet(reply: "I sent the message to Sam.", route: "local", results: [],
                                       ask: "Write a message to Sam on Slack").text
        XCTAssertFalse(out.lowercased().contains("ready"), out)
        XCTAssertFalse(out.lowercased().contains("to use"), out)
    }
}
