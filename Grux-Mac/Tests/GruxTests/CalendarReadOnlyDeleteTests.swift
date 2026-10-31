import XCTest
@testable import Grux

/// D92 (sense pass 8, `calendar-1.png`): Halloween, from the subscribed and read-only
/// US Holidays calendar, carried a red delete button that could only fail. Delete shows
/// only for an event in a calendar that allows changes, and an unknown calendar reads
/// as read-only.
final class CalendarReadOnlyDeleteTests: XCTestCase {
    private func event(calendarId: String) -> CalendarService.EventSummary {
        let day = Date(timeIntervalSince1970: 1_793_419_200)
        return CalendarService.EventSummary(id: "e-\(calendarId)", title: "Halloween", start: day,
                                            end: day.addingTimeInterval(86_400), isAllDay: true,
                                            location: nil, notes: nil, calendarName: "US Holidays",
                                            calendarId: calendarId)
    }

    private let calendars = [
        CalendarService.CalendarSummary(id: "work", title: "Work", allowsModifications: true, colorHex: nil),
        CalendarService.CalendarSummary(id: "holidays", title: "US Holidays", allowsModifications: false, colorHex: nil),
    ]

    func test_onlyAWritableCalendarsEventCanBeDeleted() {
        let writable = CalendarView.writableCalendarIds(calendars)
        XCTAssertEqual(writable, ["work"])
        XCTAssertTrue(CalendarView.canDelete(event(calendarId: "work"), writableCalendarIds: writable))
        XCTAssertFalse(CalendarView.canDelete(event(calendarId: "holidays"), writableCalendarIds: writable))
        XCTAssertFalse(CalendarView.canDelete(event(calendarId: "gone"), writableCalendarIds: writable),
                       "a calendar Grux does not know reads as read-only")
        XCTAssertFalse(CalendarView.canDelete(event(calendarId: "work"), writableCalendarIds: []),
                       "with no calendars read yet nothing offers delete")
    }

    func test_theServiceSaysPlainlyWhyAReadOnlyEventStays() {
        XCTAssertEqual(CalendarService.ServiceError.readOnlyCalendar("US Holidays").errorDescription,
                       "US Holidays is a read-only calendar, so its events cannot be deleted.")
    }
}
