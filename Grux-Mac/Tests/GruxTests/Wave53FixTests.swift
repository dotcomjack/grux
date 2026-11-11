import XCTest
@testable import Grux

/// W53-FIX: the wave 53 review's findings (`~/grux-loop/logs/wave53-review.txt`),
/// each with the review's own failing input.
@MainActor
final class Wave53FixTests: XCTestCase {

    private let draftAsk = "Write a short email to Sarah about lunch tomorrow"

    private func calendar(_ id: Calendar.Identifier) throws -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return c
    }

    // MARK: 1 (P1): the day line on a Mac whose calendar is not Gregorian

    /// Islamic and Persian calendars read Nov 4 2026 as month 5 or 8, so the
    /// line said "Tomorrow is Thursday, May 25." The names are Gregorian English.
    func testTheDayLineIsGregorianWhateverCalendarTheMacUses() throws {
        let wed = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T20:49:00-05:00"))
        for id in [Calendar.Identifier.islamic, .persian, .hebrew, .buddhist, .japanese, .gregorian] {
            let note = try XCTUnwrap(DraftAsk.localNote(ask: draftAsk, now: wed, calendar: try calendar(id)))
            XCTAssertTrue(note.contains("Tomorrow is Thursday, November 5."), "\(id): \(note)")
            XCTAssertEqual(DraftAsk.checkingDays(reply: "Lunch on Tuesday?", ask: draftAsk, now: wed, calendar: try calendar(id)),
                           "Lunch on Tuesday?\n\nTomorrow is Thursday, November 5. This draft names Tuesday: "
                           + "check that is the day you mean before you send it.", "\(id)")
        }
    }

    /// Hebrew numbers Elul month 13: `months[12]` was out of range, a crash.
    func testTheDayLineDoesNotCrashInElul() throws {
        let elul = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-09-15T12:00:00-04:00"))
        XCTAssertEqual(try calendar(.hebrew).component(.month, from: elul), 13, "control: Elul is month 13")
        let note = try XCTUnwrap(DraftAsk.localNote(ask: draftAsk, now: elul, calendar: try calendar(.hebrew)))
        XCTAssertTrue(note.contains("Tomorrow is Thursday, September 16."), note)
    }

    // MARK: 4 (P2): a draft is never rewritten; the day is named after it

    /// Rounds 1 and 2 found drafts that name another day on purpose, which the
    /// weekday rewrite turned into the day being declined. The draft is left
    /// exactly as written and one line after it names the day asked about.
    func testADraftIsNeverRewritten_theDayIsNamedAfterIt() throws {
        let wed = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T09:00:00-05:00"))
        let cal = try calendar(.gregorian)
        func check(_ reply: String, _ ask: String) -> String? {
            DraftAsk.checkingDays(reply: reply, ask: ask, now: wed, calendar: cal)
        }
        let sick = "Write a text to my boss that I'm out sick today"
        let lunch = "Write an email to Sarah saying I can't make lunch tomorrow"
        let today = "Today is Wednesday, November 4."
        let tomorrow = "Tomorrow is Thursday, November 5."
        func tail(_ day: String, _ list: String) -> String {
            "\n\n\(day) This draft names \(list): check that is the day you mean before you send it."
        }
        // Both rounds' inputs: left as written, the day named after.
        for (reply, ask, day, list) in [
            ("Hi, I'm out sick today. I'll be back Monday.", sick, today, "Monday"),
            ("Hi Tom, I'm unwell and won't be in. See you Monday.", sick, today, "Monday"),
            ("I hope to be back in the office on Monday.", sick, today, "Monday"),
            ("Sorry, I can't make lunch tomorrow. Could we do Friday instead?", lunch, tomorrow, "Friday"),
            ("Sorry, I can't make lunch. How about Friday?", lunch, tomorrow, "Friday"),
            ("Can we do this Friday or next?", lunch, tomorrow, "Friday"),
            ("I'm thinking of grabbing some food on Tuesday.", draftAsk, tomorrow, "Tuesday"),
        ] {
            XCTAssertEqual(check(reply, ask), reply + tail(day, list), reply)
        }
        // Every other weekday named once, in order; the day asked about is not listed.
        XCTAssertEqual(check("Can we meet Monday? Or Friday, or monday?", sick),
                       "Can we meet Monday? Or Friday, or monday?" + tail(today, "Monday and Friday"))
        XCTAssertEqual(check("Monday, Tuesday or Friday, not Wednesday.", sick),
                       "Monday, Tuesday or Friday, not Wednesday." + tail(today, "Monday, Tuesday and Friday"))
        // Only the asked day, or none: nothing added.
        XCTAssertNil(check("Lunch on Thursday?", draftAsk))
        XCTAssertNil(check("Lunch tomorrow?", draftAsk))
        XCTAssertNil(check("I love Mondays and Wednesdayish plans.", draftAsk))
        // A weekday in a paragraph Grux added after the draft is not the draft's.
        let held = "Lunch tomorrow?\n\n" + ActionClaimGuard.approvalsPrefix + "Add the event \"Friday standup\"."
        XCTAssertNil(check(held, draftAsk))
        XCTAssertNil(check("Lunch tomorrow?\n\nNot done yet: the event \"Friday standup\" is waiting.", draftAsk))
        // Not a draft ask, or a day the ask does not count: nothing added.
        XCTAssertNil(check("Friday works.", "What's for lunch tomorrow?"))
        XCTAssertNil(check("Friday works.", "Write a text to Sam about the day after tomorrow"))
    }

    // MARK: 2 (P2): a cut copy never leaves a reply with no true line

    func testACutCopyAlwaysLeavesATrueLine() {
        let copy = "Your note is waiting for your OK in Approvals. Nothing is saved until you approve it."
        // After a question, with Approvals empty: the person is told nothing waits.
        let q = ActionClaimGuard.vet(reply: "Yes, it is still there. " + copy, route: "local", results: [],
                                     ask: "Is my note still waiting?", approvals: [])
        XCTAssertEqual(q.text, "Yes, it is still there.\n\n" + ActionClaimGuard.nothingWaitsLine)
        let held = ["Send the email to Maria."]
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Yes, it is still there. " + copy, route: "local", results: [],
                                            ask: "Is my note still waiting?", approvals: held).text,
                       "Yes, it is still there.\n\n" + ActionClaimGuard.approvalsLine(held))
        XCTAssertEqual(ActionClaimGuard.vet(reply: "Yes, it is still there. " + copy, route: "local", results: [],
                                            ask: "Is my note still waiting?").text,
                       "Yes, it is still there.\n\n" + ActionClaimGuard.nothingDoneNote)
        // After a request with no tool run: what Approvals holds, never a bare "Sure thing!".
        let r = ActionClaimGuard.vet(reply: "Sure thing! Not done yet: " + copy.prefix(1).lowercased() + copy.dropFirst(),
                                     route: "local", results: [], ask: "Save a note: buy milk", approvals: [])
        XCTAssertEqual(r.text, "Sure thing!\n\n" + ActionClaimGuard.nothingWaitsLine)
        XCTAssertTrue(r.replaced)
        // Round 2: a request that was answered keeps its answer; nothing says it was not done.
        let read: [ActionClaimGuard.ToolResult] = [("list_inbox", [:], "- [Work] Nov 4 | Maria | Deck")]
        let summary = "You have one unread email, from Maria about the deck."
        let answered = ActionClaimGuard.vet(reply: summary + " " + copy, route: "local", results: read,
                                            ask: "Summarize my unread mail", approvals: [])
        XCTAssertEqual(answered.text, summary + "\n\n" + ActionClaimGuard.nothingWaitsLine)
        XCTAssertFalse(answered.text.contains(ActionClaimGuard.offer))
        let draft = "Hi Sarah, are you free for lunch tomorrow?"
        let drafted = ActionClaimGuard.vet(reply: draft + "\n\n" + copy, route: "local", results: [],
                                           ask: "Write an email to Sarah about lunch tomorrow", approvals: held)
        XCTAssertEqual(drafted.text, draft + "\n\n" + ActionClaimGuard.approvalsLine(held))
        // Approvals not known and a tool ran: nothing is claimed either way.
        XCTAssertEqual(ActionClaimGuard.vet(reply: summary + " " + copy, route: "local", results: read,
                                            ask: "Summarize my unread mail").text, summary)
    }

    // MARK: 3 (P2): nothing after the ask is read as the note

    /// Rounds 1 and 2 found commands and changes of mind the follow-up took as
    /// the note. There is no follow-up: `reply(for:)` reads only the message in
    /// hand, so "Remind me to call the vet at 5" after the ask goes on as
    /// itself. The ask says how to send the words, and its own example works.
    func testTheAskForWordsGivesAnExampleThatWritesTheNote() throws {
        for (ask, app, topic) in [("Write a note to Joplin about the recipe", "Joplin", "the recipe" as String?),
                                  ("Put a note in Logseq.", "Logseq", nil),
                                  ("Make a note in Day One about the 3:30 call", "Day One", "the 3:30 call"),
                                  ("Add an entry to Bear on the trip", "Bear", "the trip")] {
            let asked = try XCTUnwrap(ForeignNoteAsk.reply(for: ask), ask)
            XCTAssertEqual(asked, ForeignNoteAsk.askForWords(app: app, topic: topic))
            XCTAssertFalse(asked.contains("What should it say?"), asked)
            // The quoted example, with words in place of "your words", is a note.
            let quote = try XCTUnwrap(asked.components(separatedBy: "\"").dropFirst().first, asked)
            let filled = quote.replacingOccurrences(of: "your words", with: "buy milk")
            XCTAssertEqual(ForeignNoteAsk.reply(for: filled),
                           ForeignNoteAsk.note(app: app, topic: topic, words: "buy milk"), filled)
        }
        for answer in ["Remind me to call the vet at 5", "Mark the dentist task as done", "nvm", "Milk, eggs and bread"] {
            XCTAssertNil(ForeignNoteAsk.reply(for: answer), answer)
        }
    }

    /// The class guard: chat hands the note fast path the message in hand and
    /// nothing from the thread, so no later message can become a note again.
    func testChatGivesTheNotePathOnlyTheMessageInHand() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let calls = src.components(separatedBy: "ForeignNoteAsk.reply(").dropFirst()
        XCTAssertEqual(calls.count, 1, "one call site")
        for call in calls {
            XCTAssertTrue(call.hasPrefix("for: trimmed)"), "the note path reads more than the message: \(call.prefix(120))")
        }
        let fna = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Chat/ForeignNoteAsk.swift"), encoding: .utf8)
        XCTAssertFalse(fna.contains("previousReply"), "the note path reads Grux's last reply again")
    }

    /// The words open at a colon followed by a space, so a time in the topic stays whole.
    func testATimeInTheTopicIsNotTheWords() {
        XCTAssertEqual(ForeignNoteAsk.match("Write a note in Obsidian about the 3:30 call: bring the deck"),
                       ForeignNoteAsk.Ask(app: "Obsidian", topic: "the 3:30 call", words: "bring the deck"))
        XCTAssertEqual(ForeignNoteAsk.match("Write a note in Obsidian about the 3:30 call"),
                       ForeignNoteAsk.Ask(app: "Obsidian", topic: "the 3:30 call", words: nil))
        XCTAssertEqual(ForeignNoteAsk.match("Write a note in Obsidian about the trip:"),
                       ForeignNoteAsk.Ask(app: "Obsidian", topic: "the trip", words: nil))
    }

    // MARK: round 3: the colon way in takes every note

    /// A note typed on lines after its title: the colon before a newline opens the words.
    func testANoteOnSeveralLinesIsWritten() {
        XCTAssertEqual(ForeignNoteAsk.match("Write a note to Joplin about groceries:\nmilk\neggs"),
                       ForeignNoteAsk.Ask(app: "Joplin", topic: "groceries", words: "milk\neggs"))
        XCTAssertEqual(ForeignNoteAsk.match("Write a note to Joplin about groceries:\n- milk\n- eggs\n"),
                       ForeignNoteAsk.Ask(app: "Joplin", topic: "groceries", words: "- milk\n- eggs"))
        XCTAssertEqual(ForeignNoteAsk.match("Write a note to Joplin about the 3:30 call:\tbring the deck"),
                       ForeignNoteAsk.Ask(app: "Joplin", topic: "the 3:30 call", words: "bring the deck"))
    }

    /// The note's own words may say "and make" or "then add"; only the ask before them is read for a second ask.
    func testTheNotesOwnWordsAreNeverReadAsASecondAsk() {
        for (ask, topic, words) in [
            ("Write a note to Joplin about the recipe: mix flour and sugar, then add eggs", "the recipe" as String?, "mix flour and sugar, then add eggs"),
            ("Write a note to Joplin about the recipe: buy milk and make dinner", "the recipe", "buy milk and make dinner"),
            ("Write a note to Joplin saying: call mom and send flowers", nil, "call mom and send flowers"),
            ("Write a note to Joplin: draft a message to Sam about lunch", nil, "draft a message to Sam about lunch"),
        ] {
            XCTAssertEqual(ForeignNoteAsk.match(ask), ForeignNoteAsk.Ask(app: "Joplin", topic: topic, words: words), ask)
        }
        // A second ask before the words still goes to the model.
        XCTAssertNil(ForeignNoteAsk.match("Write a note to Joplin and remind me tomorrow: buy milk"))
        XCTAssertNil(ForeignNoteAsk.match("Write a note to Joplin about the trip and then add a task"))
    }

    /// Always on keeps what it hears as text on this Mac whatever model there
    /// is (round 4: "with a model key" was the wrong condition; a local model
    /// does the noting too), and the model reads it for more than plans and
    /// promises, passwords said aloud included, so the copy names no condition
    /// and no closed list.
    func testListeningCopySaysWhatAlwaysOnKeeps() throws {
        let always = ListeningMode.alwaysOn.explanation
        for text in [always, try listeningPoint()] {
            XCTAssertFalse(text.contains("Nothing you say is kept"), text)
            XCTAssertFalse(text.contains("With a model key"), text)
            XCTAssertTrue(text.contains("kept as text on this Mac"), text)
            // Round 5: a cloud model reads it at the provider, and for more than memory.
            XCTAssertTrue(text.contains("Any model Grux uses, on this Mac or at your model provider, can read that text"), text)
            XCTAssertTrue(text.contains("for example to remember plans, facts, people and decisions you mention"), text)
            XCTAssertTrue(text.contains("passwords said aloud included"), text)
        }
        // Never readable as covering the wake word, whose audio may go to Apple.
        XCTAssertTrue(always.hasSuffix("Always on's audio stays on this Mac."), always)
        XCTAssertFalse(always.contains("The audio stays"), always)
        // The wake word's audio may go to Apple, as the consent sheet says.
        let point = try listeningPoint()
        XCTAssertTrue(point.contains("Always on's audio never leaves this Mac"), point)
        XCTAssertTrue(point.contains("may send short audio to Apple"), point)
        XCTAssertTrue(MicConsent.body(for: .wakeWord).contains("may send short audio to Apple"), "control: the sheet says it")
        let line = HowItWorksStep.whatStaysHere
        XCTAssertTrue(line.contains("while listening is on"), line)
        XCTAssertTrue(line.contains("what it hears and a picture of your screen go as they are"), line)
    }

    private func listeningPoint() throws -> String {
        try XCTUnwrap(HowItWorksStep.parts.compactMap { part -> String? in
            if case .point(let p) = part, p.title == "What is off until you say so" { return p.body }
            return nil
        }.first)
    }

    // MARK: 5 (P2): first run says only what the build does

    func testWhatStaysHereClaimsNoRedactionTheBuildDoesNotDo() {
        let line = HowItWorksStep.whatStaysHere
        XCTAssertFalse(line.contains("blanks out"), "screenshots and inbox listings go unredacted: \(line)")
        XCTAssertTrue(line.contains("a picture of your screen go as they are"), line)
        XCTAssertTrue(line.contains("sort new mail and notifications"), "the unasked paths are named: \(line)")
        XCTAssertTrue(line.contains("once Focus is set up, look at your screen now and then"), line)
        XCTAssertTrue(line.contains("Passwords and keys are taken out of mail and notification text first"), line)
        XCTAssertTrue(line.contains("refuses one that holds an API key"), line)
        XCTAssertFalse(line.contains("keeps all of it on this Mac"), "read_screen uses a cloud key even when chat is local: \(line)")
    }
}
