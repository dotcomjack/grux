import SwiftUI

/// One field for every `key.` capability in the contract, generated from the
/// capability list rather than written out by hand.
///
/// This exists because the audit that preceded it found 8 of the 14 credential
/// capabilities had NO field anywhere in the app. Their remediation sentence
/// says to add the credential in Settings, and there was nowhere to add it:
/// key.resend, key.godaddy, key.openai, key.openrouter, key.github,
/// key.appstoreconnect and key.reddit were all dead ends.
///
/// Generated, so that cannot happen again. A capability added to the contract
/// gets a field here the moment `SetupRequirement` learns it, and
/// `CapabilityCredentialsTests` fails if any key capability lacks a slot to
/// write to. Hand-written fields drift; this list cannot.
///
/// Never renders an existing secret. A stored credential shows as "configured"
/// and can be replaced or removed, which is all anyone needs and avoids putting
/// a live key on screen where a screenshot or a screen share can take it.
@MainActor
struct CapabilityCredentialsSection: View {

    /// Set by a deep link from a setup card so the field the user was sent for
    /// is highlighted rather than left for them to find in a list of fourteen.
    var focus: SetupRequirement?

    @State private var drafts: [String: String] = [:]
    @State private var saved: Set<String> = []
    @State private var companionDrafts: [String: String] = [:]
    @State private var rejected: Set<String> = []

    /// Every credential a SHIPPING feature claims, in contract order.
    ///
    /// This used to be every `key.` capability in the contract, all fourteen, which
    /// put a live paste field in front of a stranger for five credentials nothing
    /// in the app reads. The rule and the reasoning live on the registry, in
    /// `FeatureRegistry.credentialsToOffer`, because it is a question about the
    /// registry and because a private computed property on a View is untestable.
    private var credentials: [SetupRequirement] { FeatureRegistry.credentialsToOffer }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.l) {
            header
            ForEach(credentials, id: \.rawValue) { req in
                row(req)
            }
        }
        .frame(maxWidth: GruxLayout.contentMax, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Credentials")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text("Every key Grux can use. All of them are empty until you paste one, and each stays in your Mac's Keychain.")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func row(_ req: SetupRequirement) -> some View {
        let isConfigured = CapabilityResolver.isSatisfied(req)
        let isFocused = focus == req

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: GruxSpacing.s) {
                Text(req.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                if isConfigured {
                    Text("configured")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.successMint)
                } else {
                    Text("not set")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                Spacer(minLength: 0)
                // The second re-offer surface, and for some capabilities the
                // ONLY one. A tab card can re-offer anything a feature needs,
                // but `key.github` is a contract capability that no feature
                // registry row consumes, so nothing would ever raise it again
                // after it was skipped during onboarding. This row is where that
                // conversation continues.
                if !isConfigured && OnboardingModel.shared.wasSkipped(req) {
                    Text("skipped in setup")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.warnAmber)
                }
                if saved.contains(req.rawValue) {
                    Text("saved")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.successMint)
                }
            }

            // The contract's own sentence, so the reason this credential exists
            // is stated in the same words the setup card used to get them here.
            Text(req.remediation)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // labelsHidden, because a macOS Form promotes a field's PLACEHOLDER
            // to a label and renders it in a leading column outside the content
            // area. "Replace the stored value" and "Paste it here" were drawing
            // to the LEFT of the detail pane, under the nav rail, which widened
            // this section past its pane at the 840pt floor: the sidebar's
            // "Watch" link collided with the GitHub row and the pane picker was
            // cut at the right. Same defect and same fix as the Models pane.
            HStack(spacing: GruxSpacing.s) {
                SecureField(isConfigured ? "Replace the stored value" : "Paste it here",
                            text: binding(for: req))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    .onSubmit { save(req) }

                Button("Save") { save(req) }
                    .disabled(draft(for: req).isEmpty)

                if isConfigured {
                    // The highest-consequence Remove in the app. An Anthropic
                    // key is displayed exactly once at creation and cannot be
                    // read back, so a misclick here can cost somebody a
                    // credential permanently, and the feature it unlocks with it.
                    DestructiveButton(
                        "Remove",
                        question: "Remove your \(req.label)?",
                        detail: "Grux deletes it from your Mac's Keychain. It is not stored "
                            + "anywhere else, so if you cannot paste it again you will need a new "
                            + "one from the provider. Anything that uses it goes back to needing "
                            + "setup.",
                        confirmLabel: "Remove key"
                    ) { remove(req) }
                        .foregroundStyle(GruxTheme.destructiveRose)
                }
            }

            // The second half of a paired credential. GoDaddy needs a secret
            // beside its key, which its own remediation sentence says. Without
            // this the field would look complete while the capability stayed
            // unsatisfied.
            if let companion = CapabilityResolver.companion(for: req) {
                VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: GruxSpacing.s) {
                    Text(companion.title)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                    TextField("", text: companionBinding(for: req),
                              prompt: Text(companion.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        .onSubmit { saveCompanion(req, companion) }
                    Button("Save") { saveCompanion(req, companion) }
                        .disabled(companionDraft(for: req).isEmpty)
                    if companion.isSatisfied() {
                        Text("set").font(GruxTheme.Font.microCaps)
                            .foregroundStyle(GruxTheme.successMint)
                    }
                    if rejected.contains(req.rawValue) {
                        Text("not accepted, check the format")
                            .font(GruxTheme.Font.caption)
                            .foregroundStyle(GruxTheme.warnAmber)
                    }
                }
                }
            }
        }
        .padding(GruxSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? GruxTheme.accentPrimary.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? GruxTheme.accentPrimary.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        // The scroll anchor the existing deep-link machinery targets, so a setup
        // card sending the user here lands on this row rather than the top of a
        // list of fourteen.
        .id(SettingsTabAliases.credentialAnchor(req))
    }

    // MARK: - Storage

    private func draft(for req: SetupRequirement) -> String {
        drafts[req.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func binding(for req: SetupRequirement) -> Binding<String> {
        Binding(
            get: { drafts[req.rawValue] ?? "" },
            set: { drafts[req.rawValue] = $0 }
        )
    }

    private func save(_ req: SetupRequirement) {
        let value = draft(for: req)
        guard !value.isEmpty, let slot = CapabilityResolver.keychainKey(for: req) else { return }
        _ = KeychainStore.set(slot, value)
        drafts[req.rawValue] = ""
        saved.insert(req.rawValue)
    }

    private func companionDraft(for req: SetupRequirement) -> String {
        companionDrafts[req.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func companionBinding(for req: SetupRequirement) -> Binding<String> {
        Binding(
            get: { companionDrafts[req.rawValue] ?? "" },
            set: { companionDrafts[req.rawValue] = $0 }
        )
    }

    private func saveCompanion(_ req: SetupRequirement, _ companion: CredentialCompanion) {
        let value = companionDraft(for: req)
        guard !value.isEmpty else { return }
        if companion.save(value) {
            companionDrafts[req.rawValue] = ""
            rejected.remove(req.rawValue)
        } else {
            // Says so rather than storing something that can never work.
            rejected.insert(req.rawValue)
        }
    }

    private func remove(_ req: SetupRequirement) {
        guard let slot = CapabilityResolver.keychainKey(for: req) else { return }
        _ = KeychainStore.set(slot, "")
        drafts[req.rawValue] = ""
        saved.remove(req.rawValue)
    }
}
