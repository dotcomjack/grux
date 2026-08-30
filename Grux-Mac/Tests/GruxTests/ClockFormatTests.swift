import XCTest
@testable import Grux

/// The house rule is `7:30 PM`, never `19:30`, on every US-facing surface.
/// Settings shipped `End: 23:00` on the Active hours row and no guard in this
/// repo was looking for it, so this is that guard.
final class ClockFormatTests: XCTestCase {

    /// Midnight and noon are where every naive `h % 12` implementation breaks:
    /// both land on 0 and render as "0 AM" / "0 PM" instead of 12.
    func testMidnightAndNoonRenderAsTwelve() {
        XCTAssertEqual(ClockFormat.hourLabel(0), "12 AM")
        XCTAssertEqual(ClockFormat.hourLabel(12), "12 PM")
    }

    /// The end slider ranges 1...24, where 24 means midnight closing the day.
    /// It must not render as "24 PM" or trap.
    func testTwentyFourIsMidnight() {
        XCTAssertEqual(ClockFormat.hourLabel(24), "12 AM")
    }

    /// The exact value that was on screen.
    func testTheAfternoonHoursThatWereWrong() {
        XCTAssertEqual(ClockFormat.hourLabel(23), "11 PM")
        XCTAssertEqual(ClockFormat.hourLabel(13), "1 PM")
        XCTAssertEqual(ClockFormat.hourLabel(17), "5 PM")
    }

    func testMorningHours() {
        XCTAssertEqual(ClockFormat.hourLabel(1), "1 AM")
        XCTAssertEqual(ClockFormat.hourLabel(5), "5 AM")
        XCTAssertEqual(ClockFormat.hourLabel(11), "11 AM")
    }

    /// A label is never worth a crash, so out-of-range wraps instead of trapping.
    func testOutOfRangeWrapsRatherThanTrapping() {
        XCTAssertEqual(ClockFormat.hourLabel(25), "1 AM")
        XCTAssertEqual(ClockFormat.hourLabel(-1), "11 PM")
    }

    /// The actual convention, asserted directly: no rendered hour may contain a
    /// bare 24-hour "HH:00" form, and every one must carry AM or PM.
    func testNoLabelAcrossTheWholeRangeIsMilitaryTime() {
        for hour in 0...24 {
            let label = ClockFormat.hourLabel(hour)
            XCTAssertFalse(label.contains(":"), "\(hour) rendered as \(label), which reads as military time")
            XCTAssertTrue(label.hasSuffix(" AM") || label.hasSuffix(" PM"),
                          "\(hour) rendered as \(label), with no AM or PM")
        }
    }
}
