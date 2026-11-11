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
    /// False where the feature's own UI, with its requirement missing, is
    /// nothing but its own empty state. Mail with no account drew the card over
    /// a dimmed "No email accounts yet" and a ghosted toolbar: two empty states
    /// saying the same thing (audit 2026-10-13, item 5). There the card stands
    /// alone.
    var showsFeatureBehind: Bool = true
    /// True where only PART of the pane needs the missing capability. Jax HQ
    /// dimmed its whole page behind the mail card, so a "Save your note"
    /// approval that has nothing to do with mail could not be approved there
    /// (D200 item 1, `jaxHQ-1.png`). In this mode the gate dims nothing itself:
    /// the pane draws the card where `CapabilitySetupSlot` sits and dims only
    /// the parts it marks `.needsGatedCapability()`.
    var keepsUnneededPartsLive: Bool = false
    @ViewBuilder var content: () -> Content

    /// Redraws the gate when a setup step is answered (D138: a consent answered
    /// on the card left the card up, since nothing watches UserDefaults).
    @ObservedObject private var setupRevision = SetupRevision.shared

    // No @EnvironmentObject here either. There was one, it was never read, and
    // an unused environment dependency is not free: it imposes an injection
    // requirement on every future host of this view and fails at runtime rather
    // than at compile time when one forgets.

    var body: some View {
        // Recomputed on every render on purpose. Permissions are live system
        // reads, so pasting a key or granting a permission in another window
        // clears the card without a relaunch.
        let needsSetup = Self.showsSetupCard(forTab: tabKey)

        if Self.leavesDimmingToParts(needsSetup: needsSetup, keepsUnneededPartsLive: keepsUnneededPartsLive) {
            content()
                .environment(\.capabilitySetupPendingTab, tabKey)
        } else {
            wholePaneGate(needsSetup: needsSetup)
        }
    }

    @ViewBuilder
    private func wholePaneGate(needsSetup: Bool) -> some View {
        ZStack(alignment: .top) {
            if !needsSetup || showsFeatureBehind {
                content()
                    .disabled(needsSetup)
                    .opacity(needsSetup ? CapabilityGateDimming.opacity : 1)
                    .allowsHitTesting(!needsSetup)
                    .accessibilityHidden(needsSetup)
            } else {
                // The pane keeps its size and background with nothing behind the card.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if needsSetup {
                // The card sits at the top and is sized to its content, so the
                // dimmed feature stays visible below and around it. An earlier
                // version stretched the card to fill and its background hid the
                // very thing the dimming exists to show.
                CapabilitySetupCard(featureKey: tabKey)
                    .capabilitySetupCardFrame()
                    .padding(GruxSpacing.l)
                    .transition(.opacity)
            }
        }
    }
}

/// The opacity a dimmed part of a gated pane draws at, shared by both modes.
enum CapabilityGateDimming {
    static let opacity: Double = 0.28
}

private struct CapabilitySetupPendingTabKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The tab whose setup card is up, set only by a gate in
    /// `keepsUnneededPartsLive` mode. Nil everywhere else.
    var capabilitySetupPendingTab: String? {
        get { self[CapabilitySetupPendingTabKey.self] }
        set { self[CapabilitySetupPendingTabKey.self] = newValue }
    }
}

/// Where a `keepsUnneededPartsLive` pane draws its setup card. Draws nothing
/// when the capability is there or outside such a gate.
struct CapabilitySetupSlot: View {
    @Environment(\.capabilitySetupPendingTab) private var pendingTab

    var body: some View {
        if let pendingTab {
            CapabilitySetupCard(featureKey: pendingTab)
                .capabilitySetupCardFrame()
        }
    }
}

private struct NeedsGatedCapability: ViewModifier {
    @Environment(\.capabilitySetupPendingTab) private var pendingTab

    func body(content: Content) -> some View {
        let dimmed = CapabilityGate<EmptyView>.dimsPart(pendingTab: pendingTab)
        content
            .disabled(dimmed)
            .opacity(dimmed ? CapabilityGateDimming.opacity : 1)
            .allowsHitTesting(!dimmed)
            .accessibilityHidden(dimmed)
    }
}

extension View {
    /// Marks a part of a `keepsUnneededPartsLive` pane that does need the
    /// missing capability: it dims and stops taking input while the card is up.
    func needsGatedCapability() -> some View {
        modifier(NeedsGatedCapability())
    }

    fileprivate func capabilitySetupCardFrame() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12)
                .fill(GruxTheme.base.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(GruxTheme.textTertiary.opacity(0.22), lineWidth: 1)
                )
        )
    }
}

extension CapabilityGate {
    /// Whether an opened pane draws the setup card over itself.
    ///
    /// NOT `FeatureRegistry.state(forTab:)`. That answers `.notChosen` for a
    /// feature left out of the onboarding selection before it reads a single
    /// capability, so a pane opened anyway (Recent, search, a link) drew no
    /// card: Meetings offered Start with the microphone and screen recording
    /// both refused (D57, 2026-10-30). The selection decides what the sidebar
    /// lists; a pane somebody opened still says what it needs.
    static func showsSetupCard(forTab tabKey: String) -> Bool {
        !FeatureRegistry.missing(forTab: tabKey).isEmpty
    }

    /// Whether the gate hands the dimming to the pane's own marked parts
    /// instead of dimming the whole pane.
    static func leavesDimmingToParts(needsSetup: Bool, keepsUnneededPartsLive: Bool) -> Bool {
        needsSetup && keepsUnneededPartsLive
    }

    /// Whether a part marked `.needsGatedCapability()` dims: only while a
    /// parts-mode gate has its card up.
    static func dimsPart(pendingTab: String?) -> Bool {
        pendingTab != nil
    }
}

extension View {
    /// Gates this feature on its registry row. No-op for a tab with no row, so
    /// adopting a tab that needs nothing is harmless.
    func capabilityGated(_ tabKey: String, showsFeatureBehind: Bool = true, keepsUnneededPartsLive: Bool = false) -> some View {
        CapabilityGate(tabKey: tabKey, showsFeatureBehind: showsFeatureBehind,
                       keepsUnneededPartsLive: keepsUnneededPartsLive) { self }
    }
}
