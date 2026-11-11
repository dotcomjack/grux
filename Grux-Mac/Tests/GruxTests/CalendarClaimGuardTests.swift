import XCTest
@testable import Grux

/// D140, live 2026-11-02 5:11 PM on qwen3.5:4b: "Is there anything going on
/// tonight?" came back "Nothing scheduled for tonight. Want me to block an hour
/// now for back-up work?" with no tool call. True by luck that day; with a
/// 7 PM dinner on the calendar it tells the person their evening is free. A
/// local reply that says the calendar is empty, on a turn that read no
/// calendar, is replaced by what the calendar holds.
@MainActor
final class CalendarClaimGuardTests: XCTestCase {

    private var cal: Foundation.Calendar = {
        var c = Foundation.Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 1
        return c
    }()
    private let us = Locale(identifier: "en_US")

    /// Monday Nov 2, 2026, 5:11 PM in New York: the live turn.
    private var now: Date { date(2026, 11, 2, 17, 11) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date) -> CalendarService.EventSummary {
        CalendarService.EventSummary(id: UUID().uuidString, title: title, start: start, end: end, isAllDay: false,
                                     location: nil, notes: nil, calendarName: "Home", calendarId: "home")
    }

    private var savedEvents: (@MainActor (Date, Date) -> [CalendarService.EventSummary]?)!

    override func setUp() async throws {
        try await super.setUp()
        savedEvents = CalendarAsk.events
    }

    override func tearDown() async throws {
        CalendarAsk.events = savedEvents
        try await super.tearDown()
    }

    private func vet(_ reply: String, ask: String, route: String = "local",
                     results: [ActionClaimGuard.ToolResult] = []) -> (text: String, replaced: Bool) {
        CalendarClaimGuard.vet(reply: reply, route: route, results: results, ask: ask,
                               now: now, calendar: cal, locale: us)
    }

    // MARK: - The live turn

    /// The live reply on a day with a 7 PM dinner: the person reads the dinner,
    /// not a free evening, and not the offer to block time that rested on it.
    func testAFreeEveningClaimWithNoReadSaysWhatTheCalendarHolds() {
        var asked: [(Date, Date)] = []
        let dinner = event("Dinner with Ana", date(2026, 11, 2, 19), date(2026, 11, 2, 21))
        CalendarAsk.events = { start, end in asked.append((start, end)); return [dinner] }

        let out = vet("Nothing scheduled for tonight. Want me to block an hour now for back-up work?",
                      ask: "Is there anything going on tonight?")

        XCTAssertTrue(out.replaced)
        XCTAssertEqual(asked.count, 1, "the calendar is read once, for the day asked about")
        XCTAssertEqual(asked.first?.0, date(2026, 11, 2))
        XCTAssertEqual(asked.first?.1, date(2026, 11, 3))
        XCTAssertEqual(out.text, "On your calendar today (Monday, Nov 2), one thing: Dinner with Ana, 7:00 PM to 9:00 PM.")
        XCTAssertFalse(out.text.contains("block"), out.text)
    }

    /// An empty day reads as the calendar's own empty line.
    func testAnEmptyDayReadsTheCalendarsOwnLine() {
        CalendarAsk.events = { _, _ in [] }
        let out = vet("Nothing scheduled for tonight. Want me to block an hour now for back-up work?",
                      ask: "Is there anything going on tonight?")
        XCTAssertTrue(out.replaced)
        XCTAssertEqual(out.text, "Nothing on your calendar today (Monday, Nov 2).")
    }

    /// With no Calendar access the person reads that Grux cannot look, never "free".
    func testNoAccessSaysGruxCannotLook() {
        CalendarAsk.events = { _, _ in nil }
        let out = vet("You're free tonight!", ask: "Anything tonight?")
        XCTAssertTrue(out.replaced)
        XCTAssertTrue(out.text.hasPrefix("I cannot read your calendar"), out.text)
    }

    // MARK: - What counts as a claim

    func testEveryEmptyCalendarWordingIsAClaim() {
        let claims = [
            "Nothing scheduled for tonight.",
            "Nothing scheduled.",
            "Nothing is planned for tomorrow.",
            "Your calendar is clear tomorrow.",
            "Your calendar's empty today.",
            "Your schedule is wide open this weekend.",
            "Your evening looks free.",
            "Your day is completely clear.",
            "You're free tonight.",
            "You are totally free on Friday.",
            "You have no meetings on Friday.",
            "You've got no events today.",
            "You have nothing scheduled tomorrow.",
            "You've got nothing planned for tonight.",
            "Nothing on your calendar this weekend.",
            "There's nothing on your schedule today.",
            "There are no events on your calendar tomorrow.",
            "Not tonight, your calendar is clear.",
            "Looks like a clear calendar today, so you can relax.",
            "Nothing going on tonight.",
            "No plans for tonight.",
        ]
        for reply in claims {
            XCTAssertTrue(CalendarClaimGuard.claimsCalendar(reply), "should be a claim: \(reply)")
        }
    }

    func testOtherRepliesAreNotClaims() {
        let answers = [
            "You're free to ask me anything.",
            "Feel free to ask.",
            "Nothing is waiting in Approvals.",
            "Your task stack is clear.",
            "Nothing scheduled to run in Commands yet.",
            "Are you free tonight?",
            "If you're free tonight, want me to plan dinner?",
            "Want me to check your calendar?",
            "I can put it on your calendar for tomorrow.",
            "I don't know about events in town tonight.",
            "Your day looks busy: three meetings.",
            "There is no meeting recording for that call.",
            "You have no tasks today.",
        ]
        for reply in answers {
            XCTAssertFalse(CalendarClaimGuard.claimsCalendar(reply), "should not be a claim: \(reply)")
        }
    }

    /// Live 8:44 PM on the installed build: "Got any plans for me tomorrow
    /// night?" came back with a copy of the earlier turn's words about TODAY,
    /// read nowhere, while tomorrow held Election Day. Stating what is on the
    /// calendar with no read is the same claim as saying it is empty.
    func testAStatedCalendarWithNoReadIsAClaimToo() {
        let claims = [
            "You've got an all-day Day of the Dead holiday on your calendar. Nothing else scheduled for tonight.",
            "Nothing else scheduled for tonight.",
            "Nothing else on tonight.",
            "You have nothing else planned tomorrow.",
            "Election Day is on your calendar tomorrow.",
            "There's a lunch with Sarah in your calendar at 1 PM.",
        ]
        for reply in claims {
            XCTAssertTrue(CalendarClaimGuard.claimsCalendar(reply), "should be a claim: \(reply)")
        }
        let offers = [
            "Want me to add that to your calendar?",
            "I'll block an hour on your calendar.",
            "I could put it on your calendar.",
            "Shall I schedule it on your calendar for Friday",
            "Open the Calendar tab to allow it.",
            "I cannot read your calendar yet.",
            "Grux helps you manage what's on your calendar.",
            "Just ask and I'll show what is on your calendar.",
        ]
        for reply in offers {
            XCTAssertFalse(CalendarClaimGuard.claimsCalendar(reply), "should not be a claim: \(reply)")
        }
    }

    /// The live miss end to end: the person reads tomorrow's calendar.
    func testTheLiveTomorrowMissReadsTomorrow() {
        var asked: [Date] = []
        let election = CalendarService.EventSummary(id: "e", title: "Election Day", start: date(2026, 11, 3),
                                                    end: date(2026, 11, 4), isAllDay: true, location: nil, notes: nil,
                                                    calendarName: "US Holidays", calendarId: "us")
        CalendarAsk.events = { start, _ in asked.append(start); return [election] }
        let out = vet("You've got an all-day Day of the Dead holiday on your calendar. Nothing else scheduled for tonight.",
                      ask: "Got any plans for me tomorrow night?")
        XCTAssertTrue(out.replaced)
        XCTAssertEqual(asked, [date(2026, 11, 3)])
        XCTAssertEqual(out.text, "On your calendar tomorrow (Tuesday, Nov 3), one thing: Election Day, all day.")
    }

    // MARK: - When the guard stands aside

    /// An event Grux wrote this turn backs its own confirmation.
    func testAnEventWrittenThisTurnBacksItsConfirmation() {
        CalendarAsk.events = { _, _ in XCTFail("no read after a write that succeeded"); return [] }
        let wrote: ActionClaimGuard.ToolResult = ("create_event", ["title": "Lunch"], "ok: created Lunch, Friday 1:00 PM")
        let out = vet("Done, lunch is on your calendar for Friday.", ask: "Put lunch on my calendar Friday at 1", results: [wrote])
        XCTAssertFalse(out.replaced)
    }

    /// A calendar read this turn backs what the reply says about it.
    func testACalendarReadThisTurnBacksTheReply() {
        CalendarAsk.events = { _, _ in XCTFail("no second read when the turn read the calendar"); return [] }
        let read: ActionClaimGuard.ToolResult = ("list_events", ["range": "today"], "No events today.")
        let out = vet("Nothing scheduled for tonight.", ask: "Anything tonight?", results: [read])
        XCTAssertFalse(out.replaced)
        XCTAssertEqual(out.text, "Nothing scheduled for tonight.")
    }

    /// A read that failed backs nothing: the person reads the calendar's own answer.
    func testAFailedReadBacksNothing() {
        CalendarAsk.events = { _, _ in [] }
        let failed: ActionClaimGuard.ToolResult = ("list_events", [:], "error: calendar timed out")
        let out = vet("You're free tonight.", ask: "Anything tonight?", results: [failed])
        XCTAssertTrue(out.replaced)
        XCTAssertEqual(out.text, "Nothing on your calendar today (Monday, Nov 2).")
    }

    /// Another tool's result is not a calendar read.
    func testAnotherToolsResultIsNotACalendarRead() {
        CalendarAsk.events = { _, _ in [] }
        let tasks: ActionClaimGuard.ToolResult = ("list_tasks", [:], "ok: 0 tasks")
        let out = vet("Your calendar is clear today.", ask: "How is today?", results: [tasks])
        XCTAssertTrue(out.replaced)
    }

    /// A reply that claims nothing about the calendar is left alone and reads nothing.
    func testAReplyWithNoClaimReadsNothing() {
        CalendarAsk.events = { _, _ in XCTFail("no read for a reply that claims nothing"); return [] }
        let out = vet("Paris is the capital of France.", ask: "What is the capital of France?")
        XCTAssertFalse(out.replaced)
    }

    /// The cloud route streams its reply to speech as it arrives, so this guard,
    /// like ActionClaimGuard, checks the local route only.
    func testTheCloudRouteIsLeftAlone() {
        CalendarAsk.events = { _, _ in XCTFail("no read on the cloud route"); return [] }
        let out = vet("You're free tonight.", ask: "Anything tonight?", route: "anthropic")
        XCTAssertFalse(out.replaced)
    }

    // MARK: - The day

    /// The day comes from the ask first, then the reply, then today.
    func testTheDayComesFromTheAskThenTheReplyThenToday() {
        var asked: [Date] = []
        CalendarAsk.events = { start, _ in asked.append(start); return [] }
        _ = vet("You're free.", ask: "What about Friday?")
        _ = vet("Your calendar is clear tomorrow.", ask: "How's it looking?")
        _ = vet("You're free.", ask: "How's it looking?")
        _ = vet("Nothing on your calendar this weekend.", ask: "Am I busy next week?")
        XCTAssertEqual(asked, [date(2026, 11, 6), date(2026, 11, 3), date(2026, 11, 2), date(2026, 11, 8)])
    }

    func testTheMentionedWindow() {
        func start(_ text: String) -> Date? { CalendarAsk.mentionedWindow(in: text, now: now, calendar: cal)?.start }
        XCTAssertEqual(start("Is there anything going on tonight?"), date(2026, 11, 2))
        XCTAssertEqual(start("anything tomorrow evening"), date(2026, 11, 3))
        XCTAssertEqual(start("what about this Friday"), date(2026, 11, 6))
        XCTAssertEqual(start("Am I busy this weekend?"), date(2026, 11, 7))
        XCTAssertEqual(start("busy next week?"), date(2026, 11, 8))
        XCTAssertEqual(start("tomorrow or today?"), date(2026, 11, 3), "the first one named")
        XCTAssertNil(start("How's it looking?"))
        XCTAssertNil(start("Mondays are hard"), "a weekday inside another word is not a day")
    }

    // MARK: - The enforcement: send() runs it

    /// In send(): after the action claim check, before the reply is stored or spoken.
    func testSendRunsTheGuardBeforeTheReplyIsShown() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let claims = try XCTUnwrap(src.range(of: "ActionClaimGuard.vet(reply: finalText"))
        let calendar = try XCTUnwrap(src.range(of: "CalendarClaimGuard.vet(reply: finalText"))
        let shown = try XCTUnwrap(src.range(of: "state.appendChat(ChatMessage(role: .assistant, content: finalText))"))
        XCTAssertTrue(claims.lowerBound < calendar.lowerBound && calendar.lowerBound < shown.lowerBound)
    }
}
