import SwiftUI

// Blueprint 02: the one empty state. Icon, one line, optional detail line,
// optional CTA, optional voice hint rendered italic as: say: "Grux, ..."
// Replaces every hand-rolled Spacer/Image/Text/Spacer stack in the PIM tabs.
struct GruxEmptyState: View {
    let icon: String
    let line: String
    var detail: String? = nil
    var ctaTitle: String? = nil
    var ctaAction: (() -> Void)? = nil
    var voiceHint: String? = nil
    /// Narrow list columns use the compact scale (smaller icon + caption line).
    var compact: Bool = false
    /// Override for permission/warning states (e.g. GruxTheme.warnAmber).
    var iconColor: Color? = nil

    var body: some View {
        VStack(spacing: GruxSpacing.s) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: compact ? 22 : 28))
                .foregroundStyle(iconColor ?? GruxTheme.textTertiary)
            Text(line)
                .font(compact ? GruxType.caption : GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            if let ctaTitle, let ctaAction {
                Button(ctaTitle, action: ctaAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(GruxTheme.accentPrimary)
                    .padding(.top, GruxSpacing.xs)
            }
            if let voiceHint {
                Text("say: \"\(voiceHint)\"")
                    .font(GruxType.caption)
                    .italic()
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(.top, GruxSpacing.xs)
            }
            Spacer()
        }
        .padding(.horizontal, GruxSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
