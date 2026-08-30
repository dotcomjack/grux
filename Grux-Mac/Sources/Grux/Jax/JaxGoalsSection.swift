import SwiftUI

// JaxGoalsSection: what Jax is chasing between check-ins. The clone works the
// user's long-term goals on its own; the in-progress tier of the
// shared roadmap (RoadmapStore.shared) is the canonical "in motion" set, so HQ and
// the Roadmap tab never disagree about what Jax is pushing.
struct JaxGoalsSection: View {
    let items: [RoadmapItem]

    var body: some View {
        JaxSection(
            title: "Goals in motion",
            icon: "scope",
            tint: GruxTheme.accentPrimaryLight,
            count: items.isEmpty ? nil : items.count
        ) {
            if items.isEmpty {
                JaxEmptyLine(icon: "scope", text: "Nothing in motion. \(UserIdentity.assistantName) adopts your long-term goals and chases them between check-ins.")
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        JaxGoalRow(item: item)
                    }
                }
            }
        }
    }
}

struct JaxGoalRow: View {
    let item: RoadmapItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                stateBadge
                Spacer()
                Text("started \(JaxTime.ago(item.addedAt))")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(GruxTheme.accentPrimaryLight.opacity(0.25), lineWidth: 1)
        )
    }

    private var stateBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
            Text("CHASING").font(GruxTheme.Font.microCaps).kerning(1.0)
        }
        .foregroundStyle(GruxTheme.accentPrimaryLight)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(GruxTheme.accentPrimaryLight.opacity(0.16)))
    }
}
