import XCTest
@testable import Grux

/// D157 item 17 and D159: a message the person asks Grux to write for someone
/// is drafted in the reply, never asked about first and never saved as a note.
@MainActor
final class DraftAskTests: XCTestCase {

    /// The live asks, and the shapes around them.
    static let drafts = [
        "Write a short email to my landlord saying the kitchen sink is leaking.",
        "Draft a quick note to my boss that I'll be late tomorrow.",
        "write an email to the team about Friday",
        "Please write a thank-you note to my aunt for the sweater",
        "Can you draft a polite message to my neighbor about the noise?",
        "Could you write a letter to the editor about the bike lanes",
        "compose a text to my sister saying I landed",
        "Grux, write a reply to my manager saying yes",
        "write me a short, friendly note to Sarah thanking her for dinner",
        "Draft an e-mail to our landlord asking for the deposit back",
        "write a formal email to his teacher about the trip",
    ]

    /// Not a message to someone: a note to keep, a question, a compound ask
    /// that also wants something saved, or no recipient at all.
    static let notDrafts = [
        "write a note to self: buy milk", "Write a note to myself to call the bank",
        "write a note to remind me about the dentist", "write a note to the file",
        "Make a note to call my boss", "note that my boss is out tomorrow",
        "Write a short email", "write a note for the meeting",
        "Draft a note to my boss and add a task to follow up",
        "write an email to my landlord, then remind me tomorrow",
        "What should I write to my boss?", "Did you write the email to my landlord?",
        "Remind me to write an email to my landlord", "I wrote a note to my boss",
        "write the Q3 report", "write a poem about the sea", "",
        "write a note to me", "write an email to Me about lunch",
    ]

    func testAMessageToSomeoneIsADraftAndNothingElseIs() {
        for ask in Self.drafts { XCTAssertTrue(DraftAsk.matches(ask), ask) }
        for ask in Self.notDrafts { XCTAssertFalse(DraftAsk.matches(ask), ask) }
    }

    /// W52-FIX (wave 52 review, P2-1 and P2-2): a note to keep for oneself or
    /// in an app read as a message to a person and lost every tool; a reply to a
    /// message that exists, or a message also to be sent, lost the tool that
    /// reads or sends it. Each stays with the model and its tools. The drafts
    /// beside them, one word away, still match.
    func testANoteToKeepOrAMessageToSendIsNotADraft() {
        let kept = [
            "Write a note to my future self: stretch every hour",
            "write a note to my older self about this year",
            "write a note to my journal about today", "Write a note to my diary",
            "write a note to my notebook", "write a note to my notes saying buy milk",
            "Write a note to Apple Notes saying buy milk", "write a note to Notion about the launch",
            "write a note to Evernote", "write a note to Obsidian: idea for the app",
            "WRITE A NOTE TO REMIND ME TO CALL MOM", "WRITE AN EMAIL TO MY LANDLORD",
            "Write a reply to Sarah's last email", "write a reply to Sarah\u{2019}s message",
            "write a reply to my boss's email", "write a reply to the email from Sam",
            "write a reply to the message from my landlord", "Draft a reply to the text from Mom",
            "Write an email to Sam and send it", "write an email to my landlord and send it",
            "draft a message to my boss then send it", "write a text to my sister and text it to her",
        ]
        for ask in kept { XCTAssertFalse(DraftAsk.matches(ask), ask) }
        let stillDrafts = [
            "Write a note to my boss: I'll be late", "write a reply to Sarah saying yes",
            "write an email to Sam about Friday", "Write a short email to my landlord",
            "write a letter to my future employer", "Draft a note to Kim about lunch",
        ]
        for ask in stillDrafts { XCTAssertTrue(DraftAsk.matches(ask), ask) }
    }

    /// W52-FIX round 2: a deny-list let through a note to "Future Me" or to
    /// "my to-do list", and a reply that names the email fourth or later. After
    /// "my", "the" and the like the recipient must now be a person word, and
    /// any message word after "to" leaves the ask with its tools.
    func testOnlyAPersonAfterMyIsARecipient_andAMessageNamedLaterKeepsItsTools() {
        let kept = [
            "Write a note to Future Me: stretch every hour", "write a note to my future me",
            "Write a note to my to-do list: call the plumber", "write a note to my shopping list: eggs",
            "write a note to my grocery list", "write a note to the fridge", "write a note to my desktop",
            "Write a reply to Sam about his last email", "Draft a reply to my boss about her email",
            "write a reply to Sam saying I got his message", "draft an email to my boss about the thread",
            "write a note to Myself", "write a note to Me and Sam",
        ]
        for ask in kept { XCTAssertFalse(DraftAsk.matches(ask), ask) }
        let stillDrafts = [
            "write a note to my new boss: I'll be late", "write an email to the hiring manager about the role",
            "write a letter to our new neighbors about the fence", "Draft a thank-you note to my grandma",
            "write a reply to my landlord saying yes", "write a text to my wife saying I'm on my way",
        ]
        for ask in stillDrafts { XCTAssertTrue(DraftAsk.matches(ask), ask) }
    }

    /// W52-FIX round 3, the class fix: the recipient is a closed phrase. After
    /// "my", "the" and the like (any case) it is a person word that ENDS the
    /// phrase (the end, punctuation, or a word like "about", "saying", "that");
    /// a name is mixed case and is followed by such a word. "the team doc",
    /// "My Desktop" and "Things: buy milk" are places to keep a note, so the
    /// ask keeps its tools. "us" and "ourselves" are never someone to write to.
    func testTheRecipientIsAPersonThatEndsThePhrase() {
        let kept = [
            "Write a note to My Desktop", "Write a note to The fridge: buy milk",
            "Write a note to Groceries: eggs and milk", "Write a note to Things: buy milk",
            "Write a note to the team doc: launch moved to Friday", "write a note to the client doc",
            "write a note to my kids' chore chart", "Write a message to the team channel saying standup moved",
            "write a message to the team on Slack", "write a note to us about the trip",
            "write a note to ourselves", "write a note to Sam", "write a note to the team wiki about Friday",
        ]
        for ask in kept { XCTAssertFalse(DraftAsk.matches(ask), ask) }
        let stillDrafts = [
            "write a note to my boss", "write a note to my boss.", "Write a note to my boss: I'll be late",
            "write a note to my boss, I'll be late", "write a note to My Boss about Friday",
            "write a note to Sarah about lunch", "write an email to Sam Lee saying thanks",
            "write a note to my boss to say thanks", "write a letter to my future employer",
            "Write a note to MY BOSS",
        ]
        for ask in stillDrafts { XCTAssertTrue(DraftAsk.matches(ask), ask) }
    }

    /// W52-FIX round 4: the name path trusted any one or two capitalized
    /// words before "about", so a journaling app or a notes folder read as a
    /// person, and "to" cut "my team to do list" after "team". A name now has
    /// to be one the on-device NaturalLanguage tagger reads as a person's name
    /// (or Mom, Dad and the like), and "to do" never ends the phrase.
    func testANameIsAPersonsName_andToDoIsAList() {
        let kept = [
            "Write a note to Day One about today", "Write a note to Google Docs about the launch",
            "Write a note to Ideas for the app: dark mode", "Write a note to Work about the deck",
            "Write a note to Groceries about eggs", "write a note to Notion about the launch",
            "Write a note to my team to do list: ship Friday", "write a note to the family to do list",
            "write a note to Us about the trip", "write a note to Ourselves about the trip",
            // Round 5: apps the tagger itself reads as people (measured), kept out by name.
            "Write a note to Joplin about the recipe", "Write a note to Anytype about the reading list",
            "Write a note to Jira about the login bug", "Write a note to Asana about the launch tasks",
            "Write a note to Alfred about the hotkey", "Write a note to Siri about the timer",
            "Write a note to Alexa about the lights", "Write a note to Gemini about the trip",
        ]
        for ask in kept { XCTAssertFalse(DraftAsk.matches(ask), ask) }
        let stillDrafts = [
            "write an email to Sam about Friday", "write a reply to Kim saying yes", "write a text to Jo saying I landed",
            "write an email to Mom about Sunday", "write a note to my boss to say thanks",
        ]
        for ask in stillDrafts { XCTAssertTrue(DraftAsk.matches(ask), ask) }
        // Accepted misses, measured 2026-11-04 and not asserted (they pin Apple's
        // model, not the grammar): the tagger does not read "Al" or "Jordan" as a
        // person's name, so "Draft a note to Al about lunch" goes to the model
        // with its tools. Round 1 asserted "Al" matched; it no longer does.
    }

    func testTheLineSaysWriteItNowWithPlaceholdersAndDoNotSaveIt() throws {
        for ask in Self.drafts {
            let note = try XCTUnwrap(DraftAsk.localNote(ask: ask), ask)
            XCTAssertTrue(note.hasPrefix("DRAFT: "), note)
            XCTAssertTrue(note.contains("[Name]"), note)
            XCTAssertTrue(note.contains("Do not ask for them first"), note)
            XCTAssertTrue(note.contains("not a note, task or memory to save"), note)
        }
        for ask in Self.notDrafts { XCTAssertNil(DraftAsk.localNote(ask: ask), ask) }
        // The cost when it rides, in the per-turn block's own units.
        let note = try XCTUnwrap(DraftAsk.localNote(ask: Self.drafts[0]))
        XCTAssertLessThanOrEqual(LocalTurn.tokens(chars: note.count), 90, "the draft line grew: \(note.count) chars")
    }

    /// The live failures: the local turn for the boss note offered `create_note`,
    /// and with the note tools withheld it called `create_event` instead.
    func testALocalDraftTurnCarriesTheLineAndOffersNoTool() {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        func turn(_ lean: Bool, _ ask: String) -> (text: String, tools: Set<String>) {
            state.chat = [ChatMessage(role: .user, content: ask)]
            let p = ChatService.shared.assemblePendingContext(state: state, lean: lean, window: 16_384)
            return (p.systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n"),
                    Set(p.tools.map(\.name)))
        }
        let boss = turn(true, "Draft a quick note to my boss that I'll be late tomorrow.")
        XCTAssertTrue(boss.text.contains("DRAFT: "), "the local turn was not told")
        XCTAssertTrue(boss.tools.isEmpty, "offered \(boss.tools.sorted())")
        // A note to keep still reaches the note tool, and the cloud turn is unchanged.
        let keep = turn(true, "Make a note to call my boss")
        XCTAssertFalse(keep.text.contains("DRAFT: "))
        XCTAssertTrue(keep.tools.contains("create_note"), "a note to keep lost its tool")
        let cloud = turn(false, "Draft a quick note to my boss that I'll be late tomorrow.")
        XCTAssertFalse(cloud.text.contains("DRAFT: "), "a cloud turn carries it")
        XCTAssertTrue(cloud.tools.contains("create_note"), "a cloud turn lost a tool")
    }

    /// D163, live on grux-local:2b (8:49 PM Wednesday Nov 4): "Write a short email to
    /// Sarah about lunch tomorrow" came back "I'm thinking of grabbing some food on
    /// Tuesday." The NOW block carried the date; a 2B model still counted wrong. The
    /// draft line names the day the person said, and a weekday the draft names that
    /// they never asked for is named after it, the draft left as written (W53-FIX).
    func testADraftNamesTheDayThePersonMeant() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let wed = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T20:49:00-05:00"))
        let ask = "Write a short email to Sarah about lunch tomorrow"
        let note = try XCTUnwrap(DraftAsk.localNote(ask: ask, now: wed, calendar: cal))
        XCTAssertTrue(note.contains("Tomorrow is Thursday, November 5."), note)
        XCTAssertLessThanOrEqual(LocalTurn.tokens(chars: note.count), 110, "the draft line grew: \(note.count) chars")
        let tonight = try XCTUnwrap(DraftAsk.localNote(ask: "Write a text to Sam that I'm late tonight", now: wed, calendar: cal))
        XCTAssertTrue(tonight.contains("Today is Wednesday, November 4."), tonight)
        let plain = try XCTUnwrap(DraftAsk.localNote(ask: "Write a short email to my landlord saying the sink is leaking.",
                                                     now: wed, calendar: cal))
        XCTAssertFalse(plain.contains("day is"), plain)

        // W53-FIX: the draft is left as written and the day is named after it.
        func check(_ reply: String, _ ask: String = ask, at now: Date? = nil) -> String? {
            DraftAsk.checkingDays(reply: reply, ask: ask, now: now ?? wed, calendar: cal)
        }
        func named(_ day: String, _ list: String) -> String {
            "\n\n\(day) This draft names \(list): check that is the day you mean before you send it."
        }
        let tomorrow = "Tomorrow is Thursday, November 5."
        let live = "Subject: Lunch Plans\n\nHi Sarah,\n\nI'm thinking of grabbing some food on Tuesday. What are your plans?"
        XCTAssertEqual(check(live), live + named(tomorrow, "Tuesday"))
        XCTAssertEqual(check("See you Friday.", "Write a text to Sam that I'm late tonight"),
                       "See you Friday." + named("Today is Wednesday, November 4.", "Friday"))
        XCTAssertEqual(check("tuesday's lunch works."), "tuesday's lunch works." + named(tomorrow, "Tuesday"))
        XCTAssertEqual(check("TUESDAY works."), "TUESDAY works." + named(tomorrow, "Tuesday"))
        // Right already, or no weekday: nothing added.
        XCTAssertNil(check("Lunch on Thursday?"))
        XCTAssertNil(check("Lunch tomorrow?"))
        XCTAssertNil(check("I love Mondays."))
        // The person named a weekday, two days, or a day this cannot count: nothing added.
        XCTAssertNil(check("Lunch Tuesday?", "Write an email to Sarah about lunch tomorrow or Tuesday"))
        XCTAssertNil(check("Friday works.", "Write a text to Sam: not today, tomorrow"))
        XCTAssertNil(check("Friday works.", "Write a text to Sam about the day after tomorrow"))
        XCTAssertNil(check("Friday works.", "Write a text to Sam about yesterday and tomorrow"))
        // Not a draft ask: nothing added.
        XCTAssertNil(check(live, "What's for lunch tomorrow?"))
        // On either side of midnight.
        let late = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T23:59:59-05:00"))
        let early = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T00:00:00-05:00"))
        XCTAssertEqual(check("See you Tuesday.", at: late), "See you Tuesday." + named(tomorrow, "Tuesday"))
        XCTAssertEqual(check("See you Tuesday.", at: early),
                       "See you Tuesday." + named("Tomorrow is Friday, November 6.", "Tuesday"))
        XCTAssertNil(check("See you Friday.", at: early))
    }
}
