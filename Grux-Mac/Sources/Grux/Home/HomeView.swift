import SwiftUI

// The Home tab. The most beautiful surface in the app and the default tab on
// cold boot. A full-bleed aurora hero with the orb + greeting, then a tight
// "Daily Launch" briefing card stack assembled READ-ONLY from the live
// stores, a prominent time-aware primary action ("Start my day" in the
// morning, "Wrap up the day" in the evening), and a row of secondary quick
// actions.
//
// Every action routes through an EXISTING seam (AppState.requestedTab,
// FoundryEngine, MorningBriefScheduler, DailyRecapScheduler, AgentService,
// openWindow). Home never
// duplicates a store's logic; it only reads snapshots and fires the same
// entry points the rest of the app uses.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = HomeBriefingModel()
    @StateObject private var briefingEngine = BriefingEngine.shared
    @Environment(\.openWindow) private var openWindow

    @State private var startingDay = false

    private var b: HomeBriefing { model.briefing }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HomeHeroView(greeting: b.greeting, dateLine: b.dateLine)

                VStack(spacing: GruxSpacing.l) {
                    startMyDayButton
                    quickActions

                    if briefingEngine.latest != nil {
                        jaxBriefingCard
                    }

                    if b.hasAnySignal {
                        briefingStack
                    } else {
                        allQuietCard
                    }
                }
                .padding(.horizontal, GruxSpacing.xl)
                .padding(.bottom, GruxSpacing.xl)
                // Pull the card stack up so it overlaps the hero's faded base,
                // making hero and briefing read as one continuous surface.
                .padding(.top, GruxSpacing.s)
                // Cap the CARD STACK only. The hero above stays full bleed,
                // because a hero image is supposed to run edge to edge; the
                // stack under it is not. At a 2400pt window "Wrap up the day"
                // rendered as a single button roughly 2200pt wide, with the four
                // quick actions stretched to match. Inert at the 840pt floor.
                .frame(maxWidth: GruxLayout.contentMax)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GruxTheme.base)
        .onAppear {
            model.refresh()
            // Keep the spoken briefing live: if the shown one is stale or from an
            // earlier part of the day, silently regenerate it time-framed for now.
            Task { await briefingEngine.refreshIfStale() }
        }
    }

    // MARK: - Primary action

    private var startMyDayButton: some View {
        Button(action: startMyDay) {
            HStack(spacing: GruxSpacing.s) {
                Image(systemName: startingDay ? "sparkles" : b.primaryAction.icon)
                    .font(.system(size: 14, weight: .bold))
                Text(startingDay ? b.primaryAction.busyLabel : b.primaryAction.label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(GruxTheme.iridescent))
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
            .shadow(color: GruxTheme.violetGlow(strong: true), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(startingDay)
        .help(b.primaryAction.help)
    }

    // The genuinely-useful sequence, all through existing seams. The action is
    // time-aware (see HomeBriefingBuilder.primaryAction):
    //   Morning (before 17:00): refresh the agenda, fire the forward morning
    //   brief (MorningBriefScheduler), refresh again. Forward, not a recap.
    //   Evening (17:00 onward): run the daily recap (DailyRecapScheduler),
    //   which is the correct backward wrap-up at that hour.
    // The resume affordance stays visible afterward if a job is parked.
    private func startMyDay() {
        // Snapshot the mode at press time so it stays fixed across the await.
        let mode = b.primaryAction.mode
        startingDay = true
        model.refresh()
        Task {
            switch mode {
            case .morning: await MorningBriefScheduler.shared.fireBriefNow()
            case .evening: await DailyRecapScheduler.shared.fireRecapNow()
            }
            await MainActor.run {
                model.refresh()
                startingDay = false
            }
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: GruxSpacing.s) {
            QuickActionPill(title: "New chat", icon: "plus.bubble") {
                _ = state.newThread()
                state.requestedTab = "chat"
            }
            QuickActionPill(title: "Deep research", icon: "magnifyingglass") {
                state.requestedTab = "research"
            }
            QuickActionPill(title: "Upgrade yourself", icon: "wand.and.stars") {
                _ = FoundryEngine.shared.triggerManualCycle()
                state.requestedTab = "selfUpgrade"
            }
            QuickActionPill(title: "Pair phone", icon: "iphone") {
                openWindow(id: "pair-iphone")
            }
        }
    }

    // MARK: - Briefing card stack

    // Jax voice-first briefing: the latest morning / night briefing Jax spoke in
    // the user's voice clone, with a one-tap "brief me" to speak a fresh one now.
    @ViewBuilder
    private var jaxBriefingCard: some View {
        if let brief = briefingEngine.latest {
            BriefingCard(
                title: brief.displayTitle,
                icon: "sparkle",
                accent: GruxTheme.accentPrimaryLight
            ) {
                VStack(alignment: .leading, spacing: GruxSpacing.s) {
                    if !brief.spokenText.isEmpty {
                        Text(brief.spokenText)
                            .font(GruxType.body)
                            .foregroundStyle(GruxTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(brief.items) { item in
                        HStack(spacing: GruxSpacing.s) {
                            Image(systemName: item.kind.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(GruxTheme.accentPrimaryLight)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(GruxType.caption)
                                    .foregroundStyle(GruxTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(GruxType.caption)
                                        .foregroundStyle(GruxTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            } action: {
                Button {
                    Task { await briefingEngine.briefNow() }
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                }
                .buttonStyle(.plain)
                .disabled(briefingEngine.isBriefing)
                .help("Have \(UserIdentity.assistantName) speak a fresh briefing now in your cloned voice")
            }
        }
    }

    private var briefingStack: some View {
        VStack(spacing: GruxSpacing.m) {
            // The legacy narrative cards (today / recap) come from the older
            // morning-brief reminder and can read stale. When the live Jax
            // briefing card is present it already covers the narrative, so only
            // fall back to these when there is no Jax briefing.
            if briefingEngine.latest == nil, let today = b.todayBriefPreview {
                todayCard(today)
            }
            if !b.agenda.isEmpty {
                agendaCard
            }
            if !b.commitments.isEmpty {
                commitmentsCard
            }
            HStack(spacing: GruxSpacing.m) {
                if b.jobsRunning > 0 || b.jobsPaused > 0 {
                    jobsCard
                }
                if b.proposalsCount > 0 {
                    proposalsCard
                }
            }
            if let meeting = b.meeting {
                meetingCard(meeting)
            }
            if briefingEngine.latest == nil, let recap = b.recapPreview {
                recapCard(recap)
            }
        }
    }

    private var agendaCard: some View {
        BriefingCard(title: "Agenda", icon: "calendar", accent: GruxTheme.accentPrimary) {
            VStack(spacing: GruxSpacing.s) {
                ForEach(b.agenda) { item in
                    HStack(spacing: GruxSpacing.m) {
                        Text(item.timeLabel)
                            .font(GruxType.caption.monospacedDigit())
                            .foregroundStyle(item.isToday ? GruxTheme.accentPrimaryLight : GruxTheme.textTertiary)
                            .frame(width: 92, alignment: .leading)
                        Text(item.title)
                            .font(GruxType.body)
                            .foregroundStyle(GruxTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        } action: {
            CardLink(label: "Open calendar") { state.requestedTab = "calendar" }
        }
    }

    private var commitmentsCard: some View {
        BriefingCard(title: "Open commitments", icon: "checklist", accent: GruxTheme.warnAmber) {
            VStack(spacing: GruxSpacing.s) {
                ForEach(b.commitments) { c in
                    HStack(spacing: GruxSpacing.m) {
                        Circle()
                            .fill(GruxTheme.warnAmber.opacity(0.8))
                            .frame(width: 6, height: 6)
                        Text(c.title)
                            .font(GruxType.body)
                            .foregroundStyle(GruxTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let due = c.dueLabel {
                            Text(due)
                                .font(GruxType.caption)
                                .foregroundStyle(GruxTheme.textTertiary)
                        }
                    }
                }
            }
        } action: {
            CardLink(label: "Open tasks") { state.requestedTab = "tasks" }
        }
    }

    private var jobsCard: some View {
        BriefingCard(title: "Agents", icon: "cpu", accent: GruxTheme.accentCo) {
            VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                if b.jobsRunning > 0 {
                    statRow(count: b.jobsRunning, noun: "job", verb: "active", color: GruxTheme.successMint)
                }
                if b.jobsPaused > 0 {
                    statRow(count: b.jobsPaused, noun: "job", verb: "paused", color: GruxTheme.warnAmber)
                }
            }
        } action: {
            if let jobId = b.resumableJobId {
                CardLink(label: "Resume") {
                    state.pendingResumeJobId = jobId
                    state.requestedTab = "agents"
                }
            } else {
                CardLink(label: "Open agents") { state.requestedTab = "agents" }
            }
        }
    }

    private var proposalsCard: some View {
        BriefingCard(title: "Foundry", icon: "wand.and.stars", accent: GruxTheme.accentPrimary) {
            VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                statRow(count: b.proposalsCount, noun: "proposal", verb: "pending", color: GruxTheme.accentPrimaryLight)
                if let top = b.topProposal {
                    Text(top.title)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(2)
                    Text(top.costLabel)
                        .font(GruxType.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
            }
        } action: {
            CardLink(label: "Review") { state.requestedTab = "selfUpgrade" }
        }
    }

    private func meetingCard(_ meeting: HomeBriefing.MeetingItem) -> some View {
        BriefingCard(title: "Latest meeting", icon: "waveform", accent: GruxTheme.accentCo) {
            VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                HStack(spacing: GruxSpacing.s) {
                    Text(meeting.title)
                        .font(GruxType.body)
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(1)
                    Text(meeting.whenLabel)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                if let excerpt = meeting.excerpt {
                    Text(excerpt)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(2)
                }
            }
        } action: {
            CardLink(label: "Open meetings") { state.requestedTab = "meetings" }
        }
    }

    // Forward counterpart to recapCard: the morning brief under a sun icon.
    private func todayCard(_ brief: String) -> some View {
        BriefingCard(title: "Today", icon: "sun.max", accent: GruxTheme.accentPrimary) {
            Text(brief)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } action: {
            EmptyView()
        }
    }

    private func recapCard(_ recap: String) -> some View {
        BriefingCard(title: "Daily recap", icon: "moon.stars", accent: GruxTheme.accentPrimary) {
            Text(recap)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } action: {
            EmptyView()
        }
    }

    /// The card stack's copy when nothing has any signal, static so it can be
    /// asserted on.
    ///
    /// This is what a first run reads, because every source it folds is empty on
    /// a machine that has not been used yet. It says nothing is WRONG and then
    /// says where the first signal comes from, because "All quiet" on its own
    /// over a screen with no cards is indistinguishable from a briefing that
    /// failed to build.
    static let allQuietCopy = (
        headline: "All quiet",
        detail: "No agenda, commitments, or live work right now. "
            + "This fills in on its own as you use the app, and the button above starts it."
    )

    private var allQuietCard: some View {
        VStack(spacing: GruxSpacing.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
            Text(Self.allQuietCopy.headline)
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)
            Text(Self.allQuietCopy.detail)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            // Surface the connect-calendar nudge here so a user with calendar
            // permission denied actually sees it (agendaEmptyCopy was computed
            // but never rendered before). In the all-quiet state the agenda is
            // always empty, so this reads "Connect a calendar..." when
            // unauthorized and "Nothing on the calendar..." when authorized.
            Text(b.agendaEmptyCopy)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, GruxSpacing.xl)
    }

    // MARK: - Shared bits

    private func statRow(count: Int, noun: String, verb: String, color: Color) -> some View {
        HStack(spacing: GruxSpacing.s) {
            Text("\(count)")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text("\(noun)\(count == 1 ? "" : "s") \(verb)")
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
        }
    }
}

// MARK: - Briefing card chrome

// A single briefing card: a glass-leaning panel with an icon kicker, a
// title, arbitrary content, and an optional trailing inline link.
private struct BriefingCard<Content: View, Action: View>: View {
    let title: String
    let icon: String
    let accent: Color
    @ViewBuilder let content: () -> Content
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            HStack(spacing: GruxSpacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                Text(title.uppercased())
                    .font(GruxType.microCaps)
                    .kerning(1.4)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer(minLength: 0)
                action()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GruxSpacing.l)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// Lean inline link used in card headers. Lighter than a button.
private struct CardLink: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.accentPrimaryLight)
        }
        .buttonStyle(.plain)
    }
}

// Secondary quick-action pill. Tight per the app's button scale (no chunky
// controls): icon + label, transparent fill, subtle hover.
private struct QuickActionPill: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    // One line, allowed to shrink slightly before truncating, so
                    // a button label never wraps mid-word. Kept on its own
                    // merits: it was TESTED as the suspected cause of Home
                    // overflowing its pane at the window floor and measured NOT
                    // to be (the nav rail stayed at 217pt of its 240 either
                    // way), so do not read this as the fix for that.
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(hovering ? GruxTheme.textPrimary : GruxTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(Color.white.opacity(hovering ? 0.10 : 0.05))
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
