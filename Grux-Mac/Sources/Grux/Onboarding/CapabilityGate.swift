import SwiftUI

/// Wraps a feature's own UI and puts the setup card over it when a required
/// capability is missing.
///
/// Adoption is one line per tab, `.capabilityGated("integrations")`, which is
/// deliberate: it makes the set of adopted features greppable, so "did every tab
/// actually move onto the registry" is a question the shell can answer instead
/// of a claim in a commit message.
///
/// The treatment follows contract section 3 rather than simply swapping the view
/// out. needs-setup renders the feature's OWN UI, dimmed and non-interactive,
/// with the setup card over it. That is a deliberate piece of design and not
/// decoration: a stranger seeing the real thing behind the card learns what they
/// are being asked to unlock, where a blank replacement teaches nothing and
/// reads like a broken tab.
struct CapabilityGate<Content: View>: View {
    let tabKey: String
    @ViewBuilder var content: () -> Content

    // No @EnvironmentObject here either. There was one, it was never read, and
    // an unused environment dependency is not free: it imposes an injection
    // requirement on every future host of this view and fails at runtime rather
    // than at compile time when one forgets.

    var body: some View {
        // Recomputed on every render on purpose. Permissions are live system
        // reads, so pasting a key or granting a permission in another window
        // clears the card without a relaunch.
        let needsSetup = FeatureRegistry.state(forTab: tabKey) == .needsSetup

        ZStack(alignment: .top) {
            content()
                .disabled(needsSetup)
                .opacity(needsSetup ? 0.28 : 1)
                .allowsHitTesting(!needsSetup)
                .accessibilityHidden(needsSetup)

            if needsSetup {
                // The card sits at the top and is sized to its content, so the
                // dimmed feature stays visible below and around it. An earlier
                // version stretched the card to fill and its background hid the
                // very thing the dimming exists to show.
                CapabilitySetupCard(featureKey: tabKey)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(GruxTheme.base.opacity(0.97))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(GruxTheme.textTertiary.opacity(0.22), lineWidth: 1)
                            )
                    )
                    .padding(GruxSpacing.l)
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    /// Gates this feature on its registry row. No-op for a tab with no row, so
    /// adopting a tab that needs nothing is harmless.
    func capabilityGated(_ tabKey: String) -> some View {
        CapabilityGate(tabKey: tabKey) { self }
    }
}
