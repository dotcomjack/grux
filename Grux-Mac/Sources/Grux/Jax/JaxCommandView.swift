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
                    semanticKinds: memory.countByKind(),
                    semanticTotal: memory.totalCount
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
                MetaAdsEyebrow(text: "The control room for your clone", tint: GruxTheme.accentPrimaryLight)
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
        case .observe:  return "OBSERVE: \(UserIdentity.assistantName) plans the move and queues it to Jax HQ for your one-tap yes. Still nothing runs unprompted."
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
// template + budget as $N), and an honest status badge: SIMULATED when nothing
// ran (the default), DISPATCHED only when run.executed is true.
struct JaxGoalPursuitSection: View {
    let runs: [GoalPursuitRun]
    let isRunning: Bool

    private var recent: [GoalPursuitRun] { Array(runs.prefix(8)) }

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
                    ForEach(recent) { run in
                        JaxRunCard(run: run)
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

private struct JaxRunCard: View {
    let run: GoalPursuitRun

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
                statusBadge
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
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle").font(.system(size: 10))
                    Text("No action worth taking this cycle.")
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
    // Everything else is SIMULATED, the plan existed but nothing ran.
    private var statusBadge: some View {
        let dispatched = run.executed
        let tint = dispatched ? GruxTheme.successMint : GruxTheme.textSecondary
        let label = dispatched ? "DISPATCHED" : "SIMULATED"
        let icon = dispatched ? "paperplane.fill" : "circle.dashed"
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(label).font(GruxTheme.Font.microCaps).kerning(0.8)
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
                Text(MetaAdsFormat.dollars(Int((action.budgetUSD * 100).rounded())))
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
    let semanticTotal: Int

    private var corpusTotal: Int { sources.reduce(0) { $0 + $1.totalIndexed } }

    // Hot lanes, biggest first, excluding the uncapped corpus lane (shown above).
    private var hotLanes: [(SemanticMemoryKind, Int)] {
        semanticKinds
            .filter { $0.key != .corpus && $0.value > 0 }
            .sorted { $0.value > $1.value }
    }

    var body: some View {
        JaxSection(title: "Memory", icon: "internaldrive.fill", tint: GruxTheme.successMint) {
            VStack(alignment: .leading, spacing: 12) {
                corpusHeadline

                if sources.allSatisfy({ $0.totalIndexed == 0 }) {
                    JaxEmptyLine(icon: "tray",
                                 text: "No corpus indexed yet. Run a corpus sweep to teach \(UserIdentity.assistantName) your voice from your own writing.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(sources) { source in
                            corpusRow(source)
                        }
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
            Text("voice corpus items indexed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GruxTheme.textSecondary)
            Spacer()
        }
    }

    private func corpusRow(_ source: CorpusCoordinator.SourceStatus) -> some View {
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
            Text(source.totalIndexed > 0 ? source.totalIndexed.formatted() : statusHint(source))
                .font(.system(size: 11, weight: source.totalIndexed > 0 ? .heavy : .medium, design: source.totalIndexed > 0 ? .rounded : .default))
                .foregroundStyle(source.totalIndexed > 0 ? sourceTint(source) : GruxTheme.textTertiary)
        }
        .help(source.lastNote)
    }

    private func statusHint(_ source: CorpusCoordinator.SourceStatus) -> String {
        switch source.permission {
        case .ready:   return source.isRunning ? "indexing" : "ready"
        case .noData:  return "no data"
        case .unknown: return "not run"
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
                Text("HOT SEMANTIC LANES")
                    .font(GruxTheme.Font.microCaps).kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                Text("\(semanticTotal.formatted()) total")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            JaxLaneChips(chips: hotLanes.map { ($0.0.laneLabel, $0.1) })
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

private extension SemanticMemoryKind {
    var laneLabel: String {
        switch self {
        case .chatUser:      return "you"
        case .chatAssistant: return "jax"
        case .ambient:       return "heard"
        case .focus:         return "screen"
        case .fact:          return "facts"
        case .web:           return "web"
        case .corpus:        return "corpus"
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

// Static, by design. These are the absolute lines from Jax's persona, the same
// ones the decision gate enforces. Shown so the user (and anyone over their
// shoulder) can see, in one place, exactly what the clone will never do.
struct JaxGuardrailsSection: View {
    private struct Rule: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private let rules: [Rule] = [
        Rule(icon: "dollarsign.circle.fill", title: "Never moves money",
             detail: "No send, transfer, swap, or purchase, ever, on its own. The most it does is queue a spend for your one-tap yes."),
        Rule(icon: "lock.doc.fill", title: "Never leaks the edge",
             detail: "Your documents, files, insights, and trade secrets never go to anyone outside. The empire's edge stays inside."),
        Rule(icon: "megaphone.fill", title: "Never posts publicly as you",
             detail: "No Threads, no social publishing, no public statements in your name."),
        Rule(icon: "person.2.fill", title: "Always discloses correctly",
             detail: "Outbound mail is signed as Sarah for business, as you for personal. It never blurs that line."),
        Rule(icon: "hand.raised.fill", title: "When unsure, it pauses and asks",
             detail: "Its default verdict past a guardrail is pause. It notifies you now and waits in the Jax HQ queue. It never guesses past a hard rule.")
    ]

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
