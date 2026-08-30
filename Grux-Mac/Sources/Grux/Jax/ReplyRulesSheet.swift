import SwiftUI

// ReplyRulesSheet: per-brand control over which mail Jax auto-drafts replies for
// (the approved reply-policy design). Three KIND toggles (no-reply/automated,
// marketing/promotional, personal/business), the support CATEGORY toggles, and
// the muted-senders list. Opt-out posture: personal on, automated + marketing
// off by default, so no-reply and marketing mail (e.g. Walmart Marketplace) is
// never drafted unless the user opts the brand in. Rendered in GruxTheme, tight
// controls, zero em/en dashes, money as $N.
struct ReplyRulesSheet: View {
    let brand: String                       // the brand slug this rule applies to
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var policyStore = ReplyPolicyStore.shared
    @ObservedObject private var suppression = SenderSuppressionStore.shared

    private var policy: BrandReplyPolicy { policyStore.policy(for: brand) }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            header

            section("Email kinds", hint: "Which kinds of mail get a drafted reply. No-reply and marketing are off by default.") {
                ForEach(EmailKind.allCases) { kind in
                    toggleRow(kind.label, subtitle: kindHint(kind), isOn: policy.allows(kind: kind)) { on in
                        policyStore.setKind(kind, enabled: on, for: brand)
                    }
                }
            }

            section("Support categories", hint: "For personal/business mail, which support topics to draft for.") {
                ForEach(SupportCategory.allCases, id: \.self) { cat in
                    toggleRow(cat.label, subtitle: nil, isOn: policy.allows(category: cat)) { on in
                        policyStore.setCategory(cat, enabled: on, for: brand)
                    }
                }
            }

            mutedSection

            HStack {
                Spacer()
                GruxChip(title: "Done", style: .primary) { dismiss() }
            }
        }
        .padding(GruxSpacing.l)
        // 540 is still what this sheet WANTS, but as an ideal rather than a
        // demand. A sheet hangs off the main window, and a hard width has
        // nowhere to go when the window or the display is smaller than the
        // number: SwiftUI centres an oversized child, so it bleeds off the
        // left and the right at once, which is exactly how Settings lost text
        // off both edges. Bounded, it still renders at 540 everywhere 540
        // fits, and shrinks toward GruxLayout.sheetMin instead of clipping.
        .frame(minWidth: GruxLayout.sheetMin,
               idealWidth: 540,
               maxWidth: GruxLayout.sheetMax)
        .background(GruxTheme.base)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reply rules")
                .font(GruxTheme.Font.title)
                .foregroundStyle(GruxTheme.textPrimary)
            Text("\(brandLabel) mailbox")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var brandLabel: String {
        BrandScope(rawValue: brand)?.label ?? brand.uppercased()
    }

    // MARK: Muted senders

    private var mutedSection: some View {
        section("Muted senders", hint: "Senders and domains that never get a draft. Add from a draft card or a Mailbox message.") {
            if suppression.emails.isEmpty && suppression.domains.isEmpty {
                Text("None muted yet.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .italic()
            } else {
                ForEach(suppression.domains.sorted(), id: \.self) { d in
                    mutedRow(label: "@\(d)", icon: "globe") { suppression.unmuteDomain(d) }
                }
                ForEach(suppression.emails.sorted(), id: \.self) { e in
                    mutedRow(label: e, icon: "person.fill") { suppression.unmuteEmail(e) }
                }
            }
        }
    }

    private func mutedRow(label: String, icon: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(GruxTheme.textTertiary)
            Text(label).font(.system(size: 12)).foregroundStyle(GruxTheme.textSecondary).lineLimit(1)
            Spacer()
            Button {
                remove()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(GruxTheme.textTertiary)
            .help("Unmute")
        }
        .padding(.vertical, 3)
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, hint: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            Text(title.uppercased())
                .font(GruxTheme.Font.microCaps).kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            if let hint {
                Text(hint).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
            }
            content()
        }
        .padding(GruxSpacing.m - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private func toggleRow(_ title: String, subtitle: String?, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: GruxSpacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(GruxTheme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { set($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func kindHint(_ kind: EmailKind) -> String {
        switch kind {
        case .automated: return "no-reply, system, bounce, auto-generated"
        case .marketing: return "newsletters, promotions, bulk mail"
        case .personal: return "a real person or business writing to you"
        }
    }
}
