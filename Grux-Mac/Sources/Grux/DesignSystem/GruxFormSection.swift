import SwiftUI

// Blueprint 02: the consistent settings/editor section. Micro-caps kicker
// label, frosted rounded card around the content, optional footer line.
// Use for grouped controls in editors, sheets, and Settings panes.
struct GruxFormSection<Content: View>: View {
    let label: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    init(_ label: String, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            Text(label.uppercased())
                .font(GruxType.microCaps)
                .kerning(1.2)
                .foregroundStyle(GruxTheme.textTertiary)
            VStack(alignment: .leading, spacing: GruxSpacing.s) {
                content()
            }
            .padding(GruxSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .font(GruxType.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
    }
}

// Bare section label for places that need the kicker without the card
// (inline editor groups like Schedules' WHEN / ACTION).
struct GruxSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(GruxType.microCaps)
            .kerning(1.4)
            .foregroundStyle(GruxTheme.textTertiary)
    }
}
