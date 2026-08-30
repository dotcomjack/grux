import SwiftUI

// MetaAdsFamilyRow (Unit U2)
//
// One row in the Meta Ads tab's concept-family roll-up. A "family" is a lineage
// FOREST root (the engine's crid: a stable concept-family root id, pushed to
// utm_content) plus its descendant ad variants. This row collapses that whole
// subtree into a single dense line so a big tree shows ~8 rows: the crid label,
// how many nodes are in the family, the family's best (lowest) CPA, a bucket dot
// (winner / contender / graveyard), and a status chip.
//
// Reads U1's ConceptFamily (crid, label?, bucket: FamilyBucket, nodeCount,
// bestCpaCents?, status?, displayLabel). FamilyBucket is U1's enum; its visual
// presentation (tint / title / icon) is defined here in U2 since U1 left the
// bucket as a pure data enum. winners -> successMint, contenders -> warnAmber,
// graveyard -> textTertiary, per the blueprint.
//
// All money is cents to $N. Theme tokens only. Zero em/en dashes.

// MARK: - U2-owned bucket presentation

extension FamilyBucket {
    var tint: Color {
        switch self {
        case .winners: return GruxTheme.successMint
        case .contenders: return GruxTheme.warnAmber
        case .graveyard: return GruxTheme.textTertiary
        }
    }

    var title: String {
        switch self {
        case .winners: return "Winners"
        case .contenders: return "Contenders"
        case .graveyard: return "Graveyard"
        }
    }

    var icon: String {
        switch self {
        case .winners: return "trophy.fill"
        case .contenders: return "flame.fill"
        case .graveyard: return "xmark.bin.fill"
        }
    }
}

struct MetaAdsFamilyRow: View {
    let family: ConceptFamily

    var body: some View {
        HStack(spacing: 10) {
            // Bucket dot
            Circle()
                .fill(family.bucket.tint)
                .frame(width: 7, height: 7)
                .shadow(color: family.bucket.tint.opacity(0.6), radius: 3)

            // crid + label
            VStack(alignment: .leading, spacing: 1) {
                Text(family.crid)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let label = family.label, !label.isEmpty, label != family.crid {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(GruxTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Node count
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(family.nodeCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(GruxTheme.textSecondary)
                Text("NODES")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .frame(width: 46, alignment: .trailing)

            // Best CPA
            VStack(alignment: .trailing, spacing: 0) {
                Text(bestCpaLabel)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(family.bestCpaCents != nil ? family.bucket.tint : GruxTheme.textTertiary)
                Text("BEST CPA")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .frame(width: 64, alignment: .trailing)

            // Status chip
            statusChip
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(family.bucket.tint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(family.bucket.tint.opacity(0.20), lineWidth: 1)
        )
    }

    private var bestCpaLabel: String {
        guard let c = family.bestCpaCents else { return "-" }
        let v = Double(c) / 100.0
        if v == v.rounded() { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    @ViewBuilder
    private var statusChip: some View {
        let status = (family.status?.isEmpty == false) ? family.status! : "-"
        Text(status.uppercased())
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .kerning(0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(family.bucket.tint.opacity(0.18))
            )
            .overlay(
                Capsule().strokeBorder(family.bucket.tint.opacity(0.40), lineWidth: 0.8)
            )
            .foregroundStyle(family.bucket.tint)
    }
}
