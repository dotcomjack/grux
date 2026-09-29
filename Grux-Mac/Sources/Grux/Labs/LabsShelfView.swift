import SwiftUI

/// P-E-3: the Labs door opens onto a shelf. Eight cards, one line each on what
/// the surface is for, in the accepted shape A (`docs/superpowers/visuals/
/// labs-a.png`, accepted 2026-09-22).
///
/// The cards are read from the registry (every row whose door is Labs, in
/// registry order, then the Labs-only keys), so the shelf and the door cannot
/// disagree about what is behind it. Only the one-line descriptions are
/// written here, because the registry holds labels, not descriptions.
@MainActor
enum LabsShelf {

    struct Card: Identifiable, Equatable {
        let id: String
        let title: String
        let line: String
        let icon: String
        /// The tab it opens; nil for a surface that is a window (the phone).
        let tabKey: String?
    }

    static let intro = "Grux working on itself, and ideas still being built. Everything here works, and any of it can change without notice."

    static let lines: [String: String] = [
        "reactor": "The live panel: what Grux is doing right now, and how hard.",
        "jax.hq": "The inbox agent's desk: approvals, briefings and the mail it filtered.",
        "jax.command": "Goals Grux pursues on its own, and the next step it would take.",
        "cognition.map": "Why Grux decided what it did: the rules, memories and gates behind each call.",
        "feature.review": "Grux explains its own work, and you decide what reaches main.",
        "self.upgrade": "Improvements Grux proposes, builds and installs, with a breaker you hold.",
        "phone": "Pair an iPhone to hear Grux and talk to it away from the Mac.",
        "roadmap": "What you are building, grouped by when you plan to ship it.",
    ]

    static var cards: [Card] {
        var out: [Card] = SidebarIA.behind(.labs).map { row in
            let key = FeatureRegistry.tabKey(forRowId: row.id)
            let icon = key.flatMap { SidebarIA.item(forKey: $0)?.icon } ?? "iphone"
            return Card(id: row.id, title: row.label, line: lines[row.id] ?? "", icon: icon, tabKey: key)
        }
        out += SidebarIA.labsOnlyKeys.compactMap { key in
            SidebarIA.item(forKey: key).map {
                Card(id: key, title: $0.label, line: lines[key] ?? "", icon: $0.icon, tabKey: key)
            }
        }
        return out
    }
}

struct LabsShelfView: View {
    /// Opens a card: a tab key, or nil for a surface that is a window.
    let open: (String?) -> Void

    /// Two columns where two cards each get `labsCardMin`, one below that:
    /// two at a 360pt pane left each card a word per line.
    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: GruxSpacing.m), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("Labs")
                        .font(GruxType.title)
                        .foregroundStyle(GruxTheme.textPrimary)
                    BetaBadge()
                }
                Text(LabsShelf.intro)
                    .font(.callout)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                GruxWidthSwitch(threshold: 2 * GruxLayout.labsCardMin + GruxSpacing.m) {
                    grid(columns: 2)
                } narrow: {
                    grid(columns: 1)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func grid(columns count: Int) -> some View {
        LazyVGrid(columns: columns(count), spacing: GruxSpacing.m) {
            ForEach(LabsShelf.cards) { card in
                Button { open(card.tabKey) } label: { cardView(card) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(card.title). \(card.line)")
            }
        }
    }

    private func cardView(_ card: LabsShelf.Card) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(GruxTheme.accentPrimary.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(GruxTheme.textPrimary)
                Text(card.line)
                    .font(.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: GruxTheme.Radius.card).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .contentShape(Rectangle())
    }
}
