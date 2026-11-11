import XCTest
@testable import Grux

/// D179 item 2, sense pass 22 (`home-1.png`): Home said "Good evening, Jack"
/// above "AFTERNOON BRIEFING / Afternoon." written at 4:11 PM, with nothing
/// saying when. A briefing shown in a later part of the day, or on a later day,
/// says when it was written.
final class BriefingCardTitleTests: XCTestCase {

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute
        return BriefingWindow.calendar.date(from: c)!
    }

    private func brief(_ date: Date, _ slot: Briefing.Slot = .onDemand) -> Briefing {
        Briefing(date: date, slot: slot, spokenText: "Afternoon.", items: [])
    }

    func test_theLiveCaseSaysWhenItWasWritten() {
        XCTAssertEqual(brief(at(5, 16, 11)).cardTitle(now: at(5, 17, 2)), "Afternoon Briefing, 4:11 PM")
    }

    /// On, under and over the 5 PM edge, and the same part of the day.
    func test_theTimeShowsOnlyOnceThePartOfTheDayHasMoved() {
        XCTAssertEqual(brief(at(5, 16, 11)).cardTitle(now: at(5, 16, 59)), "Afternoon Briefing")
        XCTAssertEqual(brief(at(5, 16, 11)).cardTitle(now: at(5, 17, 0)), "Afternoon Briefing, 4:11 PM")
        XCTAssertEqual(brief(at(5, 12, 0)).cardTitle(now: at(5, 12, 0)), "Afternoon Briefing")
        XCTAssertEqual(brief(at(5, 9, 5), .morning).cardTitle(now: at(5, 11, 59)), "Morning Briefing")
        XCTAssertEqual(brief(at(5, 9, 5), .morning).cardTitle(now: at(5, 12, 0)), "Morning Briefing, 9:05 AM")
    }

    /// A briefing from another day names the day, so "Afternoon Briefing" from
    /// yesterday never reads as this afternoon's.
    func test_anEarlierDayIsNamed() {
        XCTAssertEqual(brief(at(5, 16, 11)).cardTitle(now: at(6, 16, 30)), "Afternoon Briefing, yesterday at 4:11 PM")
        XCTAssertEqual(brief(at(5, 21, 0), .night).cardTitle(now: at(6, 0, 30)), "Night Briefing, yesterday at 9:00 PM")
        XCTAssertEqual(brief(at(3, 16, 11)).cardTitle(now: at(6, 16, 30)), "Afternoon Briefing, Nov 3 at 4:11 PM")
    }

    func test_homeShowsTheCardTitle() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/BriefingCardTitleTests.swift",
            with: "Sources/Grux/Home/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("brief.cardTitle(now:"), "Home titles the card by when it was written")
        XCTAssertFalse(src.contains("brief.displayTitle"), src)
    }
}

/// Wave 61 review round 1 P3s: late night spans midnight, and a clock set back.
final class BriefingCardTitleRound2Tests: XCTestCase {

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute
        return BriefingWindow.calendar.date(from: c)!
    }
    private func brief(_ date: Date) -> Briefing {
        Briefing(date: date, slot: .onDemand, spokenText: "Late check.", items: [])
    }

    /// 00:30 and 22:30 the same date are both "late", 22 hours apart.
    func test_lateNightBeforeAndAfterTheDayAreApart() {
        XCTAssertEqual(brief(at(6, 0, 30)).cardTitle(now: at(6, 22, 30)), "Late Briefing, 12:30 AM")
        XCTAssertEqual(brief(at(6, 0, 30)).cardTitle(now: at(6, 4, 59)), "Late Briefing")
        XCTAssertEqual(brief(at(6, 22, 0)).cardTitle(now: at(6, 23, 59)), "Late Briefing")
        XCTAssertEqual(brief(at(6, 22, 0)).cardTitle(now: at(7, 0, 30)), "Late Briefing, yesterday at 10:00 PM")
    }

    /// A briefing dated after now (the clock moved back) never shows a time to come.
    func test_aBriefingFromTheFutureShowsNoTime() {
        XCTAssertEqual(brief(at(6, 18, 0)).cardTitle(now: at(6, 16, 0)), "Evening Briefing")
        // Round 2: another day still names the day.
        XCTAssertEqual(brief(at(7, 18, 0)).cardTitle(now: at(6, 16, 0)), "Evening Briefing, Nov 7")
    }
}
