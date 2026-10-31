import XCTest
@testable import Grux

/// D43: a crash-loop pause stops every self-upgrade pass, and the only way out
/// was a `fire-` file. The pane now says when and why it paused, and its Resume
/// button clears the pause through the same call the trigger makes.
@MainActor
final class FoundryResumeTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundry-resume-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var stateDir: URL { root.appendingPathComponent("updater-state", isDirectory: true) }

    private func makeUpdater() -> GruxUpdater {
        GruxUpdater(appURL: root.appendingPathComponent("Applications/Grux.app", isDirectory: true),
                    archiveRoot: root.appendingPathComponent("previous-build", isDirectory: true),
                    stateDir: stateDir,
                    proposalStore: ProposalStore(storageURL: root.appendingPathComponent("proposals.json")),
                    trustLedger: TrustLedger(storageURL: root.appendingPathComponent("ledger.json")),
                    timeline: FoundryTimelineStore(storageURL: root.appendingPathComponent("timeline.json")))
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func test_thePauseCarriesWhenAndWhetherItWentBack() {
        let updater = makeUpdater()
        XCTAssertNil(updater.autoLandPause())
        let at = date("2026-10-30 07:30")
        updater.tripAutoLandPause(reason: "2 crashes at launch inside 10 minutes; restored=true.", restored: true, now: at)
        let pause = updater.autoLandPause()
        XCTAssertEqual(pause?.trippedAt, at)
        XCTAssertEqual(pause?.restored, true)
        XCTAssertTrue(updater.isAutoLandPaused())
    }

    // A pause written by an older build has no `restored` field: it still reads
    // as paused, and the pane does not claim either way.
    func test_aPauseFromAnOlderBuildStillReads() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let old = #"{"paused":true,"trippedAt":"2026-10-30T14:30:00Z","reason":"2 crashes at launch inside 10 minutes; restored=true."}"#
        try Data(old.utf8).write(to: stateDir.appendingPathComponent("auto-land-paused.json"))
        let updater = makeUpdater()
        XCTAssertTrue(updater.isAutoLandPaused())
        XCTAssertNotNil(updater.autoLandPause())
        XCTAssertNil(updater.autoLandPause()?.restored)
    }

    func test_resumeClearsThePause() {
        let updater = makeUpdater()
        updater.tripAutoLandPause(reason: "test", restored: true, now: Date())
        updater.clearAutoLandPause()
        XCTAssertNil(updater.autoLandPause())
        XCTAssertFalse(updater.isAutoLandPaused())
    }

    func test_thePaneSaysWhenAndWhyInPlainWords() {
        let now = date("2026-10-30 09:00")
        let at = date("2026-10-30 07:30")
        XCTAssertEqual(
            FoundrySchedule.pauseLine(GruxUpdater.AutoLandPause(trippedAt: at, restored: true), now: now, calendar: calendar),
            "Self-upgrade paused itself today at 7:30 AM: Grux crashed 2 times at launch within 10 minutes, so it went back to the last build that worked. Nothing installs until you resume.")
        XCTAssertEqual(
            FoundrySchedule.pauseLine(GruxUpdater.AutoLandPause(trippedAt: at, restored: false), now: now, calendar: calendar),
            "Self-upgrade paused itself today at 7:30 AM: Grux crashed 2 times at launch within 10 minutes, and it could not go back to an earlier build. Nothing installs until you resume.")
        XCTAssertEqual(
            FoundrySchedule.pauseLine(GruxUpdater.AutoLandPause(trippedAt: nil, restored: nil), now: now, calendar: calendar),
            "Self-upgrade paused itself: Grux crashed 2 times at launch within 10 minutes. Nothing installs until you resume.")
    }

    // The button and the trigger clear the pause the same way, so the trigger's
    // live proof is the button's.
    func test_thePaneOffersResumeThroughTheTriggersCall() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: src.appendingPathComponent("Sources/Grux/Foundry/SelfUpgradeView.swift"), encoding: .utf8)
        let button = try XCTUnwrap(view.range(of: "Button(\"Resume self-upgrade\")"))
        XCTAssertTrue(view[button.upperBound...].prefix(300).contains("GruxUpdater.shared.clearAutoLandPause()"))
        XCTAssertTrue(view.contains("FoundrySchedule.pauseLine("))
        let triggers = try String(contentsOf: src.appendingPathComponent("Sources/Grux/Triggers/AppTriggers.swift"), encoding: .utf8)
        XCTAssertTrue(triggers.contains("GruxUpdater.shared.clearAutoLandPause()"))
    }

    // Wave 14 P3s, red first.

    // A pause from days back names its date with "on"; today and yesterday read
    // as they are.
    func test_aPauseDaysAgoReadsOnItsDate() {
        let now = date("2026-10-30 09:00")
        XCTAssertTrue(FoundrySchedule.pauseLine(GruxUpdater.AutoLandPause(trippedAt: date("2026-10-27 09:00"), restored: true),
                                                now: now, calendar: calendar)
            .hasPrefix("Self-upgrade paused itself on Oct 27 at 9:00 AM: "))
        XCTAssertTrue(FoundrySchedule.pauseLine(GruxUpdater.AutoLandPause(trippedAt: date("2026-10-29 21:00"), restored: true),
                                                now: now, calendar: calendar)
            .hasPrefix("Self-upgrade paused itself yesterday at 9:00 PM: "))
    }

    // The trip's timeline row says what the banner says, so a restore that failed
    // is never written up as "Restored the last-good build."
    func test_theTimelineRowAgreesWithTheBanner() {
        for restored in [true, false] {
            let store = FoundryTimelineStore(storageURL: root.appendingPathComponent("timeline-\(restored).json"))
            let updater = GruxUpdater(appURL: root.appendingPathComponent("Applications/Grux.app", isDirectory: true),
                                      archiveRoot: root.appendingPathComponent("previous-build", isDirectory: true),
                                      stateDir: root.appendingPathComponent("state-\(restored)", isDirectory: true),
                                      proposalStore: ProposalStore(storageURL: root.appendingPathComponent("p-\(restored).json")),
                                      trustLedger: TrustLedger(storageURL: root.appendingPathComponent("l-\(restored).json")),
                                      timeline: store)
            updater.tripAutoLandPause(reason: "2 crashes at launch inside 10 minutes; restored=\(restored).", restored: restored)
            let detail = store.entries.last?.detail ?? ""
            XCTAssertEqual(detail, FoundrySchedule.pauseLine(GruxUpdater.AutoLandPause(trippedAt: nil, restored: restored), now: Date()))
            XCTAssertEqual(detail.contains("went back to the last build that worked"), restored)
        }
    }

    // Resume measures crashes from the moment a person resumed, so one more launch
    // crash does not re-trip at once on the crashes that already tripped it.
    func test_resumeForgetsTheCrashesThatTrippedIt() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode([Date().addingTimeInterval(-120), Date().addingTimeInterval(-60)])
            .write(to: stateDir.appendingPathComponent("crashes.json"))
        let updater = makeUpdater()
        XCTAssertEqual(updater.loadCrashes().count, 2)
        updater.tripAutoLandPause(reason: "test", restored: true)
        updater.clearAutoLandPause()
        XCTAssertEqual(updater.loadCrashes(), [])
    }

    // Wave 15 review P3: a resume with nothing paused (the trigger touched while a new
    // build is watched) must not erase the one crash the watch has counted so far.
    func test_aResumeWithNothingPausedKeepsTheCrashes() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode([Date().addingTimeInterval(-60)])
            .write(to: stateDir.appendingPathComponent("crashes.json"))
        let updater = makeUpdater()
        XCTAssertFalse(updater.isAutoLandPaused())
        updater.clearAutoLandPause()
        XCTAssertEqual(updater.loadCrashes().count, 1, "a resume with nothing paused erased the watch's crash")
    }

    // A clear from the trigger (or anywhere) tells an open pane at once, not at its
    // next minute tick.
    func test_aClearFromAnywhereRedrawsThePane() throws {
        let updater = makeUpdater()
        updater.tripAutoLandPause(reason: "test", restored: true)
        let told = expectation(forNotification: GruxUpdater.autoLandPauseChanged, object: nil)
        updater.clearAutoLandPause()
        wait(for: [told], timeout: 1)
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: src.appendingPathComponent("Sources/Grux/Foundry/SelfUpgradeView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains(".onReceive(NotificationCenter.default.publisher(for: GruxUpdater.autoLandPauseChanged))"))
    }
}
