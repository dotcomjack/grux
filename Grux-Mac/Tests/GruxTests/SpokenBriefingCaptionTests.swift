import XCTest
@testable import Grux

/// D191 item 4 (sense pass 25, `settings-voice` page): the spoken-briefing
/// caption said "It needs a mail account to have anything to say." A briefing
/// has plenty to say without mail (what waits in Approvals, Self-Upgrade
/// proposals, goals, the day ahead). What mail gates is the SCHEDULE:
/// `BriefingEngine.tick` fires the 7 AM and 9 PM slots only when Jax HQ is
/// ready, and Jax HQ requires a mail account. The speaker on Home's briefing
/// card (`briefNow`) is not gated on mail. And nothing is spoken unless
/// Tuning's "Speak Grux's replies aloud" (Talks back) is on too. The caption
/// now says each of those, built from the gates it describes.
@MainActor
final class SpokenBriefingCaptionTests: XCTestCase {

    func test_theScheduleGateIsReadFromTheRegistry() {
        let row = FeatureRegistry.rows.first { $0.id == "jax.hq" }
        XCTAssertNotNil(row)
        XCTAssertEqual(SpokenBriefingCopy.scheduleNeedsMail, row?.requires.contains(.endpointImap) ?? false)
        XCTAssertTrue(SpokenBriefingCopy.scheduleNeedsMail, "jax.hq requires a mail account today")
    }

    func test_theCaptionNeverSaysABriefingHasNothingToSay() {
        for needs in [true, false] {
            let c = SpokenBriefingCopy.caption(scheduleNeedsMail: needs)
            XCTAssertFalse(c.contains("anything to say"), c)
        }
    }

    func test_theCaptionNamesMailboxExactlyWhenTheScheduleWaitsForMail() {
        let with = SpokenBriefingCopy.caption(scheduleNeedsMail: true)
        XCTAssertTrue(with.contains("once a mail account is added in Mail."), with)
        let without = SpokenBriefingCopy.caption(scheduleNeedsMail: false)
        XCTAssertFalse(without.contains("in Mail"), without)
        XCTAssertFalse(without.contains("mail account"), without)
    }

    func test_theCaptionNamesTheOtherGatesASpokenBriefingPasses() {
        let c = SpokenBriefingCopy.caption(scheduleNeedsMail: true)
        // `BriefingEngine.speaks` needs speakRepliesAloud: Tuning's Talks back card.
        XCTAssertTrue(c.contains("Talks back in Tuning"), c)
        // `briefNow` (Home's speaker button) runs with no readiness gate.
        XCTAssertTrue(c.contains("speaker on Home's briefing card"), c)
        // With it off the briefing is still written (the passive refresh).
        XCTAssertTrue(c.contains("still written"), c)
    }

    func test_theHoursComeFromTheSchedule() {
        let morning = SpokenBriefingCopy.clock(BriefingWindow.morningHour)
        let night = SpokenBriefingCopy.clock(BriefingWindow.nightHour)
        XCTAssertEqual(morning, "7 AM")
        XCTAssertEqual(night, "9 PM")
        XCTAssertEqual(SpokenBriefingCopy.toggleLabel, "Read me a briefing at \(morning) and \(night)")
        XCTAssertTrue(SpokenBriefingCopy.caption(scheduleNeedsMail: true).contains("\(morning) and \(night)"))
        XCTAssertEqual(SpokenBriefingCopy.clock(0), "12 AM")
        XCTAssertEqual(SpokenBriefingCopy.clock(12), "12 PM")
        XCTAssertEqual(SpokenBriefingCopy.clock(11), "11 AM")
        XCTAssertEqual(SpokenBriefingCopy.clock(13), "1 PM")
    }

    func test_settingsShowsTheBuiltCopy() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/SettingsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("Toggle(SpokenBriefingCopy.toggleLabel"), "the toggle reads the built label")
        XCTAssertTrue(src.contains("SpokenBriefingCopy.caption(scheduleNeedsMail: SpokenBriefingCopy.scheduleNeedsMail)"),
                      "the caption reads the built copy")
        XCTAssertFalse(src.contains("anything to say"))
    }
}
