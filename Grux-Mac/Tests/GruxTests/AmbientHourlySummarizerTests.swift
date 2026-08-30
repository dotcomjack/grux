import XCTest
@testable import Grux

final class AmbientHourlySummarizerTests: XCTestCase {

    private func date(y: Int, m: Int, d: Int, h: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = h; comps.minute = 0; comps.second = 0
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    func test_dayKey_for5am_usesPreviousDate() {
        let cal = Calendar(identifier: .gregorian)
        let d = date(y: 2026, m: 4, d: 23, h: 5)
        XCTAssertEqual(
            AmbientHourlySummarizer.dayKey(forHourStart: d, calendar: cal),
            "2026-04-22"
        )
    }

    func test_dayKey_for6am_usesSameDate() {
        let cal = Calendar(identifier: .gregorian)
        let d = date(y: 2026, m: 4, d: 23, h: 6)
        XCTAssertEqual(
            AmbientHourlySummarizer.dayKey(forHourStart: d, calendar: cal),
            "2026-04-23"
        )
    }

    func test_dayKey_forMidnight_usesPreviousDate() {
        let cal = Calendar(identifier: .gregorian)
        let d = date(y: 2026, m: 4, d: 23, h: 0)
        XCTAssertEqual(
            AmbientHourlySummarizer.dayKey(forHourStart: d, calendar: cal),
            "2026-04-22"
        )
    }

    func test_dayKey_forNoon_usesSameDate() {
        let cal = Calendar(identifier: .gregorian)
        let d = date(y: 2026, m: 4, d: 23, h: 12)
        XCTAssertEqual(
            AmbientHourlySummarizer.dayKey(forHourStart: d, calendar: cal),
            "2026-04-23"
        )
    }
}
