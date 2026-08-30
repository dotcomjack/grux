import Foundation

// Forward-looking morning brief. The sunrise counterpart to DailyRecap.
//
// Fired by the Home "Start my day" button (daytime only). Unlike the recap,
// this does NOT take over the screen with a glass panel; it surfaces as a
// "Today" card on the Home tab and (optionally) speaks itself aloud. It is
// button-fired only, with no auto-schedule timer (contrast: DailyRecap and
// EnergyRecap are time-triggered). A future morning-hour auto-fire is
// deliberately deferred and out of scope here.
//
// Assembled from the SAME live stores HomeBriefingModel reads:
//   - Today's calendar agenda (CalendarService)
//   - Top NOW / NEXT tasks (AppState)
//   - Open commitments (GruxReminderState)
//   - Agent jobs parked overnight (AgentService, waiting / paused)
//   - Pending Foundry proposal count (ProposalStore)
// plus a Claude-generated forward narrative, with an offline fallback.

struct MorningBriefData: Codable, Hashable {
    var date: Date
    var narrative: String           // Claude-generated, 40-70 words, forward-looking
    var agendaHighlights: [String]  // today's calendar titles with times
    var topTasks: [String]          // NOW then NEXT, prefix 3
    var openCommitments: [String]   // pending commitment / info reminder titles
    var parkedJobs: [String]        // paused / waiting agent jobs carried overnight
    var pendingProposalCount: Int   // Foundry proposals awaiting review
}

@MainActor
final class MorningBriefScheduler {
    static let shared = MorningBriefScheduler()

    // No UserDefaults day-key seed: the brief is manual-only (button-fired),
    // so there is no double-fire window to dedupe against.
    private init() {}

    // Manually trigger from Home's "Start my day" button. Mirrors
    // DailyRecapScheduler.fireRecapNow().
    func fireBriefNow() async {
        await fireBrief()
    }

    private func fireBrief() async {
        WakeLog.shared.log("morningBrief: generating…")
        let data = await generateData()
        // Deliberately NO full-screen takeover. The recap presents
        // DailyRecapPanelController (a "good night" takeover); the morning
        // brief instead surfaces as a Home "Today" card and stays out of the
        // way. Do not "fix" this by adding a panel present call.
        if AppState.shared.config.speakRepliesAloud {
            SpeechEngine.shared.speakAfterCurrent(data.narrative, maxWaitSeconds: 60)
        }
        // Record into reminder history pre-stamped as fired (mirrors
        // EnergyRecapScheduler) so it does not pollute pendingScheduled and so
        // HomeBriefingModel can pick the latest fired .morningBrief. We insert
        // directly instead of calling GruxReminderState.fire() so no toast
        // panel pops; the brief lives on the Home card only.
        let reminder = GruxReminder(
            kind: .morningBrief,
            title: "Morning Brief",
            body: data.narrative,
            scheduledFor: nil,
            firedAt: Date()
        )
        GruxReminderState.shared.reminders.insert(reminder, at: 0)
        GruxReminderState.shared.save()
    }

    // MARK: - Data assembly

    private func generateData() async -> MorningBriefData {
        let state = AppState.shared
        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? now

        // Today's agenda from now through end of day. Map "clock title".
        var agendaHighlights: [String] = []
        if CalendarService.shared.hasAccess {
            agendaHighlights = CalendarService.shared.events(from: now, to: endOfDay)
                .filter { cal.isDate($0.start, inSameDayAs: now) }
                .prefix(4)
                .map { ev in
                    let title = ev.title.isEmpty ? "(untitled)" : ev.title
                    if ev.isAllDay { return "All day \(title)" }
                    return "\(Self.clockLabel(ev.start)) \(title)"
                }
        }

        // Top NOW then NEXT tasks, formatted "title · project".
        let nows = state.activeTasks.filter { $0.priority == .now }
        let nexts = state.activeTasks.filter { $0.priority == .next }
        let topTasks: [String] = (nows + nexts).prefix(3).map { t in
            t.project.isEmpty ? t.title : "\(t.title) · \(t.project)"
        }

        // Open commitments (mirror HomeBriefingModel's kind filter).
        let openCommitments: [String] = GruxReminderState.shared.pendingScheduled
            .filter { $0.kind == .commitment || $0.kind == .info }
            .prefix(6)
            .map(\.title)

        // Jobs parked overnight: non-terminal, waiting or paused.
        let parkedJobs: [String] = AgentService.shared.jobs
            .filter { !$0.isTerminal && ($0.status == .waiting || $0.status == .paused) }
            .prefix(4)
            .map(\.title)

        let pendingProposalCount = ProposalStore.shared.ranked().count

        let narrative = await composeNarrative(
            agenda: agendaHighlights,
            tasks: topTasks,
            commitments: openCommitments,
            parked: parkedJobs,
            proposalCount: pendingProposalCount
        )
        return MorningBriefData(
            date: now,
            narrative: narrative,
            agendaHighlights: agendaHighlights,
            topTasks: topTasks,
            openCommitments: openCommitments,
            parkedJobs: parkedJobs,
            pendingProposalCount: pendingProposalCount
        )
    }

    private func composeNarrative(
        agenda: [String],
        tasks: [String],
        commitments: [String],
        parked: [String],
        proposalCount: Int
    ) async -> String {
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so a local-only or custom-endpoint user was
        // skipped here forever while the Chat tab worked. Resolved ONCE per
        // run, on the main actor, never inside a loop.

        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else {
            return Self.defaultNarrative(
                agenda: agenda, tasks: tasks, commitments: commitments,
                parked: parked, proposalCount: proposalCount
            )
        }

        let sys = """
        You are Grux helping the user START their day. Write ONE short forward-looking paragraph (40 to 70 words) that: names today's agenda highlights, points at the top one or two tasks to hit now and next, carries any open commitments forward, flags anything parked overnight (paused agent jobs) and the count of pending Foundry proposals waiting on them. Warm, direct, encouraging, like a friend kicking off the day. Forward, not retrospective. No emoji, no markdown, no bullet lists. Plain spoken prose, this will be read aloud.
        """

        let user = """
        TODAY_DATE: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short))

        AGENDA_TODAY (calendar, time order):
        \(agenda.isEmpty ? "(nothing scheduled today)" : agenda.map { "- \($0)" }.joined(separator: "\n"))

        TOP_TASKS (NOW then NEXT, priority order):
        \(tasks.isEmpty ? "(stack is light)" : tasks.map { "- \($0)" }.joined(separator: "\n"))

        OPEN_COMMITMENTS (carry these forward):
        \(commitments.isEmpty ? "(none tracked)" : commitments.map { "- \($0)" }.joined(separator: "\n"))

        PARKED_OVERNIGHT (agent jobs waiting or paused):
        \(parked.isEmpty ? "(none parked)" : parked.map { "- \($0)" }.joined(separator: "\n"))

        PENDING_PROPOSALS: \(proposalCount)

        Your one-paragraph forward brief (40 to 70 words, spoken-aloud friendly):
        """
        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 200,
                temperature: 0.55,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete",
                feature: "morningBrief"
            )
            let cleaned = reply
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            if cleaned.isEmpty {
                return Self.defaultNarrative(agenda: agenda, tasks: tasks, commitments: commitments, parked: parked, proposalCount: proposalCount)
            }
            // Fact-grounding vet: if the spoken narrative drifted a product fact
            // (the $18 class, spoken aloud), drop to the deterministic brief.
            let verdict = await MainActor.run { GroundingGate.vet(draft: cleaned, brief: user) }
            if !verdict.surfaceable {
                WakeLog.shared.log("morningBrief: grounding vet blocked a drifted fact; using deterministic fallback")
                return Self.defaultNarrative(agenda: agenda, tasks: tasks, commitments: commitments, parked: parked, proposalCount: proposalCount)
            }
            return cleaned
        } catch {
            WakeLog.shared.log("morningBrief narrative FAILED: \(error.localizedDescription)")
            return Self.defaultNarrative(
                agenda: agenda, tasks: tasks, commitments: commitments,
                parked: parked, proposalCount: proposalCount
            )
        }
    }

    // Offline fallback so the brief always has a forward narrative even without
    // network. Static + pure (nonisolated) so it unit-tests without booting the
    // singleton graph or the main actor.
    nonisolated static func defaultNarrative(
        agenda: [String],
        tasks: [String],
        commitments: [String],
        parked: [String],
        proposalCount: Int
    ) -> String {
        if agenda.isEmpty && tasks.isEmpty && commitments.isEmpty && parked.isEmpty && proposalCount == 0 {
            return "Morning, boss. Clean slate, nothing scheduled and nothing parked. Pick the thing that matters most and let's move."
        }
        var parts: [String] = []
        if let first = tasks.first {
            parts.append("First up: \(first).")
        }
        if !agenda.isEmpty {
            parts.append("You've got \(agenda.count) thing\(agenda.count == 1 ? "" : "s") on the calendar today.")
        }
        if !commitments.isEmpty {
            parts.append("Carrying \(commitments.count) open commitment\(commitments.count == 1 ? "" : "s").")
        }
        if proposalCount > 0 {
            parts.append("\(proposalCount) proposal\(proposalCount == 1 ? "" : "s") waiting on you.")
        }
        if !parked.isEmpty {
            parts.append("\(parked.count) job\(parked.count == 1 ? "" : "s") parked overnight to resume.")
        }
        return parts.joined(separator: " ") + " Let's get after it."
    }

    // MARK: - Shared formatters

    static func clockLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
