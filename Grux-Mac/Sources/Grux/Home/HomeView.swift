import SwiftUI

// The Home tab, which is Today (Phase D). Your name, then three cards (Next,
// Mail that needs you, Watching), Start my day, one line inviting you to just
// say it, then the briefing. What each card shows is decided in TodayModel,
// where a test can drive it; this file only draws it. Chat stays the landing
// tab: Today is where you go, not where you land.
//
// The old Agenda, Open commitments, Agents and Foundry cards are gone because
// Next and Watching now carry them, and the quick-action row is gone because
// every pill in it was another door to a surface the rail already opens (New
// chat, Research, Upgrade yourself, Pair phone). No two elements with the same
// job in one view.
//
// Every action routes through an EXISTING seam (AppState.requestedTab,
// FoundryEngine, MorningBriefScheduler, DailyRecapScheduler, AgentService,
// openWindow). Home never
// duplicates a store's logic; it only reads snapshots and fires the same
// entry points the rest of the app uses.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = HomeBriefingModel()
    /// Changes only when hearing starts or stops, never at audio rate.
    @ObservedObject private var micHealth = MicHealth.shared
    @StateObject private var briefingEngine = BriefingEngine.shared
    @Environment(\.openWindow) private var openWindow

    @State private var startingDay = false

    private var b: HomeBriefing { model.briefing }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HomeHeroView(greeting: b.greeting, dateLine: b.dateLine)

                VStack(spacing: GruxSpacing.l) {
                    todayCards

                    VStack(spacing: GruxSpacing.s) {
                        startMyDayButton
                        sayItLine
                        Button("Tune how Grux works") { AppState.shared.requestedTab = "tuning" }
                            .buttonStyle(.borderless)
                            .font(GruxType.caption)
                    }

                    if briefingEngine.latest != nil {
                        jaxBriefingCard
                    }
                    briefingStack
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
            if let meeting = b.meeting {
                meetingCard(meeting)
            }
            if briefingEngine.latest == nil, let recap = b.recapPreview {
                recapCard(recap)
            }
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

// MARK: - Today

    private var todayCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: GruxSpacing.m, alignment: .top)],
                  alignment: .leading, spacing: GruxSpacing.m) {
            nextCard
            mailCard
            watchingCard
        }
    }

    private var nextCard: some View {
        BriefingCard(title: "Next", icon: "arrow.right.circle", accent: GruxTheme.accentPrimary) {
            if let next = model.today.next {
                VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                    Text(next.title)
                        .font(GruxType.title)
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(2)
                    if !next.when.isEmpty {
                        Text(next.when)
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.accentPrimaryLight)
                    }
                    ForEach(next.then, id: \.self) { line in
                        Text("Then: \(line)")
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
            } else {
                emptyLine(TodayModel.Copy.nextEmpty)
            }
        } action: {
            CardLink(label: model.today.next?.kind == .event ? "Open calendar" : "Open tasks") {
                state.requestedTab = model.today.next?.tab ?? "tasks"
            }
        }
    }

    private var mailCard: some View {
        BriefingCard(title: "Mail that needs you", icon: "envelope.badge", accent: GruxTheme.warnAmber) {
            if !model.today.mail.isEmpty {
                VStack(alignment: .leading, spacing: GruxSpacing.s) {
                    ForEach(model.today.mail) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.subject)
                                .font(GruxType.body)
                                .foregroundStyle(GruxTheme.textPrimary)
                                .lineLimit(1)
                            Text(m.from)
                                .font(GruxType.caption)
                                .foregroundStyle(GruxTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    if model.today.mailTotal > model.today.mail.count {
                        Text("and \(model.today.mailTotal - model.today.mail.count) more")
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                }
            } else {
                emptyLine(model.today.hasMailAccount ? TodayModel.Copy.mailEmpty : TodayModel.Copy.mailNoAccount)
            }
        } action: {
            CardLink(label: "Open mail") { state.requestedTab = "mailbox" }
        }
    }

    private var watchingCard: some View {
        BriefingCard(title: "Watching", icon: "eye", accent: GruxTheme.accentCo) {
            if !model.today.watching.isEmpty {
                VStack(alignment: .leading, spacing: GruxSpacing.s) {
                    ForEach(model.today.watching) { item in
                        Button { state.requestedTab = item.tab } label: {
                            HStack(spacing: GruxSpacing.s) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(GruxTheme.accentCo)
                                    .frame(width: 14)
                                Text(item.line)
                                    .font(GruxType.body)
                                    .foregroundStyle(GruxTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                emptyLine(TodayModel.Copy.watchingEmpty)
            }
        } action: {
            EmptyView()
        }
    }

    /// The say-it line, from the one shared microphone tell. Speaking and
    /// thinking are left out on purpose: they are moments, and observing the
    /// speech engine here would redraw Today at audio rate while Grux talks.
    private var sayItLine: some View {
        Text(TodayModel.sayItLine(ListeningTell.resolve(mode: state.config.listeningModeInEffect,
                                                        micMuted: state.micMuted,
                                                        isSpeaking: false, isThinking: false,
                                                        notHearing: micHealth.notHearing)))
            .font(GruxType.caption)
            .foregroundStyle(GruxTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(GruxType.body)
            .foregroundStyle(GruxTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
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

