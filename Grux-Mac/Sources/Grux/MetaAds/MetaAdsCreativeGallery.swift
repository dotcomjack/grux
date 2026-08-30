import SwiftUI

// A thumbnail grid of every creative with a performance overlay (status badge,
// CPA, ROAS) on each tile. AsyncImage resolves the engine thumbnail; a glass
// placeholder fills while loading or when no image is present. Tapping a tile
// drills to ad detail.
struct MetaAdsCreativeGallery: View {
    let ads: [ActiveAd]
    var onSelectAd: (ActiveAd) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetaAdsEyebrow(text: "Creative", icon: "photo.on.rectangle.angled", tint: GruxTheme.accentPrimary)
            if ads.isEmpty {
                // Names what fills it. "No creatives yet." alone left a reader
                // unable to tell a broken engine from one that simply has not
                // generated a variant.
                VStack(alignment: .leading, spacing: 3) {
                    Text("No creatives yet.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GruxTheme.textTertiary)
                    Text("Images appear here as the engine generates ad variants for this brand.")
                        .font(.system(size: 10))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ads) { ad in
                        MetaAdsCreativeTile(ad: ad) { onSelectAd(ad) }
                    }
                }
            }
        }
    }
}

struct MetaAdsCreativeTile: View {
    let ad: ActiveAd
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    image
                    HStack(spacing: 4) {
                        Image(systemName: ad.status.icon).font(.system(size: 8, weight: .bold))
                        Text(ad.status.label).font(GruxTheme.Font.microCaps)
                    }
                    .foregroundStyle(GruxTheme.base)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(ad.status.tint))
                    .padding(7)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ad.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Label(MetaAdsFormat.dollarsOpt(ad.cpaCents), systemImage: "target")
                            .foregroundStyle(GruxTheme.textSecondary)
                        Label(MetaAdsFormat.ratio(ad.roas), systemImage: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(GruxTheme.successMint)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    if let v = ad.changedVariable {
                        Text(v.uppercased())
                            .font(GruxTheme.Font.microCaps)
                            .foregroundStyle(GruxTheme.accentPrimaryLight)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var image: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.05))
            if let urlStr = ad.thumbnailURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .empty: ProgressView().controlSize(.small)
                    default: Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(GruxTheme.textTertiary)
                    }
                }
            } else {
                Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}
