import XCTest
@testable import Grux

// Unit tests for the pure-Swift ICS parser/serializer. No EventKit, no disk,
// no network: everything runs against in-memory strings.
final class ICSTests: XCTestCase {

    // MARK: - Parsing

    func testParseBasicUTCEvent() throws {
        let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:abc-123\r
        SUMMARY:Standup\r
        DTSTART:20260609T140000Z\r
        DTEND:20260609T143000Z\r
        LOCATION:Zoom\r
        DESCRIPTION:Daily sync\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let events = ICSImportExport.parse(ics)
        XCTAssertEqual(events.count, 1)
        let ev = try XCTUnwrap(events.first)
        XCTAssertEqual(ev.uid, "abc-123")
        XCTAssertEqual(ev.summary, "Standup")
        XCTAssertEqual(ev.location, "Zoom")
        XCTAssertEqual(ev.description, "Daily sync")
        XCTAssertFalse(ev.isAllDay)

        var utc = Foundation.Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day, .hour, .minute], from: ev.start)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 9)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(ev.effectiveEnd.timeIntervalSince(ev.start), 1800, accuracy: 1)
    }

    func testParseTZIDEvent() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Team Coffee
        DTSTART;TZID=America/Chicago:20260115T090000
        DTEND;TZID=America/Chicago:20260115T100000
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSImportExport.parse(ics)
        let ev = try XCTUnwrap(events.first)
        var zoned = Foundation.Calendar(identifier: .gregorian)
        zoned.timeZone = TimeZone(identifier: "America/Chicago")!
        let comps = zoned.dateComponents([.hour, .minute], from: ev.start)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(ev.effectiveEnd.timeIntervalSince(ev.start), 3600, accuracy: 1)
    }

    func testParseAllDayEvent() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Launch Day
        DTSTART;VALUE=DATE:20260701
        DTEND;VALUE=DATE:20260702
        END:VEVENT
        END:VCALENDAR
        """
        let ev = try XCTUnwrap(ICSImportExport.parse(ics).first)
        XCTAssertTrue(ev.isAllDay)
        XCTAssertEqual(ev.effectiveEnd.timeIntervalSince(ev.start), 86400, accuracy: 1)
    }

    func testParseBareDateIsAllDayWithoutValueParam() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Holiday
        DTSTART:20261225
        END:VEVENT
        END:VCALENDAR
        """
        let ev = try XCTUnwrap(ICSImportExport.parse(ics).first)
        XCTAssertTrue(ev.isAllDay)
        // No DTEND -> all-day default span of one day.
        XCTAssertEqual(ev.effectiveEnd.timeIntervalSince(ev.start), 86400, accuracy: 1)
    }

    func testParseUnfoldsContinuationLines() throws {
        // SUMMARY folded across two lines (continuation starts with a space).
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Quarterly planning sess\r\n ion with the whole team\r\nDTSTART:20260609T140000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let ev = try XCTUnwrap(ICSImportExport.parse(ics).first)
        XCTAssertEqual(ev.summary, "Quarterly planning session with the whole team")
    }

    func testParseUnescapesText() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Dinner\\, drinks\\; recap
        DESCRIPTION:Line one\\nLine two \\\\ backslash
        DTSTART:20260609T230000Z
        END:VEVENT
        END:VCALENDAR
        """
        let ev = try XCTUnwrap(ICSImportExport.parse(ics).first)
        XCTAssertEqual(ev.summary, "Dinner, drinks; recap")
        XCTAssertEqual(ev.description, "Line one\nLine two \\ backslash")
    }

    func testParseCarriesRRULEThrough() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Weekly sync
        DTSTART:20260609T140000Z
        RRULE:FREQ=WEEKLY;INTERVAL=1;COUNT=10
        END:VEVENT
        END:VCALENDAR
        """
        let ev = try XCTUnwrap(ICSImportExport.parse(ics).first)
        XCTAssertEqual(ev.rrule, "FREQ=WEEKLY;INTERVAL=1;COUNT=10")
    }

    func testParseMultipleEventsAndIgnoresOtherComponents() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTIMEZONE
        TZID:America/Chicago
        END:VTIMEZONE
        BEGIN:VEVENT
        SUMMARY:One
        DTSTART:20260609T140000Z
        END:VEVENT
        BEGIN:VTODO
        SUMMARY:Not an event
        END:VTODO
        BEGIN:VEVENT
        SUMMARY:Two
        DTSTART:20260610T140000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSImportExport.parse(ics)
        XCTAssertEqual(events.map { $0.summary }, ["One", "Two"])
    }

    func testParseSkipsEventWithoutDTSTART() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:No date
        END:VEVENT
        END:VCALENDAR
        """
        XCTAssertTrue(ICSImportExport.parse(ics).isEmpty)
    }

    func testParseQuotedParamWithColonDoesNotSplitEarly() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY;X-FOO="a:b":Colon Param Event
        DTSTART:20260609T140000Z
        END:VEVENT
        END:VCALENDAR
        """
        let ev = try XCTUnwrap(ICSImportExport.parse(ics).first)
        XCTAssertEqual(ev.summary, "Colon Param Event")
    }

    // MARK: - Serialization

    func testSerializeContainsRequiredProperties() {
        let event = ICSImportExport.ICSEvent(
            uid: "uid-1",
            summary: "Ship it",
            start: Date(timeIntervalSince1970: 1_780_000_000),
            end: Date(timeIntervalSince1970: 1_780_003_600),
            location: "Main Office",
            description: "Final review",
            rrule: "FREQ=DAILY;COUNT=3"
        )
        let out = ICSImportExport.serialize([event])
        XCTAssertTrue(out.hasPrefix("BEGIN:VCALENDAR"))
        XCTAssertTrue(out.contains("VERSION:2.0"))
        XCTAssertTrue(out.contains("BEGIN:VEVENT"))
        XCTAssertTrue(out.contains("UID:uid-1"))
        XCTAssertTrue(out.contains("SUMMARY:Ship it"))
        XCTAssertTrue(out.contains("LOCATION:Main Office"))
        XCTAssertTrue(out.contains("DESCRIPTION:Final review"))
        XCTAssertTrue(out.contains("RRULE:FREQ=DAILY;COUNT=3"))
        XCTAssertTrue(out.contains("END:VEVENT"))
        XCTAssertTrue(out.contains("END:VCALENDAR"))
        // CRLF line endings per RFC 5545.
        XCTAssertTrue(out.contains("\r\n"))
    }

    func testSerializeEscapesSpecialCharacters() {
        let event = ICSImportExport.ICSEvent(
            summary: "Lunch, then; planning",
            start: Date(timeIntervalSince1970: 1_780_000_000),
            description: "line1\nline2"
        )
        let out = ICSImportExport.serialize([event])
        XCTAssertTrue(out.contains("SUMMARY:Lunch\\, then\\; planning"))
        XCTAssertTrue(out.contains("DESCRIPTION:line1\\nline2"))
    }

    func testSerializeFoldsLongLines() {
        let longSummary = String(repeating: "x", count: 200)
        let event = ICSImportExport.ICSEvent(
            summary: longSummary,
            start: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let out = ICSImportExport.serialize([event])
        for line in out.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 75, "line exceeds 75 octets: \(line.prefix(40))…")
        }
        // The folded summary must reassemble to the original on re-parse.
        let reparsed = ICSImportExport.parse(out)
        XCTAssertEqual(reparsed.first?.summary, longSummary)
    }

    // MARK: - Round trip

    func testRoundTripTimedEvent() throws {
        let original = ICSImportExport.ICSEvent(
            uid: "rt-1",
            summary: "Round trip, with; specials\nand a newline",
            start: Date(timeIntervalSince1970: 1_781_234_100),
            end: Date(timeIntervalSince1970: 1_781_237_700),
            isAllDay: false,
            location: "HQ; floor 2",
            description: "Body, with commas\nand lines",
            rrule: "FREQ=MONTHLY;INTERVAL=2"
        )
        let serialized = ICSImportExport.serialize([original])
        let back = try XCTUnwrap(ICSImportExport.parse(serialized).first)

        XCTAssertEqual(back.uid, original.uid)
        XCTAssertEqual(back.summary, original.summary)
        XCTAssertEqual(back.location, original.location)
        XCTAssertEqual(back.description, original.description)
        XCTAssertEqual(back.rrule, original.rrule)
        XCTAssertFalse(back.isAllDay)
        // ICS second-level resolution: compare within 1s.
        XCTAssertEqual(back.start.timeIntervalSince1970, original.start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(
            back.effectiveEnd.timeIntervalSince1970,
            original.effectiveEnd.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testRoundTripAllDayEvent() throws {
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_782_000_000))
        let original = ICSImportExport.ICSEvent(
            uid: "rt-2",
            summary: "All Day Thing",
            start: day,
            end: day.addingTimeInterval(86400),
            isAllDay: true
        )
        let serialized = ICSImportExport.serialize([original])
        let back = try XCTUnwrap(ICSImportExport.parse(serialized).first)
        XCTAssertTrue(back.isAllDay)
        XCTAssertEqual(back.summary, "All Day Thing")
        XCTAssertEqual(back.start.timeIntervalSince1970, original.start.timeIntervalSince1970, accuracy: 1)
    }

    func testRoundTripMultipleEventsPreservesOrder() throws {
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        let originals = (0..<4).map { i in
            ICSImportExport.ICSEvent(
                uid: "multi-\(i)",
                summary: "Event \(i)",
                start: base.addingTimeInterval(Double(i) * 7200),
                end: base.addingTimeInterval(Double(i) * 7200 + 3600)
            )
        }
        let back = ICSImportExport.parse(ICSImportExport.serialize(originals))
        XCTAssertEqual(back.map { $0.uid }, originals.map { $0.uid })
        XCTAssertEqual(back.map { $0.summary }, originals.map { $0.summary })
    }

    // MARK: - Tool date input parsing

    func testToolParsesISOAndDateOnlyInputs() {
        XCTAssertNotNil(CalendarTool.parseDateInput("2026-06-09T15:00:00Z"))
        XCTAssertNotNil(CalendarTool.parseDateInput("2026-06-09T15:00:00-04:00"))
        let local = CalendarTool.parseDateInput("2026-06-09T15:00:00")
        XCTAssertNotNil(local)
        XCTAssertEqual(local?.isDateOnly, false)
        let dateOnly = CalendarTool.parseDateInput("2026-06-09")
        XCTAssertNotNil(dateOnly)
        XCTAssertEqual(dateOnly?.isDateOnly, true)
        XCTAssertNil(CalendarTool.parseDateInput("not a date"))
        XCTAssertNil(CalendarTool.parseDateInput(""))
    }
}
