import SwiftUI

// JaxFilteredSection: the visible counterpart to the silent reply-policy skip.
// It surfaces the mail Jax chose NOT to draft (no-reply / marketing / muted /
// category-off) and why, so a wrongly-skipped message is recoverable and a
// genuinely unwanted one is one tap from permanent. Brand-filtered like the
// Drafts section. Every action is local and safe: no outbound mail, no clicking
// sender links. Muting a domain here is a manual, one-tap escalation the user
// chooses (nothing auto-suppresses).
struct JaxFilteredSection: View {
    @ObservedObject private var store = FilteredMailStore.shared
    @ObservedObject private var brand = BrandFilter.shared

    private var shown: [FilteredMail] {
        store.items.filter { brand.scope.matches(voice: $0.brand) }
    }

    var body: some View {
        // Stay quiet when there is nothing filtered for the current brand: this
        // is a secondary surface, it should not shout an empty box.
        if !shown.isEmpty {
            JaxSection(
                title: "Filtered", icon: "line.3.horizontal.decrease.circle.fill",
                tint: GruxTheme.textSecondary, count: shown.count,
                trailing: AnyView(
                    DestructiveButton(
                        "Clear all",
                        question: "Clear the list of filtered mail?",
                        detail: "Removes the record of what \(UserIdentity.assistantName) filtered out. The mail itself is "
                            + "untouched in your inbox, but you lose the audit trail of what was "
                            + "held back and why.",
                        confirmLabel: "Clear the list"
                    ) { FilteredMailStore.shared.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GruxTheme.textTertiary)
                )
            ) {
                Text("Mail \(UserIdentity.assistantName) did not draft a reply for. Mute the domain to silence it for good, or draft it anyway.")
                    .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textTertiary)
                    .padding(.bottom, 4)
                ForEach(shown) { JaxFilteredRow(item: $0) }
            }
        }
    }
}

private struct JaxFilteredRow: View {
    let item: FilteredMail
    @State private var busy = false

    private let gold = Color(red: 0x8a/255, green: 0x64/255, blue: 0x20/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                pill(item.reason, GruxTheme.textTertiary)
                // The roster's display text, matching the Drafts and Autonomy
                // pills in the same scroll view. Rendering the raw token here
                // made one brand read as two.
                pill(BrandRoster.label(forId: item.brand), gold)
                Spacer()
            }
            Text("\(item.fromName) <\(item.fromEmail)>")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary)
                .lineLimit(1)
            Text(item.subject)
                .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textSecondary).lineLimit(1)

            HStack(spacing: 8) {
                if let dom = item.domain {
                    Button("Mute @\(dom)") { EmailTriageEngine.shared.muteFilteredDomain(item.id) }
                        .foregroundStyle(GruxTheme.destructiveRose)
                }
                if item.kind != nil {
                    Button("Enable this kind") { EmailTriageEngine.shared.enableFilteredKind(item.id) }
                        .foregroundStyle(GruxTheme.textSecondary)
                }
                Button(busy ? "Drafting..." : "Draft anyway") {
                    busy = true
                    Task { _ = await EmailTriageEngine.shared.draftFiltered(item.id); busy = false }
                }
                .disabled(busy)
                .foregroundStyle(GruxTheme.accentPrimary)
                Spacer()
                Button("Dismiss") { FilteredMailStore.shared.remove(item.id) }
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .font(.system(size: 12, weight: .semibold)).padding(.top, 2)
        }
        .padding(12)
        .background(Color(red: 0x14/255, green: 0x12/255, blue: 0x0d/255))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(GruxTheme.textTertiary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.16)).foregroundStyle(color).clipShape(Capsule())
    }
}
