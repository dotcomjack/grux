import SwiftUI

// JaxCommandView: the in-app Jax Command dashboard. A first-class current Grux
// surface (matches the MetaAds power-tool / Jax HQ look exactly) that renders
// Jax's whole operating posture LIVE from the real stores, with zero parallel
// state and zero fabrication:
//
//   1. AUTONOMY      : the real AutonomyController mode (SIMULATE / OBSERVE /
//                      LIVE) as a segmented control wired to setMode, plus the
//                      hard-stop kill switch (setKilled). Reads + writes the
//                      live controller.
//   2. GOAL PURSUIT  : the real GoalPursuitEngine.shared.runs as cards (domain,
//                      chosen goal, rationale, the planned Claude Code action,
//                      and a SIMULATED / DISPATCHED badge from run.executed).
//   3. IDENTITY      : counts + a sample of priorities / values / heuristics
//                      from JaxProfile.shared.
//   4. MEMORY        : the corpus total + per-source counts (CorpusCoordinator),
//                      plus the hot SemanticMemory kinds by count.
//   5. ROADMAP       : RoadmapStore items with status + a progress bar.
//   6. GUARDRAILS    : the five hard rules, stated plainly (static).
//
// Jax HQ is the OVERSIGHT inbox (approvals, briefing, goals in motion). Jax
// Command is the CONTROL ROOM: it is where the user reads, at a glance, what
// their clone's mind is set to, what it has been doing between check-ins, what
// it knows, and what it is chasing, and where they flip the mode or hit the
// kill switch.
//
// HARD HONESTY: there is no "brain map" / neural / fMRI data anywhere here. The
// Identity + Memory sections are a DECISION/COGNITION TRACE, the real provenance
// the app actually has: heuristics it learned, values it weighs, corpus voice it
// retrieves, the mode it runs in. Nothing invents neural numbers.
//
// Zero em/en dashes. Money is $N (MetaAdsFormat.dollars). GruxTheme tokens only.
struct JaxCommandView: View {
    /// D192 (3): the header line over "Jax Command". It was "The control room for your
    /// clone", a word the pane never explains; it now opens the Labs shelf's own line for it.
    static let eyebrowText = "Goals Grux pursues on its own"

    @ObservedObject private var autonomy = AutonomyController.shared
    @ObservedObject private var pursuit = GoalPursuitEngine.shared
    @ObservedObject private var profile = JaxProfile.shared
    @ObservedObject private var corpus = CorpusCoordinator.shared
    @ObservedObject private var memory = SemanticMemory.shared
    @ObservedObject private var roadmap = RoadmapStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                JaxAutonomySection()
                JaxGoalPursuitSection(runs: pursuit.runs, isRunning: pursuit.isRunning)
                JaxIdentitySection(
                    priorities: profile.values.filter { $0.kind == .priority },
                    coreValues: profile.values.filter { $0.kind == .value },
                    heuristics: profile.heuristics
                )
                JaxMemorySection(
                    sources: corpus.orderedStatuses,
                    semanticKinds: memory.countByKind()
                )
                JaxRoadmapSection(items: roadmap.items, progress: roadmap.progress())
                JaxGuardrailsSection()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GruxTheme.base)
        .onAppear {
            profile.load()
            roadmap.load()
            // CorpusCoordinator's own comment has always said the probe is refreshed "on
            // Jax HQ / Settings appear so the permission rows are current". It was not:
            // grep found the launch bootstrap and the onboarding screen and nothing else,
            // so this screen rendered whatever the last launch happened to see.
            //
            // It matters more now. The launch probe is held behind
            // step.corpus_sources_confirmed, because probing Notes used to raise an
            // Automation dialog on a first launch, so without this the rows would sit at
            // "Status unknown until first run." until somebody quit and reopened Grux. The
            // probe no longer sends an Apple event, so running it here raises nothing.
            Task { @MainActor in await corpus.refreshPermissions() }
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(GruxTheme.iridescent)
                    .frame(width: 38, height: 38)
                    .shadow(color: GruxTheme.violetGlow(strong: true), radius: 12)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                MetaAdsEyebrow(text: Self.eyebrowText, tint: GruxTheme.accentPrimaryLight)
                Text("Jax Command")
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
            }
            Spacer()
            modePill
            if autonomy.killed { killedPill }
        }
    }

    private var modePill: some View {
        let tint = JaxModeStyle.tint(autonomy.mode)
        return HStack(spacing: 5) {
            Image(systemName: JaxModeStyle.icon(autonomy.mode)).font(.system(size: 10, weight: .bold))
            Text(autonomy.mode.label.uppercased()).font(GruxTheme.Font.microCaps).kerning(1.2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var killedPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .bold))
            Text("HALTED").font(GruxTheme.Font.microCaps).kerning(1.2)
        }
        .foregroundStyle(GruxTheme.destructiveRose)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(GruxTheme.destructiveRose.opacity(0.14)))
        .overlay(Capsule().strokeBorder(GruxTheme.destructiveRose.opacity(0.4), lineWidth: 1))
    }
}

// MARK: - Mode presentation tokens

// Visual identity for the three AutonomyModes. SIMULATE is calm (it touches
// nothing), OBSERVE is co-pilot cyan (it queues for a yes), LIVE is the violet
// "the clone is acting" accent. Kept here as a small namespace so it can be
// reused by the hero pill and the segmented control without extending the enum
// (which AutonomyController owns) from the view layer.
enum JaxModeStyle {
    static func tint(_ mode: AutonomyMode) -> Color {
        switch mode {
        case .simulate: return GruxTheme.textSecondary
        case .observe:  return GruxTheme.accentCo
        case .live:     return GruxTheme.accentPrimary
        }
    }

    static func icon(_ mode: AutonomyMode) -> String {
        switch mode {
        case .simulate: return "circle.dashed"
        case .observe:  return "eye.fill"
        case .live:     return "bolt.fill"
        }
    }

    // @MainActor because the copy now reads the assistant's name, which is
    // MainActor isolated. Both call sites are SwiftUI views, so this costs
    // nothing and is where this help text was always used from.
    @MainActor
    static func helpText(_ mode: AutonomyMode) -> String {
        switch mode {
        case .simulate: return "SIMULATE (default): \(UserIdentity.assistantName) plans and logs the move, executes nothing. Zero real-world effect."
        case .observe:  return "OBSERVE: \(UserIdentity.assistantName) plans the move and queues it to Jax HQ for your one-click yes. Still nothing runs unprompted."
        case .live:     return "LIVE: \(UserIdentity.assistantName) dispatches the planned Claude Code session itself. Every action still passes the decision gate."
        }
    }
}

// MARK: - 1. Autonomy status + controls

// Binds DIRECTLY to AutonomyController.shared so it reads and writes the live
// mode + kill switch. setMode / setKilled persist to ~/.grux/jax/autonomy.json,
// which is exactly what the goal-pursuit engine reads at run time, so flipping a
// segment here genuinely changes what Jax does on its next cycle.
struct JaxAutonomySection: View {
    @ObservedObject private var autonomy = AutonomyController.shared

    var body: some View {
        JaxSection(
            title: "Autonomy",
            icon: "dial.medium.fill",
            tint: JaxModeStyle.tint(autonomy.mode)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                segmented
                Text(JaxModeStyle.helpText(autonomy.mode))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.white.opacity(0.06))

                killSwitchRow
            }
        }
    }

    private var segmented: some View {
        HStack(spacing: 5) {
            ForEach(AutonomyMode.allCases, id: \.self) { mode in
                modeSegment(mode)
            }
        }
        .opacity(autonomy.killed ? 0.5 : 1.0)
        .help(autonomy.killed
              ? "Kill switch is on. Clear the halt to change the mode."
              : "Pick how far \(UserIdentity.assistantName) may go on its own.")
    }

    @ViewBuilder
    private func modeSegment(_ mode: AutonomyMode) -> some View {
        let selected = (autonomy.mode == mode)
        let tint = JaxModeStyle.tint(mode)

        Button {
            autonomy.setMode(mode)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: JaxModeStyle.icon(mode)).font(.system(size: 9, weight: .bold))
                Text(mode.label.uppercased())
                    .font(.system(size: 11, weight: selected ? .bold : .semibold))
            }
            .foregroundStyle(selected ? tint : GruxTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? tint.opacity(0.20) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(JaxModeStyle.helpText(mode))
    }

    private var killSwitchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: autonomy.killed ? "hand.raised.fill" : "hand.raised")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(autonomy.killed ? GruxTheme.destructiveRose : GruxTheme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(autonomy.killed ? "Hard stop is ON" : "Hard stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                Text(autonomy.killed
                     ? "No cycle runs in any mode until you clear this."
                     : "Flip this to freeze every goal-pursuit cycle instantly, regardless of mode.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { autonomy.killed },
                set: { autonomy.setKilled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(GruxTheme.destructiveRose)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(autonomy.killed ? GruxTheme.destructiveRose.opacity(0.10) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(autonomy.killed ? GruxTheme.destructiveRose.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 2. Goal pursuit

// The real GoalPursuitRun records, newest first, exactly as the engine stored
// them. Each card shows the domain, the verbatim real goal it advanced, Jax's
// one-line rationale, the planned Claude Code action (title + scoped goal +
// template + budget as $N), and an honest status badge with a line saying what
// it means (JaxRunDisplay.status). Idle cycles in a row share one card (D98).
struct JaxGoalPursuitSection: View {
    let runs: [GoalPursuitRun]
    let isRunning: Bool

    private var recent: [JaxRunEntry] { JaxRunDisplay.entries(runs) }

    var body: some View {
        JaxSection(
            title: "Goal pursuit",
            icon: "scope",
            tint: GruxTheme.accentPrimaryLight,
            count: runs.isEmpty ? nil : runs.count,
            trailing: isRunning ? AnyView(runningChip) : nil
        ) {
            if recent.isEmpty {
                JaxEmptyLine(icon: "moon.zzz.fill",
                             text: "No cycles yet. \(UserIdentity.assistantName) runs nightly (2:00 AM to 6:00 AM local) and on demand; runs land here.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recent) { entry in
                        JaxRunCard(entry: entry)
                    }
                }
            }
        }
    }

    private var runningChip: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text("THINKING").font(GruxTheme.Font.microCaps).kerning(1.2)
                .foregroundStyle(GruxTheme.accentPrimaryLight)
        }
    }
}

// One card in Goal pursuit: a run, plus how many cycles in a row before it
// chose the same goal and found nothing to do (D98), so an idle stretch is
// one card, not a new one every cycle.
struct JaxRunEntry: Identifiable {
    let run: GoalPursuitRun
    let repeats: Int
    let firstDate: Date
    var id: UUID { run.id }
}

// What a run card says, kept out of the view so the words are tested.
enum JaxRunDisplay {
    struct Status: Equatable {
        let label: String
        let explanation: String?
    }

    // Runs arrive newest first. A cycle with no plan joins the card above it
    // when that card is also planless on the same domain and goal; a plan is
    // always its own card. `limit` counts cards, not cycles.
    static func entries(_ runs: [GoalPursuitRun], limit: Int = 8) -> [JaxRunEntry] {
        var out: [JaxRunEntry] = []
        for run in runs {
            if let last = out.last, last.run.action == nil, run.action == nil,
               last.run.domain == run.domain, last.run.chosenGoal == run.chosenGoal {
                out[out.count - 1] = JaxRunEntry(run: last.run, repeats: last.repeats + 1, firstDate: run.date)
                continue
            }
            if out.count == limit { break }
            out.append(JaxRunEntry(run: run, repeats: 1, firstDate: run.date))
        }
        return out
    }

    // A plan's budget as its card shows it. A run stored before plans were
    // capped can hold any finite budget a model returned, and `Int(usd * 100)`
    // traps from 9.2e16 up (wave 27), so whole cents are made only where they fit.
    static func budget(_ usd: Double) -> String {
        let cents = (usd * 100).rounded()
        guard cents.isFinite, abs(cents) < 1e15 else { return AgentsView.money(usd) }
        return MetaAdsFormat.dollars(Int(cents))
    }

    // No plan, no badge: nothing was simulated, queued or dispatched.
    static func status(_ run: GoalPursuitRun) -> Status? {
        guard run.action != nil else { return nil }
        if run.executed { return Status(label: "DISPATCHED", explanation: nil) }
        if run.mode == AutonomyMode.simulate.rawValue {
            return Status(label: "SIMULATED",
                          explanation: "Planned only. Nothing ran, because Autonomy was set to Simulate.")
        }
        // Observe, and Live when the worth judgment held it: both queue the
        // plan to Approvals (GoalPursuitEngine.runCycle).
        return Status(label: "SENT TO APPROVALS",
                      explanation: "Nothing ran from here. It runs only if you say yes in Approvals.")
    }

    // A streak names its first cycle by clock time and day. "the first 1 day
    // ago" read the same on two streaks a day apart, so the newer one seemed
    // to start when the older one did (D116 item 3).
    static func noActionLine(_ entry: JaxRunEntry, now: Date = Date(), calendar: Calendar = .current) -> String {
        entry.repeats == 1
            ? "No action worth taking this cycle."
            : "No action worth taking, \(entry.repeats) cycles in a row (the first at \(JaxTime.clockAndDay(entry.firstDate, now: now, calendar: calendar)))."
    }
}

private struct JaxRunCard: View {
    let entry: JaxRunEntry
    private var run: GoalPursuitRun { entry.run }

    private var domainTint: Color {
        switch run.domain {
        case "product/code": return GruxTheme.accentPrimaryLight
        case "comms":        return GruxTheme.accentCo
        case "ops":          return GruxTheme.warnAmber
        default:             return GruxTheme.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(run.domain.uppercased())
                    .font(GruxTheme.Font.microCaps).kerning(0.8)
                    .foregroundStyle(domainTint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(domainTint.opacity(0.16)))
                Spacer()
                if let status = JaxRunDisplay.status(run) {
                    statusBadge(status)
                }
                Text(JaxTime.ago(run.date))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            Text(run.chosenGoal)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !run.rationale.isEmpty {
                Text(run.rationale)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action = run.action {
                plannedAction(action)
                if let explanation = JaxRunDisplay.status(run)?.explanation {
                    Text(explanation)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle").font(.system(size: 10))
                    Text(JaxRunDisplay.noActionLine(entry))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // Honest status: DISPATCHED only when the run actually executed (LIVE mode).
    private func statusBadge(_ status: JaxRunDisplay.Status) -> some View {
        let dispatched = run.executed
        let tint = dispatched ? GruxTheme.successMint : GruxTheme.textSecondary
        let icon = dispatched ? "paperplane.fill" : "circle.dashed"
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(status.label).font(GruxTheme.Font.microCaps).kerning(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.16)))
    }

    @ViewBuilder
    private func plannedAction(_ action: PlannedSwarmAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(GruxTheme.accentPrimaryLight)
                Text(action.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(action.template)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
                Text(JaxRunDisplay.budget(action.budgetUSD))
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(GruxTheme.warnAmber)
            }
            Text(action.goal)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(GruxTheme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GruxTheme.accentPrimary.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - 3. Identity (decision provenance, NOT a brain map)

// Counts + a sample of the priorities / values / heuristics from JaxProfile.
// This is the honest answer to "what is shaping the clone's decisions": the
// learned rules and weighed values it actually carries, not invented neural
// data. Empty state is handled (the identity layer is built over time).
struct JaxIdentitySection: View {
    let priorities: [JaxValue]
    let coreValues: [JaxValue]
    let heuristics: [JaxHeuristic]

    var body: some View {
        JaxSection(title: "Identity", icon: "person.crop.circle.badge.checkmark", tint: GruxTheme.accentCo) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    countTile(n: priorities.count, label: "PRIORITIES", icon: "flag.fill", tint: GruxTheme.warnAmber)
                    countTile(n: coreValues.count, label: "VALUES", icon: "heart.fill", tint: GruxTheme.accentCo)
                    countTile(n: heuristics.count, label: "HEURISTICS", icon: "function", tint: GruxTheme.accentPrimaryLight)
                }

                if priorities.isEmpty && coreValues.isEmpty && heuristics.isEmpty {
                    JaxEmptyLine(icon: "sparkle.magnifyingglass",
                                 text: "No learned identity yet. \(UserIdentity.assistantName) writes priorities, values, and heuristics as it watches you decide.")
                } else {
                    if !priorities.isEmpty {
                        provenanceGroup(title: "Priorities (what wins when goals compete)",
                                        lines: priorities.prefix(3).map { ("flag.fill", $0.text) },
                                        tint: GruxTheme.warnAmber)
                    }
                    if !coreValues.isEmpty {
                        provenanceGroup(title: "Values weighed on every call",
                                        lines: coreValues.prefix(3).map { ("heart.fill", $0.text) },
                                        tint: GruxTheme.accentCo)
                    }
                    if !heuristics.isEmpty {
                        provenanceGroup(title: "Decision heuristics",
                                        lines: heuristics.prefix(4).map { h in
                                            ("function", h.domain.isEmpty ? h.rule : "[\(h.domain)] \(h.rule)")
                                        },
                                        tint: GruxTheme.accentPrimaryLight)
                    }
                }
            }
        }
    }

    private func countTile(n: Int, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                Text("\(n)").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(GruxTheme.textPrimary)
            }
            Text(label).font(GruxTheme.Font.microCaps).kerning(1.0).foregroundStyle(GruxTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }

    private func provenanceGroup(title: String, lines: [(String, String)], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(GruxTheme.Font.microCaps).kerning(1.0)
                .foregroundStyle(tint)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: line.0).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint.opacity(0.8))
                        .padding(.top, 2)
                    Text(line.1)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - 4. Memory (the corpus + the hot semantic lanes)

// The "you-ness" corpus: per-source totals from CorpusCoordinator (the user's
// own sent mail, iMessages, Notes, chat-export turns, voice memos), plus the hot
// SemanticMemory lanes by count. All real, all local. This is what Jax retrieves
// into context each turn, the durable provenance of its voice, not a brain scan.
struct JaxMemorySection: View {
    let sources: [CorpusCoordinator.SourceStatus]
    let semanticKinds: [SemanticMemoryKind: Int]

    private var corpusTotal: Int { sources.reduce(0) { $0 + $1.totalIndexed } }

    // Hot lanes, biggest first, excluding the uncapped corpus lane (shown above).
    private var hotLanes: [(SemanticMemoryKind, Int)] { Self.hotLanes(semanticKinds) }

    static func hotLanes(_ kinds: [SemanticMemoryKind: Int]) -> [(SemanticMemoryKind, Int)] {
        kinds
            .filter { $0.key != .corpus && $0.value > 0 }
            .sorted { $0.value > $1.value }
    }

    // D128: the card holds two stores and said so of neither. The corpus is the person's
    // own writing, indexed only from the sources they pick; the chips below it are what
    // was said in chat (and heard, seen or looked up) while Settings, Memory is on. The
    // card read "0 voice corpus items indexed" over "JAX 619 YOU 556", under a setup card
    // saying "Nothing is indexed until you choose.", so each line now names its source.

    /// The sum of the chips it sits beside. It was `SemanticMemory.totalCount`, which
    /// counts the corpus the chips leave out.
    static func lanesTotal(_ kinds: [SemanticMemoryKind: Int]) -> Int {
        hotLanes(kinds).reduce(0) { $0 + $1.1 }
    }

    static let corpusHeadlineText = "items of your own writing indexed"

    /// D179 item 4: this said "Run a corpus sweep" where no control has that name.
    /// Wave 63 rounds 1 and 2: it then named a setup step whose confirm indexes nothing,
    /// then first run's "Teach Grux your voice" screen, which the default first run never
    /// shows. The card now lists every source with an Index button on each readable one
    /// (`canIndex`), and the line points at those, or says none can be read yet. A read
    /// in progress is said as such; once anything has been read, the line points at the
    /// rows, which say what each read reported (round 6).
    static func canIndex(_ s: CorpusCoordinator.SourceStatus) -> Bool {
        s.permission == .ready && !s.isRunning
    }

    /// Why a source with nothing indexed cannot be read now, in words a person can act
    /// on. Wave 63 round 3: the probe's own text read "Status unknown until first run."
    /// for Notes while the Notes app is closed (its probe cannot tell then) and "No data
    /// found yet for this source." for the two import folders, naming neither folder.
    static func needLine(_ s: CorpusCoordinator.SourceStatus) -> String? {
        guard s.totalIndexed == 0 else { return nil }
        // Wave 66 round 3: the probe on reopen sees only a stored password, so a
        // refused login stands until a later read and keeps naming the fix.
        if loginRefused(s) {
            return "Last read: \(sentence(s.lastNote.trimmingCharacters(in: .whitespacesAndNewlines))) "
                + "Gmail needs an app password, not your Google password: remove the Gmail account in Mail, Accounts "
                + "and add it again with one, then " + (s.permission == .ready ? "press Index." : "reopen this tab.")
        }
        // Wave 63 rounds 4 and 6: a read that indexed nothing showed a guessed reason
        // ("Not checked yet", "No Gmail account configured", or the line's "had
        // nothing"). While its verdict still stands, the row says what that read
        // reported, readable or not; a failed one says how to check again.
        if readVerdictStands(s), !s.lastNote.isEmpty, s.lastNote != s.permission.humanReason {
            let note = s.lastNote.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.permission == .ready
                ? "Last read: \(note)"
                : "Last read: \(sentence(note)) Reopen this tab to check it again."
        }
        guard s.permission != .ready else { return nil }
        switch (s.source, s.permission) {
        case (.chatHistory, .noData):
            return "Put a Claude or ChatGPT export (.json or .zip) in \(shownPath(ChatHistoryImporter.importsDir)), then reopen this tab."
        case (.voiceRecording, .noData):
            return "Put recordings (.m4a, .wav, .mp3, .caf, .aiff or .aac) in \(shownPath(VoiceRecordingsIngester.voiceDir)), then reopen this tab."
        case (.notes, .unknown):
            return "Grux can tell whether it may read Notes only while Notes is running. Open the Notes app, then reopen this tab."
        case (_, .noData):
            return "Grux found nothing in it to read yet."
        case (_, .unknown):
            return "Not checked yet. Reopen this tab to check."
        default:
            return s.permission.humanReason
        }
    }

    /// The note as a sentence: its own closing mark kept, a period added only when it
    /// has none. Wave 63 round 7 P3 16: "IMAP timed out (FETCH).. Reopen this tab".
    static func sentence(_ note: String) -> String {
        guard let last = note.last else { return note }
        return ".!?\u{2026}".contains(last) ? note : note + "."
    }

    /// Gmail refused the password on the last read, no read has worked since, and
    /// the account is still there. The line names Remove and Add again (wave 66
    /// round 4); since wave 75 round 3 adding the same address alone also
    /// updates the account (`EmailAccountStore.formTarget`).
    static func loginRefused(_ s: CorpusCoordinator.SourceStatus) -> Bool {
        s.source == .gmailSent && s.lastRunAt != nil && s.lastRunPermission == .unknown
            && s.permission != .needsAccount && s.permission != .needsPassword
            && GmailSentIngester.refusedLogin(s.lastNote)
    }

    /// A read happened and no later probe disagrees with its verdict. A status saved
    /// before the verdict was kept (nil) counts as standing.
    static func readVerdictStands(_ s: CorpusCoordinator.SourceStatus) -> Bool {
        s.lastRunAt != nil && (s.lastRunPermission ?? s.permission) == s.permission
    }

    /// The folder an import source reads, for its Show folder button.
    static func folder(for source: CorpusSource) -> URL? {
        switch source {
        case .chatHistory:    return ChatHistoryImporter.importsDir
        case .voiceRecording: return VoiceRecordingsIngester.voiceDir
        default:              return nil
        }
    }

    private static func shownPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func corpusEmptyText(assistant: String, anySourceRan: Bool = false, anyRunning: Bool = false,
                                anyReady: Bool = false) -> String {
        if anyRunning {
            return "None of your own writing is indexed yet. Grux is reading the sources now."
        }
        if anySourceRan {
            // No claim about what the reads found: each way a read can fail fooled one
            // (wave 63 round 6). The rows say it.
            return "None of your own writing is indexed yet. Each source below says where it stands."
        }
        if anyReady {
            return "None of your own writing is indexed yet. Index a source below to teach \(assistant) your voice from it; nothing is read until you do."
        }
        return "None of your own writing is indexed. No source below can be read yet, so \(assistant) cannot learn your voice from them; each says why."
    }

    static let lanesTitle = "REMEMBERED FROM CHAT"

    static func lanesCaption(assistant: String) -> String? {
        "What you and \(assistant) said in chat, and what \(assistant) learned while you used Grux, kept on this Mac while Memory is on. Separate from your own writing above."
    }

    static func laneLabel(_ kind: SemanticMemoryKind, assistant: String) -> String {
        switch kind {
        case .chatUser:      return "you said"
        case .chatAssistant: return "\(assistant) said"
        case .ambient:       return "heard"
        case .focus:         return "screen"
        case .fact:          return "facts"
        case .web:           return "web"
        case .corpus:        return "corpus"
        }
    }

    var body: some View {
        JaxSection(title: "Memory", icon: "internaldrive.fill", tint: GruxTheme.successMint) {
            VStack(alignment: .leading, spacing: 12) {
                corpusHeadline

                if sources.allSatisfy({ $0.totalIndexed == 0 }) {
                    JaxEmptyLine(icon: "tray",
                                 text: Self.corpusEmptyText(assistant: UserIdentity.assistantName,
                                                                 anySourceRan: sources.contains { $0.lastRunAt != nil },
                                                                 anyRunning: sources.contains { $0.isRunning },
                                                                 anyReady: sources.contains { Self.canIndex($0) }))
                }
                // Listed even while nothing is indexed: each readable source carries
                // its own Index button, the one place after first run to start it.
                VStack(spacing: 6) {
                    ForEach(sources) { source in
                        corpusRow(source)
                    }
                }

                if !hotLanes.isEmpty {
                    Divider().overlay(Color.white.opacity(0.06))
                    hotLanesView
                }
            }
        }
    }

    private var corpusHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(corpusTotal.formatted())")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(Self.corpusHeadlineText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GruxTheme.textSecondary)
            Spacer()
        }
    }

    private func corpusRow(_ source: CorpusCoordinator.SourceStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 9) {
            Circle()
                .fill(sourceTint(source).opacity(source.totalIndexed > 0 ? 0.9 : 0.3))
                .frame(width: 7, height: 7)
            Text(source.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(source.totalIndexed > 0 ? GruxTheme.textPrimary : GruxTheme.textTertiary)
            if source.isRunning {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Text(source.totalIndexed > 0 ? source.totalIndexed.formatted() : Self.statusHint(source))
                .font(.system(size: 11, weight: source.totalIndexed > 0 ? .heavy : .medium, design: source.totalIndexed > 0 ? .rounded : .default))
                .foregroundStyle(source.totalIndexed > 0 ? sourceTint(source) : GruxTheme.textTertiary)
            if Self.canIndex(source) {
                Button("Index") {
                    Task { @MainActor in _ = await CorpusCoordinator.shared.run(source.source) }
                }
                .controlSize(.small)
                .help("Read \(source.displayName) and learn how you write from it")
            }
        }
            // Why a source cannot be read, on the row, not only on hover.
            if let need = Self.needLine(source) {
                Text(need)
                    .font(.system(size: 10.5))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                if source.permission == .noData, let dir = Self.folder(for: source.source) {
                    Button("Show folder") {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    .controlSize(.small)
                    .padding(.leading, 16)
                }
            }
        }
        .help(source.lastNote)
    }

    /// The chip beside a row with nothing indexed. It said "not run" for every unknown
    /// state, beside "Last read: Sent sync error" after a read that failed (wave 63).
    static func statusHint(_ source: CorpusCoordinator.SourceStatus) -> String {
        if loginRefused(source), !source.isRunning { return "login failed" }
        switch source.permission {
        case .ready:   return source.isRunning ? "indexing" : "ready"
        case .noData:  return "no data"
        case .unknown: return readVerdictStands(source) ? "read failed" : "not checked"
        // D192: no account is something to set up, not a permission to grant.
        case .needsAccount: return "not set up"
        case .needsPassword: return "no password"
        case .needsKeychain: return "keychain locked"
        default:       return "needs access"
        }
    }

    private func sourceTint(_ source: CorpusCoordinator.SourceStatus) -> Color {
        switch source.source {
        case .gmailSent:      return GruxTheme.accentCo
        case .iMessage:       return GruxTheme.successMint
        case .notes:          return GruxTheme.warnAmber
        case .chatHistory:    return GruxTheme.accentPrimaryLight
        case .voiceRecording: return GruxTheme.accentPrimary
        }
    }

    private var hotLanesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.lanesTitle)
                    .font(GruxTheme.Font.microCaps).kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                Text("\(Self.lanesTotal(semanticKinds).formatted()) total")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            if let caption = Self.lanesCaption(assistant: UserIdentity.assistantName) {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            JaxLaneChips(chips: hotLanes.map { (Self.laneLabel($0.0, assistant: UserIdentity.assistantName), $0.1) })
        }
    }
}

// Simple wrapping row of count chips for the hot lanes. Avoids a layout
// dependency; a single HStack with a Spacer is enough at this count.
private struct JaxLaneChips: View {
    let chips: [(String, Int)]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.prefix(6).enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 4) {
                    Text(chip.0.uppercased())
                        .font(GruxTheme.Font.microCaps).kerning(0.6)
                        .foregroundStyle(GruxTheme.textSecondary)
                    Text("\(chip.1.formatted())")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 5. Roadmap

// RoadmapStore items with a progress bar and per-item status. Newest tier order
// preserved. Shows the in-progress and not-started items being pushed; done
// items roll into the progress headline.
struct JaxRoadmapSection: View {
    let items: [RoadmapItem]
    let progress: (done: Int, inProgress: Int, total: Int)

    private var fraction: Double {
        progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
    }

    // Show in-progress first, then not-started, capped so the section stays tight.
    private var visible: [RoadmapItem] {
        let inProg = items.filter { $0.status == .inProgress }.sorted { $0.order < $1.order }
        let queued = items.filter { $0.status == .notStarted }.sorted { ($0.tier.rawValue, $0.order) < ($1.tier.rawValue, $1.order) }
        return Array((inProg + queued).prefix(6))
    }

    var body: some View {
        JaxSection(title: "Roadmap", icon: "map.fill", tint: GruxTheme.accentPrimaryLight) {
            VStack(alignment: .leading, spacing: 12) {
                progressBar

                if items.isEmpty {
                    JaxEmptyLine(icon: "map", text: "Roadmap is empty.")
                } else {
                    VStack(spacing: 7) {
                        ForEach(visible) { item in
                            roadmapRow(item)
                        }
                    }
                }
            }
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(progress.done) of \(progress.total) shipped")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                if progress.inProgress > 0 {
                    Text("\(progress.inProgress) in progress")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                }
                Spacer()
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(GruxTheme.accentPrimaryLight)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(GruxTheme.iridescent)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 7)
        }
    }

    private func roadmapRow(_ item: RoadmapItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.status.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusTint(item.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(item.tier.shortLabel.uppercased())
                .font(GruxTheme.Font.microCaps).kerning(0.6)
                .foregroundStyle(GruxTheme.textTertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.05)))
        }
    }

    private func statusTint(_ status: RoadmapStatus) -> Color {
        switch status {
        case .notStarted: return GruxTheme.textTertiary
        case .inProgress: return GruxTheme.accentPrimaryLight
        case .done:       return GruxTheme.successMint
        }
    }
}

// MARK: - 6. Guardrails (the five hard rules, stated plainly)

// Fixed rules, by design. These are the absolute lines the decision gate
// enforces; the only part that varies is the assistant name, read from the
// roster the person configured (D118: it once named the owner's own persona).
// Shown so the user (and anyone over their shoulder) can see, in one place,
// exactly what the clone will never do.
struct JaxGuardrailsSection: View {
    struct Rule: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private var rules: [Rule] { Self.rules(roster: CommsRosterStore.current, canSendMail: KeychainStore.exists(.resendApiKey)) }

    static func rules(roster: CommsRoster, canSendMail: Bool) -> [Rule] { [
        Rule(icon: "dollarsign.circle.fill", title: "Never moves money",
             detail: "No send, transfer, swap, or purchase, ever, on its own. The most it does is queue a spend for your one-click yes."),
        Rule(icon: "lock.doc.fill", title: "Never leaks the edge",
             detail: "Your documents, files, insights, and trade secrets never go to anyone outside. A send like that is refused, not queued for your OK."),
        Rule(icon: "megaphone.fill", title: "Never posts publicly as you",
             detail: "No Threads, no social publishing, no public statements in your name."),
        Rule(icon: "person.2.fill", title: "Always discloses correctly",
             detail: disclosure(roster: roster, canSendMail: canSendMail)),
        Rule(icon: "hand.raised.fill", title: "When unsure, it pauses and asks",
             detail: "Its default verdict past a guardrail is pause. It notifies you now and waits in the Jax HQ queue. It never guesses past a hard rule.")
    ] }

    // Who signs which mail. Without a Resend key, the one way Grux sends mail
    // (ResendClient refuses without it), no mail goes out, and the rule says so
    // before it says who would sign it (D187 item 3).
    static func disclosure(roster: CommsRoster, canSendMail: Bool) -> String {
        let who = roster.namesAssistant
            ? "business mail is signed as \(roster.businessName), your assistant, personal mail as you."
            : "business mail is signed by your assistant, personal mail by you."
        let rule = canSendMail
            ? who.prefix(1).uppercased() + who.dropFirst()
            : "Grux sends no mail until a Resend API key is added in Settings. Then " + who
        return rule + " It never blurs that line."
    }

    var body: some View {
        JaxSection(title: "Guardrails", icon: "shield.lefthalf.filled", tint: GruxTheme.warnAmber) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rules) { rule in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: rule.icon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GruxTheme.warnAmber)
                            .frame(width: 18)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.title)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(GruxTheme.textPrimary)
                            Text(rule.detail)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(GruxTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                            .strokeBorder(GruxTheme.warnAmber.opacity(0.14), lineWidth: 1)
                    )
                }
            }
        }
    }
}
