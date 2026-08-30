import SwiftUI

// The Bayesian A/B readout: per concept family a P(B>A) bar against the 0.95
// winner bar, a DECIDED / gathering badge, leader vs control, and conversions
// observed (the gate context). The bar fills mint once past the winner bar,
// amber while it is still approaching it.
struct MetaAdsConfidenceReadout: View {
    let families: [FamilyConfidence]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetaAdsEyebrow(text: "A/B confidence", icon: "chart.bar.xaxis", tint: GruxTheme.accentCo)
            if families.isEmpty {
                Text("No open A/B tests.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
            } else {
                ForEach(families) { fam in
                    MetaAdsConfidenceRow(family: fam)
                }
            }
        }
    }
}

struct MetaAdsConfidenceRow: View {
    let family: FamilyConfidence

    private var past: Bool { family.pBeatsA >= family.winnerBar }
    private var tint: Color { past ? GruxTheme.successMint : GruxTheme.warnAmber }

    var body: some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(family.label ?? family.crid)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(family.decided ? "DECIDED" : "GATHERING")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(family.decided ? GruxTheme.successMint : GruxTheme.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((family.decided ? GruxTheme.successMint : GruxTheme.textTertiary).opacity(0.14)))
                }
                // P(B>A) bar with the winner bar marked.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, family.pBeatsA))))
                        // Winner bar reference at 0.95.
                        Rectangle().fill(GruxTheme.textPrimary.opacity(0.6))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * CGFloat(min(1, family.winnerBar)))
                    }
                }
                .frame(height: 8)
                HStack(spacing: 10) {
                    Text("P(B>A) \(MetaAdsFormat.prob(family.pBeatsA))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint)
                    Text("bar \(MetaAdsFormat.prob(family.winnerBar))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(GruxTheme.textTertiary)
                    Spacer()
                    Text("\(family.conversionsObserved) conv")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(GruxTheme.textTertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
