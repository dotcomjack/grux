import XCTest
@testable import Grux

/// D171, live 2026-11-05 11:51 AM on grux-local:2b: "Write a text that tells
/// our story for the bakery website, two sentences" came back as the copy
/// ("We started as a small family business in 1985, ...") and the local
/// action-claim guard replaced it with "I have not done that. Want me to?".
/// Writing a person asked for, in "we" or "I" voice, is the answer: it stays,
/// and the line that is true whatever it meant follows it.
@MainActor
final class WritingAskClaimTests: XCTestCase {

    /// W57-FIX round 2: the writing branch runs only when no write ran this turn,
    /// so the line after the writing can say what nothing was, in the words a
    /// made-up claim would use.
    private let note = ActionClaimGuard.writtenOnlyNote

    /// The logged turn, word for word.
    func testTheBakeryCopyIsKept() {
        let ask = "Write a text that tells our story for the bakery website, two sentences"
        let reply = "We started as a small family business in 1985, growing into a beloved neighborhood staple. "
            + "Today, we continue to bake with the same passion and pride that defined us."
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
        XCTAssertEqual(out.text, reply + "\n\n" + note)
    }

    func testWritingInTheFirstPersonIsKept() {
        for (ask, reply) in [
            ("Write a short bio for my website", "I started my first bakery in 2010 and opened a second in 2018."),
            ("Draft a LinkedIn post about our launch", "We launched Grux today! It runs on your Mac."),
            ("Can you write a two sentence story about a dragon?", "I woke up as a dragon. I booked a flight anyway."),
            ("write an email to Sam saying we shipped the order", "Hi Sam,\n\nWe shipped your order this morning."),
            ("Grux, compose a toast for my sister's wedding", "We started this journey as kids, and I watched you grow."),
            ("Please write me a cover letter for a barista job", "I have worked in cafes for five years. I ran the morning shift."),
            ("Write three sentences about why we moved to Denver", "We moved to Denver in 2020. We wanted mountains."),
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
            XCTAssertEqual(out.text, reply + "\n\n" + note, ask)
        }
    }

    /// The guard still answers a made-up action where the ask was not for writing,
    /// or was for a note Grux keeps, or asked Grux to send or save it too.
    func testAClaimOutsideAWritingAskIsStillAnOffer() {
        for (ask, reply) in [
            ("Write it down", "I've saved it to your notes."),
            ("Add milk to my list", "I've added milk."),
            ("Write a note about the meeting", "I've saved your note about the meeting."),
            ("Write a reminder to call Mom", "I've set up the reminder."),
            ("Write an email to Sam and send it", "I sent the email to Sam."),
            ("Write a story and save it to my notes", "I saved the story to your notes."),
            ("write", "I wrote it."),
            ("Rewrite my resume file", "I've updated your resume."),
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
            XCTAssertEqual(out.text, ActionClaimGuard.offer, ask)
        }
    }

    /// W57-FIX 1 and round 2: whatever the ask names (a place Grux keeps things,
    /// a send after a comma, a note app), a made-up "I've saved it" never stands
    /// alone: it is the offer, or it is followed by the true line that nothing was
    /// saved, sent or added.
    func testAMadeUpSaveOrSendNeverStandsAlone() {
        XCTAssertTrue(note.contains("save") && note.contains("sent") && note.contains("add"), note)
        for ask in ["Write a poem in my notes", "Write a summary of the meeting to my notes",
                    "Write a story into a new note", "Write the summary to a file on my desktop",
                    "Write a story. Save it in Notes.", "Write lyrics, save to notes", "Write down a summary of the meeting",
                    "write it down: a poem about rain", "Write a message to Sam on Slack", "Write an email to Sam & send it",
                    "Write a post for my blog and publish it", "Write a message and DM it to Sam", "Write a tweet and share it",
                    "Write the meeting summary in Notion", "Write a haiku. Add to Bear.", "Write a story in my Documents folder",
                    "Write a poem to ~/Desktop/poem.txt", "Write a summary of this page into summary.md",
                    "Write a poem, email it to Sam"] {
            for reply in ["I've saved the poem to your notes.", "I sent the message to Sam.",
                          "I've added the summary to your Notion database."] {
                let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask).text
                XCTAssertTrue(out == ActionClaimGuard.offer || out == reply + "\n\n" + note, "\(ask) -> \(out)")
            }
        }
    }

    /// Writing about stores, events, send-offs and saving the oceans is writing
    /// (W57-FIX round 2: a word list read these as a save or a kept place).
    func testWritingAboutTheseThingsIsStillWriting() {
        for (ask, reply) in [
            ("Write a short bio for my Etsy store", "I started making candles in 2015."),
            ("Write a short description for our bakery's online store", "We started baking in 1985."),
            ("Write a toast for my sister's send-off", "We started this journey as kids."),
            ("Write an announcement for the team event", "We've booked the venue for Friday."),
            ("Write a welcome post for our Discord server", "We started this server in 2020."),
            ("Write a speech for the Teams meeting", "We launched the product in May."),
            ("Write a speech about why we should save the oceans", "I started diving at twelve."),
            ("Write a story about a girl who wants to save her dog", "I started running the moment I saw him."),
            ("Write an email to my team saying we shipped the update and will send notes Monday", "Hi team,\n\nWe shipped the update today."),
            ("Write a reply to my boss saying I will send the report tonight", "Hi,\n\nI sent the draft this morning and will send the report tonight."),
            ("Write a song about slowing down", "I started slowing down in May."),
            ("Write a toast, keep it short", "We started as friends."),
        ] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: [], ask: ask)
            XCTAssertEqual(out.text, reply + "\n\n" + note, ask)
        }
    }

    /// W57-FIX rounds 3 to 7: a look-only tool that keeps what it read
    /// (`ActionClaimGuard.keepsWhatItReads`: summarize_meeting saves the summary
    /// back, youtube_transcript and research_web store into memory) backs no
    /// claim, and after one completed the turn reads as it did before wave 57: a
    /// claim gets the offer, writing ask or not, and a copied "I did not save"
    /// note becomes the older note, true there, so no reply is ever left empty.
    func testAfterAToolThatKeepsTheTurnReadsAsBefore() {
        XCTAssertTrue(ActionClaimGuard.keepsWhatItReads.isSubset(of: ActionClaimGuard.readOnlyTools))
        let older = ActionClaimGuard.nothingDoneNote
        for keeper in ["summarize_meeting", "youtube_transcript", "research_web"] {
            XCTAssertTrue(ActionClaimGuard.keepsWhatItReads.contains(keeper), keeper)
            let ran: [ActionClaimGuard.ToolResult] = [("list_meetings", [:], "ok: 1 meeting"), (keeper, ["id": "m1"], "ok: done")]
            XCTAssertFalse(ran.contains(where: ActionClaimGuard.backsAClaim), keeper)
            for reply in ["We shipped the beta and scheduled the launch for May.",
                          "You agreed to launch in May. I've added the three action items to your tasks."] {
                XCTAssertEqual(ActionClaimGuard.vet(reply: reply, route: "local", results: ran,
                                                    ask: "Write a summary of my meeting with Sam").text,
                               ActionClaimGuard.offer, "\(keeper): \(reply)")
            }
            let ask = "Now summarize my meeting with Priya"
            let swapped = ActionClaimGuard.vet(reply: "You agreed to launch in May.\n\n" + note, route: "local", results: ran, ask: ask)
            XCTAssertEqual(swapped.text, "You agreed to launch in May.\n\n" + older, keeper)
            XCTAssertTrue(swapped.replaced, keeper)
            XCTAssertEqual(ActionClaimGuard.vet(reply: "You agreed to launch in May.\n\n" + older, route: "local",
                                                results: ran, ask: ask).text,
                           "You agreed to launch in May.\n\n" + older, keeper)
            for only in [note, older] {
                XCTAssertEqual(ActionClaimGuard.vet(reply: only, route: "local", results: ran, ask: ask).text, older, keeper)
            }
        }
        for reader in ["search_notes", "list_inbox", "get_meeting_transcript", "list_meetings"] {
            let looked: [ActionClaimGuard.ToolResult] = [(reader, [:], "ok: found 2")]
            XCTAssertEqual(ActionClaimGuard.vet(reply: "I've saved this summary to your notes.", route: "local",
                                                results: looked, ask: "Write a summary of my notes from today").text,
                           "I've saved this summary to your notes.\n\n" + note, reader)
        }
    }

    /// W57-FIX round 8: with a write waiting this turn, a copied note is only
    /// removed, never swapped for one that says nothing was queued.
    func testACopiedNoteBesideAWaitingWriteIsOnlyRemoved() {
        let ran: [ActionClaimGuard.ToolResult] = [("summarize_meeting", ["id": "m1"], "ok: done"),
                                                 ("create_event", ["title": "Follow-up"], "pending: queued for your approval")]
        let ask = "Summarize my meeting with Sam and put the follow-up on my calendar for Friday"
        // Round 9: either note, with or without the look that kept something.
        let plain: [ActionClaimGuard.ToolResult] = [("create_event", ["title": "Follow-up"], "pending: queued for your approval")]
        for (reply, results) in [("You agreed to launch in May.\n\n" + note, ran), (note, ran),
                                 ("You agreed to launch in May.\n\n" + ActionClaimGuard.nothingDoneNote, ran),
                                 (ActionClaimGuard.nothingDoneNote, ran),
                                 ("Here is the plan.\n\n" + note, plain),
                                 ("Here is the plan.\n\n" + ActionClaimGuard.nothingDoneNote, plain)] {
            let out = ActionClaimGuard.vet(reply: reply, route: "local", results: results, ask: ask, approvals: []).text
            XCTAssertFalse(out.contains(ActionClaimGuard.nothingDoneNote), out)
            XCTAssertFalse(out.contains(note), out)
            XCTAssertTrue(out.contains("waiting for your OK in Approvals"), out)
            XCTAssertFalse(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Round 6 P2 1: a look that kept something does not license other claims.
    func testALookThatKeptSomethingLicensesNoOtherClaim() {
        let looked: [ActionClaimGuard.ToolResult] = [("research_web", ["q": "Austin weather"], "ok: rain tomorrow, 80%")]
        let out = ActionClaimGuard.vet(reply: "Rain tomorrow, 80%. I've added 'pack an umbrella' to your tasks.", route: "local",
                                       results: looked, ask: "Look up tomorrow's weather in Austin and add a task to pack an umbrella")
        XCTAssertEqual(out.text, ActionClaimGuard.offer)
    }

    /// Round 4 P2 2: a summarize that failed saved nothing, and the writing stays.
    func testAFailedSummarizeLeavesTheWriting() {
        let reply = "We shipped the beta and scheduled the launch for May."
        let results: [ActionClaimGuard.ToolResult] = [("list_meetings", [:], "ok: 1 meeting"),
                                                     ("summarize_meeting", ["meeting_id": "Sam"], "error: meeting_id must be a valid UUID"),
                                                     ("get_meeting_transcript", [:], "ok: transcript")]
        let out = ActionClaimGuard.vet(reply: reply, route: "local", results: results,
                                       ask: "Write a summary of my meeting with Sam").text
        XCTAssertTrue(out.hasPrefix(reply), out)
    }

    /// Round 4 P3 1: a backed reply that was only a copied note says what was done.
    func testABackedReplyThatWasOnlyANoteSaysWhatWasDone() {
        let added: [ActionClaimGuard.ToolResult] = [("add_task", ["title": "buy milk"], "ok: added")]
        let out = ActionClaimGuard.vet(reply: ActionClaimGuard.nothingDoneNote, route: "local", results: added,
                                       ask: "Add buy milk to my tasks").text
        XCTAssertFalse(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(out, ToolReplyCopy.forPerson(tool: "add_task", input: ["title": "buy milk"], result: "ok: added"))
        // Round 5 P3 1: every backing result is named, once each.
        let two: [ActionClaimGuard.ToolResult] = [("add_task", ["title": "milk"], "ok: added"), ("add_task", ["title": "eggs"], "ok: added")]
        let both = ActionClaimGuard.vet(reply: ActionClaimGuard.nothingDoneNote, route: "local", results: two,
                                        ask: "Add milk and eggs to my tasks").text
        XCTAssertEqual(both, two.map { ToolReplyCopy.forPerson(tool: $0.tool, input: $0.input, result: $0.result) }.joined(separator: "\n\n"))
    }

    /// W57-FIX round 3 P2 2: a small model copies the shape of its last reply,
    /// note and all; on a turn where a write did run, the copied note goes.
    func testACopiedNoteGoesWhenAWriteRan() {
        let added: [ActionClaimGuard.ToolResult] = [("add_task", ["title": "Poem"], "ok: added")]
        for copied in [note, ActionClaimGuard.nothingDoneNote] {
            let out = ActionClaimGuard.vet(reply: "Added the poem to your tasks.\n\n" + copied, route: "local",
                                           results: added, ask: "Add it to my tasks").text
            XCTAssertEqual(out, "Added the poem to your tasks.", copied)
        }
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Added the poem to your tasks.", route: "local",
                                            results: added, ask: "Add it to my tasks").text,
                       "Added the poem to your tasks.")
    }

    /// Round 3 P3 2: one note, also when Approvals is not known.
    func testOneNoteWhenApprovalsAreNotKnown() {
        let out = ActionClaimGuard.vet(reply: "Not done yet: Your note is waiting for your OK in Approvals.\n\nI started baking in 1985.",
                                       route: "local", results: [], ask: "Write a bio for my bakery", approvals: nil).text
        let notes = out.components(separatedBy: note).count - 1 + out.components(separatedBy: ActionClaimGuard.nothingDoneNote).count - 1
        XCTAssertEqual(notes, 1, out)
    }

    /// A write this turn that waits in Approvals is named, writing ask or not.
    func testAWaitingWriteIsStillNamed() {
        let held: [ActionClaimGuard.ToolResult] = [("create_note", ["title": "Story"], "pending: queued for your approval")]
        let reply = "I saved the story to your notes."
        let asked = ActionClaimGuard.vet(reply: reply, route: "local", results: held, ask: "Write a story about a dragon")
        let plain = ActionClaimGuard.vet(reply: reply, route: "local", results: held, ask: "Save a story about a dragon")
        XCTAssertEqual(asked.text, plain.text)
        XCTAssertFalse(asked.text.hasPrefix(reply), asked.text)
    }

    /// A writing reply with no claim in it, and the cloud route, are untouched.
    func testNothingElseChanges() {
        let ask = "Write a text that tells our story for the bakery website"
        let plain = "Fresh bread every morning since 1985."
        XCTAssertEqual(ActionClaimGuard.vet(reply: plain, route: "local", results: [], ask: ask).text, plain)
        let reply = "We started as a small family business in 1985."
        XCTAssertEqual(ActionClaimGuard.vet(reply: reply, route: "anthropic", results: [], ask: ask).text, reply)
    }
}
