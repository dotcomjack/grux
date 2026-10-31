import XCTest
@testable import Grux

// F0: the self-upgrade schedule is a choice the person makes, saved in config.json,
// every scheduled pass OFF until they turn it on, and read by the governor on every
// tick so a change takes effect without a relaunch. Before this, the schedule lived
// only in memory with the nightly, weekly and idle passes all ON, so turning
// self-upgrade on (or pressing "Look for upgrades now") armed a nightly pass nobody chose.
final class FoundryScheduleTests: XCTestCase {

    // MARK: - Saved, and off until chosen

    // The fields a config written before this key existed always carries.
    private static let minimalConfig = Data("""
        {"anthropicApiKey": "", "model": "claude-haiku-4-5-20251001", "captureIntervalSeconds": 30,
         "driftThreshold": 2, "autoPromoteDetectedTask": true, "notificationsEnabled": true,
         "screenAnalysisEnabled": true, "launchAtLogin": false, "snoozeMinutes": 15,
         "activeHoursStart": 6, "activeHoursEnd": 23}
        """.utf8)

    func testAConfigWithNoScheduleHasEveryScheduledPassOff() throws {
        let cfg = try JSONDecoder().decode(GruxConfig.self, from: Self.minimalConfig)
        XCTAssertEqual(cfg.foundrySchedule, FoundrySchedule())
        XCTAssertFalse(cfg.foundrySchedule.nightly)
        XCTAssertFalse(cfg.foundrySchedule.weeklyDeep)
        XCTAssertFalse(cfg.foundrySchedule.whenIdle)
        XCTAssertFalse(cfg.foundrySchedule.anyOn)
    }

    func testTheScheduleIsSavedInConfigAndReadBack() throws {
        var cfg = try JSONDecoder().decode(GruxConfig.self, from: Self.minimalConfig)
        cfg.foundrySchedule = FoundrySchedule(nightly: true, weeklyDeep: false, whenIdle: true)
        let data = try JSONEncoder().encode(cfg)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let saved = try XCTUnwrap(json["foundrySchedule"] as? [String: Any],
                                  "config.json must carry the schedule the person chose")
        XCTAssertEqual(saved["nightly"] as? Bool, true)
        XCTAssertEqual(saved["whenIdle"] as? Bool, true)
        let back = try JSONDecoder().decode(GruxConfig.self, from: data)
        XCTAssertEqual(back.foundrySchedule, cfg.foundrySchedule)
    }

    func testAHandEditedScheduleMissingAPassReadsThatPassAsOff() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.minimalConfig) as? [String: Any])
        json["foundrySchedule"] = ["nightly": true]
        let cfg = try JSONDecoder().decode(GruxConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(cfg.foundrySchedule, FoundrySchedule(nightly: true, weeklyDeep: false, whenIdle: false))
    }

    // MARK: - What the governor is allowed to schedule

    func testWithSelfUpgradeOffNoScheduledPassRunsWhateverTheScheduleSays() {
        let all = FoundrySchedule(nightly: true, weeklyDeep: true, whenIdle: true)
        XCTAssertEqual(FoundrySchedule.effective(enabled: false, schedule: all), FoundrySchedule())
        XCTAssertEqual(FoundrySchedule.effective(enabled: true, schedule: all), all)
    }

    func testTheGovernorConfigTakesItsPassesFromTheSchedule() {
        let off = FoundryGovernorConfig().scheduled(FoundrySchedule())
        XCTAssertFalse(off.nightlyEnabled)
        XCTAssertFalse(off.deepPassEnabled)
        XCTAssertFalse(off.opportunisticEnabled)
        let idleOnly = FoundryGovernorConfig().scheduled(FoundrySchedule(whenIdle: true))
        XCTAssertFalse(idleOnly.nightlyEnabled)
        XCTAssertFalse(idleOnly.deepPassEnabled)
        XCTAssertTrue(idleOnly.opportunisticEnabled)
    }

    // MARK: - Honored live

    private let zone = FoundryGovernorWindow.calendar.timeZone

    private func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.timeZone = zone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @MainActor
    private func governorAt(_ now: Date, idle: TimeInterval) -> FoundryGovernor {
        let gov = FoundryGovernor(stateURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-schedule-test-\(UUID().uuidString).json"))
        gov.now = { now }
        gov.idleSeconds = { idle }
        gov.onACPower = { true }
        gov.sessionLimited = { false }
        return gov
    }

    @MainActor
    func testAnUnscheduledGovernorLaunchesNothingInsideEveryWindow() async {
        let breakerWasPaused = GruxUpdater.shared.isAutoLandPaused()
        GruxUpdater.shared.clearAutoLandPause()
        defer {
            if breakerWasPaused {
                GruxUpdater.shared.tripAutoLandPause(reason: "restored after FoundryScheduleTests")
            }
        }
        // 3 AM Monday (nightly window), 11 PM Sunday (deep window), and an idle Mac on
        // power for two hours (opportunistic): with the saved schedule off, none run.
        for (now, idle) in [(local(2026, 6, 15, 3), 0.0), (local(2026, 6, 14, 23), 0.0),
                            (local(2026, 6, 15, 14), 7200.0)] {
            let gov = governorAt(now, idle: idle)
            gov.schedule = { FoundrySchedule() }
            gov.runCycle = { pass in XCTFail("\(pass) ran with every scheduled pass off") }
            gov.tick()
            XCTAssertEqual(gov.phase, .idle)
            XCTAssertNil(gov.lastNightlyAt)
            XCTAssertNil(gov.lastDeepAt)
            XCTAssertNil(gov.lastOpportunisticAt)
        }
    }

    @MainActor
    func testTurningNightlyOnTakesEffectOnTheNextTickWithNoRelaunch() async {
        let breakerWasPaused = GruxUpdater.shared.isAutoLandPaused()
        GruxUpdater.shared.clearAutoLandPause()
        defer {
            if breakerWasPaused {
                GruxUpdater.shared.tripAutoLandPause(reason: "restored after FoundryScheduleTests")
            }
        }
        let gov = governorAt(local(2026, 6, 15, 3), idle: 0)
        var chosen = FoundrySchedule()
        gov.schedule = { chosen }
        gov.runCycle = { _ in XCTFail("nothing chosen yet") }
        gov.tick()
        XCTAssertNil(gov.lastNightlyAt)

        chosen.nightly = true
        let launched = expectation(description: "nightly launched")
        gov.runCycle = { pass in
            XCTAssertEqual(pass, .nightlyLight)
            launched.fulfill()
        }
        gov.tick()
        await fulfillment(of: [launched], timeout: 2)
    }

    @MainActor
    func testTheLiveGovernorReadsTheSavedConfigByDefault() {
        let state = AppState.shared
        let saved = (state.config.foundryEnabled, state.config.foundrySchedule)
        defer { state.config.foundryEnabled = saved.0; state.config.foundrySchedule = saved.1 }
        let gov = FoundryGovernor(stateURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-schedule-test-\(UUID().uuidString).json"))

        state.config.foundryEnabled = true
        state.config.foundrySchedule = FoundrySchedule(nightly: true)
        XCTAssertEqual(gov.schedule(), FoundrySchedule(nightly: true))
        // Turning self-upgrade off stops every scheduled pass at once, live.
        state.config.foundryEnabled = false
        XCTAssertEqual(gov.schedule(), FoundrySchedule())
    }

    // MARK: - Plain words

    func testTheScheduleLineSaysWhatRunsByItself() {
        XCTAssertEqual(FoundrySchedule.line(enabled: false, schedule: FoundrySchedule(nightly: true)),
                       "Self-upgrade is off. Turn it on in Settings, or ask Grux to upgrade itself.")
        XCTAssertEqual(FoundrySchedule.line(enabled: true, schedule: FoundrySchedule()),
                       "Self-upgrade is on. It runs only when you ask.")
        XCTAssertEqual(FoundrySchedule.line(enabled: true, schedule: FoundrySchedule(nightly: true, whenIdle: true)),
                       "Self-upgrade is on. It also runs nightly between 2 and 6 AM and when your Mac is idle on power.")
        XCTAssertEqual(FoundrySchedule.line(enabled: true, schedule: FoundrySchedule(nightly: true, weeklyDeep: true, whenIdle: true)),
                       "Self-upgrade is on. It also runs nightly between 2 and 6 AM, Sundays at 11 PM and when your Mac is idle on power.")
    }
}
