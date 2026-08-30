import SwiftUI
import AppKit

// Self-Upgrade tab: the Foundry's front door. Three panes:
//   1. Proposals: ranked UpgradeProposal cards with Accept / Reject / Copy.
//   2. Trust ladder: lane x domain tiles with tier, streak, and history.
//   3. Timeline: reverse-chron audit entries from FoundryTimelineStore.
// Data flows in through FoundryDashboardModel (display models pushed by the
// engine or integration glue); decisions flow back through its hooks.
struct SelfUpgradeView: View {
    @ObservedObject private var model = FoundryDashboardModel.shared
    @ObservedObject private var timeline = FoundryTimelineStore.shared

    private enum Pane: String, CaseIterable, Identifiable {
        case proposals = "Proposals"
        case trust = "Trust ladder"
        case timeline = "Timeline"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .proposals
    @State private var expandedEvidence: Set<String> = []
    @State private var copiedID: String?

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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 13, weight: .bold))
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
                emptyState(
                    icon: "hammer",
                    line: "No proposals yet. The next sense pass files them here.",
                    hint: "say: Grux, upgrade yourself"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: GruxSpacing.m) {
                        // Phase C: pending install-approval cards pin to the
                        // top. Renders nothing while the queue is empty.
                        FoundryApprovalsPanel()
                        ForEach(model.ranked) { card in
                            proposalCard(card)
                        }
                    }
                    .padding(GruxSpacing.l)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func proposalCard(_ card: FoundryProposalCardModel) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            // Title row + tier badge
            HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.s) {
                // Proposal prose is model written (FoundryEngine and RDWorker
                // both call a model), and nothing in Foundry/ scrubbed dashes,
                // so the house no-dash rule was unenforced on the whole
                // Self-Upgrade tab. Scrubbing at the RENDER boundary rather than
                // at generation covers every proposal already sitting in the
                // store, which is the lesson from Feature Review: a parse-time
                // fix cleans future rows and leaves the existing ones dirty.
                Text(DashSanitizer.stripDashesOnly(card.title))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(2)
                Spacer()
                tierBadge(card.tierRequired)
            }

            // Lane + domain + risk chips
            HStack(spacing: GruxSpacing.xs + 2) {
                tagChip(card.lane, color: GruxTheme.accentPrimary)
                tagChip(card.domain, color: GruxTheme.accentCo)
                riskChip(card.risk)
                if card.status != .pending {
                    statusChip(card.status)
                }
            }

            // Evidence (expandable)
            if !card.evidence.isEmpty {
                evidenceList(card)
            }

            // Expected gain + estimated cost
            if !card.expectedGain.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.xs + 1) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(GruxTheme.successMint)
                    Text(DashSanitizer.stripDashesOnly(card.expectedGain))
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(3)
                }
            }
            Text(FoundryFormat.estimatedCostLabel(usd: card.estimatedCostUSD))
                .font(GruxType.mono)
                .foregroundStyle(GruxTheme.textTertiary)

            // Actions
            if card.status == .pending {
                HStack(spacing: GruxSpacing.s) {
                    GruxChip(title: "ACCEPT", systemImage: "checkmark", style: .primary) {
                        acceptCard(card)
                    }
                    GruxChip(title: "REJECT", systemImage: "xmark", style: .destructive) {
                        model.reject(id: card.id)
                    }
                    GruxChip(title: copiedID == card.id ? "COPIED" : "COPY PROMPT", systemImage: "doc.on.doc", style: .secondary) {
                        copyPrompt(card)
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(card.status == .pending ? 0.05 : 0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(
                    card.status == .pending
                        ? GruxTheme.accentPrimary.opacity(0.25)
                        : Color.white.opacity(0.07),
                    lineWidth: 1
                )
        )
        .opacity(card.status == .pending ? 1 : 0.6)
    }

    private func evidenceList(_ card: FoundryProposalCardModel) -> some View {
        let expanded = expandedEvidence.contains(card.id)
        let shown = expanded ? (card.evidence, 0) : FoundryFormat.truncateEvidence(card.evidence)
        return VStack(alignment: .leading, spacing: GruxSpacing.xs - 1) {
            ForEach(Array(shown.0.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.xs + 1) {
                    Circle()
                        .fill(GruxTheme.textTertiary)
                        .frame(width: 3, height: 3)
                        .padding(.top, 4)
                    Text(DashSanitizer.stripDashesOnly(line))
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if shown.1 > 0 || expanded {
                Button {
                    if expanded { expandedEvidence.remove(card.id) }
                    else { expandedEvidence.insert(card.id) }
                } label: {
                    Text(expanded ? "show less" : "+\(shown.1) more")
                        .font(GruxType.microCaps)
                        .kerning(1.0)
                        .foregroundStyle(GruxTheme.accentCo)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(GruxSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
    }

    private func acceptCard(_ card: FoundryProposalCardModel) {
        if let prompt = model.accept(id: card.id), !prompt.isEmpty {
            Self.copyToClipboard(prompt)
            copiedID = card.id
        }
    }

    private func copyPrompt(_ card: FoundryProposalCardModel) {
        guard !card.readyPrompt.isEmpty else { return }
        Self.copyToClipboard(card.readyPrompt)
        copiedID = card.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if copiedID == card.id { copiedID = nil }
        }
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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

    private func tierBadge(_ tier: Int) -> some View {
        Text(FoundryFormat.tierName(tier))
            .font(GruxType.microCaps)
            .kerning(1.0)
            .foregroundStyle(Self.tierColor(tier))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(
                Capsule().stroke(Self.tierColor(tier).opacity(0.5), lineWidth: 0.8)
            )
    }

    static func tierColor(_ tier: Int) -> Color {
        switch tier {
        case 0: return GruxTheme.textSecondary
        case 1: return GruxTheme.accentCo
        default: return GruxTheme.successMint
        }
    }

    private func tagChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GruxType.microCaps)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func riskChip(_ risk: String) -> some View {
        let color: Color
        switch risk.lowercased() {
        case "high", "protected": color = GruxTheme.destructiveRose
        case "medium", "med": color = GruxTheme.warnAmber
        default: color = GruxTheme.successMint
        }
        return Text(risk.lowercased() == "protected" ? "PROTECTED" : "\(risk.uppercased()) RISK")
            .font(GruxType.microCaps)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func statusChip(_ status: FoundryProposalCardStatus) -> some View {
        let color: Color = status == .accepted ? GruxTheme.successMint : GruxTheme.warnAmber
        return Text(status.rawValue.uppercased())
            .font(GruxType.microCaps)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 0.8))
    }

    private func emptyState(icon: String, line: String, hint: String) -> some View {
        // Voice hints arrive already prefixed with "say: " here, so strip that
        // marker and pass the bare phrase to the shared primitive, which adds
        // its own italic `say: "..."` rendering.
        let phrase = hint.replacingOccurrences(of: "say: ", with: "")
        return GruxEmptyState(icon: icon, line: line, voiceHint: phrase)
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
