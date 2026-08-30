import XCTest
@testable import Grux

// Tests for the user cron subsystem: pure next-fire-date math in
// CronSchedule plus UserCronStore CRUD against temp storage. The calendar
// and time zone are pinned so results don't drift with the test machine.
@MainActor
final class UserCronTests: XCTestCase {

    // Gregorian calendar pinned to one fixed zone so weekday math is stable.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    // Helper: build a concrete local date. June 8, 2026 is a Monday.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        return cal.date(from: comps)!
    }

    // MARK: - CronSchedule.nextFireDate

    func testSameDayLaterTimeFiresToday() {
        // Monday 8:00 AM, schedule is weekdays at 9:00 AM → fires Monday 9:00 AM.
        let ref = date(2026, 6, 8, 8, 0)
        let next = CronSchedule.nextFireDate(after: ref, weekdays: [2, 3, 4, 5, 6], hour: 9, minute: 0, calendar: cal)
        XCTAssertEqual(next, date(2026, 6, 8, 9, 0))
    }

    func testSameDayEarlierTimeRollsToNextAllowedDay() {
        // Monday 10:00 AM, schedule weekdays 9:00 AM → Tuesday 9:00 AM.
        let ref = date(2026, 6, 8, 10, 0)
        let next = CronSchedule.nextFireDate(after: ref, weekdays: [2, 3, 4, 5, 6], hour: 9, minute: 0, calendar: cal)
        XCTAssertEqual(next, date(2026, 6, 9, 9, 0))
    }

    func testFridayEveningRollsOverWeekendToMonday() {
        // Friday June 12 2026, 6:00 PM; weekdays-only 9:00 AM → Monday June 15.
        let ref = date(2026, 6, 12, 18, 0)
        let next = CronSchedule.nextFireDate(after: ref, weekdays: [2, 3, 4, 5, 6], hour: 9, minute: 0, calendar: cal)
        XCTAssertEqual(next, date(2026, 6, 15, 9, 0))
    }

    func testSingleWeekdaySchedule() {
        // Monday 8:00 AM, schedule only Sunday (1) at 7:30 PM → Sunday June 14.
        let ref = date(2026, 6, 8, 8, 0)
        let next = CronSchedule.nextFireDate(after: ref, weekdays: [1], hour: 19, minute: 30, calendar: cal)
        XCTAssertEqual(next, date(2026, 6, 14, 19, 30))
        XCTAssertEqual(cal.component(.weekday, from: next!), 1, "lands on Sunday")
    }

    func testExactBoundaryIsStrictlyAfter() {
        // Reference exactly at the scheduled instant → next occurrence, not now.
        let ref = date(2026, 6, 8, 9, 0, 0)
        let next = CronSchedule.nextFireDate(after: ref, weekdays: [2], hour: 9, minute: 0, calendar: cal)
        XCTAssertEqual(next, date(2026, 6, 15, 9, 0), "Monday-only schedule rolls a full week")
    }

    func testEveryDaySchedule() {
        // Saturday 11:59 PM → Sunday at 0:05 AM.
        let ref = date(2026, 6, 13, 23, 59)
        let next = CronSchedule.nextFireDate(after: ref, weekdays: Set(1...7), hour: 0, minute: 5, calendar: cal)
        XCTAssertEqual(next, date(2026, 6, 14, 0, 5))
    }

    func testInvalidInputsReturnNil() {
        let ref = date(2026, 6, 8, 8, 0)
        XCTAssertNil(CronSchedule.nextFireDate(after: ref, weekdays: [], hour: 9, minute: 0, calendar: cal), "no weekdays")
        XCTAssertNil(CronSchedule.nextFireDate(after: ref, weekdays: [2], hour: 24, minute: 0, calendar: cal), "hour out of range")
        XCTAssertNil(CronSchedule.nextFireDate(after: ref, weekdays: [2], hour: 9, minute: 60, calendar: cal), "minute out of range")
        XCTAssertNil(CronSchedule.nextFireDate(after: ref, weekdays: [0, 8], hour: 9, minute: 0, calendar: cal), "weekday out of range")
    }

    // MARK: - UserCronJob

    func testDisabledJobHasNoNextFire() {
        var job = UserCronJob(title: "Recap", action: .agentPrompt("recap my day"))
        job.enabled = false
        XCTAssertNil(job.nextFire(after: date(2026, 6, 8, 8, 0), calendar: cal))
        job.enabled = true
        XCTAssertNotNil(job.nextFire(after: date(2026, 6, 8, 8, 0), calendar: cal))
    }

    func testWeekdaysLabelPresets() {
        XCTAssertEqual(CronSchedule.weekdaysLabel([2, 3, 4, 5, 6]), "Weekdays")
        XCTAssertEqual(CronSchedule.weekdaysLabel(Set(1...7)), "Every day")
        XCTAssertEqual(CronSchedule.weekdaysLabel([1, 7]), "Weekends")
        XCTAssertEqual(CronSchedule.weekdaysLabel([2, 4, 6]), "Mon Wed Fri")
    }

    func testActionCodableRoundtrip() throws {
        let enc = JSONEncoder()
        let dec = JSONDecoder()

        let run = UserCronAction.runCommand(definitionId: "testflight-feedback")
        let runBack = try dec.decode(UserCronAction.self, from: enc.encode(run))
        XCTAssertEqual(run, runBack)

        let prompt = UserCronAction.agentPrompt("summarize my open PRs")
        let promptBack = try dec.decode(UserCronAction.self, from: enc.encode(prompt))
        XCTAssertEqual(prompt, promptBack)
    }

    // MARK: - UserCronStore

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-cron-test-\(UUID().uuidString).json")
    }

    func testStoreCRUDAndPersistence() {
        let url = tempURL()
        let store = UserCronStore(storageURL: url)
        XCTAssertTrue(store.jobs.isEmpty)

        let job = store.create(
            title: "Morning standup",
            weekdays: [2, 3, 4, 5, 6],
            hour: 9, minute: 15,
            action: .runCommand(definitionId: "smoke-hello-world")
        )
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(job.scheduleSummary, "Weekdays at 9:15 AM")

        var edited = job
        edited.hour = 17
        edited.minute = 0
        XCTAssertEqual(store.update(edited)?.hour, 17)

        _ = store.setEnabled(id: job.id, false)
        XCTAssertEqual(store.job(id: job.id)?.enabled, false)

        store.markFired(id: job.id)
        XCTAssertNotNil(store.job(id: job.id)?.lastFiredAt)

        // Reload from disk: everything persisted.
        let reloaded = UserCronStore(storageURL: url)
        XCTAssertEqual(reloaded.jobs.count, 1)
        XCTAssertEqual(reloaded.job(id: job.id)?.hour, 17)
        XCTAssertEqual(reloaded.job(id: job.id)?.enabled, false)
        XCTAssertNotNil(reloaded.job(id: job.id)?.lastFiredAt)

        store.delete(id: job.id)
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testFireAnchorAdvancesPastFiredOccurrence() {
        // Simulates the scheduler contract: after marking fired at `now`,
        // the next computed occurrence is in the future, never the same one.
        let firedAt = date(2026, 6, 8, 9, 0, 30) // fired 30s after the 9:00 slot
        let job = UserCronJob(
            title: "Daily",
            weekdays: Set(1...7),
            hour: 9, minute: 0,
            action: .agentPrompt("x"),
            lastFiredAt: firedAt
        )
        let next = job.nextFire(after: job.lastFiredAt!, calendar: cal)
        XCTAssertEqual(next, date(2026, 6, 9, 9, 0), "anchor moves to tomorrow")
    }
}
