import SwiftUI

/// P-E-2: Tuning, the accepted shape C (`docs/superpowers/visuals/tuning-c.png`,
/// accepted 2026-09-22). One card per thing Grux does for the person, each
/// opening to its dials, organised by what Grux does rather than by subsystem.
///
/// A surface with no rail row (the first-run rail stays at fourteen), opened
/// from the orb, from Today, from the command palette and from a link at the
/// top of Settings. Every dial binds straight to the one config value it
/// always had, and saves on change, so Tuning and anything else reading the
/// config cannot disagree. The controls that moved here left Settings, which
/// keeps a pointer rather than a second copy.
///
/// Changing Grux itself, beyond these dials, is one button away: "Tell Grux
/// what you want" opens Optimize Grux.
@MainActor
enum TuningCopy {
    static let title = "Tuning"
    static let subtitle = "What Grux does for you. Open one to change how it does it."
    static let optimizeTitle = "Tell Grux what you want"
    static let optimizeBody = "Anything these dials cannot do, from a color to a new surface. Your coding agent builds it; you approve it."
    static let pointer = "Now in Tuning, with everything else about how Grux acts, interrupts, spends and remembers."
    static let settingsLink = "How Grux acts on what you say, talks back, interrupts you, works on its own, spends and remembers. Every one of those dials is in Tuning."
    static let spokenPointer = "Speaking aloud and voice speed are in Tuning. The voice itself and its key stay here."
    static let memoryPointer = "The switch is in Tuning. What Grux holds, and clearing it, stay here."
    static let selfUpgradePointer = "How much it may do by itself, at most, is in Tuning."
    static let listeningPointer = "Choosing the mode, and whether Grux tells you when it acts, are in Tuning beside how sure it must be."
    /// The one true way to cut Grux off mid-sentence. It does not listen while
    /// it talks (SpeechEngine), so a "stop when I talk over it" switch would
    /// promise something nothing does.
    static let interrupt = "To cut Grux off mid-sentence, press the microphone in Chat to answer, or mute its voice."

    /// `spends` is whether anything on this setup is billed. The estimate is
    /// for a cloud key; a fresh install with none read "about $60 a month"
    /// while nothing could be charged (W4 pass 2, 2026-10-13).
    static func tierPointer(_ tier: GruxTier, spends: Bool = true) -> String {
        guard spends else {
            return "\(tier.label), $0 a month as set up: there is no cloud key, so nothing is billed. "
                + "How often Grux looks, and what a key would cost, is in Tuning."
        }
        return "\(tier.label), about $\(tier.estimatedMonthlyUSD) a month. How often Grux looks, and what that costs, is in Tuning."
    }

    /// Whether this setup can be billed at all: a cloud key, or a hosted endpoint.
    @MainActor static var tierSpends: Bool {
        if KeychainStore.exists(.anthropicApiKey) { return true }
        if case .custom = ModelRegistry.shared.resolvedProvider { return true }
        return false
    }

    /// Every entry point opens the same tab.
    static func open() { AppDelegate.shared?.openLaunchWindow(tab: "tuning") }

    /// 1.5 reads "1.5", 1.25 reads "1.25", 2 reads "2". `%.2g` rounded 1.25
    /// to "1.2", which misstated the speed actually set.
    static func rate(_ r: Double) -> String {
        var t = String(format: "%.2f", r)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    enum Card: String, CaseIterable, Identifiable {
        case acts, talks, interrupts, alone, spends, remembers, asks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .acts: return "Acts on what I say"
            case .talks: return "Talks back"
            case .interrupts: return "Interrupts me"
            case .alone: return "Works on its own"
            case .spends: return "Spends"
            case .remembers: return "Remembers"
            case .asks: return "Asks before"
            }
        }
    }

    // MARK: - One line per card, from live values. Pure.

    /// The headline says the threshold in words; the number stays on the
    /// dial under it. "Acts at 0.70" asked a person to know what 0.70 of
    /// what (audit 2026-10-13, item 9).
    static func acts(threshold: Double, mode: ListeningMode, waiting: Bool = false) -> String {
        "Acts \(sure(threshold)), listening \(mode.label.lowercased())"
            + (waiting ? " once you agree." : ".")
    }

    /// How sure Grux must be, in words. The slider runs 0.50 to 0.95.
    static func sure(_ threshold: Double) -> String {
        switch threshold {
        case ..<0.625: return "when it is fairly sure"
        case ..<0.775: return "when it is sure"
        case ..<0.875: return "when it is very sure"
        default:       return "only when it is certain"
        }
    }

    /// Under the Listening picker when the mode is chosen but not agreed to.
    static let waitingNote = "The microphone is still closed: Grux needs your OK first."

    static func talks(speaks: Bool, rate: Double) -> String {
        speaks ? "Speaks replies at \(Self.rate(rate))x." : "Quiet: replies stay on screen."
    }

    static func interrupts(start: Int, end: Int, cooldown: Int) -> String {
        "Between \(ClockFormat.hourLabel(start)) and \(ClockFormat.hourLabel(end)), at most every \(cooldown) min."
    }

    static func alone(mode: GruxMode, ceiling: Int) -> String {
        let tier = ["proposes only", "builds, then asks", "lands on its own"][max(0, min(2, ceiling))]
        return "\(mode.rawValue.capitalized) energy; self-upgrade \(tier)."
    }

    static func spends(count: Int, costUSD: Double, budget: Int) -> String {
        let cost = costUSD < 0.01 ? "under $0.01" : String(format: "$%.2f", costUSD)
        let cap = budget > 0 ? ", \(budget) a day, then on device" : ""
        return "\(count) decisions today, \(cost)\(cap)."
    }

    static func remembers(memory: Bool, recapHour: Int) -> String {
        (memory ? "Remembers across sessions" : "Forgets when you quit") + "; recap at \(ClockFormat.hourLabel(recapHour))."
    }

    static let asks = ListeningSection.copy.body

    static func decisionsKey(saved: Bool, capped: Bool) -> String {
        guard saved else { return "Decisions: on this Mac. A Decisions key makes them faster and surer." }
        return capped ? "Decisions: on this Mac until midnight; today's cap is reached." : "Decisions: Jev, with your key."
    }
}

struct TuningView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var ledger = DecisionLedger.shared
    @Environment(\.paneTitles) private var paneTitles
    @State private var open: TuningCopy.Card?

    /// Opens with "Acts on what I say" unfolded, as the accepted render does.
    init(open: TuningCopy.Card? = .acts) { _open = State(initialValue: open) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !PaneHeading.repeats(TuningCopy.title, paneTitles: paneTitles) {
                    Text(TuningCopy.title)
                        .font(GruxType.title)
                        .foregroundStyle(GruxTheme.textPrimary)
                }
                Text(TuningCopy.subtitle)
                    .font(.callout)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .padding(.bottom, 8)
                // Two columns, as accepted (tuning-c.png), wherever two cards
                // fit side by side; one column on a narrower pane, where two
                // squeezed the listening picker past the card's edge.
                GruxWidthSwitch(threshold: 2 * GruxLayout.tuningCardMin + GruxSpacing.m) {
                    twoColumns
                } narrow: {
                    oneColumn
                }
            }
            .padding(.vertical, GruxSpacing.xl + GruxSpacing.xs)
            .adaptiveHorizontalPadding(GruxSpacing.xl + GruxSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(GruxTheme.accentPrimary)
    }

    // MARK: - Cards

    /// Seven cards leave the eighth place for "Tell Grux what you want", so
    /// the way past these dials sits where the eye ends up.
    ///
    /// Two columns that size independently. As a Grid, a row's two cards
    /// matched heights, so the open "Acts on what I say" stretched "Talks
    /// back" beside it into a 450pt empty card (audit 2026-10-13, item 9).
    private var twoColumns: some View {
        let cards = TuningCopy.Card.allCases
        let left = stride(from: 0, to: cards.count, by: 2).map { cards[$0] }
        let right = stride(from: 1, to: cards.count, by: 2).map { cards[$0] }
        return HStack(alignment: .top, spacing: GruxSpacing.m) {
            VStack(alignment: .leading, spacing: GruxSpacing.m) {
                ForEach(left, id: \.self) { cardView($0) }
                if cards.count % 2 == 0 { optimizeCard }
            }
            VStack(alignment: .leading, spacing: GruxSpacing.m) {
                ForEach(right, id: \.self) { cardView($0) }
                if cards.count % 2 == 1 { optimizeCard }
            }
        }
        // At its ideal height, always: offered a finite height, a stack can
        // spread it over its cards and draw over the title.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The same cards in one column, the way past them still last.
    private var oneColumn: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            ForEach(TuningCopy.Card.allCases, id: \.self) { cardView($0) }
            optimizeCard
        }
    }

    private func cardView(_ card: TuningCopy.Card) -> some View {
        let isOpen = open == card && card != .asks
        let header = VStack(alignment: .leading, spacing: 5) {
            Text(card.title).font(.system(size: 15, weight: .bold)).foregroundStyle(GruxTheme.textPrimary)
            Text(summary(card)).font(.callout).foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        return VStack(alignment: .leading, spacing: 0) {
            if card == .asks {
                // Nothing to turn: these always ask, and the card says so.
                header
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { open = isOpen ? nil : card }
                } label: { header }
                .buttonStyle(.plain)
                .accessibilityHint(isOpen ? "Closes its dials" : "Opens its dials")
            }
            if isOpen {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 16)
                VStack(alignment: .leading, spacing: 14) { dials(card) }
            }
        }
        .padding(20)
        // Its own height: a card never stretches to match a neighbour.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card)
            .fill(isOpen ? GruxTheme.accentPrimary.opacity(0.07) : Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: GruxTheme.Radius.card)
            .stroke(isOpen ? GruxTheme.accentPrimary.opacity(0.6) : Color.white.opacity(0.07), lineWidth: isOpen ? 1.5 : 1))
    }

    private var optimizeCard: some View {
        Button { OptimizeState.shared.isOpen = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(TuningCopy.optimizeTitle).font(.system(size: 15, weight: .bold)).foregroundStyle(GruxTheme.textPrimary)
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(GruxTheme.accentPrimaryLight)
                }
                Text(TuningCopy.optimizeBody).font(.callout).foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            // Its own height, like every card: stretched, it ran to the
            // bottom of the taller column as one long empty card.
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).fill(GruxTheme.accentPrimary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).stroke(GruxTheme.accentPrimary.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func summary(_ card: TuningCopy.Card) -> String {
        let c = state.config
        switch card {
        case .acts: return TuningCopy.acts(threshold: c.listeningThreshold, mode: c.listeningMode,
                                           waiting: c.listeningAwaitingConsent)
        case .talks: return TuningCopy.talks(speaks: c.speakRepliesAloud, rate: c.voicePlaybackRate)
        case .interrupts: return TuningCopy.interrupts(start: c.activeHoursStart, end: c.activeHoursEnd, cooldown: c.focusCooldownMinutes)
        case .alone: return TuningCopy.alone(mode: c.currentMode, ceiling: c.selfUpgradeMaxTier)
        case .spends:
            let today = ledger.today()
            return TuningCopy.spends(count: today.count, costUSD: today.costUSD, budget: c.dailyDecisionBudget)
        case .remembers: return TuningCopy.remembers(memory: c.memoryEnabled, recapHour: c.dailyRecapHour)
        case .asks: return TuningCopy.asks
        }
    }

    // MARK: - Dials

    @ViewBuilder
    private func dials(_ card: TuningCopy.Card) -> some View {
        switch card {
        case .acts:
            dial("Listening") {
                Picker("", selection: binding(\.listeningMode, then: { Task { @MainActor in await ListeningController.shared.apply() } })) {
                    ForEach(ListeningMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                note(state.config.listeningMode.explanation)
                if state.config.listeningAwaitingConsent {
                    // Chosen but not agreed to: say so here, where the choice
                    // was made, with the one button that opens the microphone.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(TuningCopy.waitingNote)
                            .font(.caption).foregroundStyle(GruxTheme.warnAmber)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(ListeningTell.allowTitle) { ListeningTell.allow() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                } else if state.config.listeningMode != .off { note(MicConsent.runningNote) }
            }
            dial("How sure before acting", value: String(format: "%.2f", state.config.listeningThreshold)) {
                Slider(value: binding(\.listeningThreshold), in: 0.50...0.95, step: 0.05)
                note("At or above this Grux does it; below it, Grux asks. Sending, deleting and spending always ask.")
            }
            Toggle(ListeningSection.bannerCopy.title, isOn: binding(\.showLastDecision))
            note(ListeningSection.bannerCopy.body)
            decisionsKeyRow
        case .talks:
            Toggle("Speak Grux's replies aloud", isOn: binding(\.speakRepliesAloud))
            dial("Voice speed", value: "\(TuningCopy.rate(state.config.voicePlaybackRate))x") {
                Slider(value: binding(\.voicePlaybackRate, then: { SpeechEngine.shared.applyPlaybackRate(state.config.voicePlaybackRate) }),
                       in: 0.75...2.0, step: 0.05)
                note("1 is natural pacing; 1.5, the default, reads briskly without changing the pitch.")
            }
            note(TuningCopy.interrupt)
        case .interrupts:
            step("Focus nudges at most every", "\(state.config.focusCooldownMinutes) min",
                 binding(\.focusCooldownMinutes), 1...120)
            step("Checks in after silence of", "\(state.config.stuckThresholdMinutes) min",
                 binding(\.stuckThresholdMinutes), 2...60)
            step("Active from", ClockFormat.hourLabel(state.config.activeHoursStart), binding(\.activeHoursStart), 0...23)
            step("Until", ClockFormat.hourLabel(state.config.activeHoursEnd), binding(\.activeHoursEnd), 1...24)
            step("Snooze lasts", "\(state.config.snoozeMinutes) min", binding(\.snoozeMinutes), 5...240, by: 5)
        case .alone:
            dial("Energy") {
                Picker("", selection: binding(\.currentMode)) {
                    ForEach(GruxMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                note("Tone, reply length and how often Grux nudges.")
            }
            dial("How often it looks, and what that costs") {
                ForEach(GruxTier.allCases) { tierRow($0) }
            }
            dial("Self-upgrade, at most") {
                Picker("", selection: binding(\.selfUpgradeMaxTier)) {
                    Text("Proposes").tag(0); Text("Builds, then asks").tag(1); Text("Lands on its own").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
                note("The most any part of Grux may do by itself, whatever it has earned. Lowering it takes effect at once.")
            }
        case .spends:
            step("Decisions a day", state.config.dailyDecisionBudget == 0 ? "no cap" : "\(state.config.dailyDecisionBudget)",
                 binding(\.dailyDecisionBudget), 0...5000, by: 100)
            note("Past the cap Grux decides on this Mac until midnight, for free.")
            if let last = ledger.last {
                note("Last decision: \(last.surface), \(last.latencyMs) ms, \(last.provider == .jev ? "Jev" : "on device").")
            }
            UsageCard()
            ForEach(Array(ledger.recent.suffix(5).reversed().enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.surface).font(.caption.monospaced()).foregroundStyle(GruxTheme.textSecondary)
                    Spacer()
                    Text("\(row.latencyMs) ms").font(.caption.monospaced()).foregroundStyle(GruxTheme.textTertiary)
                }
            }
        case .remembers:
            Toggle("Remember chats, screen events and voice across sessions", isOn: binding(\.memoryEnabled))
            note("On this Mac only. Clearing what it knows is in Settings.")
            step("Daily recap at", ClockFormat.hourLabel(state.config.dailyRecapHour), binding(\.dailyRecapHour), 0...23)
            step("Energy recap at", ClockFormat.hourLabel(state.config.energyRecapHour), binding(\.energyRecapHour), 0...23)
        case .asks:
            EmptyView()
        }
    }

    private func tierRow(_ tier: GruxTier) -> some View {
        let on = state.config.tier == tier
        return Button {
            state.config.tier = tier
            state.saveConfig()
            FocusWatcher.shared.restartForTierChange()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? GruxTheme.accentPrimary : GruxTheme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(tier.label).font(.caption.weight(.semibold)).foregroundStyle(GruxTheme.textPrimary)
                        Spacer()
                        Text("about $\(tier.estimatedMonthlyUSD) a month").font(.caption.monospacedDigit())
                            .foregroundStyle(on ? GruxTheme.accentPrimary : GruxTheme.textTertiary)
                    }
                    Text(tier.architecture).font(.caption).foregroundStyle(GruxTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var decisionsKeyRow: some View {
        let engine = DecisionEngine.shared
        return HStack {
            Text(TuningCopy.decisionsKey(saved: engine.hasSavedKey, capped: engine.budgetReached()))
                .font(.caption).foregroundStyle(GruxTheme.textSecondary)
            Spacer()
            Button(engine.hasSavedKey ? "Manage the key" : "Add a key") {
                AppState.shared.requestedTab = "integrations"
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }

    /// A titled dial, its value right-aligned in the accent as accepted.
    private func dial<Content: View>(_ title: String, value: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout).foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                if let value { accentValue(value) }
            }
            content()
        }
    }

    private func step(_ title: String, _ value: String, _ binding: Binding<Int>,
                      _ range: ClosedRange<Int>, by: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout).foregroundStyle(GruxTheme.textPrimary)
            Spacer()
            accentValue(value)
            Stepper(title, value: binding, in: range, step: by).labelsHidden()
        }
    }

    private func accentValue(_ text: String) -> some View {
        Text(text).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(GruxTheme.accentPrimaryLight)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(GruxTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    /// A live binding to one config value that saves on change, the same way
    /// every other Settings control writes, plus an optional follow-up.
    private func binding<T>(_ key: WritableKeyPath<GruxConfig, T>, then: (() -> Void)? = nil) -> Binding<T> {
        Binding(get: { state.config[keyPath: key] },
                set: { state.config[keyPath: key] = $0; state.saveConfig(); then?() })
    }
}

/// What Settings shows where a control that moved to Tuning used to be: one
/// line saying where it went, and the button that goes there.
struct TuningPointer: View {
    var text: String = TuningCopy.pointer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Tuning") { TuningCopy.open() }
                .buttonStyle(.borderless).font(.caption)
        }
    }
}
