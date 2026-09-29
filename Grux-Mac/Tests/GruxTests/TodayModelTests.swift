import XCTest
@testable import Grux

/// Phase D, D1: Today decides what is next in a type a test can drive.
final class TodayModelTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ h: Int, _ m: Int = 0, day: Int = 21) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarService.EventSummary {
        CalendarService.EventSummary(id: title, title: title, start: start, end: end, isAllDay: allDay,
                                     location: nil, notes: nil, calendarName: "Work", calendarId: "w")
    }

    private func task(_ title: String, due: Date? = nil) -> TodayModel.TaskLine {
        TodayModel.TaskLine(id: UUID(), title: title, dueAt: due)
    }

    func test_anEventSoonerThanTheNextTaskIsNext() {
        let now = at(9)
        let n = TodayModel.next(tasks: [task("Write the brief")],
                                events: [event("Standup", at(9, 30), at(9, 45))], now: now, calendar: cal)
        XCTAssertEqual(n?.kind, .event)
        XCTAssertEqual(n?.title, "Standup")
        XCTAssertEqual(n?.when, "At 9:30 AM")
        XCTAssertEqual(n?.then, ["Write the brief"])
    }

    func test_theNextTaskWinsOverAnEventLaterInTheDay() {
        let n = TodayModel.next(tasks: [task("Write the brief")],
                                events: [event("Dinner", at(19, 30), at(21))], now: at(9), calendar: cal)
        XCTAssertEqual(n?.kind, .task)
        XCTAssertEqual(n?.title, "Write the brief")
        XCTAssertEqual(n?.then, ["Dinner, at 7:30 PM"])
    }

    /// A meeting you are in is the most relevant thing on the screen.
    func test_anEventInProgressIsNextUntilItEnds() {
        let n = TodayModel.next(tasks: [task("Reply to Sam", due: at(10))],
                                events: [event("Design review", at(8, 45), at(10, 30))], now: at(9, 15), calendar: cal)
        XCTAssertEqual(n?.title, "Design review")
        XCTAssertEqual(n?.when, "Now, until 10:30 AM")
        let after = TodayModel.next(tasks: [], events: [event("Design review", at(8, 45), at(10, 30))],
                                    now: at(10, 31), calendar: cal)
        XCTAssertNil(after, "an event that has ended is not next")
    }

    func test_anAllDayEventNeverBeatsATimedEventAnHourAway() {
        let n = TodayModel.next(tasks: [], events: [event("Offsite", at(0), at(23, 59), allDay: true),
                                                    event("Call with the printer", at(10), at(10, 30))],
                                now: at(9), calendar: cal)
        XCTAssertEqual(n?.title, "Call with the printer")
        XCTAssertEqual(n?.then, ["Offsite, all day"])
    }

    func test_nothingAtAllIsNilAndTheCardSaysSo() {
        XCTAssertNil(TodayModel.next(tasks: [], events: [], now: at(9), calendar: cal))
        XCTAssertFalse(TodayModel.Copy.nextEmpty.isEmpty)
        XCTAssertFalse(TodayModel.Copy.watchingEmpty.isEmpty)
        XCTAssertFalse(TodayModel.Copy.mailEmpty.isEmpty)
    }

    /// `19:30` is the defect this phase is most likely to ship.
    func test_timesAreStandardTimeNeverTwentyFourHour() {
        XCTAssertEqual(TodayModel.clock(at(19, 30), calendar: cal), "7:30 PM")
        XCTAssertEqual(TodayModel.clock(at(0, 5), calendar: cal), "12:05 AM")
        XCTAssertEqual(HomeBriefingBuilder.clockLabel(at(19, 30), calendar: cal), "7:30 PM",
                       "Home's older formatter must be the same clock")
        let n = TodayModel.next(tasks: [], events: [event("Dinner", at(19, 30), at(21))], now: at(18), calendar: cal)
        XCTAssertEqual(n?.when, "At 7:30 PM")
        XCTAssertFalse(n?.when.contains("19:") ?? true)
        let tomorrow = TodayModel.next(tasks: [], events: [event("Flight", at(6, 15, day: 22), at(9, day: 22))],
                                       now: at(20), calendar: cal)
        XCTAssertEqual(tomorrow?.when, "Tomorrow at 6:15 AM")
    }

    func test_dueTimesReadPlainly() {
        XCTAssertEqual(TodayModel.next(tasks: [task("Invoice", due: at(17))], events: [], now: at(9), calendar: cal)?.when,
                       "Due at 5:00 PM")
        XCTAssertEqual(TodayModel.next(tasks: [task("Invoice", due: at(8))], events: [], now: at(9), calendar: cal)?.when,
                       "Overdue")
    }

    /// The card and the rail badge must never disagree about what needs you.
    func test_mailThatNeedsYouUsesTheBadgesRule() {
        func m(_ from: String, unread: Bool = true, p: Double? = nil, minutesAgo: Double = 0) -> EmailMessage {
            var e = EmailMessage(id: UUID().uuidString, accountId: UUID(), sequenceNumber: 1, messageId: "",
                                 fromName: from, fromEmail: "\(from.lowercased())@example.com", to: "me@example.com",
                                 subject: "About \(from)", date: Date().addingTimeInterval(-minutesAgo * 60),
                                 snippet: "can you look at this", bodyText: "", isUnread: unread,
                                 fetchedAt: Date(), triageDraftId: nil)
            e.needsYouProbability = p
            return e
        }
        let messages = [m("Ana", minutesAgo: 5), m("Bo", p: 0.1), m("Cy", unread: false), m("Di", minutesAgo: 1),
                        m("Ed", minutesAgo: 9), m("Flo", minutesAgo: 20)]
        let result = TodayModel.mailThatNeedsYou(messages)
        XCTAssertEqual(result.total, MailNeedsYou.count(messages), "the card and the badge disagree")
        XCTAssertEqual(result.total, 4)
        XCTAssertEqual(result.items.map(\.from), ["Di", "Ana", "Ed"], "newest first, three at most")
    }

    func test_watchingSaysWhatGruxIsKeepingAnEyeOn() {
        XCTAssertEqual(TodayModel.watching(.init()), [])
        let lines = TodayModel.watching(.init(focusTask: "Launch plan", drifting: true, jobsRunning: 2,
                                              jobsWaitingOnYou: 1, proposals: 3, focusChecksToday: 40))
        XCTAssertEqual(lines.map(\.line), ["Focusing on Launch plan, and you have drifted",
                                           "1 agent job waiting on you", "2 agent jobs running", "3 improvements to review"])
        XCTAssertEqual(lines.map(\.tab), ["focus", "agents", "agents", "selfUpgrade"])
        // Seen live: "1306 improvements" would have read without grouping.
        XCTAssertEqual(TodayModel.watching(.init(proposals: 1306)).first?.line, "1,306 improvements to review")
    }

    /// C11: with no task in focus, the Focus log is still one tap away on a
    /// day it recorded anything, and absent on a day it recorded nothing.
    func test_theFocusLogStaysReachableFromWatching() {
        let quiet = TodayModel.watching(.init(focusChecksToday: 12))
        XCTAssertEqual(quiet.map(\.line), ["12 focus checks today"])
        XCTAssertEqual(quiet.map(\.tab), ["focus"])
        XCTAssertEqual(TodayModel.watching(.init(focusChecksToday: 0)), [])
    }

    /// C10: approvals belong to the tray at the foot of the rail. Watching
    /// saying it too would be the same fact twice in one view.
    func test_watchingNeverRepeatsTheApprovalsTray() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Home/TodayModel.swift"), encoding: .utf8)
        XCTAssertFalse(model.contains("waiting on you\",\n") && model.contains("\"approval\""),
                       "Watching lists approvals again")
        XCTAssertFalse(model.contains("id: \"approvals\""), "Watching lists approvals again")
    }

    /// Honest about the microphone, from the one shared tell.
    func test_theSayItLineIsHonestAboutListening() {
        XCTAssertTrue(TodayModel.sayItLine(.armed).contains("listening"))
        XCTAssertTrue(TodayModel.sayItLine(.muted).contains("muted"))
        XCTAssertTrue(TodayModel.sayItLine(.off).contains("Listening is off"))
        XCTAssertFalse(TodayModel.sayItLine(.off).contains("Grux is listening"), "off must not pretend to listen")
        XCTAssertFalse(TodayModel.sayItLine(.muted).contains("Grux is listening"))
        for tell in [ListeningTell.armed, .muted, .speaking, .thinking, .off] {
            let line = TodayModel.sayItLine(tell)
            XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"))
        }
    }
}

/// D2 and D3: Today draws what the model decides, with an empty state per card,
/// the say-it line from the one shared tell, and no second door to anything.
final class TodayViewWiringTests: XCTestCase {
    private func home() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/Home/HomeView.swift"), encoding: .utf8)
    }

    func test_theThreeCardsEachHaveAnEmptyState() throws {
        let src = try home()
        for copy in ["TodayModel.Copy.nextEmpty", "TodayModel.Copy.mailEmpty", "TodayModel.Copy.mailNoAccount",
                     "TodayModel.Copy.watchingEmpty"] {
            XCTAssertTrue(src.contains(copy), "\(copy) is never drawn")
        }
        for title in ["title: \"Next\"", "title: \"Mail that needs you\"", "title: \"Watching\""] {
            XCTAssertTrue(src.contains(title), "missing card \(title)")
        }
    }

    func test_theSayItLineComesFromTheSharedTell() throws {
        XCTAssertTrue(try home().contains("TodayModel.sayItLine(ListeningTell.resolve("))
    }

    /// Every quick-action pill was a second door to a surface the rail opens.
    func test_noSecondDoorsOnToday() throws {
        let src = try home()
        XCTAssertFalse(src.contains("QuickActionPill("), "the quick-action row is back")
        XCTAssertFalse(src.contains("agendaCard"), "Agenda duplicates Next")
        XCTAssertFalse(src.contains("jobsCard"), "Agents duplicates Watching")
    }
}
