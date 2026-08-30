import Foundation
import Combine
import GruxAgentCore

// Home tab "Daily Launch" briefing model.
//
// The Home tab is a READ-ONLY composite of state that already lives in the
// app's stores: today + next-two-days calendar agenda, open commitments,
// the most recent meeting, pending Foundry proposals, active/paused agent
// jobs, and the latest daily recap. Nothing here mutates a store; it only
// reads public snapshots.
//
// Architecture mirrors ActivityStripModel: all the assembly logic is a pure
// fold (`HomeBriefingBuilder`) over an injectable value snapshot
// (`HomeBriefingInput`). The pure layer unit-tests with empty/populated
// fixtures and never touches EventKit, the singletons, or the clock except
// through injected values. `HomeBriefingModel` is the thin live wrapper that
// fills the snapshot from the real singletons on the main actor.

// MARK: - Injectable input snapshot

// Everything the briefing needs, as plain value types. Built from the live
// singletons by `HomeBriefingModel.assembleInput()`, or hand-built in tests.
struct HomeBriefingInput {
    var now: Date
    // The whole ", Name" tail of the greeting, not the bare name, so an unset
    // name renders "Good morning" and not "Good morning, " with a dangling
    // comma. Passed in rather than read from config because this builder is a
    // pure fold with no singletons, which is what makes it testable.
    var nameSuffix: String = ""
    // Calendar agenda window: today + the next two days (already filtered to
    // [now, +3 days) by the caller). Sorted ascending by start.
    var agenda: [CalendarService.EventSummary]
    // Whether calendar permission is granted. Drives the agenda empty-state
    // copy ("connect" vs "nothing scheduled").
    var calendarAuthorized: Bool
    // Open commitments / pending reminders: scheduled, not yet fired, not
    // dismissed. (GruxReminderState.pendingScheduled, mapped to values.)
    var openCommitments: [CommitmentLine]
    // Most recent finalized meeting, if any.
    var latestMeeting: MeetingLine?
    // Pending (non-terminal, non-landed) Foundry proposals, ranked best-first.
    var pendingProposals: [ProposalLine]
    // Live agent jobs: anything non-terminal (running / queued / waiting /
    // paused), newest-first.
    var liveJobs: [AgentJob]
    // Latest daily-recap narrative, if one has fired.
    var latestRecap: RecapLine?
    // Latest forward morning-brief narrative, if one has fired. Reuses
    // RecapLine since it is just {date, narrative}.
    var latestMorningBrief: RecapLine?

    struct CommitmentLine: Equatable, Identifiable {
        var id: UUID
        var title: String
        var dueAt: Date?
    }

    struct MeetingLine: Equatable, Identifiable {
        var id: UUID
        var title: String
        var endedAt: Date?
        var excerpt: String?
    }

    struct ProposalLine: Equatable, Identifiable {
        var id: UUID
        var title: String
        var estCostLabel: String
    }

    struct RecapLine: Equatable {
        var date: Date
        var narrative: String
    }
}

// MARK: - View-model output (rendered by HomeView)

// The folded briefing the cards render. Each card has its own value so the
// view stays declarative and the fold stays unit-testable.
struct HomeBriefing: Equatable {
    var greeting: String          // "Good morning, Priya" or "Good morning"
    var dateLine: String          // "Wednesday, June 11"
    var agenda: [AgendaItem]
    var agendaEmptyCopy: String   // shown when agenda is empty
    var commitments: [CommitmentItem]
    var meeting: MeetingItem?
    var proposalsCount: Int
    var topProposal: ProposalItem?
    var jobsRunning: Int
    var jobsPaused: Int
    var resumableJobId: String?   // first paused-for-auth job, for the resume affordance
    var recapPreview: String?     // first ~140 chars of the latest recap narrative
    var todayBriefPreview: String?  // first ~140 chars of the latest morning brief
    // Time-aware primary action (label / icon / help / busy label / mode),
    // computed from the local hour so the big Home button reads forward in the
    // morning and points at the recap in the evening.
    var primaryAction: HomeBriefingBuilder.PrimaryAction

    struct AgendaItem: Equatable, Identifiable {
        var id: String
        var title: String
        var timeLabel: String     // "9:30 AM" or "All day" or "Tue 2:00 PM"
        var isAllDay: Bool
        var isToday: Bool
    }

    struct CommitmentItem: Equatable, Identifiable {
        var id: UUID
        var title: String
        var dueLabel: String?     // "due 3:00 PM" / "due Fri" / nil
    }

    struct MeetingItem: Equatable {
        var title: String
        var whenLabel: String     // "2h ago" relative
        var excerpt: String?
    }

    struct ProposalItem: Equatable {
        var title: String
        var costLabel: String
    }

    // A briefing with zero signal still renders the hero + greeting; the
    // card stack collapses to the "all quiet" state.
    var hasAnySignal: Bool {
        !agenda.isEmpty || !commitments.isEmpty || meeting != nil
            || proposalsCount > 0 || jobsRunning > 0 || jobsPaused > 0
            || recapPreview != nil || todayBriefPreview != nil
    }
}

// MARK: - Pure fold (unit tested, no singletons, no EventKit)

enum HomeBriefingBuilder {

    // Agenda is capped so a busy week doesn't blow out the card.
    static let maxAgenda = 6
    static let maxCommitments = 5
    static let recapPreviewChars = 160

    static func build(_ input: HomeBriefingInput, calendar: Calendar = .current) -> HomeBriefing {
        HomeBriefing(
            greeting: greeting(for: input.now, calendar: calendar, nameSuffix: input.nameSuffix),
            dateLine: dateLine(for: input.now, calendar: calendar),
            agenda: agendaItems(input, calendar: calendar),
            agendaEmptyCopy: input.calendarAuthorized
                ? "Nothing on the calendar through the next two days."
                : "Connect a calendar to see your agenda here.",
            commitments: commitmentItems(input, calendar: calendar),
            meeting: meetingItem(input),
            proposalsCount: input.pendingProposals.count,
            topProposal: input.pendingProposals.first.map {
                HomeBriefing.ProposalItem(title: $0.title, costLabel: $0.estCostLabel)
            },
            jobsRunning: input.liveJobs.filter { $0.status == .running || $0.status == .queued }.count,
            jobsPaused: input.liveJobs.filter { $0.status == .waiting || $0.status == .paused }.count,
            resumableJobId: input.liveJobs.first {
                $0.status == .waiting && $0.pausedReason == .authLimitHit
            }?.id,
            recapPreview: recapPreview(input),
            todayBriefPreview: morningBriefPreview(input),
            primaryAction: primaryAction(for: input.now, calendar: calendar)
        )
    }

    // MARK: Greeting

    // Time-aware greeting keyed off the local hour. Calendar is injectable so
    // the test can pin a timezone-stable hour without touching the device.
    /// `nameSuffix` is the whole ", Name" tail rather than the bare name, so an
    /// unset name renders "Good morning" instead of "Good morning, " with a
    /// dangling comma. Injectable for the same reason `calendar` is: the test
    /// pins it rather than reading whatever the running app happens to hold.
    static func greeting(for date: Date,
                         calendar: Calendar = .current,
                         nameSuffix: String = "") -> String {
        let hour = calendar.component(.hour, from: date)
        let part: String
        switch hour {
        case 5..<12:  part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default:      part = "Still up"   // 22:00 to 04:59
        }
        return part + nameSuffix
    }

    // Every formatter here takes the SAME calendar the date arithmetic uses.
    //
    // Without this, `build(input, calendar: x)` did its comparisons in x and its
    // formatting in the system zone, so one function answered "is this today"
    // and "what time is it" in two different time zones. That agrees only where
    // the two zones agree, which is the author's machine. On a UTC CI runner the
    // labels came out exactly four hours off and two tests failed that had never
    // failed locally.
    static func dateLine(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    // MARK: Time-aware primary action

    // The big Home button is dynamic by time of day. Daytime (before 17:00)
    // gives a forward morning brief; evening / night (17:00 onward) runs the
    // backward-looking recap, which is correct THEN. The 17:00 boundary lines
    // up with the greeting buckets (afternoon ends at 17, evening starts at
    // 17), keeping the button consistent with the greeting.
    struct PrimaryAction: Equatable {
        enum Mode: Equatable { case morning, evening }
        var mode: Mode
        var label: String       // "Start my day" / "Wrap up the day"
        var busyLabel: String   // "Starting your day…" / "Wrapping up…"
        var icon: String        // "sun.max.fill" / "moon.stars"
        var help: String
    }

    static func primaryAction(for date: Date, calendar: Calendar = .current) -> PrimaryAction {
        let hour = calendar.component(.hour, from: date)
        if hour < 17 {
            return PrimaryAction(
                mode: .morning,
                label: "Start my day",
                busyLabel: "Starting your day…",
                icon: "sun.max.fill",
                help: "Refresh your agenda and pull a forward brief: today's highlights, top tasks, and anything parked overnight"
            )
        }
        return PrimaryAction(
            mode: .evening,
            label: "Wrap up the day",
            busyLabel: "Wrapping up…",
            icon: "moon.stars",
            help: "Run today's recap: what you shipped, open commitments, and tomorrow's top three"
        )
    }

    // MARK: Agenda

    static func agendaItems(_ input: HomeBriefingInput, calendar: Calendar) -> [HomeBriefing.AgendaItem] {
        let today = calendar.startOfDay(for: input.now)
        return input.agenda.prefix(maxAgenda).map { ev in
            let isToday = calendar.isDate(ev.start, inSameDayAs: today)
            return HomeBriefing.AgendaItem(
                id: ev.id,
                title: ev.title.isEmpty ? "(untitled)" : ev.title,
                timeLabel: agendaTimeLabel(ev, isToday: isToday, calendar: calendar),
                isAllDay: ev.isAllDay,
                isToday: isToday
            )
        }
    }

    static func agendaTimeLabel(
        _ ev: CalendarService.EventSummary,
        isToday: Bool,
        calendar: Calendar
    ) -> String {
        if ev.isAllDay {
            return isToday ? "All day" : weekdayLabel(ev.start, calendar: calendar)
        }
        let time = clockLabel(ev.start, calendar: calendar)
        return isToday ? time : "\(weekdayLabel(ev.start, calendar: calendar)) \(time)"
    }

    // MARK: Commitments

    static func commitmentItems(_ input: HomeBriefingInput,
                                calendar: Calendar = .current) -> [HomeBriefing.CommitmentItem] {
        input.openCommitments.prefix(maxCommitments).map { c in
            HomeBriefing.CommitmentItem(
                id: c.id,
                title: c.title,
                dueLabel: c.dueAt.map { dueLabel(for: $0, now: input.now, calendar: calendar) }
            )
        }
    }

    static func dueLabel(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "due \(clockLabel(date, calendar: calendar))"
        }
        return "due \(weekdayLabel(date, calendar: calendar))"
    }

    // MARK: Meeting

    static func meetingItem(_ input: HomeBriefingInput) -> HomeBriefing.MeetingItem? {
        guard let m = input.latestMeeting else { return nil }
        let when = m.endedAt.map { relativeLabel(from: $0, to: input.now) } ?? "recent"
        let title = m.title.isEmpty ? "Untitled meeting" : m.title
        return HomeBriefing.MeetingItem(
            title: title,
            whenLabel: when,
            excerpt: m.excerpt?.isEmpty == false ? m.excerpt : nil
        )
    }

    // MARK: Recap

    static func recapPreview(_ input: HomeBriefingInput) -> String? {
        guard let recap = input.latestRecap else { return nil }
        let trimmed = recap.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= recapPreviewChars { return trimmed }
        let cut = trimmed.prefix(recapPreviewChars)
        // Trim back to the last word boundary so the ellipsis lands cleanly.
        if let lastSpace = cut.lastIndex(of: " ") {
            return cut[..<lastSpace] + "…"
        }
        return cut + "…"
    }

    // Forward counterpart to recapPreview: same word-boundary trim against the
    // latest morning brief.
    static func morningBriefPreview(_ input: HomeBriefingInput) -> String? {
        guard let brief = input.latestMorningBrief else { return nil }
        let trimmed = brief.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= recapPreviewChars { return trimmed }
        let cut = trimmed.prefix(recapPreviewChars)
        if let lastSpace = cut.lastIndex(of: " ") {
            return cut[..<lastSpace] + "…"
        }
        return cut + "…"
    }

    // MARK: Shared formatters

    static func clockLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    static func weekdayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    // Coarse relative label ("just now" / "2h ago" / "3d ago"). Kept simple
    // and deterministic so the meeting card stays test-stable.
    static func relativeLabel(from past: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(past))
        if seconds < 90 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h ago" }
        let days = Int(seconds / 86_400)
        return "\(days)d ago"
    }
}

// MARK: - Live model

@MainActor
final class HomeBriefingModel: ObservableObject {

    @Published private(set) var briefing: HomeBriefing

    // Test seam for the clock; the live model uses the wall clock.
    var now: () -> Date = { Date() }

    private var cancellables = Set<AnyCancellable>()

    // Live clock: re-folds once a minute so the greeting, date line, relative
    // "Xm ago" labels, and the time-aware primary action stay honest while
    // Home sits open across hour / day boundaries. Cheap by design: it skips
    // the EventKit agenda read on the tick.
    private var clockTimer: Timer?

    init(autoObserve: Bool = true) {
        // Seed with an empty snapshot so the view has something to render on
        // the first frame, before refresh() runs.
        self.briefing = HomeBriefingBuilder.build(
            HomeBriefingInput(
                now: Date(),
                nameSuffix: UserIdentity.greetingSuffix(),
                agenda: [],
                calendarAuthorized: false,
                openCommitments: [],
                latestMeeting: nil,
                pendingProposals: [],
                liveJobs: [],
                latestRecap: nil,
                latestMorningBrief: nil
            )
        )
        guard autoObserve else { return }
        // Re-fold when any live store publishes. These are cheap reads, so a
        // straight refresh on every change is fine; agenda (EventKit) only
        // refreshes on explicit refresh() to avoid a synchronous store hit on
        // every reminder mutation.
        GruxReminderState.shared.$reminders
            .sink { [weak self] _ in self?.refresh(includeAgenda: false) }
            .store(in: &cancellables)
        ProposalStore.shared.$proposals
            .sink { [weak self] _ in self?.refresh(includeAgenda: false) }
            .store(in: &cancellables)
        AgentService.shared.$jobs
            .sink { [weak self] _ in self?.refresh(includeAgenda: false) }
            .store(in: &cancellables)

        // Per-minute live tick. weak self + a MainActor hop breaks the retain
        // cycle (self is MainActor-isolated; the timer fires on the run loop).
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(includeAgenda: false) }
        }
    }

    deinit {
        // Timer.invalidate() is thread-safe to call from the nonisolated deinit.
        clockTimer?.invalidate()
    }

    // Full assembly from the live singletons. `includeAgenda` gates the
    // EventKit read (synchronous), so store-publish refreshes can skip it.
    func refresh(includeAgenda: Bool = true) {
        let nowDate = now()

        let calService = CalendarService.shared
        let authorized = calService.hasAccess
        let agenda: [CalendarService.EventSummary]
        if includeAgenda && authorized {
            let windowEnd = Calendar.current.date(byAdding: .day, value: 3,
                                                  to: Calendar.current.startOfDay(for: nowDate)) ?? nowDate
            agenda = calService.events(from: nowDate, to: windowEnd)
        } else {
            // Preserve the last agenda we fetched on an agenda-skipping refresh.
            agenda = lastAgenda
        }
        lastAgenda = agenda

        let commitments = GruxReminderState.shared.pendingScheduled
            .filter { $0.kind == .commitment || $0.kind == .info }
            .map { r in
                HomeBriefingInput.CommitmentLine(id: r.id, title: r.title, dueAt: r.scheduledFor)
            }

        let latestMeeting = MeetingStore.shared.list(limit: 1).first.map { entry in
            HomeBriefingInput.MeetingLine(
                id: entry.id,
                title: entry.title ?? "",
                endedAt: entry.endedAt,
                excerpt: entry.summaryExcerpt
            )
        }

        let proposals = ProposalStore.shared.ranked().map { p in
            HomeBriefingInput.ProposalLine(id: p.id, title: p.title, estCostLabel: p.estCostLabel)
        }

        let jobs = AgentService.shared.jobs.filter { !$0.isTerminal }

        let recap = GruxReminderState.shared.reminders
            .first { $0.kind == .dailyRecap && $0.firedAt != nil }
            .map { HomeBriefingInput.RecapLine(date: $0.firedAt ?? $0.createdAt, narrative: $0.body) }

        // Only TODAY's brief feeds the forward "Today" card: a morning brief
        // is a same-day artifact, so yesterday's must not linger after midnight.
        let morningBrief = GruxReminderState.shared.reminders
            .first {
                $0.kind == .morningBrief && $0.firedAt != nil
                    && Calendar.current.isDate($0.firedAt!, inSameDayAs: nowDate)
            }
            .map { HomeBriefingInput.RecapLine(date: $0.firedAt ?? $0.createdAt, narrative: $0.body) }

        let input = HomeBriefingInput(
            now: nowDate,
            nameSuffix: UserIdentity.greetingSuffix(),
            agenda: agenda,
            calendarAuthorized: authorized,
            openCommitments: commitments,
            latestMeeting: latestMeeting,
            pendingProposals: proposals,
            liveJobs: jobs,
            latestRecap: recap,
            latestMorningBrief: morningBrief
        )
        briefing = HomeBriefingBuilder.build(input)
    }

    private var lastAgenda: [CalendarService.EventSummary] = []
}
