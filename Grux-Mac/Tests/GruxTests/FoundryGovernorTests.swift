import XCTest
@testable import Grux

// Governor unit tests: window math (DST-safe, computed in the same time zone
// the governor uses), the scheduling decision table, session-limit yielding,
// estimated-cost label formatting, and the per-cycle hard token cap.
final class FoundryGovernorTests: XCTestCase {

    // Build instants in the SAME zone the governor computes windows in, so the
    // assertions hold wherever the configured zone points.
    private let windowZone = FoundryGovernorWindow.calendar.timeZone

    private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi
        comps.timeZone = windowZone
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private func snapshot(
        now: Date,
        idle: TimeInterval = 0,
        ac: Bool = true,
        limited: Bool = false,
        lastNightly: Date? = nil,
        lastDeep: Date? = nil,
        running: Bool = false
    ) -> FoundryGovernorSnapshot {
        FoundryGovernorSnapshot(
            now: now, idleSeconds: idle, onACPower: ac, sessionLimited: limited,
            lastNightlyAt: lastNightly, lastDeepAt: lastDeep, cycleRunning: running
        )
    }

    // MARK: - Nightly window math

    func testNightlyWindowBoundariesOnNormalDay() {
        // Monday 2026-06-15, no DST transition anywhere near.
        XCTAssertFalse(FoundryGovernorWindow.isInNightlyWindow(localDate(2026, 6, 15, 1, 59)))
        XCTAssertTrue(FoundryGovernorWindow.isInNightlyWindow(localDate(2026, 6, 15, 2, 0)))
        XCTAssertTrue(FoundryGovernorWindow.isInNightlyWindow(localDate(2026, 6, 15, 5, 59)))
        XCTAssertFalse(FoundryGovernorWindow.isInNightlyWindow(localDate(2026, 6, 15, 6, 0)))
        XCTAssertFalse(FoundryGovernorWindow.isInNightlyWindow(localDate(2026, 6, 15, 14, 0)))
    }

    func testNightlyWindowOnSpringForwardNight() {
        // Under US DST rules 2026-03-08 skips the 2 o'clock hour: 02:00 jumps
        // straight to 03:00, so that hour does not exist. The window still
        // opens; 03:30 local is inside it.
        let inWindow = localDate(2026, 3, 8, 3, 30)
        XCTAssertTrue(FoundryGovernorWindow.isInNightlyWindow(inWindow))

        // And the next-start computation does not skip the day: from Saturday
        // 23:00 the next nightly start lands on March 8, inside the window.
        let next = FoundryGovernorWindow.nextNightlyStart(after: localDate(2026, 3, 7, 23, 0))
        XCTAssertTrue(FoundryGovernorWindow.sameLocalDay(next, localDate(2026, 3, 8, 12, 0)),
                      "next nightly start should land on the spring-forward day, got \(next)")
        XCTAssertTrue(FoundryGovernorWindow.isInNightlyWindow(next))
    }

    func testNightlyWindowOnFallBackNight() {
        // Under US DST rules 2026-11-01 repeats the 1 o'clock hour. The window
        // math keys on the local hour component, so 02:30 is still in.
        XCTAssertTrue(FoundryGovernorWindow.isInNightlyWindow(localDate(2026, 11, 1, 2, 30)))
        XCTAssertFalse(FoundryGovernorWindow.isInNightlyWindow(localDate(2026, 11, 1, 6, 30)))
    }

    func testNextNightlyStartFromInsideWindowMovesToTomorrow() {
        let next = FoundryGovernorWindow.nextNightlyStart(after: localDate(2026, 6, 15, 2, 30))
        XCTAssertTrue(FoundryGovernorWindow.sameLocalDay(next, localDate(2026, 6, 16, 12, 0)))
        let cal = FoundryGovernorWindow.calendar
        XCTAssertEqual(cal.component(.hour, from: next), 2)
    }

    // MARK: - Deep pass window math

    func testDeepPassWindowIsSunday2300Only() {
        // 2026-06-14 is a Sunday.
        XCTAssertTrue(FoundryGovernorWindow.isInDeepPassWindow(localDate(2026, 6, 14, 23, 0)))
        XCTAssertTrue(FoundryGovernorWindow.isInDeepPassWindow(localDate(2026, 6, 14, 23, 59)))
        XCTAssertFalse(FoundryGovernorWindow.isInDeepPassWindow(localDate(2026, 6, 14, 22, 59)))
        // Monday 23:30 is not the slot.
        XCTAssertFalse(FoundryGovernorWindow.isInDeepPassWindow(localDate(2026, 6, 15, 23, 30)))
    }

    func testNextDeepPassStartLandsOnSunday23() {
        let next = FoundryGovernorWindow.nextDeepPassStart(after: localDate(2026, 6, 8, 9, 0))
        let cal = FoundryGovernorWindow.calendar
        XCTAssertEqual(cal.component(.weekday, from: next), 1, "weekday 1 is Sunday")
        XCTAssertEqual(cal.component(.hour, from: next), 23)
        XCTAssertTrue(FoundryGovernorWindow.sameLocalDay(next, localDate(2026, 6, 14, 12, 0)))
    }

    // MARK: - Scheduling decision

    func testDecisionPicksNightlyInsideWindowOncePerDay() {
        let config = FoundryGovernorConfig()
        let at0300 = localDate(2026, 6, 15, 3, 0)
        XCTAssertEqual(FoundryGovernorDecision.nextPass(snapshot: snapshot(now: at0300), config: config), .nightlyLight)

        // Already ran tonight: no second nightly pass the same local day.
        let ranAt0205 = localDate(2026, 6, 15, 2, 5)
        XCTAssertNil(FoundryGovernorDecision.nextPass(
            snapshot: snapshot(now: at0300, lastNightly: ranAt0205), config: config
        ))
    }

    func testDecisionPicksDeepPassSunday23() {
        let config = FoundryGovernorConfig()
        let sunday2310 = localDate(2026, 6, 14, 23, 10)
        XCTAssertEqual(FoundryGovernorDecision.nextPass(snapshot: snapshot(now: sunday2310), config: config), .weeklyDeep)

        // Once per Sunday.
        XCTAssertNil(FoundryGovernorDecision.nextPass(
            snapshot: snapshot(now: localDate(2026, 6, 14, 23, 40), lastDeep: sunday2310), config: config
        ))
    }

    func testDecisionOpportunisticNeedsACAndIdle() {
        let config = FoundryGovernorConfig()
        let afternoon = localDate(2026, 6, 15, 14, 0)
        // 31 minutes idle on AC: go.
        XCTAssertEqual(FoundryGovernorDecision.nextPass(
            snapshot: snapshot(now: afternoon, idle: 31 * 60, ac: true), config: config
        ), .opportunistic)
        // On battery: no.
        XCTAssertNil(FoundryGovernorDecision.nextPass(
            snapshot: snapshot(now: afternoon, idle: 31 * 60, ac: false), config: config
        ))
        // Active user: no.
        XCTAssertNil(FoundryGovernorDecision.nextPass(
            snapshot: snapshot(now: afternoon, idle: 5 * 60, ac: true), config: config
        ))
    }

    func testDecisionOpportunisticHonorsSpacingCooldown() {
        let config = FoundryGovernorConfig()
        let afternoon = localDate(2026, 6, 15, 14, 0)
        // A pass ran 60s ago (one tick): blocked, even though the machine
        // is still idle on AC (the cycle generates no HID events).
        var snap = snapshot(now: afternoon, idle: 3600, ac: true)
        snap.lastOpportunisticAt = afternoon.addingTimeInterval(-60)
        XCTAssertNil(FoundryGovernorDecision.nextPass(snapshot: snap, config: config),
                     "no opportunistic re-fire inside the spacing window")
        // Inside the window by a wide margin: still blocked.
        snap.lastOpportunisticAt = afternoon.addingTimeInterval(-3 * 3600)
        XCTAssertNil(FoundryGovernorDecision.nextPass(snapshot: snap, config: config))
        // Past the spacing window: allowed again.
        snap.lastOpportunisticAt = afternoon.addingTimeInterval(-config.opportunisticSpacingHours * 3600)
        XCTAssertEqual(FoundryGovernorDecision.nextPass(snapshot: snap, config: config), .opportunistic)
        // Never ran before: allowed.
        snap.lastOpportunisticAt = nil
        XCTAssertEqual(FoundryGovernorDecision.nextPass(snapshot: snap, config: config), .opportunistic)
    }

    func testDecisionYieldsEntirelyOnSessionLimit() {
        let config = FoundryGovernorConfig()
        // Even in the middle of the nightly window with a perfect setup.
        XCTAssertNil(FoundryGovernorDecision.nextPass(
            snapshot: snapshot(now: localDate(2026, 6, 15, 3, 0), idle: 3600, limited: true), config: config
        ))
    }

    func testDecisionNeverDoubleBooks() {
        let config = FoundryGovernorConfig()
        XCTAssertNil(FoundryGovernorDecision.nextPass(
            snapshot: snapshot(now: localDate(2026, 6, 14, 23, 10), running: true), config: config
        ))
    }

    func testShouldYield() {
        XCTAssertTrue(FoundryGovernorDecision.shouldYield(pass: .nightlyLight, idleSeconds: 9999, sessionLimited: true))
        XCTAssertTrue(FoundryGovernorDecision.shouldYield(pass: .opportunistic, idleSeconds: 30, sessionLimited: false),
                      "opportunistic work stands down the moment the user is back")
        XCTAssertFalse(FoundryGovernorDecision.shouldYield(pass: .opportunistic, idleSeconds: 600, sessionLimited: false))
        XCTAssertFalse(FoundryGovernorDecision.shouldYield(pass: .nightlyLight, idleSeconds: 0, sessionLimited: false),
                       "the nightly window does not care about idle, only limits")
    }

    func testSessionLimitedPredicateOverAuthState() {
        var state = AuthState()
        state.accounts = [ClaudeAuthAccount(id: "org-1", label: "Main", email: nil, orgId: "org-1", addedAt: Date())]
        state.activeAccountId = "org-1"
        let now = localDate(2026, 6, 15, 12, 0)

        // No limit recorded: not limited.
        XCTAssertFalse(FoundryGovernorDecision.sessionLimited(state: state, now: now, cooldownHours: 6))

        // Hit one hour ago: limited.
        state.perAccount["org-1"] = PerAccountInfo(lastLimitHitAt: now.addingTimeInterval(-3600), estimatedResetAt: nil)
        XCTAssertTrue(FoundryGovernorDecision.sessionLimited(state: state, now: now, cooldownHours: 6))

        // Hit seven hours ago with a six hour cooldown: clear again.
        state.perAccount["org-1"] = PerAccountInfo(lastLimitHitAt: now.addingTimeInterval(-7 * 3600), estimatedResetAt: nil)
        XCTAssertFalse(FoundryGovernorDecision.sessionLimited(state: state, now: now, cooldownHours: 6))

        // Limit on a non-active account does not yield.
        state.perAccount["org-2"] = PerAccountInfo(lastLimitHitAt: now, estimatedResetAt: nil)
        XCTAssertFalse(FoundryGovernorDecision.sessionLimited(state: state, now: now, cooldownHours: 6))
    }

    // MARK: - Estimated cost accounting

    func testCostLabelsAlwaysCarryTheWordEstimated() {
        for usd in [0.0, 0.37, 2.0, 17.4, 123.0] {
            let label = FoundryCostMeter.label(usd: usd)
            XCTAssertTrue(label.contains("estimated"), "label \"\(label)\" must carry the word estimated")
            XCTAssertTrue(label.hasPrefix("$"), "dollar amounts render as $N, got \"\(label)\"")
        }
        let usageLabel = FoundryCostMeter.label(
            usage: FoundryTokenUsage(inputTokens: 1_000_000), modelID: "claude-haiku-4-5"
        )
        XCTAssertTrue(usageLabel.contains("estimated"))
    }

    func testEstimatedUSDMathAgainstRatesTable() {
        // 1M input tokens on Haiku at $1.00 / MTok. (This was $0.80 before the
        // canonical ModelRates consolidation corrected Haiku 4.5 to Anthropic's
        // published 1.00/5.00; FoundryCostMeter now delegates to that table.)
        let haiku = FoundryCostMeter.estimatedUSD(
            usage: FoundryTokenUsage(inputTokens: 1_000_000), modelID: "claude-haiku-4-5-20251001"
        )
        XCTAssertEqual(haiku, 1.00, accuracy: 0.0001)

        // 1M output tokens on Opus at $75 / MTok.
        let opus = FoundryCostMeter.estimatedUSD(
            usage: FoundryTokenUsage(outputTokens: 1_000_000), modelID: "claude-opus-4-7"
        )
        XCTAssertEqual(opus, 75.0, accuracy: 0.0001)

        // Sonnet cache read at $0.30 / MTok.
        let sonnet = FoundryCostMeter.estimatedUSD(
            usage: FoundryTokenUsage(cacheReadTokens: 2_000_000), modelID: "claude-sonnet-4-6"
        )
        XCTAssertEqual(sonnet, 0.60, accuracy: 0.0001)

        // Unknown model falls to the cheapest known tier (Haiku), never
        // inflating: now $1.00 / MTok input to match the corrected Haiku rate.
        let unknown = FoundryCostMeter.estimatedUSD(
            usage: FoundryTokenUsage(inputTokens: 1_000_000), modelID: "mystery-model"
        )
        XCTAssertEqual(unknown, 1.00, accuracy: 0.0001)
    }

    func testCycleBudgetHardTokenCap() {
        var budget = FoundryCycleBudget(pass: .nightlyLight, tokenCap: 1000)
        XCTAssertTrue(budget.record(FoundryTokenUsage(inputTokens: 400, outputTokens: 100), modelID: "claude-haiku-4-5"))
        XCTAssertFalse(budget.capExceeded)
        // This one crosses the cap: record returns false and the caller must stop.
        XCTAssertFalse(budget.record(FoundryTokenUsage(inputTokens: 600), modelID: "claude-haiku-4-5"))
        XCTAssertTrue(budget.capExceeded)
        XCTAssertEqual(budget.tokensUsed, 1100)
        XCTAssertTrue(budget.estimatedCostLabel.contains("estimated"))
    }

    // MARK: - Live governor seams

    @MainActor
    func testGovernorManualTriggerYieldsWhenSessionLimited() async {
        // Isolate from the shared crash-loop breaker so the yield we observe
        // is the session-limit yield, not a tripped auto-land pause.
        let breakerWasPaused = GruxUpdater.shared.isAutoLandPaused()
        GruxUpdater.shared.clearAutoLandPause()
        defer {
            if breakerWasPaused {
                GruxUpdater.shared.tripAutoLandPause(reason: "restored after FoundryGovernorTests")
            }
        }

        let gov = FoundryGovernor(stateURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-governor-test-\(UUID().uuidString).json"))
        gov.sessionLimited = { true }
        gov.runCycle = { _ in XCTFail("must not launch a cycle while session limited") }
        gov.triggerManual()
        guard case .yielded = gov.phase else {
            return XCTFail("expected yielded phase, got \(gov.phase)")
        }
    }

    @MainActor
    func testGovernorTickLaunchesNightlyAndStampsOncePerDay() async {
        // tick() consults the shared GruxUpdater crash-loop breaker before
        // scheduling. That breaker reads a file in the real app-support
        // directory, so if a prior real run (or another test) tripped it, the
        // governor yields and never launches a cycle, hanging this test on the
        // expectation. Clear it for the duration and restore it after so the
        // test is hermetic and does not mutate the machine's persistent state.
        let breakerWasPaused = GruxUpdater.shared.isAutoLandPaused()
        GruxUpdater.shared.clearAutoLandPause()
        defer {
            if breakerWasPaused {
                GruxUpdater.shared.tripAutoLandPause(reason: "restored after FoundryGovernorTests")
            }
        }

        let gov = FoundryGovernor(stateURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-governor-test-\(UUID().uuidString).json"))
        let fixedNow = localDate(2026, 6, 15, 3, 0)
        gov.now = { fixedNow }
        gov.idleSeconds = { 0 }
        gov.onACPower = { true }
        gov.sessionLimited = { false }

        let launched = expectation(description: "cycle launched")
        gov.runCycle = { pass in
            XCTAssertEqual(pass, .nightlyLight)
            launched.fulfill()
        }
        gov.tick()
        await fulfillment(of: [launched], timeout: 2)
        XCTAssertEqual(gov.lastNightlyAt, fixedNow)

        // A second tick in the same window does nothing (once per local day).
        gov.runCycle = { _ in XCTFail("nightly must not run twice in one night") }
        // Allow the first cycle's completion hop to settle back to idle.
        try? await Task.sleep(nanoseconds: 100_000_000)
        gov.tick()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
