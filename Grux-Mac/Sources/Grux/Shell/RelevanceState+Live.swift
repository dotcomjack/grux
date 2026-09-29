import Foundation
import GruxAgentCore

extension RelevanceState {
    /// The two inputs that cost a system call each: the calendar (a
    /// synchronous EventKit fetch) and the setup gaps (capability and keychain
    /// probes). The panel reads them on appear and on its 60 s timer (R5.10),
    /// never on every store change.
    struct SlowInputs {
        var agenda: [CalendarService.EventSummary] = []
        var setupGaps: [SetupGap] = []

        @MainActor
        static func live(now: Date = Date()) -> SlowInputs {
            var slow = SlowInputs()
            let calendar = CalendarService.shared
            if calendar.hasAccess {
                let windowEnd = Calendar.current.date(byAdding: .day, value: 3,
                                                      to: Calendar.current.startOfDay(for: now)) ?? now
                slow.agenda = calendar.events(from: now, to: windowEnd)
            }
            // `featuresNeedingSetup` already leaves out rows the person did not
            // pick: `FeatureRegistry.state(of:)` answers `.notChosen` for them.
            // `unmetBlocking(of:)` is what `missing(forTab:)` answers for a row.
            slow.setupGaps = FeatureRegistry.featuresNeedingSetup.compactMap { row in
                setupGap(for: row, missing: FeatureRegistry.unmetBlocking(of: row))
            }
            return slow
        }
    }

    /// This Mac, right now, from the stores Home already reads. The mapping
    /// mirrors `HomeBriefingModel.buildToday` so Now and the Today pane never
    /// disagree about what is next or what needs you.
    @MainActor
    static func live(now: Date = Date()) -> RelevanceState {
        live(now: now, slow: .live(now: now))
    }

    /// The same, with the slow inputs the caller already holds.
    @MainActor
    static func live(now: Date, slow: SlowInputs) -> RelevanceState {
        var s = RelevanceState()

        s.approvalsPending = ApprovalQueue.shared.pendingCount
        s.reviewsWaiting = WorkOrderStore.shared.orders
            .filter { $0.progress.stage.isReview }
            .map { WorkOrderReview(id: $0.id, request: $0.request) }

        let mail = TodayModel.mailThatNeedsYou(MailStore.shared.messages)
        s.mail = mail.items
        s.mailTotal = mail.total

        let jobs = jobRows(AgentService.shared.jobs)
        s.jobsRunning = jobs.running
        s.jobsWaitingOnYou = jobs.waiting

        s.workflowRunning = CommandV2Engine.shared.activeRuns.first { !$0.status.isTerminal }?.displayName

        s.next = next(now: now, agenda: slow.agenda)
        s.setupGaps = slow.setupGaps

        // One count for Now, the Improve door and the head badge: spec 5.4
        // binds the door to the badge's source, and 4.1 names no store.
        s.proposals = FoundryDashboardModel.shared.pendingCount
        s.hasBrand = !BrandRoster.brands.isEmpty
        s.claudeSignInExpired = ClaudeSignInState.shared.expired
        s.oldHookNeedsRemoval = TerminalFocusHookState.shared.needsManualRemoval
        return s
    }

    /// Unfinished agent jobs, split the way Home splits them: waiting or
    /// paused ones need the person, the rest are running. Each list is in
    /// start order; a job that has not started yet counts from its creation.
    static func jobRows(_ jobs: [AgentJob]) -> (running: [RunningJob], waiting: [RunningJob]) {
        let open = jobs.filter { !$0.isTerminal }
            .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        let needsYou: (AgentJob) -> Bool = { $0.status == .waiting || $0.status == .paused }
        let row = { (j: AgentJob) in RunningJob(id: j.id, title: j.title) }
        return (open.filter { !needsYou($0) }.map(row), open.filter(needsYou).map(row))
    }

    /// One registry row's gap, named by its first missing thing. Only rows
    /// reachable without a door suggest setup (spec 4.1): rail, Studio (under
    /// the Studio rail row), fold and brand scoped. The Developer and Labs
    /// doors contribute nothing (spec 4.2). Brand scoped straight from the
    /// registry's door.
    @MainActor
    static func setupGap(for row: FeatureRow, missing: [SetupRequirement]) -> SetupGap? {
        let door = row.disposition
        switch door {
        case .rail, .studio, .folds, .brandScoped: break
        case .developer, .labs, .ripped: return nil
        }
        guard let first = missing.first else { return nil }
        return SetupGap(featureId: row.id, label: row.label, missing: first.label,
                        brandScoped: door == .brandScoped)
    }

    /// Next, built exactly as `HomeBriefingModel.buildToday` builds it: the
    /// focused task, then Now and Next tasks, then open commitments, against
    /// the next three days of calendar (`agenda`, empty without access).
    @MainActor
    private static func next(now: Date, agenda: [CalendarService.EventSummary]) -> TodayModel.Next? {
        let app = AppState.shared
        let focused = app.currentTask
        let open = app.activeTasks.filter { $0.parentId == nil && $0.priority != .later }
        let ordered = (focused.map { [$0] } ?? [])
            + open.filter { $0.id != focused?.id && $0.priority == .now }
            + open.filter { $0.id != focused?.id && $0.priority == .next }
        var lines = ordered.map { TodayModel.TaskLine(id: $0.id, title: $0.title, dueAt: nil) }
        lines += GruxReminderState.shared.pendingScheduled
            .filter { $0.kind == .commitment || $0.kind == .info }
            .map { TodayModel.TaskLine(id: $0.id, title: $0.title, dueAt: $0.scheduledFor) }

        return TodayModel.next(tasks: lines, events: agenda, now: now)
    }
}
