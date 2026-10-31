import XCTest
@testable import Grux

/// D91 (sense pass 8, `reactor-1.png`): on Halloween the Reactor's Calendar card read
/// "11h ago / Halloween". An all-day event started at midnight, so the card counted from
/// midnight and made today's event look over. A timed event already underway read the
/// same way ("20 min. ago"), and an all-day event sorted ahead of the meeting later today.
final class ReactorCalendarReadoutTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func at(_ h: Int, _ m: Int = 0, day: Int = 31) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarService.EventSummary {
        CalendarService.EventSummary(id: title, title: title, start: start, end: end, isAllDay: allDay,
                                     location: nil, notes: nil, calendarName: "US Holidays", calendarId: "h")
    }

    private func readout(_ events: [CalendarService.EventSummary], now: Date) -> (value: String, sub: String) {
        let r = ReactorView.calendarReadout(events: events, now: now, calendar: cal)
        return (r.value, r.sub)
    }

    private var halloween: CalendarService.EventSummary {
        event("Halloween", at(0), at(0, day: 32), allDay: true)
    }

    func test_anAllDayEventTodayReadsToday() {
        let r = readout([halloween], now: at(11, 22))
        XCTAssertEqual(r.value, "Today")
        XCTAssertEqual(r.sub, "Halloween")
        // On the boundaries: the first minute of the day and the last.
        XCTAssertEqual(readout([halloween], now: at(0)).value, "Today")
        XCTAssertEqual(readout([halloween], now: at(23, 59)).value, "Today")
    }

    func test_anAllDayEventTomorrowReadsTomorrowAndLaterReadsItsDay() {
        let tomorrow = event("Day off", at(0, day: 32), at(0, day: 33), allDay: true)
        XCTAssertEqual(readout([tomorrow], now: at(23, 59)).value, "Tomorrow")
        let tuesday = event("Trip", at(0, day: 34), at(0, day: 35), allDay: true)
        XCTAssertEqual(readout([tuesday], now: at(9)).value, "Tue")
    }

    /// Wave 24 round 1 P3: an all-day event a week out read as today's weekday ("Sat" on a
    /// Saturday). Six days out reads its weekday; seven and on read the date.
    func test_anAllDayEventAWeekOutReadsItsDate() {
        let friday = event("Fri", at(0, day: 37), at(0, day: 38), allDay: true)       // Nov 6, six days out
        XCTAssertEqual(readout([friday], now: at(23, 59)).value, "Fri")
        let saturday = event("Sat", at(0, day: 38), at(0, day: 39), allDay: true)     // Nov 7, seven days out
        XCTAssertEqual(readout([saturday], now: at(11)).value, "Nov 7")
        XCTAssertEqual(readout([saturday], now: at(0)).value, "Nov 7")
        let sunday = event("Sun", at(0, day: 39), at(0, day: 40), allDay: true)       // Nov 8, eight days out
        XCTAssertEqual(readout([sunday], now: at(11)).value, "Nov 8")
    }

    func test_aTimedEventUnderwayReadsNow() {
        let call = event("Standup", at(11), at(11, 30))
        XCTAssertEqual(readout([call], now: at(11, 20)).value, "Now")
        XCTAssertEqual(readout([call], now: at(11)).value, "Now", "it starts this minute")
        XCTAssertEqual(readout([call], now: at(11, 30)).value, "Clear", "it ended this minute")
        XCTAssertEqual(readout([call], now: at(10, 59)).value, "in 1m")
        XCTAssertFalse(readout([call], now: at(11, 29)).value.contains("ago"))
    }

    func test_aMeetingLaterTodayComesBeforeTodaysAllDayEvent() {
        let meeting = event("Dentist", at(15), at(16))
        let r = readout([halloween, meeting], now: at(11))
        XCTAssertEqual(r.sub, "Dentist")
        XCTAssertEqual(r.value, "in 4h")
    }

    func test_todaysAllDayEventComesBeforeAMeetingOnAnotherDay() {
        let nextWeek = event("Review", at(10, day: 35), at(11, day: 35))
        XCTAssertEqual(readout([nextWeek, halloween], now: at(11)).sub, "Halloween")
    }

    func test_nothingAheadIsClear() {
        let r = readout([], now: at(11))
        XCTAssertEqual(r.value, "Clear")
        XCTAssertEqual(r.sub, "Nothing scheduled")
    }

    func test_noReadoutEverSaysAgo() {
        let events = [halloween, event("Standup", at(9), at(12)), event("Lunch", at(12), at(13))]
        for h in 0..<24 {
            for m in [0, 1, 29, 59] {
                XCTAssertFalse(readout(events, now: at(h, m)).value.contains("ago"), "\(h):\(m)")
            }
        }
    }
}
