import SwiftUI

// JaxActivitySection: a recent timeline of what Jax actually did, derived from the
// approval queue's full history (ApprovalQueue.shared.items: queued / approved /
// skipped) plus the latest briefing spoken. This is real persisted state, so the
// log is populated without depending on a separate activity store. The decision
// gate routing every guardrailed action through the queue means this timeline is an
// honest audit trail of the clone's autonomous moves.
struct JaxActivitySection: View {
    let history: [PendingApproval]
    let latestBriefing: Briefing?

    private static let visibleCap = 24

    // Build a unified, newest-first timeline from the queue history and the last
    // briefing. Resolved items use resolvedAt; pending items use createdAt.
    private var entries: [JaxActivityEntry] {
        var out: [JaxActivityEntry] = []

        for item in history {
            let summary = item.action.summary.isEmpty ? "an action" : item.action.summary
            let brand = item.action.brand
            switch item.state {
            case .pending:
                out.append(JaxActivityEntry(id: "q-\(item.id)", kind: .queued, text: "Queued: \(summary)", brand: brand, at: item.createdAt))
            case .approved:
                out.append(JaxActivityEntry(id: "a-\(item.id)", kind: .approved, text: "Approved: \(summary)", brand: brand, at: item.resolvedAt ?? item.createdAt))
            case .skipped:
                out.append(JaxActivityEntry(id: "s-\(item.id)", kind: .skipped, text: "Skipped: \(summary)", brand: brand, at: item.resolvedAt ?? item.createdAt))
            }
        }

        if let b = latestBriefing {
            let slot = b.slot == .morning ? "morning" : (b.slot == .night ? "night" : "on-demand")
            out.append(JaxActivityEntry(id: "b-\(b.id)", kind: .spoke, text: "Spoke the \(slot) briefing", brand: nil, at: b.date))
        }

        return out.sorted { $0.at > $1.at }
    }

    var body: some View {
        let entries = self.entries
        return JaxSection(
            title: "Activity log",
            icon: "list.bullet.rectangle.fill",
            tint: GruxTheme.textSecondary,
            count: entries.isEmpty ? nil : entries.count
        ) {
            if entries.isEmpty {
                JaxEmptyLine(icon: "clock.arrow.circlepath", text: "Nothing logged yet. \(UserIdentity.assistantName) records every move here as it works.")
            } else {
                let shown = Array(entries.prefix(Self.visibleCap))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, item in
                        JaxActivityRow(entry: item, isLast: idx == shown.count - 1)
                    }
                }
            }
        }
    }
}

// A flattened timeline entry. Kept local to the view layer: it is a projection of
// the real queue/briefing state, not a persisted model.
struct JaxActivityEntry: Identifiable {
    enum Kind {
        case queued, approved, skipped, spoke

        var icon: String {
            switch self {
            case .queued: return "tray.and.arrow.down.fill"
            case .approved: return "checkmark.seal.fill"
            case .skipped: return "xmark.seal.fill"
            case .spoke: return "waveform"
            }
        }

        var tint: Color {
            switch self {
            case .queued: return GruxTheme.warnAmber
            case .approved: return GruxTheme.successMint
            case .skipped: return GruxTheme.destructiveRose
            case .spoke: return GruxTheme.accentCo
            }
        }
    }

    let id: String
    let kind: Kind
    let text: String
    let brand: String?
    let at: Date
}

struct JaxActivityRow: View {
    let entry: JaxActivityEntry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timeline rail: dot + connecting line.
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(entry.kind.tint.opacity(0.18)).frame(width: 22, height: 22)
                    Image(systemName: entry.kind.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(entry.kind.tint)
                }
                if !isLast {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let brand = entry.brand, !brand.isEmpty { JaxBrandTag(brand: brand) }
                }
                Text(JaxTime.ago(entry.at))
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
    }
}
