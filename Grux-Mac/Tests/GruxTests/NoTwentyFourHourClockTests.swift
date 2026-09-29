import XCTest
@testable import Grux

/// Times a person reads say `8:54 AM`, never `08:54` or `13:48`.
///
/// Found 2026-09-21 in a live capture of Mail: every message received that
/// day was stamped `08:54`, `10:00`, `12:07`, and the Security log did the
/// same. Both now go through `TodayModel.clock`.
@MainActor
final class NoTwentyFourHourClockTests: XCTestCase {

    private var eastern: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    func test_mailStampsTodayWithTheTwelveHourClock() {
        let cal = eastern
        let morning = cal.date(bySettingHour: 8, minute: 54, second: 0, of: Date())!
        XCTAssertEqual(MailboxView.shortDate(morning, calendar: cal), "8:54 AM")
        let afternoon = cal.date(bySettingHour: 13, minute: 48, second: 0, of: Date())!
        XCTAssertTrue(MailboxView.longDate(afternoon, calendar: cal).hasSuffix(" at 1:48 PM"),
                      MailboxView.longDate(afternoon, calendar: cal))
    }

    func test_theSecurityLogStampsWithTheTwelveHourClock() {
        let cal = eastern
        let d = cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 13, minute: 48))!
        XCTAssertTrue(SecuritySettingsView.stamp(d).contains("PM"), SecuritySettingsView.stamp(d))
        XCTAssertFalse(SecuritySettingsView.stamp(d).contains("13:"), SecuritySettingsView.stamp(d))
    }

    /// No view builds a 24 hour format of its own. Data formats (ISO strings,
    /// parsers, what a model reads) live outside view files and are not
    /// rendering, so they are not this test's business.
    func test_noViewFileFormatsATwentyFourHourClock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix("View.swift") }
        XCTAssertGreaterThan(files.count, 50, "the scan found too few view files to mean anything")
        var offenders: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            if text.contains("HH:mm") { offenders.append(f.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "these views print a 24 hour clock")
    }
}
