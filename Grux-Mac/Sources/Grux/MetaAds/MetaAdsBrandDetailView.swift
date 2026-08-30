import SwiftUI

// Level 1: the brand drill. A segmented control switches between calm
// sub-surfaces so the brand view is never a wall. OVERVIEW composes the KPI
// strip, pacing bars, forecast, this brand's attention slice, and the mode
// control. The other segments mount the sibling components.
struct MetaAdsBrandDetailView: View {
    let brand: MetaAdsBrand
    let snapshotMode: String
    var onBack: () -> Void = { }
    var onSelectAd: (ActiveAd) -> Void = { _ in }

    @State private var segment: MetaAdsBrandSegment = .overview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backBar
                segmentPicker
                switch segment {
                case .overview: overview
                case .ads: MetaAdsActiveAdTable(ads: brand.activeAds, onSelectAd: onSelectAd)
                case .creative: MetaAdsCreativeGallery(ads: brand.activeAds, onSelectAd: onSelectAd)
                case .lineage:
                    VStack(alignment: .leading, spacing: 16) {
                        MetaAdsConfidenceReadout(families: brand.confidence)
                        MetaAdsLineageTree(nodes: brand.lineageNodes)
                    }
                case .journal: MetaAdsJournalView()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GruxTheme.base)
    }

    private var backBar: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Fleet").font(GruxTheme.Font.microCaps)
                }
                .foregroundStyle(GruxTheme.textSecondary)
            }
            .buttonStyle(.plain)
            Text(brand.displayName).font(GruxTheme.Font.title).foregroundStyle(GruxTheme.textPrimary)
            Spacer()
            SendToClaudeButton(scope: .brand, label: brand.displayName, brand: brand.slug ?? brand.id, compact: true)
        }
    }

    private var segmentPicker: some View {
        HStack(spacing: 6) {
            ForEach(MetaAdsBrandSegment.allCases, id: \.self) { s in
                Button { segment = s } label: {
                    Text(s.label.uppercased())
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(segment == s ? GruxTheme.base : GruxTheme.textSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(segment == s ? GruxTheme.accentCo : Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Until the brand is live, the onboarding checklist leads the overview
            // so the path to live ads is the first thing in view.
            if let onboarding = brand.onboarding, !brand.isBootstrapped {
                MetaAdsOnboardingCard(
                    brandKey: brand.slug ?? brand.id,
                    brandName: brand.displayName,
                    onboarding: onboarding
                )
            }
            kpiStrip
            pacing
            MetaAdsForecastCard(forecast: brand.forecast)
            if !brand.attention.isEmpty {
                MetaAdsAttentionQueue(items: brand.attention)
            }
            MetaAdsModeControl(brand: MetaAdsBrandState(brand: brand, snapshotMode: snapshotMode))
                .padding(13)
                .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).fill(Color.white.opacity(0.04)))
        }
    }

    private var kpiStrip: some View {
        let k = brand.kpis
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            kpiTile("Spend today", MetaAdsFormat.dollars(k.spendTodayCents), "dollarsign.circle.fill")
            kpiTile("Spend week", MetaAdsFormat.dollars(k.spendWeekCents), "calendar")
            kpiTile("Conversions", MetaAdsFormat.count(k.conversions), "cart.fill")
            kpiTile("CPA", MetaAdsFormat.dollarsOpt(k.cpaCents), "target")
            kpiTile("CTR", MetaAdsFormat.pct2(k.ctr), "percent")
            kpiTile("ROAS", MetaAdsFormat.ratio(k.roas), "chart.line.uptrend.xyaxis")
            kpiTile("Impressions", MetaAdsFormat.count(k.impressions), "eye.fill")
            kpiTile("Clicks", MetaAdsFormat.count(k.clicks), "cursorarrow.click")
        }
    }

    private func kpiTile(_ label: String, _ value: String, _ icon: String) -> some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(GruxTheme.accentCo)
                    Text(label.uppercased()).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
                }
                Text(value).font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(GruxTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 66)
    }

    private var pacing: some View {
        VStack(spacing: 12) {
            MetaAdsPacingBar(label: "Today", spentCents: brand.kpis.spendTodayCents,
                             capCents: brand.pacing.dailyCapCents,
                             softCapCents: MetaAdsCaps.effectiveDailyBudgetCents)
            MetaAdsPacingBar(label: "This week", spentCents: brand.kpis.spendWeekCents,
                             capCents: brand.pacing.weeklyCapCents)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).fill(Color.white.opacity(0.04)))
    }
}

enum MetaAdsBrandSegment: String, CaseIterable {
    case overview, ads, creative, lineage, journal
    var label: String { rawValue }
}
