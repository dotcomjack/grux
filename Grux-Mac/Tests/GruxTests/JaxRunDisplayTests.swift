import XCTest
@testable import Grux

// D98: Jax Command's Goal pursuit added the same "No action worth taking this
// cycle" card, badged SIMULATED, every cycle, and SIMULATED never said what it
// meant. An idle stretch is one card that counts its cycles; a cycle with no
// plan has no badge (nothing was simulated); a plan's badge says what happened
// to it in words.
final class JaxRunDisplayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ minutesAgo: Double, goal: String = "2 items already waiting in the Jax HQ approval queue",
                     domain: String = "ops", mode: AutonomyMode = .simulate,
                     action: PlannedSwarmAction? = nil, executed: Bool = false) -> GoalPursuitRun {
        GoalPursuitRun(date: t0.addingTimeInterval(-minutesAgo * 60), mode: mode.rawValue, domain: domain,
                       chosenGoal: goal, rationale: "Answer it in Approvals.", action: action, executed: executed)
    }

    private var newYork: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private let plan = PlannedSwarmAction(title: "Fix the build", goal: "Make the build green",
                                          template: "fix", budgetUSD: 2)

    func testRepeatedIdleCyclesOnTheSameGoalAreOneCard() {
        let runs = [run(2), run(120), run(360)]
        let entries = JaxRunDisplay.entries(runs)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].run.id, runs[0].id, "the card is the newest cycle")
        XCTAssertEqual(entries[0].repeats, 3)
        XCTAssertEqual(entries[0].firstDate, runs[2].date)
        XCTAssertEqual(JaxRunDisplay.noActionLine(entries[0], now: t0, calendar: newYork),
                       "No action worth taking, 3 cycles in a row (the first at 9:00 PM yesterday).")
    }

    // D116 item 3: two idle cards on Jax Command read "5 cycles in a row (the
    // first 1 day ago)" above "8 cycles in a row (the first 1 day ago)", so the
    // newer streak seemed to start when the older one did. The real store on
    // the Mini, read Nov 1 at 3:00 PM: the newer streak began 12:08 AM Oct 31,
    // the older one 4:11 PM Oct 30. Each card names its first cycle's clock
    // time and day, so two streaks never read alike.
    func test_twoStreaksNameTheirOwnFirstCycle() {
        let now = at("2026-11-01T20:00:00Z")
        let newer = (0..<5).map { i -> GoalPursuitRun in
            var r = run(0); r.date = at("2026-11-01T04:05:50Z").addingTimeInterval(-Double(i) * 3600)
            return r
        }
        var newerFirst = run(0); newerFirst.date = at("2026-10-31T04:08:50Z")
        let older = (0..<8).map { i -> GoalPursuitRun in
            var r = run(0, goal: "1 item already waiting in the Jax HQ approval queue")
            r.date = at("2026-10-30T23:15:15Z").addingTimeInterval(-Double(i) * 600)
            return r
        }
        var olderFirst = older[7]; olderFirst.date = at("2026-10-30T20:11:06Z")
        let runs = Array(newer.prefix(4)) + [newerFirst] + Array(older.prefix(7)) + [olderFirst]
        let entries = JaxRunDisplay.entries(runs)
        XCTAssertEqual(entries.map(\.repeats), [5, 8])
        XCTAssertEqual(JaxRunDisplay.noActionLine(entries[0], now: now, calendar: newYork),
                       "No action worth taking, 5 cycles in a row (the first at 12:08 AM yesterday).")
        XCTAssertEqual(JaxRunDisplay.noActionLine(entries[1], now: now, calendar: newYork),
                       "No action worth taking, 8 cycles in a row (the first at 4:11 PM Oct 30).")
    }

    // W32-P3 item 4: the clock time followed en_US_POSIX "h:mm a" whatever
    // the person's clock was set to. A 24-hour Mac reads 24-hour times.
    func test_aStreakReadsTheClockThisMacUses() {
        let now = at("2026-11-01T20:00:00Z")
        var first = run(0); first.date = at("2026-10-30T20:11:06Z")
        var second = run(0); second.date = at("2026-10-30T20:21:06Z")
        let entry = JaxRunDisplay.entries([second, first])[0]
        for id in ["en_GB", "en_US@hours=h23", "de_DE"] {
            var calendar = newYork
            calendar.locale = Locale(identifier: id)
            XCTAssertEqual(JaxRunDisplay.noActionLine(entry, now: now, calendar: calendar),
                           "No action worth taking, 2 cycles in a row (the first at 16:11 Oct 30).", id)
        }
        var earlyToday = run(0); earlyToday.date = at("2026-11-01T04:08:50Z")
        var calendar = newYork
        calendar.locale = Locale(identifier: "en_GB")
        XCTAssertEqual(JaxTime.clockAndDay(earlyToday.date, now: now, calendar: calendar), "00:08 today")
        XCTAssertEqual(JaxTime.clockAndDay(first.date, now: now, calendar: newYork), "4:11 PM Oct 30")
    }

    func test_aStreakThatBeganTodayOrLongAgoSaysSo() {
        let now = at("2026-11-01T20:00:00Z")
        var a = run(0); a.date = at("2026-11-01T13:30:00Z")
        var b = run(0); b.date = at("2026-11-01T03:00:00Z")
        let today = JaxRunDisplay.entries([a, b])
        XCTAssertEqual(JaxRunDisplay.noActionLine(today[0], now: now, calendar: newYork),
                       "No action worth taking, 2 cycles in a row (the first at 11:00 PM yesterday).")
        var c = run(0); c.date = at("2026-11-01T19:00:00Z")
        var d = run(0); d.date = at("2026-11-01T14:45:00Z")
        XCTAssertEqual(JaxRunDisplay.noActionLine(JaxRunDisplay.entries([c, d])[0], now: now, calendar: newYork),
                       "No action worth taking, 2 cycles in a row (the first at 9:45 AM today).")
        var e = run(0); e.date = at("2026-09-02T12:00:00Z")
        XCTAssertEqual(JaxRunDisplay.noActionLine(JaxRunDisplay.entries([c, e])[0], now: now, calendar: newYork),
                       "No action worth taking, 2 cycles in a row (the first at 8:00 AM Sep 2).")
        var f = run(0); f.date = at("2025-12-30T12:00:00Z")
        XCTAssertEqual(JaxRunDisplay.noActionLine(JaxRunDisplay.entries([c, f])[0], now: now, calendar: newYork),
                       "No action worth taking, 2 cycles in a row (the first at 7:00 AM Dec 30, 2025).")
    }

    func testOneIdleCycleKeepsTodaysLine() {
        let entries = JaxRunDisplay.entries([run(2)])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].repeats, 1)
        XCTAssertEqual(JaxRunDisplay.noActionLine(entries[0], now: t0, calendar: newYork),
                       "No action worth taking this cycle.")
    }

    func testIdleCyclesOnDifferentGoalsOrDomainsOrSplitByAPlanStaySeparate() {
        let runs = [run(1), run(2, goal: "Ship the README fix"), run(3, goal: "Ship the README fix", domain: "comms"),
                    run(4, action: plan), run(5), run(6)]
        let entries = JaxRunDisplay.entries(runs)
        XCTAssertEqual(entries.map(\.repeats), [1, 1, 1, 1, 2])
        XCTAssertEqual(entries.last?.firstDate, runs[5].date)
    }

    func testPlannedRunsNeverCollapseEvenWhenAlike() {
        let entries = JaxRunDisplay.entries([run(1, action: plan), run(2, action: plan)])
        XCTAssertEqual(entries.map(\.repeats), [1, 1])
    }

    func testTheLimitCountsCardsNotCycles() {
        // 20 idle cycles then 9 different goals: the idle stretch is one card
        // and the limit of 8 still shows 8 cards.
        var runs = (0..<20).map { run(Double($0)) }
        runs += (0..<9).map { run(Double(100 + $0), goal: "Goal \($0)") }
        let entries = JaxRunDisplay.entries(runs, limit: 8)
        XCTAssertEqual(entries.count, 8)
        XCTAssertEqual(entries[0].repeats, 20)
        XCTAssertEqual(entries[7].run.chosenGoal, "Goal 6")
    }

    func testANoActionCycleHasNoBadge() {
        for mode in AutonomyMode.allCases {
            XCTAssertNil(JaxRunDisplay.status(run(1, mode: mode)), "\(mode): nothing was planned, so nothing was simulated")
        }
    }

    func testEachPlanBadgeSaysWhatHappenedToIt() {
        XCTAssertEqual(JaxRunDisplay.status(run(1, mode: .simulate, action: plan)),
                       .init(label: "SIMULATED",
                             explanation: "Planned only. Nothing ran, because Autonomy was set to Simulate."))
        for mode in [AutonomyMode.observe, .live] {
            XCTAssertEqual(JaxRunDisplay.status(run(1, mode: mode, action: plan)),
                           .init(label: "SENT TO APPROVALS",
                                 explanation: "Nothing ran from here. It runs only if you say yes in Approvals."),
                           "\(mode)")
        }
        XCTAssertEqual(JaxRunDisplay.status(run(1, mode: .live, action: plan, executed: true)),
                       .init(label: "DISPATCHED", explanation: nil))
    }

    // Wave 27 round 1: a run stored before plans were capped can hold any
    // finite budget a model returned; the card drew it with
    // `Int(budget * 100)`, which traps at 9.2e16 and up.
    func test_aStoredRunsBudgetDrawsWhateverItHolds() {
        XCTAssertEqual(JaxRunDisplay.budget(5), "$5")
        XCTAssertEqual(JaxRunDisplay.budget(2.5), "$2.50")
        XCTAssertEqual(JaxRunDisplay.budget(25), "$25")
        for huge in [9.3e16, 1e17, 1e300, Double.greatestFiniteMagnitude] {
            XCTAssertFalse(JaxRunDisplay.budget(huge).isEmpty, "\(huge)")
        }
    }

    func test_theWorthQuestionWritesAnyBudget() {
        XCTAssertEqual(AgentWorthJudgment.dollars(5), "$5")
        XCTAssertEqual(AgentWorthJudgment.dollars(2.5), "$2.50")
        for huge in [9.3e18, 1e19, 1e300, Double.greatestFiniteMagnitude] {
            XCTAssertTrue(AgentWorthJudgment.dollars(huge).hasPrefix("$"), "\(huge)")
        }
    }
}
