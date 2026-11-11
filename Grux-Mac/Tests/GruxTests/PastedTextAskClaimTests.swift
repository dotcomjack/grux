import XCTest
@testable import Grux

/// D174, live 2026-11-05 9:27 PM on grux-local:2b (sense pass 22): "Summarize
/// this in one sentence: The meeting moved to Thursday because two people were
/// out sick, and the budget review now happens first." was answered right, "The
/// meeting moved to Thursday because two people were out sick, and the budget
/// review is now scheduled first.", and the local action-claim guard replaced
/// it with "I have not done that. Want me to?": it read the person's own facts,
/// restated, as Grux saying it scheduled something.
///
/// A summary, rewrite or translation of text the person put in the message is
/// writing they asked for (D171): it stays, and when it reads like a claim the
/// line that is true whatever it meant follows it, so a made-up "I've saved it"
/// still never stands. Asks with nothing pasted, or that ask Grux to keep or
/// send the result too, are checked as before.
@MainActor
final class PastedTextAskClaimTests: XCTestCase {

    private let note = ActionClaimGuard.writtenOnlyNote
    private let offer = ActionClaimGuard.offer

    private let material = "The meeting moved to Thursday because two people were out sick, and the budget review now happens first."

    /// The logged turn, word for word.
    func testTheLoggedSummaryIsKept() {
        let ask = "Summarize this in one sentence: " + material
        let reply = "The meeting moved to Thursday because two people were out sick, and the budget review is now scheduled first."
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
        XCTAssertEqual(out.text, reply + "\n\n" + note)
    }

    /// Every ask shape against every reply shape, with no tool run. The oracle
    /// is the rule in plain words: on an ask that transforms pasted text, the
    /// reply stays, and a claim-shaped one gets the written-only note; on any
    /// other ask, a claim-shaped reply is the offer and a plain one stays.
    func testTheTruthTable() {
        let transforms = [
            "Summarize this in one sentence: " + material,
            "summarise: " + material,
            "Can you please shorten this for me: " + material,
            "Translate this into French: The order has been shipped and the invoice is now updated.",
            "Rewrite this to sound friendlier: We have cancelled your booking and refunded the deposit.",
            "Paraphrase the following:\n" + material,
            "TL;DR: " + material,
            material + "\n\nSummarize this in one line.",
            "Translate \"your table has been booked for eight\" into Spanish",
            "Proofread this: Your order has shipped and we've sent the tracking number.",
        ]
        let others = [
            "Summarize my meeting with Sam",
            "Schedule lunch with Sam on Friday",
            "Summarize this and save it to my notes: " + material,
            "Translate this and send it to Maria: " + material,
            "Move my meeting to Thursday",
            "Rewrite: hi there",
            "Summarize my inbox: what's new?",
            "Shorten my task list",
        ]
        let claims = [
            "The meeting moved to Thursday, and the budget review is now scheduled first.",
            "I've moved the meeting to Thursday.",
            "Your table has been booked for eight.",
            "Done. Saved it to your notes.",
        ]
        let plain = ["Two people were out sick, so the meeting is on Thursday."]
        for ask in transforms {
            XCTAssertTrue(DraftAsk.asksForWriting(ask), ask)
            for reply in claims {
                let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
                XCTAssertEqual(out.text, reply + "\n\n" + note, "\(ask) / \(reply)")
            }
            for reply in plain {
                XCTAssertEqual(ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask).text, reply)
            }
        }
        for ask in others {
            XCTAssertFalse(DraftAsk.asksForWriting(ask), ask)
            for reply in claims {
                let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
                XCTAssertEqual(out.text, offer, "\(ask) / \(reply)")
            }
            for reply in plain {
                XCTAssertEqual(ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask).text, reply)
            }
        }
    }

    /// On the edge of each threshold: pasted text of three words is not enough to
    /// be the thing transformed, four is; a quote needs two words.
    func testTheMaterialThresholds() {
        XCTAssertFalse(DraftAsk.asksForWriting("Summarize this: we moved it"))
        XCTAssertTrue(DraftAsk.asksForWriting("Summarize this: we moved it Thursday"))
        XCTAssertFalse(DraftAsk.asksForWriting("Translate \"booked\" into Spanish"))
        XCTAssertTrue(DraftAsk.asksForWriting("Translate \"table booked\" into Spanish"))
        XCTAssertFalse(DraftAsk.asksForWriting("we moved it\n\nSummarize this."))
        XCTAssertTrue(DraftAsk.asksForWriting("we moved it Thursday\n\nSummarize this."))
    }

    /// A save or send in the pasted text is the text's, not an ask of Grux
    /// (W53-P3 item 1's class): only the instruction is read for one.
    func testASaveInsideThePastedTextIsNotAnAsk() {
        XCTAssertTrue(DraftAsk.asksForWriting("Summarize this: Sam will review it and then send it to the board on Monday."))
        XCTAssertFalse(DraftAsk.asksForWriting("Summarize this and then send it to the board: Sam will review the plan Monday."))
    }

    /// A write that ran or waits this turn is answered as before: the pasted-text
    /// rule changes only turns where nothing ran.
    func testATurnWithAWriteIsUnchanged() {
        let ask = "Summarize this in one sentence: " + material
        let reply = "I've saved the summary to your notes."
        let waiting: ActionClaimGuard.ToolResult = ("create_note", ["title": "Summary"], "pending: this is waiting for your OK in Approvals")
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [waiting], ask: ask)
        XCTAssertNotEqual(out.text, reply + "\n\n" + note)
        XCTAssertFalse(out.text.contains(note))
    }
}
