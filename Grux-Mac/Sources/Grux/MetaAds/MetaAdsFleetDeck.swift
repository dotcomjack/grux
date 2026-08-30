import SwiftUI

// The landing fleet table. One sortable row per brand, all brands at once: mode,
// spend vs cap, winner / contender / graveyard counts, best + worst performer,
// and an attention flag. A brand with no snapshot data renders the calm
// empty-ready state. Tapping a row drills into the brand.
struct MetaAdsFleetDeck: View {
    let brands: [MetaAdsBrand]
    let snapshotMode: String
    var onSelectBrand: (String) -> Void = { _ in }

    @State private var sort: MetaAdsFleetSort = .attention

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MetaAdsEyebrow(text: "Fleet", icon: "rectangle.3.group.fill", tint: GruxTheme.accentPrimary)
                Spacer()
                sortControl
            }
            VStack(spacing: 8) {
                ForEach(sortedBrands, id: \.fleetKey) { brand in
                    MetaAdsBrandFleetRow(brand: brand, snapshotMode: snapshotMode) {
                        onSelectBrand(brand.fleetKey)
                    }
                }
            }
        }
    }

    private var sortControl: some View {
        Menu {
            ForEach(MetaAdsFleetSort.allCases, id: \.self) { s in
                Button { sort = s } label: {
                    HStack {
                        Text(s.label)
                        if s == sort { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .bold))
                Text(sort.label).font(GruxTheme.Font.microCaps)
            }
            .foregroundStyle(GruxTheme.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortedBrands: [MetaAdsBrand] {
        brands.sorted { a, b in
            switch sort {
            case .brand: return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            case .spend: return a.kpis.spendTodayCents > b.kpis.spendTodayCents
            case .cpa: return (a.kpis.cpaCents ?? Int.max) < (b.kpis.cpaCents ?? Int.max)
            case .roas: return (a.kpis.roas ?? 0) > (b.kpis.roas ?? 0)
            case .status: return bucketScore(a) > bucketScore(b)
            case .age: return (a.leaderboard?.oldestAdDays ?? 0) > (b.leaderboard?.oldestAdDays ?? 0)
            case .attention: return attentionScore(a) > attentionScore(b)
            case .family: return a.families.count > b.families.count
            }
        }
    }

    private func attentionScore(_ b: MetaAdsBrand) -> Int {
        (b.leaderboard?.attentionFlag == true ? 100 : 0) + b.attention.count
    }
    private func bucketScore(_ b: MetaAdsBrand) -> Int {
        b.families.filter { $0.bucket == .winners }.count
    }
}

enum MetaAdsFleetSort: String, CaseIterable {
    case attention, spend, cpa, roas, status, age, brand, family
    var label: String {
        switch self {
        case .attention: return "Needs you"
        case .spend: return "Spend"
        case .cpa: return "CPA"
        case .roas: return "ROAS"
        case .status: return "Status"
        case .age: return "Age"
        case .brand: return "Brand"
        case .family: return "Families"
        }
    }
}

private extension MetaAdsBrand {
    var fleetKey: String { slug ?? id }
}

struct MetaAdsBrandFleetRow: View {
    let brand: MetaAdsBrand
    let snapshotMode: String
    var onTap: () -> Void

    private var mode: String { brand.effectiveMode(default: snapshotMode) }
    private var hasAds: Bool { !brand.activeAds.isEmpty || !brand.families.isEmpty }
    private var winners: Int { brand.families.filter { $0.bucket == .winners }.count }
    private var contenders: Int { brand.families.filter { $0.bucket == .contenders }.count }
    private var graveyard: Int { brand.families.filter { $0.bucket == .graveyard }.count }
    private var needsYou: Bool { brand.leaderboard?.attentionFlag == true || !brand.attention.isEmpty }

    var body: some View {
        Button(action: onTap) {
            GruxGlassCard {
                HStack(spacing: 12) {
                    // Brand + mode
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if needsYou {
                                Circle().fill(GruxTheme.warnAmber).frame(width: 6, height: 6)
                            }
                            Text(brand.displayName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(GruxTheme.textPrimary)
                        }
                        modePill
                    }
                    .frame(width: 130, alignment: .leading)

                    if hasAds {
                        // Spend vs cap
                        metric("SPEND", MetaAdsFormat.dollars(brand.kpis.spendTodayCents) + " / " + MetaAdsFormat.dollars(brand.pacing.dailyCapCents))
                        // W/C/G
                        VStack(alignment: .leading, spacing: 2) {
                            Text("W / C / G").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
                            HStack(spacing: 4) {
                                bucketCount(winners, GruxTheme.successMint)
                                Text("/").foregroundStyle(GruxTheme.textTertiary).font(.system(size: 11))
                                bucketCount(contenders, GruxTheme.accentCo)
                                Text("/").foregroundStyle(GruxTheme.textTertiary).font(.system(size: 11))
                                bucketCount(graveyard, GruxTheme.textTertiary)
                            }
                        }
                        .frame(width: 80, alignment: .leading)
                        // Best / worst
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BEST / WORST").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
                            HStack(spacing: 6) {
                                Text(MetaAdsFormat.dollarsOpt(brand.leaderboard?.bestCpaCents))
                                    .foregroundStyle(GruxTheme.successMint)
                                Text(MetaAdsFormat.dollarsOpt(brand.leaderboard?.worstCpaCents))
                                    .foregroundStyle(GruxTheme.destructiveRose)
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        metric("ROAS", MetaAdsFormat.ratio(brand.kpis.roas))
                    } else {
                        Text("No ads yet. The engine seeds this brand on onboarding.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(GruxTheme.textTertiary)
                    }

                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var modePill: some View {
        let color: Color
        switch mode.uppercased() {
        case "AUTONOMOUS": color = GruxTheme.destructiveRose
        case "RECOMMEND": color = GruxTheme.warnAmber
        default: color = GruxTheme.successMint
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(mode.uppercased()).font(GruxTheme.Font.microCaps).kerning(0.8)
        }
        .foregroundStyle(color)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(GruxTheme.textPrimary)
        }
        .frame(minWidth: 64, alignment: .leading)
    }

    private func bucketCount(_ n: Int, _ tint: Color) -> some View {
        Text("\(n)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(tint)
    }
}
