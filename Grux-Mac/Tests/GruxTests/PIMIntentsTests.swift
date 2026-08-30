import XCTest
@testable import Grux

// Pins the voice-first PIM parser (Foundry batch 2): utterance fixtures
// across 10+ phrasings including relative dates, slot extraction, and plan
// construction. Pure parsing only: no EventKit, no NotesStore, no network.
final class PIMIntentsTests: XCTestCase {

    private var cal: Foundation.Calendar {
        var c = Foundation.Calendar(identifier: .gregorian)
        c.timeZone = .current // NSDataDetector resolves in the system zone
        return c
    }

    // MARK: - Calendar: utterance fixtures

    func test_calendar_putOnMyCalendar_fridayTime() {
        let m = PIMIntents.match("put lunch with Sarah on my calendar Friday at 1pm")
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "Lunch with Sarah")
        let date = m?.slots.date
        XCTAssertNotNil(date)
        XCTAssertEqual(cal.component(.weekday, from: date!), 6, "Friday")
        XCTAssertEqual(cal.component(.hour, from: date!), 13)
        XCTAssertEqual(m?.slots.dateIsAllDay, false)
    }

    func test_calendar_pastDate_handsOffToClaude() {
        // An explicit past year resolves before now, so a confident calendar
        // plan would file a stale event. match must decline and let Claude
        // clarify. (Bare phrasing like "January 2" rolls forward to next year
        // and is correctly NOT past, so an explicit year pins the past case.)
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 15; c.hour = 12
        let now = Calendar(identifier: .gregorian).date(from: c)!
        let m = PIMIntents.match("put taxes on my calendar January 2 2020 at 9am", now: now)
        XCTAssertNil(m, "a past-resolved date should not become a confident calendar plan")
    }

    func test_calendar_addToTheCalendar_tomorrow() {
        let m = PIMIntents.match("add dentist appointment to the calendar tomorrow at 9am")
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "Dentist appointment")
        guard let date = m?.slots.date else { return XCTFail("no date") }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertTrue(cal.isDate(date, inSameDayAs: tomorrow))
        XCTAssertEqual(m?.slots.dateIsAllDay, false)
    }

    func test_calendar_schedule_nextTuesday() {
        let m = PIMIntents.match("schedule a call with the supplier next Tuesday at 3pm")
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "Call with the supplier")
        guard let date = m?.slots.date else { return XCTFail("no date") }
        XCTAssertEqual(cal.component(.weekday, from: date), 3, "Tuesday")
        XCTAssertEqual(cal.component(.hour, from: date), 15)
    }

    func test_calendar_relative_inTwoHours() {
        let now = Date()
        let m = PIMIntents.match("put the ACME inventory check on my calendar in 2 hours", now: now)
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "ACME inventory check")
        guard let date = m?.slots.date else { return XCTFail("no date") }
        let delta = date.timeIntervalSince(now)
        XCTAssertEqual(delta, 7200, accuracy: 600, "roughly now + 2h")
        XCTAssertEqual(m?.slots.dateIsAllDay, false)
    }

    func test_calendar_dateBeforeCalendarKeyword_excisedFromTitle() {
        let m = PIMIntents.match("add lunch with Marcus Friday at noon to my calendar")
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "Lunch with Marcus")
        XCTAssertNotNil(m?.slots.date)
        XCTAssertEqual(m?.slots.dateIsAllDay, false, "noon is a time")
    }

    func test_calendar_dateOnly_isAllDay() {
        let m = PIMIntents.match("put the trade show on my calendar next Friday")
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "Trade show")
        XCTAssertNotNil(m?.slots.date)
        XCTAssertEqual(m?.slots.dateIsAllDay, true, "no time of day given")
    }

    func test_calendar_noDate_isNotConfident() {
        XCTAssertNil(PIMIntents.match("put lunch with Sarah on my calendar"),
                     "no time anchor: fall through to Claude, do not invent a slot")
    }

    func test_calendar_withPreamble() {
        let m = PIMIntents.match("hey grux, can you put the standup on my calendar tomorrow at 10am")
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "Standup")
    }

    // MARK: - Calendar: question shapes and unanchored schedule/book fall through

    func test_calendar_questionWithTrailingMark_fallsThrough() {
        XCTAssertNil(
            PIMIntents.match("can you schedule the foundry upgrade cycle for tonight at 11pm?"),
            "questions route to Claude; the fast path must not steal them"
        )
        XCTAssertNil(PIMIntents.match("did you put lunch with Sarah on my calendar Friday at 1pm?"))
    }

    func test_calendar_interrogativeLead_fallsThrough() {
        XCTAssertNil(PIMIntents.match("when did I schedule the call with the supplier for Tuesday at 3pm"),
                     "status lookups are not commands")
        XCTAssertNil(PIMIntents.match("should I book dinner with Alex tomorrow at 7pm"))
    }

    func test_calendar_scheduleWithoutEventMarker_fallsThrough() {
        XCTAssertNil(
            PIMIntents.match("schedule the foundry upgrade cycle for tonight at 11pm"),
            "no with-clause or event noun: a task for Claude, not a calendar entry"
        )
    }

    func test_calendar_scheduleWithEventMarker_stillMatches() {
        let m = PIMIntents.match("book dinner with Alex tomorrow at 7pm")
        XCTAssertEqual(m?.kind, .addToCalendar)
        XCTAssertEqual(m?.slots.title, "Dinner with Alex")
        // And the explicit put-on-my-calendar route never needed a marker.
        let put = PIMIntents.match("put the trade show on my calendar next Friday")
        XCTAssertEqual(put?.kind, .addToCalendar)
    }

    // MARK: - Note: utterance fixtures

    func test_note_noteThat() {
        let m = PIMIntents.match("note that the bar soap is always a 2 pack")
        XCTAssertEqual(m?.kind, .takeNote)
        XCTAssertEqual(m?.slots.title, "the bar soap is always a 2 pack")
    }

    func test_note_takeANote_colon() {
        let m = PIMIntents.match("take a note: order more filament for the P1S")
        XCTAssertEqual(m?.kind, .takeNote)
        XCTAssertEqual(m?.slots.title, "order more filament for the P1S")
    }

    func test_note_writeThisDown() {
        let m = PIMIntents.match("write this down, the supplier quote came in at $1,400")
        XCTAssertEqual(m?.kind, .takeNote)
        XCTAssertEqual(m?.slots.title, "the supplier quote came in at $1,400")
    }

    func test_note_winsOverEmbeddedEmailPhrase() {
        let m = PIMIntents.match("note that I still need to email Sarah about the invoice")
        XCTAssertEqual(m?.kind, .takeNote, "start-anchored note trigger outranks the email phrase inside it")
    }

    // A multi-line dictation/paste must still match: the whole-string anchored
    // regexes used to fail because default '.' does not cross '\n', dropping a
    // confident note to the generic Claude path.
    func test_note_multilineUtteranceStillMatches() {
        let m = PIMIntents.match("note that first line\nsecond line")
        XCTAssertEqual(m?.kind, .takeNote, "internal newline must not break the note match")
        XCTAssertEqual(m?.slots.title, "first line second line")
    }

    func test_calendar_multilineUtteranceStillMatches() {
        let m = PIMIntents.match("put lunch with Sarah on my calendar\ntomorrow at 1pm")
        XCTAssertEqual(m?.kind, .addToCalendar, "internal newline must not break the calendar match")
    }

    // MARK: - Email: utterance fixtures

    func test_email_emailNameAbout() {
        let m = PIMIntents.match("email Sarah about the invoice from last week")
        XCTAssertEqual(m?.kind, .draftEmail)
        XCTAssertEqual(m?.slots.recipient, "Sarah")
        XCTAssertEqual(m?.slots.title, "the invoice from last week")
    }

    func test_email_draftAnEmailTo() {
        let m = PIMIntents.match("draft an email to the supplier about the May shipment")
        XCTAssertEqual(m?.kind, .draftEmail)
        XCTAssertEqual(m?.slots.recipient, "the supplier")
        XCTAssertEqual(m?.slots.title, "the May shipment")
    }

    func test_email_sendNameAnEmail() {
        let m = PIMIntents.match("send Marcus an email about rescheduling Thursday")
        XCTAssertEqual(m?.kind, .draftEmail)
        XCTAssertEqual(m?.slots.recipient, "Marcus")
        XCTAssertEqual(m?.slots.title, "rescheduling Thursday")
    }

    func test_email_withoutTopicConnector_isNotConfident() {
        XCTAssertNil(PIMIntents.match("email looks broken on the site"),
                     "no recipient/topic shape: not a PIM command")
    }

    // MARK: - Email: descriptions of mail are not commands to send mail

    func test_email_recipientSwallowedVerb_fallsThrough() {
        XCTAssertNil(
            PIMIntents.match("email Sarah sent yesterday that the deal closed, summarize it"),
            "an utterance about an inbound email must reach Claude, not the outbound draft flow"
        )
    }

    func test_email_question_fallsThrough() {
        XCTAssertNil(PIMIntents.match("did you email Sarah about the invoice?"))
        XCTAssertNil(PIMIntents.match("when did I email the supplier about the May shipment"))
    }

    // MARK: - Document: utterance fixtures

    func test_document_findTheDocAbout() {
        let m = PIMIntents.match("find the doc about the Foundry blueprint")
        XCTAssertEqual(m?.kind, .findDocument)
        XCTAssertEqual(m?.slots.title, "Foundry blueprint")
    }

    func test_document_wheresTheDocument() {
        let m = PIMIntents.match("where's the document about ACME pricing")
        XCTAssertEqual(m?.kind, .findDocument)
        XCTAssertEqual(m?.slots.title, "ACME pricing")
    }

    func test_document_searchMyDocumentsFor() {
        let m = PIMIntents.match("search my documents for the packaging spec")
        XCTAssertEqual(m?.kind, .findDocument)
        XCTAssertEqual(m?.slots.title, "packaging spec")
    }

    // MARK: - Negative fixtures

    func test_nonPIM_utterances_returnNil() {
        for u in [
            "play some music",
            "what's on my calendar today",
            "what am I working on",
            "ship the release",
            "open chrome",
            "how do I sign a pkg installer"
        ] {
            XCTAssertNil(PIMIntents.match(u), "should not match: \(u)")
        }
    }

    // MARK: - Plan construction (no live EventKit / stores)

    func test_plan_calendar_buildsCreateEventInput() {
        let plan = PIMIntents.plan(for: "put lunch with Sarah on my calendar Friday at 1pm")
        XCTAssertEqual(plan?.kind, .addToCalendar)
        XCTAssertEqual(plan?.toolName, "create_event")
        XCTAssertEqual(plan?.toolInput?["title"] as? String, "Lunch with Sarah")
        let start = plan?.toolInput?["start"] as? String
        XCTAssertNotNil(start)
        XCTAssertTrue(start!.contains("T13:00:00"), "local 1pm, got \(start!)")
        // CalendarTool must accept exactly this string.
        let parsed = CalendarTool.parseDateInput(start!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.isDateOnly, false)
        XCTAssertTrue(plan!.requiresUndoWindow)
        XCTAssertTrue(plan!.spokenAck.lowercased().contains("locked in"))
        XCTAssertTrue(plan!.spokenAck.contains("lunch with Sarah"))
    }

    func test_plan_calendar_allDay_isDateOnlyStart() {
        let plan = PIMIntents.plan(for: "put the trade show on my calendar next Friday")
        let start = plan?.toolInput?["start"] as? String
        XCTAssertNotNil(start)
        XCTAssertEqual(CalendarTool.parseDateInput(start!)?.isDateOnly, true)
    }

    func test_plan_note_buildsCreateNoteInput() {
        let plan = PIMIntents.plan(for: "note that the bar soap is always a 2 pack")
        XCTAssertEqual(plan?.toolName, "create_note")
        XCTAssertEqual(plan?.toolInput?["body"] as? String, "the bar soap is always a 2 pack")
        XCTAssertEqual(plan?.toolInput?["title"] as? String, "The bar soap is always a 2 pack")
        XCTAssertTrue(plan!.requiresUndoWindow)
        XCTAssertTrue(plan!.spokenAck.hasPrefix("Noted:"))
    }

    func test_plan_note_longBody_titleTruncated() {
        let body = "the supplier said the turmeric citrus grove batch ships on the twenty second and the invoice net terms moved to 45 days"
        let plan = PIMIntents.plan(for: "note that \(body)")
        let title = plan?.toolInput?["title"] as? String
        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title!.count, 61, "create_note wants <60 char titles plus ellipsis")
        XCTAssertEqual(plan?.toolInput?["body"] as? String, body)
    }

    func test_plan_document_buildsDocumentsListInput() {
        let plan = PIMIntents.plan(for: "find the doc about the Foundry blueprint")
        XCTAssertEqual(plan?.toolName, "documents_list")
        XCTAssertEqual(plan?.toolInput?["query"] as? String, "Foundry blueprint")
        XCTAssertFalse(plan!.requiresUndoWindow, "read-only search runs immediately")
    }

    func test_plan_email_delegatesToChat_andCannotLoop() {
        let plan = PIMIntents.plan(for: "email Sarah about the invoice from last week")
        XCTAssertEqual(plan?.kind, .draftEmail)
        XCTAssertNil(plan?.toolName, "email never dispatches compose_email directly")
        guard let prompt = plan?.chatPrompt else { return XCTFail("expected chat delegation") }
        XCTAssertTrue(prompt.contains("Sarah"))
        XCTAssertTrue(prompt.contains("the invoice from last week"))
        XCTAssertTrue(prompt.contains("Do NOT call compose_email until I confirm"))
        // The synthesized prompt must NOT re-match a PIM trigger when it
        // round-trips through ChatService.send, or we loop forever.
        XCTAssertNil(PIMIntents.match(prompt), "delegation prompt re-matched a PIM trigger")
    }

    // MARK: - Classifier route

    func test_intentClassifier_pimRoute_delegates() {
        XCTAssertEqual(
            ChatIntentClassifier.pimRoute(utterance: "note that the printer needs filament")?.kind,
            .takeNote
        )
        XCTAssertNil(ChatIntentClassifier.pimRoute(utterance: "play a hype song"))
    }

    // MARK: - Helpers

    func test_looksTimed_heuristic() {
        XCTAssertTrue(PIMIntents.looksTimed("Friday at 1pm"))
        XCTAssertTrue(PIMIntents.looksTimed("tomorrow at 9:30"))
        XCTAssertTrue(PIMIntents.looksTimed("noon"))
        XCTAssertFalse(PIMIntents.looksTimed("next Friday"))
        XCTAssertFalse(PIMIntents.looksTimed("tomorrow"))
    }

    func test_detectDate_inNMinutes_fallback() {
        let now = Date()
        let d = PIMIntents.detectDate(in: "check the oven in 20 minutes", now: now)
        XCTAssertNotNil(d)
        XCTAssertEqual(d!.date.timeIntervalSince(now), 1200, accuracy: 300)
        XCTAssertTrue(d!.hasTime)
    }
}
