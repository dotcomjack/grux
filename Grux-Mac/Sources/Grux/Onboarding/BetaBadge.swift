import SwiftUI

/// The visible mark that a feature is `labs` rather than `core`.
///
/// `FeatureRow.tier` has declared this since the contract was frozen, and
/// `FeatureRegistryContractTests` verifies the value row by row against
/// `docs/feature-registry.md`. Nothing rendered it. Thirteen of the thirty-eight
/// features are labs and the shell drew them identically to core, so `tier` was a
/// documented, contract-tested field with no consumer: the same shape as
/// `assistantName`, which was a config key the persona never read.
///
/// That gap is not cosmetic. Grux ships several features as deliberately empty
/// shells whose content only arrives once the user connects their own accounts.
/// Unlabelled, an empty shell is indistinguishable from a broken tab, and the
/// person who reaches it concludes the app is broken rather than that they have
/// not set it up yet.
///
/// Deliberately NOT a new list of "beta features". A second list beside the
/// registry would be a second thing to keep in sync, and the registry is already
/// the frozen, contract-checked answer to which features are experimental.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(GruxTheme.Font.microCaps)
            .kerning(0.8)
            .foregroundStyle(GruxTheme.accentPrimary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(GruxTheme.accentPrimary.opacity(0.14))
            )
            // The accent, never red. Same reasoning as the needs-setup dot beside
            // it: labs is a state, not a failure, and red says broken.
            .accessibilityLabel("beta feature")
    }
}
