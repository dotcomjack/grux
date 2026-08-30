import SwiftUI

// The attention queue: the heart of the attention-first deck. Critical-first,
// severity-tinted rows, each carrying its one-click engine action and a Send to
// Claude. When the queue is empty it renders a single calm "All clear" line so
// the deck stays quiet when nothing needs the user.
struct MetaAdsAttentionQueue: View {
    let items: [AttentionItem]
    var onSelectTarget: (AttentionTarget) -> Void = { _ in }

    /// True when the snapshot behind `items` is the last one Grux managed to
    /// pull rather than a fresh one.
    ///
    /// AN EMPTY QUEUE IS NOT A HEALTH VERDICT WHEN THE PULL FAILED. It means
    /// "no alerts in a snapshot we could not refresh", and "the engine is
    /// running clean" is the strictly stronger claim, about a host we did not
    /// reach. Found by looking at the running app: on a machine with no ads
    /// service configured, the deck showed an amber outage banner naming the
    /// unset defaults key and, directly beneath it, a green check reading
    /// "All clear. The engine is running clean." The store already carried the
    /// fact (`MetaAdsStore.servingStale`, from the same classify() verdict the
    /// banner is drawn from); the view was simply never told, so the rule that
    /// stops absence being reported as health stopped at the banner and never
    /// reached the empty states beside it.
    var stale: Bool = false

    /// The rule in pure form, so a test can pin it without rendering SwiftUI.
    /// True only when the deck may state that the engine is healthy: no alerts
    /// AND the snapshot they came from is current.
    static func claimsHealth(itemCount: Int, stale: Bool) -> Bool {
        itemCount == 0 && !stale
    }

    private var reassuring: Bool {
        Self.claimsHealth(itemCount: items.count, stale: stale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: reassuring ? "checkmark.circle.fill"
                                : items.isEmpty ? "clock.arrow.circlepath" : "bell.badge.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(reassuring ? GruxTheme.successMint : GruxTheme.warnAmber)
                Text(reassuring ? "All clear"
                     : items.isEmpty ? "No alerts in the last snapshot" : "Needs you")
                    .font(GruxTheme.Font.body.weight(.bold))
                    .foregroundStyle(GruxTheme.textPrimary)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(GruxTheme.warnAmber)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(GruxTheme.warnAmber.opacity(0.16)))
                }
                Spacer()
            }

            if items.isEmpty {
                Text(reassuring
                     ? "The engine is running clean. Nothing needs your call right now."
                     : "This is the last snapshot Grux could pull, not a live check, so it says nothing about the engine right now.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
            } else {
                ForEach(items.sorted(by: { $0.severity > $1.severity })) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: AttentionItem) -> some View {
        let tint = item.severity.tint
        return GruxGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: item.kind.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                    Text(item.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(item.kind.label)
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.14)))
                }
                Text(item.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let action = item.suggestedAction {
                        MetaAdsActionBar(suggested: action,
                                         brand: action.brand ?? item.brand,
                                         nodeId: action.nodeId ?? item.target?.nodeId,
                                         crid: action.crid ?? item.target?.crid,
                                         compact: true)
                    }
                    Spacer(minLength: 0)
                    SendToClaudeButton(
                        scope: .attention,
                        label: item.target?.label ?? item.title,
                        brand: item.brand,
                        nodeId: item.target?.nodeId,
                        crid: item.target?.crid,
                        bakedPrompt: item.sendToClaudePrompt,
                        compact: true
                    )
                    if let target = item.target {
                        Button { onSelectTarget(target) } label: {
                            Image(systemName: "arrow.forward.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(GruxTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Open the affected ad or brand")
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .strokeBorder(tint.opacity(item.severity == .critical ? 0.45 : 0.0), lineWidth: 1)
        )
    }
}
