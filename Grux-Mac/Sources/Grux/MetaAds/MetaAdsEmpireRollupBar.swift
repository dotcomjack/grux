import SwiftUI

// The empire roll-up strip on the fleet deck: cross-brand totals (spend today /
// week, blended CPA / ROAS, winners, live ads, attention count), the reused
// Telegram digest control, and a single empire-wide Send to Claude.
struct MetaAdsEmpireRollupBar: View {
    let rollup: EmpireRollup?
    var attentionCount: Int = 0

    var body: some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    MetaAdsEyebrow(text: "Empire roll-up", icon: "chart.bar.doc.horizontal.fill", tint: GruxTheme.accentCo)
                    Spacer()
                    SendToClaudeButton(scope: .empire, compact: true)
                }

                let r = rollup
                // Six flexible columns kept SIX columns at every width, so at
                // the 599pt detail-pane floor each tile got about 90pt and
                // "BLENDED ROAS" clipped even against its own 0.7
                // minimumScaleFactor. The wrap has to be explicit rather than
                // adaptive: `.adaptive(minimum: 110)` MAXIMISES column count, so
                // on a 1140pt card it produces 9 columns, packs the 6 tiles into
                // the left 6 at ~117pt each and leaves ~380pt of dead space on
                // the right. Naming the three layouts and letting ViewThatFits
                // pick keeps a full-width even row on an ordinary window and a
                // balanced 3 + 3 or 2 + 2 + 2 as the pane narrows.
                ViewThatFits(in: .horizontal) {
                    rollupGrid(columns: 6, r)
                    rollupGrid(columns: 3, r)
                    rollupGrid(columns: 2, r)
                }

                Divider().overlay(GruxTheme.iridescentRim).opacity(0.5)

                HStack(spacing: 12) {
                    MetaAdsDigestControl()
                    Spacer()
                    if attentionCount > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(GruxTheme.warnAmber)
                            Text("\(attentionCount) need you")
                                .font(GruxTheme.Font.microCaps)
                                .foregroundStyle(GruxTheme.warnAmber)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(GruxTheme.warnAmber.opacity(0.14)))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The six roll-up tiles at a named column count. ViewThatFits picks the
    /// widest layout that actually fits, so the count is a deliberate choice
    /// rather than whatever an adaptive grid maximises into.
    private func rollupGrid(columns: Int, _ r: EmpireRollup?) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
                  spacing: 10) {
            tile("Spend today", MetaAdsFormat.dollarsOpt(r?.totalSpendTodayCents), GruxTheme.textPrimary)
            tile("Spend week", MetaAdsFormat.dollarsOpt(r?.totalSpendWeekCents), GruxTheme.textPrimary)
            tile("Blended CPA", MetaAdsFormat.dollarsOpt(r?.blendedCpaCents), GruxTheme.textPrimary)
            tile("Blended ROAS", MetaAdsFormat.ratio(r?.blendedRoas), GruxTheme.successMint)
            tile("Winners", "\(r?.winnerCount ?? 0)", GruxTheme.successMint)
            tile("Live ads", "\(r?.liveAdCount ?? 0)", GruxTheme.accentCo)
        }
    }

    private func tile(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
