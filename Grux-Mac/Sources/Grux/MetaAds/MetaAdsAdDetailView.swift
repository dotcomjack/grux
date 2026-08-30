import SwiftUI

// Level 2: the full ad readout. The creative, the one tested variable and value,
// the complete engine-crafted targeting, all KPIs, the cost-per-result
// sparkline, learning / fatigue / confidence / best segment, engine intent and
// proposed next action, the override action bar, the variant spawner, and a Send
// to Claude scoped to this ad.
struct MetaAdsAdDetailView: View {
    let ad: ActiveAd
    var onBack: () -> Void = { }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backBar
                header
                kpis
                if ad.costPerResultSeries.count >= 2 {
                    trendCard
                }
                signalsCard
                if let t = ad.targeting { targetingCard(t) }
                MetaAdsActionBar(suggested: nil, brand: ad.brand, nodeId: ad.id, crid: ad.crid)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).fill(Color.white.opacity(0.04)))
                MetaAdsVariantSpawner(source: ad)
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
                    Text("Ads").font(GruxTheme.Font.microCaps)
                }
                .foregroundStyle(GruxTheme.textSecondary)
            }
            .buttonStyle(.plain)
            Spacer()
            SendToClaudeButton(scope: .ad, label: ad.displayName, brand: ad.brand, nodeId: ad.id, crid: ad.crid,
                               changedVariable: ad.changedVariable, variableValue: ad.variableValue)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            thumb
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(ad.status.label, systemImage: ad.status.icon)
                        .font(GruxTheme.Font.microCaps).foregroundStyle(ad.status.tint)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(ad.status.tint.opacity(0.16)))
                    Label(ad.engineIntent.label, systemImage: ad.engineIntent.icon)
                        .font(GruxTheme.Font.microCaps).foregroundStyle(ad.engineIntent.tint)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(ad.engineIntent.tint.opacity(0.16)))
                }
                Text(ad.headline ?? ad.displayName)
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                if let p = ad.primaryText {
                    Text(p).font(.system(size: 12, weight: .medium)).foregroundStyle(GruxTheme.textSecondary).lineLimit(3)
                }
                if let v = ad.changedVariable {
                    HStack(spacing: 5) {
                        Text("TESTING").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
                        Text(v.uppercased()).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.accentPrimaryLight)
                        if let val = ad.variableValue {
                            Text("= \(val)").font(.system(size: 11, weight: .semibold)).foregroundStyle(GruxTheme.textSecondary)
                        }
                    }
                }
                if let action = ad.proposedNextAction {
                    Text(action).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(GruxTheme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card).fill(Color.white.opacity(0.05))
            if let urlStr = ad.thumbnailURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(GruxTheme.textTertiary)
                    }
                }
            } else {
                Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var kpis: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            tile("Spend", MetaAdsFormat.dollars(ad.spendCents))
            tile("CPA", MetaAdsFormat.dollarsOpt(ad.cpaCents))
            tile("ROAS", MetaAdsFormat.ratio(ad.roas))
            tile("CTR", MetaAdsFormat.pct2(ad.ctr))
            tile("Impr.", MetaAdsFormat.count(ad.impressions))
            tile("Clicks", MetaAdsFormat.count(ad.clicks))
            tile("Conv.", MetaAdsFormat.count(ad.conversions))
            tile("Days", "\(ad.daysRunning)")
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased()).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(GruxTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 60)
    }

    private var trendCard: some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                MetaAdsEyebrow(text: "Cost per result", icon: "chart.xyaxis.line", tint: GruxTheme.accentCo)
                MetaAdsSparkline(series: ad.costPerResultSeries, tint: ad.status.tint).frame(height: 54)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signalsCard: some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                MetaAdsEyebrow(text: "Signals", icon: "dot.radiowaves.left.and.right", tint: GruxTheme.accentPrimary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                    if let lp = ad.learningProgress { signal("Learning", MetaAdsFormat.pct(lp), GruxTheme.accentPrimaryLight) }
                    if let p = ad.pBeatsBaseline { signal("P(B>A)", MetaAdsFormat.prob(p), p >= 0.95 ? GruxTheme.successMint : GruxTheme.textSecondary) }
                    if let share = ad.impressionSharePct { signal("Impr. share", MetaAdsFormat.pct(share), GruxTheme.accentCo) }
                    if let f = ad.frequency { signal("Frequency", String(format: "%.1f", f), (ad.fatigueLevel ?? .ok).tint) }
                    if let fl = ad.fatigueLevel { signal("Fatigue", fl.label, fl.tint) }
                    if let seg = ad.bestAudienceSegment { signal("Best segment", seg, GruxTheme.textPrimary) }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signal(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
            Text(value).font(.system(size: 13, weight: .bold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func targetingCard(_ t: TargetingSummary) -> some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                MetaAdsEyebrow(text: "Engine-crafted targeting", icon: "scope", tint: GruxTheme.accentCo)
                if let line = t.summaryLine {
                    Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary)
                }
                FlexibleChips(items: targetingChips(t))
                if t.advantageAudience == true {
                    Text("Meta Advantage+ audience on").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.accentPrimaryLight)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func targetingChips(_ t: TargetingSummary) -> [String] {
        var chips: [String] = []
        if !t.locations.isEmpty { chips.append("Geo: " + t.locations.joined(separator: ", ")) }
        if let lo = t.ageMin, let hi = t.ageMax { chips.append("Age \(lo)-\(hi)") }
        if !t.genders.isEmpty { chips.append(t.genders.joined(separator: ", ").capitalized) }
        if !t.devices.isEmpty { chips.append(t.devices.joined(separator: ", ").capitalized) }
        if !t.placements.isEmpty { chips.append("Placements: " + t.placements.joined(separator: ", ")) }
        if !t.dayParting.isEmpty { chips.append("Hours: " + t.dayParting.joined(separator: ", ")) }
        for i in t.interests { chips.append(i) }
        return chips
    }
}

// A simple wrapping chip row for the targeting summary.
struct FlexibleChips: View {
    let items: [String]
    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .lineLimit(1)
            }
        }
    }
}
