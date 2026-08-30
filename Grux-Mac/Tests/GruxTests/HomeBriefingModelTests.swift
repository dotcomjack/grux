import XCTest
@testable import Grux
@testable import GruxAgentCore

// Home tab "Daily Launch" briefing assembly. Exercises the pure
// HomeBriefingBuilder fold against empty and populated value snapshots so it
// runs with no live EventKit, no singletons, and a pinned clock.
final class HomeBriefingModelTests: XCTestCase {

    // Pin a deterministic clock + a timezone-stable calendar so greeting /
    // time labels never flake on a CI box in another timezone.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    // 2026-06-10 09:30 local (Wednesday morning).
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func emptyInput(now: Date) -> HomeBriefingInput {
        HomeBriefingInput(
            now: now,
            agenda: [],
            calendarAuthorized: false,
            openCommitments: [],
            latestMeeting: nil,
            pendingProposals: [],
            liveJobs: [],
            latestRecap: nil,
            latestMorningBrief: nil
        )
    }

    private func event(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false
    ) -> CalendarService.EventSummary {
        CalendarService.EventSummary(
            id: id, title: title, start: start, end: end,
            isAllDay: isAllDay, location: nil, notes: nil,
            calendarName: "Cal", calendarId: "cal-1"
        )
    }

    private func job(id: String, status: AgentJob.Status, paused: AgentJob.PausedReason? = nil) -> AgentJob {
        AgentJob(id: id, title: id, goal: "g", status: status, rootDir: "/tmp", pausedReason: paused)
    }

    // MARK: - Greeting

    func testGreetingIsTimeAware() {
        let morning = at(2026, 6, 10, 9)
        let afternoon = at(2026, 6, 10, 14)
        let evening = at(2026, 6, 10, 19)
        let lateNight = at(2026, 6, 10, 23)

        let suffix = ", Priya"
        XCTAssertEqual(HomeBriefingBuilder.greeting(for: morning, calendar: calendar, nameSuffix: suffix), "Good morning, Priya")
        XCTAssertEqual(HomeBriefingBuilder.greeting(for: afternoon, calendar: calendar, nameSuffix: suffix), "Good afternoon, Priya")
        XCTAssertEqual(HomeBriefingBuilder.greeting(for: evening, calendar: calendar, nameSuffix: suffix), "Good evening, Priya")
        XCTAssertEqual(HomeBriefingBuilder.greeting(for: lateNight, calendar: calendar, nameSuffix: suffix), "Still up, Priya")
    }

    /// The case that actually ships to a stranger. A new install has no name,
    /// and the greeting has to read as a finished sentence rather than as a
    /// template that failed to fill: no trailing comma, no placeholder, and
    /// above all not somebody else's name.
    func testGreetingWithNoNameIsAFinishedSentence() {
        let morning = at(2026, 6, 10, 9)
        let lateNight = at(2026, 6, 10, 23)

        XCTAssertEqual(HomeBriefingBuilder.greeting(for: morning, calendar: calendar), "Good morning")
        XCTAssertEqual(HomeBriefingBuilder.greeting(for: lateNight, calendar: calendar), "Still up")

        // And the default flows through the whole fold, not just the helper.
        let b = HomeBriefingBuilder.build(emptyInput(now: morning), calendar: calendar)
        XCTAssertEqual(b.greeting, "Good morning")
        XCTAssertFalse(b.greeting.hasSuffix(","), "dangling comma from an unfilled name")
    }

    /// Guards the wiring, not the formatting. `build` reading `input.nameSuffix`
    /// is the link that makes a configured name reach the screen at all, and it
    /// is exactly the link a refactor drops silently: every other greeting test
    /// still passes when the fold ignores the field.
    func testBuildCarriesTheConfiguredNameIntoTheGreeting() {
        var input = emptyInput(now: at(2026, 6, 10, 9))
        input.nameSuffix = ", Priya"
        XCTAssertEqual(HomeBriefingBuilder.build(input, calendar: calendar).greeting, "Good morning, Priya")
    }

    // MARK: - Empty snapshot

    func testEmptyInputProducesNoSignal() {
        let now = at(2026, 6, 10, 9, 30)
        let b = HomeBriefingBuilder.build(emptyInput(now: now), calendar: calendar)

        XCTAssertFalse(b.hasAnySignal)
        XCTAssertTrue(b.agenda.isEmpty)
        XCTAssertTrue(b.commitments.isEmpty)
        XCTAssertNil(b.meeting)
        XCTAssertEqual(b.proposalsCount, 0)
        XCTAssertEqual(b.jobsRunning, 0)
        XCTAssertEqual(b.jobsPaused, 0)
        XCTAssertNil(b.resumableJobId)
        XCTAssertNil(b.recapPreview)
        // Unauthorized calendar gets the connect-copy.
        XCTAssertTrue(b.agendaEmptyCopy.contains("Connect"))
    }

    func testEmptyAuthorizedCalendarGetsNothingScheduledCopy() {
        let now = at(2026, 6, 10, 9, 30)
        var input = emptyInput(now: now)
        input.calendarAuthorized = true
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertTrue(b.agendaEmptyCopy.contains("Nothing"))
    }

    // MARK: - Time zone

    /// The formatters must honour the calendar they are handed, not the machine.
    ///
    /// This is asserted directly rather than left to the surrounding tests,
    /// because those only disagree with the code when the PROCESS time zone
    /// differs from the pinned one. On the author's machine, in Eastern, they
    /// agreed and the suite was green for as long as the bug existed. It took a
    /// UTC CI runner to produce labels four hours out.
    ///
    /// Formatting one instant in two fixed zones and requiring a DIFFERENT answer
    /// cannot pass by coincidence: it fails both if the zone is ignored (the two
    /// results become identical) and if it is applied wrongly.
    func testFormattersHonourTheCalendarTimeZoneNotTheMachine() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        // 2026-06-10 12:00 UTC, which is 21:00 the same day in Tokyo.
        let instant = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12))!

        XCTAssertEqual(HomeBriefingBuilder.clockLabel(instant, calendar: utc), "12:00 PM")
        XCTAssertEqual(HomeBriefingBuilder.clockLabel(instant, calendar: tokyo), "9:00 PM")
        XCTAssertNotEqual(HomeBriefingBuilder.clockLabel(instant, calendar: utc),
                          HomeBriefingBuilder.clockLabel(instant, calendar: tokyo),
                          "clockLabel ignored the calendar it was given")

        // 2026-06-10 22:00 UTC is already the 11th in Tokyo, so the weekday and
        // the date line must both move. A zone-blind formatter returns the same
        // weekday for both and this fails.
        let late = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 22))!
        XCTAssertEqual(HomeBriefingBuilder.weekdayLabel(late, calendar: utc), "Wed")
        XCTAssertEqual(HomeBriefingBuilder.weekdayLabel(late, calendar: tokyo), "Thu")
        XCTAssertEqual(HomeBriefingBuilder.dateLine(for: late, calendar: utc), "Wednesday, June 10")
        XCTAssertEqual(HomeBriefingBuilder.dateLine(for: late, calendar: tokyo), "Thursday, June 11")

        // dueLabel composes clockLabel, so it has to carry the zone through too.
        XCTAssertEqual(HomeBriefingBuilder.dueLabel(for: instant, now: instant, calendar: utc),
                       "due 12:00 PM")
        XCTAssertEqual(HomeBriefingBuilder.dueLabel(for: instant, now: instant, calendar: tokyo),
                       "due 9:00 PM")
    }

    // MARK: - Agenda

    func testAgendaLabelsTodayAsClockAndFutureWithWeekday() {
        let now = at(2026, 6, 10, 9, 30)   // Wednesday
        var input = emptyInput(now: now)
        input.calendarAuthorized = true
        input.agenda = [
            event(id: "today", title: "Standup",
                  start: at(2026, 6, 10, 10), end: at(2026, 6, 10, 10, 30)),
            event(id: "tomorrow", title: "Design review",
                  start: at(2026, 6, 11, 14), end: at(2026, 6, 11, 15)),
            event(id: "allday", title: "Offsite",
                  start: at(2026, 6, 12, 0), end: at(2026, 6, 13, 0), isAllDay: true)
        ]
        let b = HomeBriefingBuilder.build(input, calendar: calendar)

        XCTAssertEqual(b.agenda.count, 3)
        XCTAssertTrue(b.agenda[0].isToday)
        XCTAssertEqual(b.agenda[0].timeLabel, "10:00 AM")          // today -> bare clock
        XCTAssertFalse(b.agenda[1].isToday)
        XCTAssertTrue(b.agenda[1].timeLabel.contains("Thu"))       // future -> weekday prefix
        XCTAssertTrue(b.agenda[1].timeLabel.contains("2:00 PM"))
        XCTAssertTrue(b.agenda[2].isAllDay)
        XCTAssertTrue(b.agenda[2].timeLabel.contains("Fri"))       // future all-day -> weekday
        XCTAssertTrue(b.hasAnySignal)
    }

    func testAgendaIsCappedAtMax() {
        let now = at(2026, 6, 10, 9, 30)
        var input = emptyInput(now: now)
        input.calendarAuthorized = true
        input.agenda = (0..<20).map { i in
            event(id: "e\(i)", title: "Event \(i)",
                  start: at(2026, 6, 10, 10).addingTimeInterval(Double(i) * 600),
                  end: at(2026, 6, 10, 11))
        }
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.agenda.count, HomeBriefingBuilder.maxAgenda)
    }

    func testUntitledEventGetsPlaceholder() {
        let now = at(2026, 6, 10, 9, 30)
        var input = emptyInput(now: now)
        input.calendarAuthorized = true
        input.agenda = [event(id: "x", title: "",
                              start: at(2026, 6, 10, 10), end: at(2026, 6, 10, 11))]
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.agenda.first?.title, "(untitled)")
    }

    // MARK: - Commitments

    func testCommitmentsMapDueLabels() {
        let now = at(2026, 6, 10, 9, 30)
        var input = emptyInput(now: now)
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        input.openCommitments = [
            .init(id: id1, title: "Ship auth", dueAt: at(2026, 6, 10, 15)),   // today
            .init(id: id2, title: "Call vendor", dueAt: at(2026, 6, 12, 11)), // future
            .init(id: id3, title: "Someday thing", dueAt: nil)                // no due
        ]
        let b = HomeBriefingBuilder.build(input, calendar: calendar)

        XCTAssertEqual(b.commitments.count, 3)
        XCTAssertEqual(b.commitments[0].dueLabel, "due 3:00 PM")
        XCTAssertTrue(b.commitments[1].dueLabel?.contains("due") == true)
        XCTAssertNil(b.commitments[2].dueLabel)
        XCTAssertTrue(b.hasAnySignal)
    }

    func testCommitmentsCappedAtMax() {
        let now = at(2026, 6, 10, 9, 30)
        var input = emptyInput(now: now)
        input.openCommitments = (0..<10).map {
            .init(id: UUID(), title: "c\($0)", dueAt: nil)
        }
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.commitments.count, HomeBriefingBuilder.maxCommitments)
    }

    // MARK: - Meeting

    func testMeetingItemBuildsWithRelativeWhen() {
        let now = at(2026, 6, 10, 12)
        var input = emptyInput(now: now)
        input.latestMeeting = .init(
            id: UUID(),
            title: "Q3 sync",
            endedAt: at(2026, 6, 10, 10),     // 2h before now
            excerpt: "Decided to ship Friday."
        )
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.meeting?.title, "Q3 sync")
        XCTAssertEqual(b.meeting?.whenLabel, "2h ago")
        XCTAssertEqual(b.meeting?.excerpt, "Decided to ship Friday.")
        XCTAssertTrue(b.hasAnySignal)
    }

    func testMeetingWithBlankTitleGetsPlaceholder() {
        let now = at(2026, 6, 10, 12)
        var input = emptyInput(now: now)
        input.latestMeeting = .init(id: UUID(), title: "", endedAt: at(2026, 6, 10, 11, 59), excerpt: "")
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.meeting?.title, "Untitled meeting")
        XCTAssertEqual(b.meeting?.whenLabel, "just now")
        XCTAssertNil(b.meeting?.excerpt)   // empty excerpt collapses to nil
    }

    // MARK: - Proposals

    func testProposalsCountAndTop() {
        let now = at(2026, 6, 10, 9)
        var input = emptyInput(now: now)
        input.pendingProposals = [
            .init(id: UUID(), title: "Cache chat latency", estCostLabel: "$2 estimated"),
            .init(id: UUID(), title: "Trim cold start", estCostLabel: "$1 estimated")
        ]
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.proposalsCount, 2)
        XCTAssertEqual(b.topProposal?.title, "Cache chat latency")   // ranked best-first by caller
        XCTAssertEqual(b.topProposal?.costLabel, "$2 estimated")
    }

    // MARK: - Jobs

    func testJobsSplitRunningVsPausedAndExposeResumable() {
        let now = at(2026, 6, 10, 9)
        var input = emptyInput(now: now)
        input.liveJobs = [
            job(id: "running", status: .running),
            job(id: "queued", status: .queued),
            job(id: "parked", status: .waiting, paused: .authLimitHit),
            job(id: "approval", status: .waiting, paused: .awaitingApproval),
            job(id: "manual", status: .paused, paused: .manualPause)
        ]
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.jobsRunning, 2)   // running + queued
        XCTAssertEqual(b.jobsPaused, 3)    // 2 waiting + 1 paused
        // Resume affordance targets the auth-limit-parked job specifically.
        XCTAssertEqual(b.resumableJobId, "parked")
    }

    func testNoResumableWhenNoAuthLimitJob() {
        let now = at(2026, 6, 10, 9)
        var input = emptyInput(now: now)
        input.liveJobs = [job(id: "approval", status: .waiting, paused: .awaitingApproval)]
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.jobsPaused, 1)
        XCTAssertNil(b.resumableJobId)
    }

    // MARK: - Recap

    func testRecapPreviewTruncatesAtWordBoundary() throws {
        let now = at(2026, 6, 10, 22)
        var input = emptyInput(now: now)
        let long = String(repeating: "word ", count: 80)   // > 160 chars
        input.latestRecap = .init(date: now, narrative: long)
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        let preview = try XCTUnwrap(b.recapPreview)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(preview.count, HomeBriefingBuilder.recapPreviewChars + 1)
        XCTAssertFalse(preview.contains("  "))   // clean word boundary, no dangling fragment
    }

    func testShortRecapIsNotTruncated() {
        let now = at(2026, 6, 10, 22)
        var input = emptyInput(now: now)
        input.latestRecap = .init(date: now, narrative: "Shipped the Home tab.")
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.recapPreview, "Shipped the Home tab.")
    }

    func testBlankRecapCollapsesToNil() {
        let now = at(2026, 6, 10, 22)
        var input = emptyInput(now: now)
        input.latestRecap = .init(date: now, narrative: "   \n  ")
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertNil(b.recapPreview)
    }

    // MARK: - Relative label

    func testRelativeLabelBuckets() {
        let now = at(2026, 6, 10, 12)
        XCTAssertEqual(HomeBriefingBuilder.relativeLabel(from: now.addingTimeInterval(-30), to: now), "just now")
        XCTAssertEqual(HomeBriefingBuilder.relativeLabel(from: now.addingTimeInterval(-300), to: now), "5m ago")
        XCTAssertEqual(HomeBriefingBuilder.relativeLabel(from: now.addingTimeInterval(-7200), to: now), "2h ago")
        XCTAssertEqual(HomeBriefingBuilder.relativeLabel(from: now.addingTimeInterval(-172800), to: now), "2d ago")
    }

    // MARK: - Time-aware primary action

    func testPrimaryActionIsTimeAware() {
        let morning = at(2026, 6, 10, 9)
        let afternoon = at(2026, 6, 10, 14)
        let evening = at(2026, 6, 10, 19)
        let lateNight = at(2026, 6, 10, 23)

        let m = HomeBriefingBuilder.primaryAction(for: morning, calendar: calendar)
        XCTAssertEqual(m.mode, .morning)
        XCTAssertEqual(m.label, "Start my day")
        XCTAssertEqual(m.icon, "sun.max.fill")

        let a = HomeBriefingBuilder.primaryAction(for: afternoon, calendar: calendar)
        XCTAssertEqual(a.mode, .morning)
        XCTAssertEqual(a.label, "Start my day")

        let e = HomeBriefingBuilder.primaryAction(for: evening, calendar: calendar)
        XCTAssertEqual(e.mode, .evening)
        XCTAssertEqual(e.label, "Wrap up the day")
        XCTAssertEqual(e.icon, "moon.stars")

        let n = HomeBriefingBuilder.primaryAction(for: lateNight, calendar: calendar)
        XCTAssertEqual(n.mode, .evening)
        XCTAssertEqual(n.label, "Wrap up the day")
    }

    func testPrimaryActionBoundaryAt17() {
        // 16:59 still morning, 17:00 flips to evening.
        let justBefore = at(2026, 6, 10, 16, 59)
        let atSeventeen = at(2026, 6, 10, 17, 0)
        XCTAssertEqual(HomeBriefingBuilder.primaryAction(for: justBefore, calendar: calendar).mode, .morning)
        XCTAssertEqual(HomeBriefingBuilder.primaryAction(for: atSeventeen, calendar: calendar).mode, .evening)
    }

    func testBuildExposesTimeAwareActionInBriefing() {
        let morningBuild = HomeBriefingBuilder.build(emptyInput(now: at(2026, 6, 10, 9)), calendar: calendar)
        XCTAssertEqual(morningBuild.primaryAction.mode, .morning)

        let eveningBuild = HomeBriefingBuilder.build(emptyInput(now: at(2026, 6, 10, 20)), calendar: calendar)
        XCTAssertEqual(eveningBuild.primaryAction.mode, .evening)
    }

    // MARK: - Morning brief preview

    func testMorningBriefPreviewTruncatesAtWordBoundary() throws {
        let now = at(2026, 6, 10, 9)
        var input = emptyInput(now: now)
        let long = String(repeating: "word ", count: 80)   // > 160 chars
        input.latestMorningBrief = .init(date: now, narrative: long)
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        let preview = try XCTUnwrap(b.todayBriefPreview)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(preview.count, HomeBriefingBuilder.recapPreviewChars + 1)
        XCTAssertFalse(preview.contains("  "))
        // A fresh brief alone flips Home out of the all-quiet state.
        XCTAssertTrue(b.hasAnySignal)
    }

    func testShortMorningBriefIsNotTruncated() {
        let now = at(2026, 6, 10, 9)
        var input = emptyInput(now: now)
        input.latestMorningBrief = .init(date: now, narrative: "First up: ship the Home tab.")
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertEqual(b.todayBriefPreview, "First up: ship the Home tab.")
        XCTAssertTrue(b.hasAnySignal)
    }

    func testBlankMorningBriefCollapsesToNil() {
        let now = at(2026, 6, 10, 9)
        var input = emptyInput(now: now)
        input.latestMorningBrief = .init(date: now, narrative: "   \n  ")
        let b = HomeBriefingBuilder.build(input, calendar: calendar)
        XCTAssertNil(b.todayBriefPreview)
        XCTAssertFalse(b.hasAnySignal)
    }

    // MARK: - Morning brief offline narrative

    func testMorningBriefDefaultNarrativeCleanSlate() {
        let n = MorningBriefScheduler.defaultNarrative(
            agenda: [], tasks: [], commitments: [], parked: [], proposalCount: 0
        )
        XCTAssertTrue(n.contains("Clean slate"))
        assertNoDashes(n)
    }

    func testMorningBriefDefaultNarrativePopulated() {
        let n = MorningBriefScheduler.defaultNarrative(
            agenda: ["9:00 AM Standup"],
            tasks: ["Ship auth · Northwind"],
            commitments: ["Call vendor"],
            parked: ["build worker"],
            proposalCount: 2
        )
        // Leads with the top task, names the proposal count, stays forward.
        XCTAssertTrue(n.hasPrefix("First up: Ship auth · Northwind."))
        XCTAssertTrue(n.contains("2 proposals waiting on you."))
        XCTAssertTrue(n.hasSuffix("Let's get after it."))
        assertNoDashes(n)
    }

    // House rule: zero em dashes and zero en dashes anywhere.
    private func assertNoDashes(_ s: String) {
        XCTAssertFalse(s.contains("\u{2014}"), "em dash found in: \(s)")
        XCTAssertFalse(s.contains("\u{2013}"), "en dash found in: \(s)")
    }
}
