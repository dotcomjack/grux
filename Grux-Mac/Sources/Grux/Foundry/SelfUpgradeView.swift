import SwiftUI
import AppKit

// Self-Upgrade tab: the Foundry's front door. Three panes:
//   1. Proposals: ranked cards, each saying what to do next: Build it (with
//      the subscription that powers it), Copy handoff for your agent, Not now.
//   2. Trust ladder: lane x domain tiles with tier, streak, and history.
//   3. Timeline: reverse-chron audit entries from FoundryTimelineStore.
// Data flows in through FoundryDashboardModel (display models pushed by the
// engine or integration glue); decisions flow back through its hooks. What a
// card offers is decided by FoundryDirection from measured state, never here.
struct SelfUpgradeView: View {
    @ObservedObject private var model = FoundryDashboardModel.shared
    @ObservedObject private var timeline = FoundryTimelineStore.shared
    @ObservedObject private var account = AccountSwitcher.shared
    @ObservedObject private var approvals = FoundryApprovalStore.shared
    @ObservedObject private var appState = AppState.shared

    private enum Pane: String, CaseIterable, Identifiable {
        case proposals = "Proposals"
        case trust = "Trust ladder"
        case timeline = "Timeline"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .proposals
    @State private var copiedID: String?
    // Two filesystem facts the card's direction depends on: is the claude
    // CLI on this Mac (read once per appearance), and does this install know
    // where its source is (kept live while the pane is visible, so a
    // checkout that comes back re-arms Build it with no tab reload).
    @State private var cliInstalled = false
    @StateObject private var source = SourceCheckoutWatch()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch pane {
            case .proposals: proposalsPane
            case .trust: trustPane
            case .timeline: timelinePane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            cliInstalled = AccountSwitcher.locateClaudeBinary() != nil
            await account.refreshActiveStatus()
        }
        .task { await source.watch() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: "hammer.fill")
                .font(GruxType.body.weight(.bold))
                .foregroundStyle(GruxTheme.accentPrimary)
            Text("Self-Upgrade")
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)
            if model.pendingCount > 0 {
                Text("\(model.pendingCount) pending")
                    .font(GruxType.microCaps)
                    .kerning(1.0)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GruxSpacing.s).padding(.vertical, 3)
                    .background(Capsule().fill(GruxTheme.iridescent))
            }
            Spacer()
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            // Ceiling, not a demand, matching UserCronEditorView and UsageView.
            // This header also carries a title and a pending badge, so at the
            // 599pt pane floor a rigid 280 leaves the row short and pushes the
            // badge out. A segmented picker falls back to its own segment
            // widths when squeezed, which is the correct thing to give up here.
            .frame(maxWidth: 280)
            .labelsHidden()
        }
        .padding(.horizontal, GruxSpacing.m)
        .padding(.vertical, GruxSpacing.s)
    }

    // MARK: - Pane 1: Proposals

    private var proposalsPane: some View {
        Group {
            if model.proposals.isEmpty {
                proposalsEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: GruxSpacing.m) {
                        // Phase C: pending install-approval cards pin to the
                        // top. Renders nothing while the queue is empty.
                        FoundryApprovalsPanel()
                        ForEach(model.ranked) { card in
                            FoundryProposalCard(
                                card: card,
                                action: FoundryDirection.primaryAction(readiness(for: card)),
                                copied: copiedID == card.id,
                                onPrimary: { runPrimary(for: card) },
                                onCopyHandoff: { copyHandoff(card) },
                                onNotNow: card.status == .pending ? { model.reject(id: card.id) } : nil,
                                onSeeJob: { appState.requestedTab = "agents" }
                            )
                        }
                    }
                    .padding(GruxSpacing.l)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // No proposals yet. The line says where they come from; the detail says
    // what is in the way when something is; the button does the next thing.
    private var proposalsEmptyState: some View {
        let auth = FoundryDirection.authState(checked: account.statusChecked, liveStatus: account.liveStatus)
        let detail: String? = !cliInstalled
            ? "Install Claude Code and sign in, and Grux can build them with your subscription."
            : (auth == .signedOut ? "Sign in to Claude and Grux can build them with your subscription." : nil)
        return GruxEmptyState(
            icon: "hammer",
            line: "No proposals yet. The next sense pass files them here.",
            detail: detail,
            ctaTitle: appState.config.foundryEnabled ? "Look for upgrades now" : "Turn on self-upgrade",
            ctaAction: {
                if !appState.config.foundryEnabled {
                    appState.config.foundryEnabled = true
                    appState.saveConfig()
                }
                FoundryEngine.shared.activate()
                _ = FoundryEngine.shared.triggerManualCycle()
            },
            voiceHint: "Grux, upgrade yourself"
        )
    }

    // Everything the card's direction depends on, measured here and decided
    // in FoundryDirection.
    private func readiness(for card: FoundryProposalCardModel) -> FoundryBuildReadiness {
        let id = UUID(uuidString: card.id)
        return FoundryBuildReadiness(
            auth: FoundryDirection.authState(checked: account.statusChecked, liveStatus: account.liveStatus),
            subscriptionType: account.liveStatus?.subscriptionType,
            cliInstalled: cliInstalled,
            foundryEnabled: appState.config.foundryEnabled,
            sourceAvailable: source.available,
            stage: card.stage,
            buildInFlight: id.map { FoundryEngine.shared.isBuilding($0) } ?? false,
            escalatedJobId: id.flatMap { FoundryEngine.shared.escalatedJobId(for: $0) },
            approvalPending: id.map { pid in approvals.pending.contains(where: { $0.request.proposalId == pid }) } ?? false
        )
    }

    private func runPrimary(for card: FoundryProposalCardModel) {
        switch FoundryDirection.primaryAction(readiness(for: card)) {
        case .build:
            build(card)
        case .enableAndBuild:
            appState.config.foundryEnabled = true
            appState.saveConfig()
            build(card)
        case .signIn:
            Task { @MainActor in
                _ = await account.signIn()
            }
        case .checkingSignIn, .noPaidPlan, .installCLI, .noSource, .inFlight,
             .awaitingApproval, .shipped, .notPursued, .rolledBack:
            break
        }
    }

    // The real build path. Accepting a pending card fires the engine's accept
    // hook, which starts the RDWorker rail; a card accepted earlier whose build
    // never ran (no source at the time, a relaunch) is kicked directly. The
    // engine is activated first because Settings says the loop takes effect
    // on next launch, and a person who just turned it on should not wait.
    //
    // The source is re-measured HERE, at the click, not only when the tab
    // appeared: a checkout that moved or vanished in between would otherwise
    // leave a Build it that does nothing, forever. When it is gone the card
    // flips to its "cannot build here" row and the timeline records why, and
    // SourceCheckoutWatch flips it back the moment the checkout returns.
    private func build(_ card: FoundryProposalCardModel) {
        guard let id = UUID(uuidString: card.id) else { return }
        guard FoundryEngine.resolveRepoRoot() != nil else {
            source.markMissing()
            if let proposal = ProposalStore.shared.proposal(id: id) {
                FoundryEngine.noteMissingSource(for: proposal)
            }
            return
        }
        FoundryEngine.shared.activate()
        if card.status == .pending {
            model.accept(id: card.id)
        } else if card.stage == .accepted {
            Task { @MainActor in
                await FoundryEngine.shared.buildAccepted(id: id)
            }
        }
    }

    // A real work order through the one line: it reports to its progress
    // log, ends at live, and shows under Optimize Grux like any other.
    private func copyHandoff(_ card: FoundryProposalCardModel) {
        guard WorkOrderStore.shared.createAndCopy(ProposalHandoff.request(for: card),
                                                  detail: ProposalHandoff.detail(for: card)) != nil else { return }
        copiedID = card.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copiedID == card.id { copiedID = nil }
        }
    }

    // MARK: - Pane 2: Trust ladder

    private var trustPane: some View {
        Group {
            if model.trustTiles.isEmpty {
                emptyState(
                    icon: "square.grid.3x3",
                    line: "No trust pairs tracked yet. Every (lane x domain) pair starts at Tier 0.",
                    hint: "say: Grux, show the trust ladder"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: GruxSpacing.m)], spacing: GruxSpacing.m) {
                        ForEach(model.trustTiles) { tile in
                            FoundryTrustTileView(tile: tile)
                        }
                    }
                    .padding(GruxSpacing.l)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pane 3: Timeline

    private var timelinePane: some View {
        Group {
            if timeline.entries.isEmpty {
                emptyState(
                    icon: "clock.arrow.circlepath",
                    line: "No audit entries yet. Every self-change lands here.",
                    hint: "say: Grux, what changed overnight"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(timeline.ordered) { entry in
                            timelineRow(entry)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.horizontal, GruxSpacing.l)
                    .padding(.vertical, GruxSpacing.s)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timelineRow(_ entry: FoundryTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: GruxSpacing.s) {
            Image(systemName: Self.timelineIcon(entry.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.timelineColor(entry.kind))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(3)
                }
                HStack(spacing: GruxSpacing.xs + 2) {
                    Text(FoundryFormat.relativeStamp(entry.date))
                        .font(GruxType.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                    if !entry.lane.isEmpty {
                        Text(entry.lane)
                            .font(GruxType.microCaps)
                            .foregroundStyle(GruxTheme.accentPrimary.opacity(0.85))
                    }
                    if !entry.domain.isEmpty {
                        Text(entry.domain)
                            .font(GruxType.microCaps)
                            .foregroundStyle(GruxTheme.accentCo.opacity(0.85))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, GruxSpacing.s)
    }

    static func timelineIcon(_ kind: FoundryTimelineKind) -> String {
        switch kind {
        case .cycle: return "arrow.triangle.2.circlepath"
        case .proposed: return "lightbulb"
        case .accepted: return "checkmark.circle"
        case .rejected: return "xmark.circle"
        case .built: return "hammer"
        case .landed: return "checkmark.seal.fill"
        case .rollback: return "arrow.uturn.backward.circle.fill"
        case .promotion: return "arrow.up.circle.fill"
        case .demotion: return "arrow.down.circle.fill"
        }
    }

    static func timelineColor(_ kind: FoundryTimelineKind) -> Color {
        switch kind {
        case .cycle, .proposed, .built: return GruxTheme.accentCo
        case .accepted, .landed, .promotion: return GruxTheme.successMint
        case .rejected, .demotion: return GruxTheme.warnAmber
        case .rollback: return GruxTheme.destructiveRose
        }
    }

    // MARK: - Shared bits

    static func tierColor(_ tier: Int) -> Color {
        switch tier {
        case 0: return GruxTheme.textSecondary
        case 1: return GruxTheme.accentCo
        default: return GruxTheme.successMint
        }
    }

    private func emptyState(icon: String, line: String, hint: String) -> some View {
        // Voice hints arrive already prefixed with "say: " here, so strip that
        // marker and pass the bare phrase to the shared primitive, which adds
        // its own italic `say: "..."` rendering.
        let phrase = hint.replacingOccurrences(of: "say: ", with: "")
        return GruxEmptyState(icon: icon, line: line, voiceHint: phrase)
    }
}

// MARK: - Proposal card

// One proposal, and what to do about it. Pure over its inputs so a capture can
// render every state (signed in, signed out, building, shipped) from fixtures.
struct FoundryProposalCard: View {
    let card: FoundryProposalCardModel
    let action: FoundryPrimaryAction
    let copied: Bool
    let onPrimary: () -> Void
    let onCopyHandoff: () -> Void
    var onNotNow: (() -> Void)? = nil
    var onSeeJob: (() -> Void)? = nil

    @State private var showAllEvidence = false
    @State private var showDetails = false

    /// The label column in the Details block: xl + l + xs of the spacing
    /// scale, which is the width "TRUST" and "STAGE" need in microCaps with
    /// the row's own gap after them, so the values line up in one column.
    static let detailLabelWidth: CGFloat = GruxSpacing.xl + GruxSpacing.l + GruxSpacing.xs

    private var settled: Bool {
        switch action {
        case .shipped, .notPursued, .rolledBack: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            // Proposal prose is model written and nothing in Foundry/ scrubbed
            // dashes at generation, so the house rule is enforced at the
            // render boundary, which also covers proposals already on disk.
            Text(DashSanitizer.stripDashesOnly(card.title))
                .font(GruxType.body.weight(.bold))
                .foregroundStyle(GruxTheme.textPrimary)
                .lineLimit(2)

            // One calm category chip, and the risk in plain words.
            HStack(spacing: GruxSpacing.s) {
                Text(card.lane)
                    .font(GruxType.microCaps)
                    .kerning(0.8)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .padding(.horizontal, GruxSpacing.s)
                    .padding(.vertical, GruxSpacing.xs)
                    .background(Capsule().fill(GruxTheme.chipFill))
                Text(FoundryFormat.riskLabel(card.risk))
                    .font(GruxType.caption)
                    .foregroundStyle(Self.riskColor(card.risk))
                Spacer()
                Button {
                    showDetails.toggle()
                } label: {
                    Text(showDetails ? "Hide details" : "Details")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showDetails ? "Hide details" : "Show details")
            }

            if showDetails { details }

            if !card.evidence.isEmpty { evidence }

            VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                if !card.expectedGain.isEmpty {
                    Text(DashSanitizer.stripDashesOnly(card.expectedGain))
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(3)
                }
                Text(FoundryFormat.costLine(usd: card.estimatedCostUSD))
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            actions
        }
        .padding(GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(settled ? GruxTheme.chipFill.opacity(0.5) : GruxTheme.chipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(
                    settled ? GruxTheme.textTertiary.opacity(0.22) : GruxTheme.accentPrimary.opacity(0.25),
                    lineWidth: 1
                )
        )
        .opacity(settled ? 0.7 : 1)
    }

    // The internal vocabulary, one click away rather than the first thing read.
    private var details: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            detailRow("Trust", FoundryFormat.tierPlain(card.tierRequired))
            detailRow("Area", card.domain)
            detailRow("Stage", Self.stageName(card.stage))
            detailRow("Rank", String(format: "%.2f", card.score))
        }
        .padding(GruxSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(GruxTheme.chipFill)
        )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.s) {
            Text(label)
                .font(GruxType.microCaps)
                .kerning(0.8)
                .foregroundStyle(GruxTheme.textTertiary)
                .frame(width: Self.detailLabelWidth, alignment: .leading)
            Text(value)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
        }
    }

    private var evidence: some View {
        let shown = showAllEvidence ? (card.evidence, 0) : FoundryFormat.truncateEvidence(card.evidence)
        return VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            ForEach(Array(shown.0.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.xs) {
                    Circle()
                        .fill(GruxTheme.textTertiary)
                        .frame(width: 3, height: 3)
                        .padding(.top, GruxSpacing.xs)
                    Text(FoundryFormat.evidenceLabel(DashSanitizer.stripDashesOnly(line)))
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if shown.1 > 0 || showAllEvidence {
                Button {
                    showAllEvidence.toggle()
                } label: {
                    Text(showAllEvidence ? "Show less" : "\(shown.1) more")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.accentCo)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(GruxSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(GruxTheme.base.opacity(0.6))
        )
    }

    // Primary first, then the handoff, then Not now. A settled card keeps
    // only the handoff, because a rejected idea is still one an agent can run.
    private var actions: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            if action.isActionable {
                primaryButton
            } else {
                statusRow
            }
            HStack(spacing: GruxSpacing.s) {
                GruxChip(
                    title: copied ? "COPIED" : "COPY HANDOFF FOR YOUR AGENT",
                    systemImage: copied ? "checkmark" : "doc.on.doc",
                    style: .secondary,
                    action: onCopyHandoff
                )
                .accessibilityLabel(copied ? "Copied" : "Copy handoff for your agent")
                .help("Copies a complete brief a coding agent can run: the proposal, every signal behind it, the files it touches and the house rules.")
                if let onNotNow, !settled {
                    GruxChip(title: "NOT NOW", systemImage: "xmark", style: .secondary, action: onNotNow)
                        .accessibilityLabel("Not now")
                        .help("Dismiss this proposal. Two dismissals in a row lower the trust tier for this lane.")
                }
                Spacer()
            }
        }
        .padding(.top, GruxSpacing.xs)
    }

    private var primaryButton: some View {
        Button(action: onPrimary) {
            HStack(spacing: GruxSpacing.s) {
                Image(systemName: Self.primaryGlyph(action))
                    .font(GruxType.body.weight(.bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(GruxType.body.weight(.bold))
                    if !action.subtitle.isEmpty {
                        Text(action.subtitle)
                            .font(GruxType.caption)
                            .opacity(0.85)
                    }
                }
                .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, GruxSpacing.m)
            .padding(.vertical, GruxSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .fill(GruxTheme.iridescent)
            )
            .shadow(color: GruxTheme.violetGlow(strong: true), radius: 6)
        }
        .buttonStyle(.plain)
        .gruxHoverable(cornerRadius: GruxTheme.Radius.chip, lift: 1.03, rimOnHover: 0, fillOnHover: 0)
        .accessibilityLabel(action.subtitle.isEmpty ? action.title : "\(action.title), \(action.subtitle)")
    }

    // Nothing to press: the card says where things stand instead.
    private var statusRow: some View {
        HStack(spacing: GruxSpacing.s) {
            if case .inFlight = action {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: Self.primaryGlyph(action))
                    .font(GruxType.body.weight(.bold))
                    .foregroundStyle(Self.statusColor(action))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(GruxType.body.weight(.bold))
                    .foregroundStyle(GruxTheme.textPrimary)
                if !action.subtitle.isEmpty {
                    Text(action.subtitle)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .inFlight(_, let jobId) = action, jobId != nil, let onSeeJob {
                Button("See the job", action: onSeeJob)
                    .buttonStyle(.plain)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.accentCo)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    static func primaryGlyph(_ action: FoundryPrimaryAction) -> String {
        switch action {
        case .build, .enableAndBuild: return "hammer.fill"
        case .checkingSignIn: return "person.crop.circle.badge.questionmark"
        case .signIn: return "person.crop.circle"
        case .noPaidPlan: return "person.crop.circle.badge.exclamationmark"
        case .installCLI: return "terminal"
        case .noSource: return "folder.badge.questionmark"
        case .inFlight: return "hammer"
        case .awaitingApproval: return "checkmark.seal"
        case .shipped: return "checkmark.seal.fill"
        case .notPursued: return "xmark.circle"
        case .rolledBack: return "arrow.uturn.backward.circle.fill"
        }
    }

    static func statusColor(_ action: FoundryPrimaryAction) -> Color {
        switch action {
        case .shipped, .awaitingApproval: return GruxTheme.successMint
        case .rolledBack: return GruxTheme.destructiveRose
        case .installCLI, .noSource: return GruxTheme.warnAmber
        default: return GruxTheme.textSecondary
        }
    }

    static func riskColor(_ risk: String) -> Color {
        switch risk.lowercased() {
        case "high", "protected": return GruxTheme.destructiveRose
        case "medium", "med": return GruxTheme.warnAmber
        default: return GruxTheme.successMint
        }
    }

    static func stageName(_ stage: FoundryProposalStage) -> String {
        switch stage {
        case .proposed: return "Proposed"
        case .accepted: return "Accepted"
        case .building: return "Building"
        case .verifying: return "Verifying"
        case .landed: return "Shipped"
        case .rejected: return "Not pursued"
        case .rolledBack: return "Rolled back"
        }
    }
}

// MARK: - Trust tile

private struct FoundryTrustTileView: View {
    let tile: FoundryTrustTileModel
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            HStack(spacing: GruxSpacing.xs + 1) {
                Text(tile.lane)
                    .font(GruxType.microCaps)
                    .kerning(0.8)
                    .foregroundStyle(GruxTheme.accentPrimary)
                Text("x")
                    .font(GruxType.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                Text(tile.domain)
                    .font(GruxType.microCaps)
                    .kerning(0.8)
                    .foregroundStyle(GruxTheme.accentCo)
                Spacer()
                if tile.pinnedTierZero {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(GruxTheme.destructiveRose)
                        .help("Pinned to Tier 0 forever (protected zone)")
                }
            }
            Text(FoundryFormat.tierName(tile.tier))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SelfUpgradeView.tierColor(tile.tier))
            // Streak toward promotion: 5 consecutive accepted, zero rollbacks.
            HStack(spacing: GruxSpacing.xs - 1) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i < tile.streak ? GruxTheme.successMint : Color.white.opacity(0.10))
                        .frame(width: 5, height: 5)
                }
                Text("streak \(tile.streak)/5")
                    .font(GruxType.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(.leading, 3)
                Spacer()
                if !tile.history.isEmpty {
                    Button {
                        showHistory.toggle()
                    } label: {
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Promote / demote history")
                }
            }
        }
        .padding(GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !tile.history.isEmpty { showHistory.toggle() }
        }
        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
            historyPopover
        }
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            GruxSectionLabel("Promote / demote history")
            ForEach(tile.history.sorted { $0.date > $1.date }) { event in
                HStack(alignment: .top, spacing: GruxSpacing.xs + 2) {
                    Image(systemName: event.isPromotion ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(event.isPromotion ? GruxTheme.successMint : GruxTheme.warnAmber)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tier \(event.fromTier) to Tier \(event.toTier)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(GruxTheme.textPrimary)
                        Text(event.reason)
                            .font(.system(size: 10))
                            .foregroundStyle(GruxTheme.textSecondary)
                        Text(FoundryFormat.relativeStamp(event.date))
                            .font(GruxType.microCaps)
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                }
            }
        }
        .padding(GruxSpacing.m)
        .frame(minWidth: 220, maxWidth: 280, alignment: .leading)
    }
}

// MARK: - Status badge (orb-adjacent)

// Small reusable pending-proposals badge. Mount next to the orb (or in the
// menu bar header): renders nothing at zero so it never adds chrome when the
// Foundry is quiet.
struct FoundryStatusBadge: View {
    @ObservedObject private var model = FoundryDashboardModel.shared
    var action: (() -> Void)? = nil

    var body: some View {
        if model.pendingCount > 0 {
            Button {
                action?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(model.pendingCount)")
                        .font(GruxType.microCaps)
                        .kerning(0.5)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(GruxTheme.iridescent))
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                .shadow(color: GruxTheme.violetGlow(), radius: 6)
            }
            .buttonStyle(.plain)
            .help("\(model.pendingCount) Foundry proposals pending")
        }
    }
}
