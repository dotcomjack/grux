import SwiftUI

// The active-ad fleet for one brand: a sortable, status-filterable list. Each row
// shows the thumbnail, status badge, the one tested variable, spend, CPA, ROAS,
// days running, impression share, engine intent, and a compact secondary line
// with learning progress, fatigue, P(B>A), and the proposed next action. Tapping
// a row drills to ad detail.
struct MetaAdsActiveAdTable: View {
    let ads: [ActiveAd]
    var onSelectAd: (ActiveAd) -> Void = { _ in }

    @State private var filter: AdStatus? = nil
    @State private var sort: AdSort = .spend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MetaAdsEyebrow(text: "Active ads", icon: "list.bullet.rectangle.fill", tint: GruxTheme.accentCo)
                Text("\(shown.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                sortMenu
            }
            filterChips
            if shown.isEmpty {
                Text("No active ads in this view.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 7) {
                    ForEach(shown) { ad in
                        MetaAdsActiveAdRow(ad: ad) { onSelectAd(ad) }
                    }
                }
            }
        }
    }

    private var shown: [ActiveAd] {
        ads
            .filter { filter == nil || $0.status == filter }
            .sorted { a, b in
                switch sort {
                case .spend: return a.spendCents > b.spendCents
                case .cpa: return (a.cpaCents ?? Int.max) < (b.cpaCents ?? Int.max)
                case .roas: return (a.roas ?? 0) > (b.roas ?? 0)
                case .age: return a.daysRunning > b.daysRunning
                case .share: return (a.impressionSharePct ?? 0) > (b.impressionSharePct ?? 0)
                }
            }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", active: filter == nil) { filter = nil }
                ForEach(AdStatus.allCases, id: \.self) { s in
                    let count = ads.filter { $0.status == s }.count
                    if count > 0 {
                        chip(s.label, tint: s.tint, active: filter == s) { filter = filter == s ? nil : s }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, tint: Color = GruxTheme.textSecondary, active: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title.uppercased())
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(active ? GruxTheme.base : tint)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(active ? tint : tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AdSort.allCases, id: \.self) { s in
                Button { sort = s } label: {
                    HStack { Text(s.label); if s == sort { Image(systemName: "checkmark") } }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .bold))
                Text(sort.label).font(GruxTheme.Font.microCaps)
            }
            .foregroundStyle(GruxTheme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.05)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    enum AdSort: String, CaseIterable {
        case spend, cpa, roas, age, share
        var label: String {
            switch self {
            case .spend: return "Spend"
            case .cpa: return "CPA"
            case .roas: return "ROAS"
            case .age: return "Age"
            case .share: return "Share"
            }
        }
    }
}

struct MetaAdsActiveAdRow: View {
    let ad: ActiveAd
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            GruxGlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 11) {
                        thumb
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                statusBadge
                                Text(ad.displayName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(GruxTheme.textPrimary)
                                    .lineLimit(1)
                            }
                            if let v = ad.changedVariable {
                                HStack(spacing: 4) {
                                    Text(v.uppercased())
                                        .font(GruxTheme.Font.microCaps)
                                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                                    if let val = ad.variableValue {
                                        Text(val).font(.system(size: 10, weight: .medium)).foregroundStyle(GruxTheme.textTertiary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 6)
                        metric("SPEND", MetaAdsFormat.dollars(ad.spendCents))
                        metric("CPA", MetaAdsFormat.dollarsOpt(ad.cpaCents))
                        metric("ROAS", MetaAdsFormat.ratio(ad.roas))
                        intentChip
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(GruxTheme.textTertiary)
                    }
                    secondaryLine
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05))
            if let urlStr = ad.thumbnailURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(GruxTheme.textTertiary)
                    }
                }
            } else {
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var statusBadge: some View {
        Image(systemName: ad.status.icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(ad.status.tint)
            .help(ad.status.label)
    }

    private var intentChip: some View {
        HStack(spacing: 3) {
            Image(systemName: ad.engineIntent.icon).font(.system(size: 8, weight: .bold))
            Text(ad.engineIntent.label).font(GruxTheme.Font.microCaps)
        }
        .foregroundStyle(ad.engineIntent.tint)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(ad.engineIntent.tint.opacity(0.14)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(GruxTheme.textPrimary)
        }
        .frame(minWidth: 50, alignment: .trailing)
    }

    private var secondaryLine: some View {
        HStack(spacing: 12) {
            if let lp = ad.learningProgress, ad.status == .learning {
                miniStat("learning", MetaAdsFormat.pct(lp), GruxTheme.accentPrimaryLight)
            }
            if let p = ad.pBeatsBaseline {
                miniStat("P(B>A)", MetaAdsFormat.prob(p), p >= 0.95 ? GruxTheme.successMint : GruxTheme.textSecondary)
            }
            if let share = ad.impressionSharePct {
                miniStat("share", MetaAdsFormat.pct(share), GruxTheme.accentCo)
            }
            if let f = ad.fatigueLevel, f != .ok {
                miniStat("fatigue", f.label, f.tint)
            }
            if let action = ad.proposedNextAction {
                Text(action)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if ad.costPerResultSeries.count >= 2 {
                MetaAdsSparkline(series: ad.costPerResultSeries, tint: ad.status.tint, showLastDot: false)
                    .frame(width: 56, height: 20)
            }
        }
        .padding(.leading, 55)
    }

    private func miniStat(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label.uppercased()).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
            Text(value).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(tint)
        }
    }
}
