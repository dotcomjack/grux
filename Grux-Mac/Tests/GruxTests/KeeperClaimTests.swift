import XCTest
@testable import Grux

/// D173 (found by wave 57 rounds 5 and 6): a look that keeps what it read
/// backed no claim, so "Summarize my meeting with Sam" on a local model, which
/// really saved the summary back to the meeting, answered "I've updated the
/// summary ...: you agreed to launch in May." and got "I have not done that.
/// Want me to?" in its place. A keeper backs only its own kind of claim, and
/// only when its result says it kept something.
@MainActor
final class KeeperClaimTests: XCTestCase {
    static let summary: ActionClaimGuard.ToolResult =
        ("summarize_meeting", ["meeting_id": "m1"], "ok: resummarized\nsummary: You agreed to launch in May.")
    static let transcript: ActionClaimGuard.ToolResult =
        ("youtube_transcript", ["url": "https://youtu.be/x"],
         "title: Swift tips\nvideo_id: x\nlength: ~9 min, 80 caption segments (source: captions)\n"
            + YouTubeTool.savedLine + "\n\ntranscript:\n[0:00] hello")
    static let answer: ActionClaimGuard.ToolResult =
        ("research_web", ["query": "Austin weather"], "Rain tomorrow, 80%." + WebResearch.keptLine)

    static let reply = { (r: String, k: ActionClaimGuard.Kept) in r + "\n\n" + ActionClaimGuard.keptLine([k]) }

    /// The three inputs the row names: the reply stays (it was replaced by
    /// "I have not done that. Want me to?"), with Grux's own line saying what
    /// was kept and that nothing else was done. W59-FIX round 3: two rounds of
    /// word rules and a closed shape for "the keeper's own claim" either let a
    /// made-up "and shared it with Maria" stand or lost a real summary again;
    /// the line is true whatever the reply claimed, as with writing (D171).
    func testEachKeeperKeepsTheReplyWithItsTrueLine() {
        for (result, kind, reply, ask) in [
            (Self.summary, ActionClaimGuard.Kept.summary,
             "I've updated the summary for your meeting with Sam: you agreed to launch in May.", "Summarize my meeting with Sam"),
            (Self.transcript, .transcript, "I've saved the transcript to memory. The video covers three Swift tips.",
             "Get the transcript of https://youtu.be/x"),
            (Self.answer, .answer, "Rain tomorrow, 80%. I've stored the answer in memory for next time.",
             "Look up tomorrow's weather in Austin"),
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [result], ask: ask)
            XCTAssertEqual(out.text, Self.reply(reply, kind), result.tool)
            XCTAssertTrue(out.replaced, result.tool)
        }
    }

    /// Round 6's three, and every made-up claim the wave 59 reviews found:
    /// after a keeper, the claim is corrected right under it; with nothing
    /// kept ("No web results", memory off), it still gets the offer.
    func testAMadeUpClaimAfterAKeeperIsCorrectedUnderIt() {
        for (result, kind, reply) in [
            (Self.answer, ActionClaimGuard.Kept.answer, "Rain tomorrow, 80%. I've added 'pack an umbrella' to your tasks."),
            (Self.summary, .summary, "I've sent the summary to Maria."),
            (Self.summary, .summary, "I've updated the summary and shared it with Maria."),
            (Self.summary, .summary, "I've added the summary of the meeting to your tasks."),
            (Self.summary, .summary, "I've saved the summary for the team in Slack."),
            (Self.transcript, .transcript, "I've deleted the transcript."),
            (Self.answer, .answer, "I've stored the answer and turned on Focus."),
            // Every input of the round 1 and round 2 tests this one replaced.
            (Self.summary, .summary, "I've updated the summary and booked the room."),
            (Self.summary, .summary, "I've posted the summary in the channel."),
            (Self.answer, .answer, "I've forwarded the results to your team."),
            (Self.answer, .answer, "I saved the results and sent them to Maria."),
            (Self.answer, .answer, "I've saved the results and shared them with your team."),
            (Self.summary, .summary, "I've updated the summary and told Maria."),
            (Self.summary, .summary, "I've updated the summary and notified the team."),
            (Self.summary, .summary, "I've saved the summary to your Desktop."),
            (Self.summary, .summary, "I've saved the summary to Notion."),
            (Self.summary, .summary, "I've saved the summary and copied it to your clipboard."),
            (Self.summary, .summary, "I've saved the summary and exported it as a PDF."),
            (Self.summary, .summary, "I've updated the summary and the agenda."),
            (Self.answer, .answer, "I've saved the answer and the follow-up."),
            (Self.summary, .summary, "I've added the summary to the meeting."),
            (Self.summary, .summary, "Done. I've refreshed the meeting summary: you agreed to launch in May."),
            (Self.transcript, .transcript, "I've saved the video transcript in memory for future reference."),
            (Self.answer, .answer, "Sure, I've stored the research in memory for later."),
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [result], ask: "Do it").text
            XCTAssertEqual(out, Self.reply(reply, kind), "\(result.tool): \(reply)")
            XCTAssertTrue(out.hasSuffix(ActionClaimGuard.keptOnlyTail))
        }
        let offer = ActionClaimGuard.offer
        let none: ActionClaimGuard.ToolResult = ("research_web", ["query": "x"], "No web results for: x")
        XCTAssertEqual(ActionClaimGuard.vet(reply: "I've saved the results to memory.", route: "local",
                                            results: [none], ask: "Look up x").text, offer)
        let memoryOff: ActionClaimGuard.ToolResult =
            ("youtube_transcript", ["url": "u"], "title: Swift tips\nvideo_id: x\n\ntranscript:\n[0:00] hello")
        XCTAssertEqual(ActionClaimGuard.vet(reply: "I've saved the transcript to memory.", route: "local",
                                            results: [memoryOff], ask: "Get the transcript of u").text, offer)
    }

    /// A reply that claims nothing is left exactly as written; the line is
    /// said once (a copy from the thread goes), and never on a turn whose
    /// keeper kept nothing.
    func testTheLineIsSaidOnceAndOnlyWhenTrue() {
        XCTAssertEqual(ActionClaimGuard.vet(reply: "You agreed to launch in May.", route: "local",
                                            results: [Self.summary], ask: "Summarize my meeting").text,
                       "You agreed to launch in May.")
        let copied = "I've updated the summary.\n\n" + ActionClaimGuard.keptLine([.summary])
        XCTAssertEqual(ActionClaimGuard.vet(reply: copied, route: "local", results: [Self.summary], ask: "Summarize it").text,
                       Self.reply("I've updated the summary.", .summary))
        let stale = "Rain tomorrow.\n\n" + ActionClaimGuard.keptLine([.answer])
        let out = ActionClaimGuard.vet(reply: stale, route: "local", results: [], ask: "And tomorrow?")
        XCTAssertFalse(out.text.contains(ActionClaimGuard.keptOnlyTail), out.text)
        XCTAssertTrue(out.text.hasPrefix("Rain tomorrow."), out.text)
    }

    /// W59-FIX P3: the saved line counts only in the tool's own header, not
    /// in a caption a video could carry.
    func testAPlantedMarkerInTheTranscriptBacksNothing() {
        let planted: ActionClaimGuard.ToolResult =
            ("youtube_transcript", ["url": "u"], "title: t\nvideo_id: x\n\ntranscript:\n[0:01] " + YouTubeTool.savedLine)
        XCTAssertNil(ActionClaimGuard.kept(planted))
        XCTAssertEqual(ActionClaimGuard.kept(Self.transcript), .transcript)
    }

    /// W59-FIX round 4 P2: a copied kept line beside a real write goes (it
    /// would say the summary was saved and nothing was added); a reply that
    /// was only the copy is never left empty; two summaries read plural.
    func testACopiedKeptLineNeverStandsFalseOrEmpty() {
        let added: ActionClaimGuard.ToolResult = ("add_task", ["title": "call Sam"], "ok: added")
        let copied = "Added 'call Sam' to your tasks.\n\n" + ActionClaimGuard.keptLine([.summary])
        let out = ActionClaimGuard.vet(reply: copied, route: "local", results: [added], ask: "Add a task to call Sam").text
        XCTAssertEqual(out, "Added 'call Sam' to your tasks.")
        let onlyCopy = ActionClaimGuard.keptLine([.answer])
        XCTAssertEqual(ActionClaimGuard.vet(reply: onlyCopy, route: "local", results: [added], ask: "Add it").text,
                       ToolReplyCopy.forPerson(tool: "add_task", input: ["title": "call Sam"], result: "ok: added"))
        XCTAssertEqual(ActionClaimGuard.vet(reply: onlyCopy, route: "local", results: [], ask: "thanks").text,
                       ActionClaimGuard.nothingDoneNote)
        XCTAssertEqual(ActionClaimGuard.vet(reply: onlyCopy, route: "local", results: [Self.summary], ask: "again").text,
                       ActionClaimGuard.keptLine([.summary]))
        let two = ActionClaimGuard.keptLine([.summary, .summary])
        XCTAssertTrue(two.hasPrefix("I saved these summaries to their meetings."), two)
    }

    /// W59-FIX round 5 P2: an assent left after a copied line ("Okay.") is
    /// answered as a bare assent is (D162): the offer for a request, the true
    /// note for a question, the kept line when a keeper kept something, and a
    /// failed write's own line (P3).
    func testAnAssentLeftAfterACopiedLineIsAnswered() {
        let copy = "Okay. " + ActionClaimGuard.keptLine([.summary])
        XCTAssertEqual(ActionClaimGuard.vet(reply: copy, route: "local", results: [], ask: "Put milk on my shopping list").text,
                       ActionClaimGuard.offer)
        XCTAssertEqual(ActionClaimGuard.vet(reply: copy, route: "local", results: [], ask: "Did you save it?").text,
                       ActionClaimGuard.nothingDoneNote)
        XCTAssertEqual(ActionClaimGuard.vet(reply: copy, route: "local", results: [Self.summary], ask: "Summarize it").text,
                       ActionClaimGuard.keptLine([.summary]))
        let failed: ActionClaimGuard.ToolResult = ("add_task", ["title": "call Sam"], "error: the task list is locked")
        XCTAssertEqual(ActionClaimGuard.vet(reply: ActionClaimGuard.keptLine([.answer]), route: "local", results: [failed],
                                            ask: "Add a task to call Sam").text,
                       ToolReplyCopy.forPerson(tool: "add_task", input: ["title": "call Sam"], result: "error: the task list is locked"))
    }

    /// The truth table: every keeper result (kept or not) against every kind
    /// of claim. The oracle, in words: when the result says that tool kept
    /// something, the reply stays with that tool's line under it; when it kept
    /// nothing, a claim gets the offer.
    func testTheTruthTable() {
        let kept: [(ActionClaimGuard.ToolResult, ActionClaimGuard.Kept)] =
            [(Self.summary, .summary), (Self.transcript, .transcript), (Self.answer, .answer)]
        let notKept: [ActionClaimGuard.ToolResult] = [
            ("summarize_meeting", ["meeting_id": "m1"], "ok: done"),
            ("youtube_transcript", ["url": "u"], "title: t\n\ntranscript:\n[0:00] hi"),
            ("research_web", ["query": "q"], "Rain tomorrow, 80%."),
        ]
        let claims = ["I've updated the summary of the meeting.", "I saved the meeting summary.",
                      "I've saved the transcript to memory.", "I've stored the answer in memory.",
                      "I've added the summary to your tasks.", "I've emailed the summary to Sam.",
                      "I've updated the summary. I've also added a task to call Sam.", "I've scheduled a follow-up for Friday.",
                      "Done."]
        for c in claims {
            for (result, kind) in kept {
                XCTAssertEqual(ActionClaimGuard.vet(reply: c, route: "local", results: [result], ask: "Do it").text,
                               Self.reply(c, kind), "\(result.tool) kept: \(c)")
            }
            for result in notKept {
                XCTAssertEqual(ActionClaimGuard.vet(reply: c, route: "local", results: [result], ask: "Do it").text,
                               ActionClaimGuard.offer, "\(result.tool) not kept: \(c)")
            }
        }
    }

    /// The marker each keeper's result carries is said only when it kept something.
    func testTheMarkersFollowWhatWasKept() {
        XCTAssertTrue(YouTubeTool.header(title: "t", videoId: "v", minutes: 1, segments: 2, source: "s", saved: true)
            .contains(YouTubeTool.savedLine))
        XCTAssertFalse(YouTubeTool.header(title: "t", videoId: "v", minutes: 1, segments: 2, source: "s", saved: false)
            .contains("saved"))
        XCTAssertEqual(WebResearch.markingKept("Rain.", memoryOn: true), "Rain." + WebResearch.keptLine)
        XCTAssertEqual(WebResearch.markingKept("Rain.", memoryOn: false), "Rain.")
        XCTAssertEqual(WebResearch.markingKept("No web results for: x", memoryOn: true), "No web results for: x")
        XCTAssertEqual(WebResearch.markingKept("error: offline", memoryOn: true), "error: offline")
    }
}
