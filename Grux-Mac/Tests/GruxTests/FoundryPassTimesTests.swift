import XCTest
@testable import Grux

// D4: the Self-Upgrade pane said whether self-upgrade was on and what it ran by itself,
// but never when a pass last ran or when the next one would, so a person could not tell
// a quiet schedule from a broken one. The second line says both, from the same window
// math the governor schedules with.
final class FoundryPassTimesTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    // 2026-06-15 is a Monday; 2026-06-14 and 2026-06-21 are Sundays.
    private func at(_ mo: Int, _ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: m))!
    }

    private func line(enabled: Bool = true, _ schedule: FoundrySchedule = FoundrySchedule(),
                      lastRanAt: Date? = nil, lastNightlyAt: Date? = nil, lastDeepAt: Date? = nil,
                      lastIdleAt: Date? = nil, paused: Bool = false, ticking: Bool = true,
                      running: Bool = false, limitClearsAt: Date? = nil, now: Date) -> String {
        FoundrySchedule.timesLine(enabled: enabled, schedule: schedule,
                                  lastRanAt: lastRanAt, lastNightlyAt: lastNightlyAt,
                                  lastDeepAt: lastDeepAt, lastOpportunisticAt: lastIdleAt,
                                  paused: paused, ticking: ticking, running: running,
                                  limitClearsAt: limitClearsAt, now: now, calendar: cal)
    }

    // MARK: - What the running governor will really do (wave 11 review, two P2)

    // Self-upgrade turned on in Settings or from the command line after launch never starts
    // the governor's tick (only launch and the pane's own button do), so a schedule switched
    // on then runs nothing until Grux relaunches. The line must not promise a time.
    func testASchedulerThatIsNotRunningPromisesNoTime() {
        for schedule in [FoundrySchedule(nightly: true), FoundrySchedule(weeklyDeep: true),
                         FoundrySchedule(whenIdle: true), FoundrySchedule(nightly: true, whenIdle: true)] {
            for now in [at(6, 15, 14), at(6, 15, 2, 0), at(6, 14, 23, 0)] {
                XCTAssertEqual(line(schedule, ticking: false, now: now),
                               "Last pass: none yet. Next: once Grux relaunches.")
            }
        }
        // Nothing scheduled: a pass you ask for needs no tick.
        XCTAssertEqual(line(ticking: false, now: at(6, 15, 14)), "Last pass: none yet. Next: when you ask.")
        // The crash-loop pause still wins.
        XCTAssertEqual(line(FoundrySchedule(nightly: true), paused: true, ticking: false, now: at(6, 15, 14)),
                       "Last pass: none yet. Next: none, self-upgrade paused itself after a crash loop.")
    }

    // A pass already running makes the governor skip every tick: nothing starts "within a minute".
    func testAPassRunningNowIsWhatIsNext() {
        for schedule in [FoundrySchedule(), FoundrySchedule(nightly: true), FoundrySchedule(whenIdle: true)] {
            XCTAssertEqual(line(schedule, running: true, now: at(6, 15, 2, 30)),
                           "Last pass: none yet. Next: after the pass running now.")
        }
    }

    // A session limit holds every scheduled pass until it clears (nextPass returns nil while
    // limited). On, one under and one over the clearing moment against the window edge.
    func testASessionLimitHoldsPassesUntilItClears() {
        let nightly = FoundrySchedule(nightly: true)
        // Clears inside the window, tonight not yet run: the pass is due as it clears.
        XCTAssertEqual(line(nightly, limitClearsAt: at(6, 15, 4), now: at(6, 15, 2, 30)),
                       "Last pass: none yet. Next: today at 4:00 AM. After a Claude session limit, Grux waits until today at 4:00 AM to run a pass.")
        // Clears one minute before the window ends: still tonight.
        XCTAssertEqual(line(nightly, limitClearsAt: at(6, 15, 5, 59), now: at(6, 15, 2, 30)),
                       "Last pass: none yet. Next: today at 5:59 AM. After a Claude session limit, Grux waits until today at 5:59 AM to run a pass.")
        // Clears exactly as the window closes: tomorrow.
        XCTAssertEqual(line(nightly, limitClearsAt: at(6, 15, 6, 0), now: at(6, 15, 2, 30)),
                       "Last pass: none yet. Next: tomorrow at 2:00 AM. After a Claude session limit, Grux waits until today at 6:00 AM to run a pass.")
        // Already cleared (on and before now): no hold.
        XCTAssertEqual(line(nightly, limitClearsAt: at(6, 15, 2, 30), now: at(6, 15, 2, 30)),
                       "Last pass: none yet. Next: within a minute.")
        XCTAssertEqual(line(nightly, limitClearsAt: at(6, 15, 1), now: at(6, 15, 2, 30)),
                       "Last pass: none yet. Next: within a minute.")
        // Idle only: idle passes wait for the limit too.
        XCTAssertEqual(line(FoundrySchedule(whenIdle: true), limitClearsAt: at(6, 15, 16), now: at(6, 15, 14)),
                       "Last pass: none yet. Next: when your Mac is idle on power, after 4:00 PM. After a Claude session limit, Grux waits until today at 4:00 PM to run a pass.")
        // Not ticking: the wait still holds after a relaunch, so the line keeps saying it.
        XCTAssertEqual(line(nightly, ticking: false, limitClearsAt: at(6, 15, 4), now: at(6, 15, 2, 30)),
                       "Last pass: none yet. Next: once Grux relaunches. After a Claude session limit, Grux waits until today at 4:00 AM to run a pass.")
        // The wait is Grux's own cooldown after the limit, not Claude's reset: it never names Claude's.
        XCTAssertFalse(line(nightly, limitClearsAt: at(6, 15, 4), now: at(6, 15, 2, 30)).contains("limit holds"))
        // Nothing scheduled: a manual pass is refused while limited too, but the line says only what is known.
        XCTAssertEqual(line(limitClearsAt: at(6, 15, 16), now: at(6, 15, 14)),
                       "Last pass: none yet. Next: when you ask. After a Claude session limit, Grux waits until today at 4:00 PM to run a pass.")
    }

    // MARK: - Last pass

    func testLastPassSaysNoneYetThenTheDayAndTime() {
        let now = at(6, 15, 14, 5)
        XCTAssertEqual(line(now: now), "Last pass: none yet. Next: when you ask.")
        XCTAssertEqual(line(lastRanAt: at(6, 15, 3, 48), now: now),
                       "Last pass: today at 3:48 AM. Next: when you ask.")
        XCTAssertEqual(line(lastRanAt: at(6, 14, 23, 59), now: now),
                       "Last pass: yesterday at 11:59 PM. Next: when you ask.")
        XCTAssertEqual(line(lastRanAt: at(6, 13, 9, 0), now: now),
                       "Last pass: Jun 13 at 9:00 AM. Next: when you ask.")
    }

    func testWithSelfUpgradeOffOnlyTheLastPassShows() {
        XCTAssertEqual(line(enabled: false, FoundrySchedule(nightly: true, weeklyDeep: true, whenIdle: true),
                            lastRanAt: at(6, 15, 3, 48), now: at(6, 15, 14)),
                       "Last pass: today at 3:48 AM.")
    }

    func testAPausedSelfUpgradeSaysNothingIsNext() {
        XCTAssertEqual(line(FoundrySchedule(nightly: true), paused: true, now: at(6, 15, 14)),
                       "Last pass: none yet. Next: none, self-upgrade paused itself after a crash loop.")
    }

    // MARK: - Nightly, on and around its window (2:00 to 6:00 AM)

    func testNightlyNextIsTheNextTwoAMOutsideTheWindow() {
        let nightly = FoundrySchedule(nightly: true)
        XCTAssertEqual(line(nightly, now: at(6, 15, 14)), "Last pass: none yet. Next: tomorrow at 2:00 AM.")
        XCTAssertEqual(line(nightly, now: at(6, 15, 1, 59)), "Last pass: none yet. Next: today at 2:00 AM.")
        XCTAssertEqual(line(nightly, now: at(6, 15, 6, 0)), "Last pass: none yet. Next: tomorrow at 2:00 AM.")
    }

    func testNightlyInsideTheWindowIsWithinAMinuteUnlessItRanToday() {
        let nightly = FoundrySchedule(nightly: true)
        XCTAssertEqual(line(nightly, now: at(6, 15, 2, 0)), "Last pass: none yet. Next: within a minute.")
        XCTAssertEqual(line(nightly, now: at(6, 15, 5, 59)), "Last pass: none yet. Next: within a minute.")
        // Ran last night: the governor runs one nightly pass per local day.
        XCTAssertEqual(line(nightly, lastRanAt: at(6, 15, 2, 0), lastNightlyAt: at(6, 15, 2, 0),
                            now: at(6, 15, 2, 30)),
                       "Last pass: today at 2:00 AM. Next: tomorrow at 2:00 AM.")
        // Ran yesterday: tonight is still owed.
        XCTAssertEqual(line(nightly, lastNightlyAt: at(6, 14, 2, 0), now: at(6, 15, 2, 30)),
                       "Last pass: none yet. Next: within a minute.")
    }

    // MARK: - Weekly (Sunday 11 PM) and the earliest of several

    func testWeeklyNextIsTheComingSunday() {
        let weekly = FoundrySchedule(weeklyDeep: true)
        XCTAssertEqual(line(weekly, now: at(6, 15, 14)), "Last pass: none yet. Next: Sunday at 11:00 PM.")
        XCTAssertEqual(line(weekly, now: at(6, 14, 22, 59)), "Last pass: none yet. Next: today at 11:00 PM.")
        XCTAssertEqual(line(weekly, now: at(6, 14, 23, 0)), "Last pass: none yet. Next: within a minute.")
        XCTAssertEqual(line(weekly, lastDeepAt: at(6, 14, 23, 0), now: at(6, 14, 23, 30)),
                       "Last pass: none yet. Next: Jun 21 at 11:00 PM.")
    }

    func testTheEarliestScheduledPassIsNext() {
        let both = FoundrySchedule(nightly: true, weeklyDeep: true)
        // Sunday 10 PM: the 11 PM deep pass comes before Monday's 2 AM.
        XCTAssertEqual(line(both, now: at(6, 14, 22)), "Last pass: none yet. Next: today at 11:00 PM.")
        // Monday 2 PM: Tuesday's 2 AM comes before Sunday.
        XCTAssertEqual(line(both, now: at(6, 15, 14)), "Last pass: none yet. Next: tomorrow at 2:00 AM.")
    }

    // MARK: - When idle on power (spacing 4 hours)

    func testIdleOnlyHasNoClockTimeUnlessItsSpacingIsPending() {
        let idle = FoundrySchedule(whenIdle: true)
        XCTAssertEqual(line(idle, now: at(6, 15, 14)),
                       "Last pass: none yet. Next: when your Mac is idle on power.")
        // Spacing: 4 hours after the last idle pass, on, one under, one over.
        XCTAssertEqual(line(idle, lastIdleAt: at(6, 15, 10, 1), now: at(6, 15, 14)),
                       "Last pass: none yet. Next: when your Mac is idle on power, after 2:01 PM.")
        XCTAssertEqual(line(idle, lastIdleAt: at(6, 15, 10), now: at(6, 15, 14)),
                       "Last pass: none yet. Next: when your Mac is idle on power.")
        XCTAssertEqual(line(idle, lastIdleAt: at(6, 15, 9, 59), now: at(6, 15, 14)),
                       "Last pass: none yet. Next: when your Mac is idle on power.")
    }

    func testIdleWithATimedPassSaysSoonerOnlyWhenItCanBeSooner() {
        let both = FoundrySchedule(nightly: true, whenIdle: true)
        XCTAssertEqual(line(both, now: at(6, 15, 14)),
                       "Last pass: none yet. Next: tomorrow at 2:00 AM, or sooner when your Mac is idle on power.")
        XCTAssertEqual(line(both, lastIdleAt: at(6, 15, 13), now: at(6, 15, 14)),
                       "Last pass: none yet. Next: tomorrow at 2:00 AM, or sooner when your Mac is idle on power after 5:00 PM.")
        // Idle spacing ends after the nightly start: idle cannot come sooner.
        XCTAssertEqual(line(both, lastIdleAt: at(6, 15, 23), now: at(6, 15, 23, 30)),
                       "Last pass: none yet. Next: tomorrow at 2:00 AM.")
        // A nightly pass due now leaves nothing sooner to mention.
        XCTAssertEqual(line(both, now: at(6, 15, 3)), "Last pass: none yet. Next: within a minute.")
    }
}
