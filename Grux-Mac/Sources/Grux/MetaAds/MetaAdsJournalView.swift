import SwiftUI

// U3 (Meta Ads): the Qwen decision journal. A scrollable, newest-first list of
// the engine's decisions, each one a DecisionEntry the companion engine emitted into
// its snapshot. Every row shows what the engine decided (spawn / kill / scale /
// winner / hold), the Qwen rationale text behind it, the gates that passed, and
// crucially whether the decision was APPLIED (mode AUTONOMOUS acted on a live or
// bootstrapped account) or only RECORDED (OBSERVE / SIMULATE: the engine logged
// what it WOULD do but touched nothing).
//
// This is the transparency surface: in OBSERVE (the default, and the only
// possible mode for an account still on act_PLACEHOLDER) every entry is
// "recorded", which
// is exactly how you prove the loop's judgment before ever letting it spend.
//
// Type contracts (DecisionEntry, MetaAdsDecisionAction, MetaAdsSnapshot,
// MetaAdsStore) are owned by U1. This unit only READS them and adds new views.

// MARK: - Visual mapping for a decision action

// Color + icon + label for each action, drawn from GruxTheme so the journal
// reads at a glance: rose = something got killed, mint = a win or a scale-up,
// cyan = a fresh concept spawned, muted grey = a deliberate hold.
private extension MetaAdsDecisionAction {
    var tint: Color {
        switch self {
        case .kill:    return GruxTheme.destructiveRose
        case .winner:  return GruxTheme.successMint
        case .scale:   return GruxTheme.successMint
        case .spawn:   return GruxTheme.accentCo
        case .hold:    return GruxTheme.textSecondary
        }
    }

    var icon: String {
        switch self {
        case .kill:    return "xmark.octagon.fill"
        case .winner:  return "trophy.fill"
        case .scale:   return "arrow.up.right.circle.fill"
        case .spawn:   return "sparkles"
        case .hold:    return "pause.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .kill:    return "KILL"
        case .winner:  return "WINNER"
        case .scale:   return "SCALE"
        case .spawn:   return "SPAWN"
        case .hold:    return "HOLD"
        }
    }
}

// MARK: - Journal view

struct MetaAdsJournalView: View {
    @ObservedObject private var store = MetaAdsStore.shared

    // When embedded compactly in the Empire section we cap the row count.
    var maxRows: Int? = nil
    var showsHeader: Bool = true

    private var entries: [DecisionEntry] {
        let all = store.snapshot?.journal ?? []
        // Newest first. Entries carry an epoch so we sort on that, stable.
        let sorted = all.sorted { $0.atEpoch > $1.atEpoch }
        if let cap = maxRows { return Array(sorted.prefix(cap)) }
        return sorted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader { header }

            if entries.isEmpty {
                emptyState
            } else if maxRows != nil {
                // Compact embed: a plain VStack, the parent already scrolls.
                VStack(spacing: 8) {
                    ForEach(entries) { row($0) }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { row($0) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait.fill")
                .foregroundStyle(GruxTheme.accentCo)
            Text("Decision Journal").font(GruxTheme.Font.title)
            Spacer()
            Text("\(entries.count) entries")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private func row(_ e: DecisionEntry) -> some View {
        let tint = e.actionKind.tint
        return VStack(alignment: .leading, spacing: 6) {
            // Top line: action badge, brand, applied/recorded, timestamp.
            HStack(spacing: 8) {
                actionBadge(e.actionKind)
                Text(e.brandLabel.uppercased())
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.1)
                    .foregroundStyle(GruxTheme.textSecondary)
                appliedIndicator(applied: e.applied)
                Spacer()
                Text(relativeTime(e.atEpoch))
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            // The Qwen rationale, the why behind the call.
            Text(e.rationaleText)
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Optional node / lineage subject (which ad or concept this hit).
            if let subject = e.subject, !subject.isEmpty {
                Text(subject)
                    .font(GruxTheme.Font.mono)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // The gates that passed, as small chips, so the reasoning is auditable.
            if !e.gatesPassed.isEmpty {
                gatesRow(e.gatesPassed, tint: tint)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // A thin accent spine on the left edge, color-coded by action.
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 6)
        }
    }

    private func actionBadge(_ action: MetaAdsDecisionAction) -> some View {
        HStack(spacing: 4) {
            Image(systemName: action.icon).font(.system(size: 10, weight: .bold))
            Text(action.label).font(GruxTheme.Font.microCaps).kerning(1.0)
        }
        .foregroundStyle(action.tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(action.tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(action.tint.opacity(0.35), lineWidth: 0.8))
    }

    // APPLIED vs RECORDED: the single most important honesty bit in OBSERVE mode.
    private func appliedIndicator(applied: Bool) -> some View {
        let color = applied ? GruxTheme.warnAmber : GruxTheme.textTertiary
        let text = applied ? "APPLIED" : "RECORDED"
        let icon = applied ? "bolt.fill" : "eye.fill"
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(GruxTheme.Font.microCaps).kerning(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .help(applied
              ? "AUTONOMOUS mode applied this to a bootstrapped account."
              : "OBSERVE / SIMULATE: the engine logged what it would do, no live action taken.")
    }

    private func gatesRow(_ gates: [String], tint: Color) -> some View {
        FlowChips(items: gates) { gate in
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy))
                Text(gate)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint.opacity(0.95))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.10)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.largeTitle)
                .foregroundStyle(GruxTheme.textTertiary)
            Text("No decisions yet")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
            Text("The engine logs every spawn, kill, scale, and hold here as the tick loop runs.")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private func relativeTime(_ epoch: Double) -> String {
        let now = Date().timeIntervalSince1970
        let delta = max(0, now - epoch)
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }
}

// MARK: - Tiny wrapping chip layout

// A minimal flow layout so the gate chips wrap instead of clipping. Uses the
// SwiftUI Layout protocol (macOS 13+, which Grux already targets elsewhere).
struct FlowChips<Item: Hashable, ChipContent: View>: View {
    let items: [Item]
    @ViewBuilder let chip: (Item) -> ChipContent

    var body: some View {
        MetaAdsFlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(items, id: \.self) { item in
                chip(item)
            }
        }
    }
}

struct MetaAdsFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                totalHeight += rowHeight + lineSpacing
                rows.append([])
                rowWidth = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append(view)
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        let width = (proposal.width == nil) ? rowWidth : maxWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
