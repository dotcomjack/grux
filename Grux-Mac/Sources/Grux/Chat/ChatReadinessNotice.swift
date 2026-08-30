import SwiftUI

/// The bar above the composer when chat has nothing to talk to.
///
/// NOT AN ERROR BANNER, and the difference is the whole point. No send has
/// failed, and none will be attempted, so it carries no status code and offers
/// no retry. The thing it replaces did the opposite: it let the turn go to the
/// network with an empty key and then reported whatever the provider said,
/// which is how a missing model came to be described as a conversation that had
/// grown too long.
///
/// It names BOTH ways out. Running a local model needs no key and no account,
/// and next to "add your API key" that free path would otherwise be invisible.
///
/// Takes its state as a parameter rather than reading `ChatReadiness.current()`,
/// so it can be rendered in the not-ready state on a machine that has a key.
struct ChatReadinessNotice: View {
    let readiness: ChatReadiness
    var openSettings: () -> Void

    var body: some View {
        if !readiness.canSend {
            HStack(alignment: .top, spacing: GruxSpacing.s) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(GruxTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(readiness.headline)
                        .font(GruxTheme.Font.body.weight(.semibold))
                        .foregroundStyle(GruxTheme.textPrimary)
                    Text(readiness.detail)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: GruxSpacing.s)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.plain)
                    .font(GruxTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(GruxTheme.accentPrimary)
            }
            .padding(.horizontal, GruxSpacing.l)
            .padding(.vertical, GruxSpacing.s)
        }
    }
}
