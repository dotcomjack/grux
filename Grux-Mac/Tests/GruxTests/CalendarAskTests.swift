import XCTest
@testable import Grux

/// D136, live 2026-11-02 2:03 PM on qwen3.5:4b: "What is on my calendar
/// tomorrow?" was answered "a grocery run in the AM and a lunch with Sarah at
/// 1pm Friday" with no tool call, while the calendar held Election Day. A plain
/// calendar question is now answered from the calendar before any model sees it.
@MainActor
final class CalendarAskTests: XCTestCase {

    private var cal: Foundation.Calendar = {
        var c = Foundation.Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 1
        return c
    }()
    private let us = Locale(identifier: "en_US")

    /// Monday Nov 2, 2026, 2:03 PM in New York: the live turn.
    private var now: Date { date(2026, 11, 2, 14, 3) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarService.EventSummary {
        CalendarService.EventSummary(id: UUID().uuidString, title: title, start: start, end: end, isAllDay: allDay,
                                     location: nil, notes: nil, calendarName: "Home", calendarId: "home")
    }

    // MARK: - The match

    func testPlainCalendarQuestionsMatchTheirDays() {
        let cases: [(String, Date, Date, String)] = [
            ("What is on my calendar tomorrow?", date(2026, 11, 3), date(2026, 11, 4), "tomorrow"),
            ("What's on my calendar today?", date(2026, 11, 2), date(2026, 11, 3), "today"),
            ("what\u{2019}s on my calendar", date(2026, 11, 2), date(2026, 11, 3), "today"),
            ("Grux, what's on my schedule for tomorrow", date(2026, 11, 3), date(2026, 11, 4), "tomorrow"),
            ("Do I have anything tomorrow?", date(2026, 11, 3), date(2026, 11, 4), "tomorrow"),
            ("do I have anything on my calendar tonight", date(2026, 11, 2), date(2026, 11, 3), "today"),
            ("What do I have on Thursday?", date(2026, 11, 5), date(2026, 11, 6), "on Thursday"),
            ("what meetings do I have friday", date(2026, 11, 6), date(2026, 11, 7), "on Friday"),
            ("What's on my calendar on Monday?", date(2026, 11, 9), date(2026, 11, 10), "on Monday"),
            ("What's on my calendar this week?", date(2026, 11, 2), date(2026, 11, 8), "this week"),
            ("what is on my calendar next week", date(2026, 11, 8), date(2026, 11, 15), "next week"),
            ("Anything on my calendar this weekend?", date(2026, 11, 7), date(2026, 11, 9), "this weekend"),
            ("Show me my calendar", date(2026, 11, 2), date(2026, 11, 3), "today"),
            ("Hey Grux, check my calendar for tomorrow please", date(2026, 11, 3), date(2026, 11, 4), "tomorrow"),
            ("  What   is on my  calendar  tomorrow ?? ", date(2026, 11, 3), date(2026, 11, 4), "tomorrow"),
        ]
        for (text, start, end, label) in cases {
            let w = CalendarAsk.window(for: text, now: now, calendar: cal)
            XCTAssertEqual(w, CalendarAsk.Window(start: start, end: end, label: label), text)
        }
    }

    /// On the edges: a Sunday's weekend is today alone, a Saturday's week is
    /// today alone, and the day named today means a week ahead.
    func testWindowsOnTheWeekEdges() {
        let sunday = date(2026, 11, 8, 9)
        XCTAssertEqual(CalendarAsk.window(for: "anything on my calendar this weekend", now: sunday, calendar: cal),
                       CalendarAsk.Window(start: date(2026, 11, 8), end: date(2026, 11, 9), label: "this weekend"))
        let saturday = date(2026, 11, 7, 23, 59)
        XCTAssertEqual(CalendarAsk.window(for: "what's on my calendar this week", now: saturday, calendar: cal),
                       CalendarAsk.Window(start: date(2026, 11, 7), end: date(2026, 11, 8), label: "this week"))
        XCTAssertEqual(CalendarAsk.window(for: "what do I have on monday", now: now, calendar: cal)?.start,
                       date(2026, 11, 9))
        XCTAssertEqual(CalendarAsk.window(for: "what do I have on tuesday", now: now, calendar: cal)?.start,
                       date(2026, 11, 3))
    }

    /// W41-P3 item 1: "this Monday" asked on a Monday is today; a bare
    /// "Monday" or "on Monday" asked on a Monday still means the next one.
    func testThisWeekdayOnThatWeekdayIsToday() {
        let monday = now
        XCTAssertEqual(CalendarAsk.window(for: "What's on my calendar this Monday?", now: monday, calendar: cal),
                       CalendarAsk.Window(start: date(2026, 11, 2), end: date(2026, 11, 3), label: "today"))
        XCTAssertEqual(CalendarAsk.window(for: "what do I have this tuesday", now: monday, calendar: cal)?.start,
                       date(2026, 11, 3))
        XCTAssertEqual(CalendarAsk.window(for: "what do I have this sunday", now: monday, calendar: cal)?.start,
                       date(2026, 11, 8))
        XCTAssertEqual(CalendarAsk.window(for: "what do I have monday", now: monday, calendar: cal)?.start,
                       date(2026, 11, 9))
        let today = CalendarAsk.window(for: "What's on my calendar this Monday?", now: monday, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [], window: today, calendar: cal, locale: us),
                       "Nothing on your calendar today (Monday, Nov 2).")
    }

    /// W41-P3 item 5: "is there anything" and "anything" ask about the world
    /// as often as the calendar, so they match only with a calendar word.
    /// "What do I have" and "do I have anything" are about the person.
    func testAnImpersonalAskNeedsACalendarWord() {
        for text in ["Is there anything going on tonight?", "anything on tonight", "anything this weekend",
                     "is there anything tomorrow", "Anything going on Friday?", "anything for tomorrow"] {
            XCTAssertNil(CalendarAsk.window(for: text, now: now, calendar: cal), text)
        }
        let cases: [(String, Date)] = [
            ("Is there anything on my calendar tonight?", date(2026, 11, 2)),
            ("anything scheduled tomorrow", date(2026, 11, 3)),
            ("is there anything planned for friday", date(2026, 11, 6)),
            ("anything on my schedule this weekend", date(2026, 11, 7)),
            ("do I have anything going on tonight", date(2026, 11, 2)),
            ("what do I have on tomorrow", date(2026, 11, 3)),
        ]
        for (text, start) in cases {
            XCTAssertEqual(CalendarAsk.window(for: text, now: now, calendar: cal)?.start, start, text)
        }
    }

    /// A miss costs one model turn; a false match answers a question nobody
    /// asked, so everything else goes to the model.
    func testEverythingElseGoesToTheModel() {
        for text in ["Put lunch with Sarah on my calendar Friday at 1pm", "Am I free Thursday afternoon?",
                     "What's on my calendar tomorrow and email it to Sam", "What do I have?", "What do I have",
                     "anything", "What's happening today?", "What's going on tomorrow?",
                     "what is on my calendar next monday", "What's on my calendar tomorrow? Also add milk.",
                     "Cancel what's on my calendar tomorrow", "What is my calendar app called?",
                     "What's on my calendar in March?", "What is on my mind", "do I have anything to do",
                     "Is there anything I should know tomorrow?", "schedule lunch tomorrow", "", "   ", "?",
                     "What can you do for me on this Mac? Keep it short."] {
            XCTAssertNil(CalendarAsk.window(for: text, now: now, calendar: cal), text)
        }
    }

    // MARK: - The reply

    func testTheReplySaysExactlyWhatTheCalendarHolds() {
        let tomorrow = CalendarAsk.window(for: "what is on my calendar tomorrow", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [event("Election Day", date(2026, 11, 3), date(2026, 11, 4), allDay: true)],
                                         window: tomorrow, calendar: cal, locale: us),
                       "On your calendar tomorrow (Tuesday, Nov 3), one thing: Election Day, all day.")
        XCTAssertEqual(CalendarAsk.reply(events: [], window: tomorrow, calendar: cal, locale: us),
                       "Nothing on your calendar tomorrow (Tuesday, Nov 3).")
        let two = [event("Lunch with Sam", date(2026, 11, 3, 13), date(2026, 11, 3, 14)),
                   event("Standup", date(2026, 11, 3, 9), date(2026, 11, 3, 9, 30))]
        XCTAssertEqual(CalendarAsk.reply(events: two, window: tomorrow, calendar: cal, locale: us),
                       "On your calendar tomorrow (Tuesday, Nov 3), 2 things: Standup, 9:00 AM to 9:30 AM; Lunch with Sam, 1:00 PM to 2:00 PM.")
        let thursday = CalendarAsk.window(for: "what do I have on thursday", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [], window: thursday, calendar: cal, locale: us),
                       "Nothing on your calendar on Thursday, Nov 5.")
        let week = CalendarAsk.window(for: "what's on my calendar this week", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [event("Dentist", date(2026, 11, 4, 8), date(2026, 11, 4, 9))],
                                         window: week, calendar: cal, locale: us),
                       "On your calendar this week (Nov 2 to Nov 7), one thing: Dentist, Wed, Nov 4 8:00 AM to 9:00 AM.")
        // Started before the window: says until when.
        let today = CalendarAsk.window(for: "what's on my calendar", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [event("Trip", date(2026, 11, 1, 18), date(2026, 11, 2, 10))],
                                         window: today, calendar: cal, locale: us),
                       "On your calendar today (Monday, Nov 2), one thing: Trip, until 10:00 AM.")
    }

    /// W41-P3 item 6: an event that ends at midnight ends "at midnight", not
    /// at 12:00 AM on the next day; one that runs past midnight still names it.
    func testAnEventEndingAtMidnightSaysMidnight() {
        let today = CalendarAsk.window(for: "what's on my calendar", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [event("Party", date(2026, 11, 2, 23), date(2026, 11, 3))],
                                         window: today, calendar: cal, locale: us),
                       "On your calendar today (Monday, Nov 2), one thing: Party, 11:00 PM to midnight.")
        XCTAssertEqual(CalendarAsk.reply(events: [event("Party", date(2026, 11, 2, 23), date(2026, 11, 3, 0, 1))],
                                         window: today, calendar: cal, locale: us),
                       "On your calendar today (Monday, Nov 2), one thing: Party, 11:00 PM to Tue, Nov 3 12:01 AM.")
        let week = CalendarAsk.window(for: "what's on my calendar this week", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [event("Gig", date(2026, 11, 4, 22), date(2026, 11, 5))],
                                         window: week, calendar: cal, locale: us),
                       "On your calendar this week (Nov 2 to Nov 7), one thing: Gig, Wed, Nov 4 10:00 PM to midnight.")
        // Started before the window and ends at its first midnight.
        let tomorrow = CalendarAsk.window(for: "what is on my calendar tomorrow", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [event("Shift", date(2026, 11, 2, 16), date(2026, 11, 4))],
                                         window: tomorrow, calendar: cal, locale: us),
                       "On your calendar tomorrow (Tuesday, Nov 3), one thing: Shift, until midnight.")
    }

    /// W41-P3 item 3: an all-day event over several days names the days it
    /// covers inside the window, never a start day before the window.
    func testAMultiDayAllDayEventNamesItsDaysInTheWindow() {
        let week = CalendarAsk.window(for: "what's on my calendar this week", now: now, calendar: cal)!
        // Oct 30 to Nov 4 inclusive (EventKit ends an all-day event at the next midnight).
        XCTAssertEqual(CalendarAsk.reply(events: [event("Trip", date(2026, 10, 30), date(2026, 11, 5), allDay: true)],
                                         window: week, calendar: cal, locale: us),
                       "On your calendar this week (Nov 2 to Nov 7), one thing: Trip, all day Mon, Nov 2 to Wed, Nov 4.")
        // Runs past the window: to the window's last day.
        XCTAssertEqual(CalendarAsk.reply(events: [event("Conference", date(2026, 11, 6), date(2026, 11, 11), allDay: true)],
                                         window: week, calendar: cal, locale: us),
                       "On your calendar this week (Nov 2 to Nov 7), one thing: Conference, all day Fri, Nov 6 to Sat, Nov 7.")
        // One day in a week window stays as before.
        XCTAssertEqual(CalendarAsk.reply(events: [event("Election Day", date(2026, 11, 3), date(2026, 11, 4), allDay: true)],
                                         window: week, calendar: cal, locale: us),
                       "On your calendar this week (Nov 2 to Nov 7), one thing: Election Day, Tue, Nov 3 all day.")
        // A day window: still just all day.
        let today = CalendarAsk.window(for: "what's on my calendar", now: now, calendar: cal)!
        XCTAssertEqual(CalendarAsk.reply(events: [event("Trip", date(2026, 10, 30), date(2026, 11, 5), allDay: true)],
                                         window: today, calendar: cal, locale: us),
                       "On your calendar today (Monday, Nov 2), one thing: Trip, all day.")
    }

    /// At the limit every event is listed; one over names how many more.
    func testTheListStopsAtTheLimitAndCountsTheRest() {
        let tomorrow = CalendarAsk.window(for: "what is on my calendar tomorrow", now: now, calendar: cal)!
        func many(_ n: Int) -> [CalendarService.EventSummary] {
            (0..<n).map { event("E\($0)", date(2026, 11, 3, 8 + $0 / 2, ($0 % 2) * 30), date(2026, 11, 3, 8 + $0 / 2, ($0 % 2) * 30 + 15)) }
        }
        let atLimit = CalendarAsk.reply(events: many(CalendarAsk.listed), window: tomorrow, calendar: cal, locale: us)
        XCTAssertTrue(atLimit.contains("E\(CalendarAsk.listed - 1),"), atLimit)
        XCTAssertFalse(atLimit.contains("more, in Calendar"), atLimit)
        let over = CalendarAsk.reply(events: many(CalendarAsk.listed + 1), window: tomorrow, calendar: cal, locale: us)
        XCTAssertFalse(over.contains("E\(CalendarAsk.listed),"), over)
        XCTAssertTrue(over.hasSuffix("And 1 more, in Calendar."), over)
        XCTAssertTrue(over.contains("\(CalendarAsk.listed + 1) things"), over)
    }

    func testNoAccessSaysWhatToDoAndNamesNoEvent() {
        let tomorrow = CalendarAsk.window(for: "what is on my calendar tomorrow", now: now, calendar: cal)!
        let saved = CalendarAsk.access
        defer { CalendarAsk.access = saved }
        CalendarAsk.access = { .notDetermined }
        XCTAssertEqual(CalendarAsk.reply(events: nil, window: tomorrow, calendar: cal, locale: us),
                       "I cannot read your calendar yet: Grux needs your OK for Calendar. Open the Calendar tab to allow it, then ask again.")
        CalendarAsk.access = { .denied }
        XCTAssertEqual(CalendarAsk.reply(events: nil, window: tomorrow, calendar: cal, locale: us),
                       "I cannot read your calendar: macOS has Calendar turned off for Grux, and it will not ask again. Turn on Grux AI in System Settings, Privacy & Security, Calendars.")
        for line in [CalendarAsk.reply(events: nil, window: tomorrow, calendar: cal, locale: us),
                     CalendarAsk.reply(events: [], window: tomorrow, calendar: cal, locale: us)] {
            XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
        }
    }

    /// W41-P3 item 4: add-only access and a Mac whose manager restricts
    /// Calendar were told Calendar is "turned off" and to "turn it on", which
    /// is not what either can do.
    func testEachRefusalSaysWhatIsTrueOfIt() {
        let addOnly = CalendarAsk.noAccessLine(.writeOnly)
        XCTAssertEqual(addOnly, "I cannot read your calendar: Grux may add events to it but not read them. "
                       + "To let Grux read it, set Grux AI to Full Access in System Settings, Privacy & Security, Calendars.")
        let managed = CalendarAsk.noAccessLine(.restricted)
        XCTAssertEqual(managed, "I cannot read your calendar: whoever manages this Mac does not allow apps to read Calendar.")
        XCTAssertTrue(CalendarAsk.noAccessLine(.denied).contains("turned off"))
        XCTAssertTrue(CalendarAsk.noAccessLine(.notDetermined).contains("needs your OK"))
        for line in [addOnly, managed] {
            XCTAssertFalse(line.contains("turned off"), line)
            XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
        }
    }

    // MARK: - The enforcement: the real send()

    private var savedOffline = false
    private var savedChat: [ChatMessage] = []
    private var savedRecovery: ChatRecovery?
    private var savedEvents: (@MainActor (Date, Date) -> [CalendarService.EventSummary]?)!

    override func setUp() async throws {
        try await super.setUp()
        savedOffline = AppState.shared.offlineMode
        savedChat = AppState.shared.chat
        savedRecovery = AppState.shared.chatRecovery
        savedEvents = CalendarAsk.events
    }

    override func tearDown() async throws {
        AppState.shared.offlineMode = savedOffline
        AppState.shared.chat = savedChat
        AppState.shared.chatRecovery = savedRecovery
        CalendarAsk.events = savedEvents
        try await super.tearDown()
    }

    /// The live question, with no model attached at all: the reply is the
    /// calendar's, read for tomorrow's range, so no model could have made it up.
    func testTheQuestionIsAnsweredFromTheCalendarBeforeAnyModel() async {
        AppState.shared.offlineMode = true
        ModelRegistry.shared.resetLocalForTest()
        AppState.shared.chat = []
        AppState.shared.chatRecovery = nil
        XCTAssertFalse(ChatReadiness.current().canSend, "control: chat must have no model for this to prove anything")
        var asked: [(Date, Date)] = []
        let startOfToday = Foundation.Calendar.current.startOfDay(for: Date())
        let tomorrow = Foundation.Calendar.current.date(byAdding: .day, value: 1, to: startOfToday)!
        CalendarAsk.events = { start, end in
            asked.append((start, end))
            return [CalendarService.EventSummary(id: "e1", title: "Election Day", start: tomorrow,
                                                 end: Foundation.Calendar.current.date(byAdding: .day, value: 1, to: tomorrow)!,
                                                 isAllDay: true, location: nil, notes: nil,
                                                 calendarName: "US Holidays", calendarId: "us")]
        }

        await ChatService.shared.send(userText: "What is on my calendar tomorrow?")

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, tomorrow)
        let chat = AppState.shared.chat
        XCTAssertEqual(chat.map(\.role), [.user, .assistant])
        let reply = chat.last?.content ?? ""
        XCTAssertTrue(reply.hasPrefix("On your calendar tomorrow ("), reply)
        XCTAssertTrue(reply.hasSuffix("one thing: Election Day, all day."), reply)
        XCTAssertNil(AppState.shared.chatRecovery)
    }

    /// Order in send(): after the upgrade-yourself ask, before the PIM route
    /// and the readiness guard, so it needs no model.
    func testTheRouteSitsBeforeThePIMRouteAndTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let upgrade = try XCTUnwrap(src.range(of: "ChatIntentClassifier.isUpgradeYourselfAsk(trimmed)"))
        let route = try XCTUnwrap(src.range(of: "CalendarAsk.window(for: trimmed)"))
        let pim = try XCTUnwrap(src.range(of: "ChatIntentClassifier.pimRoute(utterance: trimmed)"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(upgrade.lowerBound < route.lowerBound && route.lowerBound < pim.lowerBound
                      && pim.lowerBound < readiness.lowerBound)
    }
}
