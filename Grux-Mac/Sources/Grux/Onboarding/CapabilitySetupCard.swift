import SwiftUI

/// One line item on the setup card: either a single missing capability, or an
/// `anyOf` group standing in for all of its members at once.
///
/// It exists because the card had no way to say "either of these will do". It
/// iterated `FeatureRegistry.missing(forTab:)` flat, so somebody running chat
/// with neither an account key nor a local model saw two items, each with its
/// own remediation and its own button, which reads as though both are required.
/// That is the exact misreading `CapabilityGroup` was added to prevent, so the
/// registry knew the right answer and the one surface that renders it did not.
enum CapabilitySetupEntry: Equatable, Identifiable {
    case single(SetupRequirement)
    case anyOf(needed: Int, requirements: [SetupRequirement])

    /// Stable across renders and unique within one card, which is all a ForEach
    /// needs. Prefixed so a group of one could never collide with the single it
    /// would have been.
    var id: String {
        switch self {
        case .single(let requirement):
            return "one." + requirement.rawValue
        case .anyOf(_, let requirements):
            return "any." + requirements.map(\.rawValue).joined(separator: "+")
        }
    }
}

/// The grouping rule, as a pure function of what is missing and what the row
/// declares.
///
/// PURE FOR THE SAME REASON `FeatureRegistry.unmetBlocking(of:satisfied:)` is:
/// the live answer depends on the Keychain and the discovered backend of
/// whatever machine it runs on, so a test driven through the resolver can only
/// ever observe that machine's state. Handed a list and some groups, every
/// combination is checkable from one desk, including the ones a developer's own
/// Mac can never be in.
enum CapabilitySetupLayout {

    /// Contract section 3: an unsatisfied group renders as ONE entry, under a
    /// single line naming the count.
    ///
    /// - Parameters:
    ///   - missing: `FeatureRegistry.unmetBlocking`, in contract order. A
    ///     satisfied group has already excused every one of its members, so
    ///     anything from a group that appears here belongs to a SHORT group.
    ///   - groups: the row's `anyOf`, whether short or not.
    ///
    /// THE COUNT IS WHAT IS STILL NEEDED, not `group.min` verbatim. For the one
    /// group that ships, `min` 1 of 2 with neither satisfied, the two are the
    /// same number and the line reads "Any 1 of these" exactly as the contract
    /// writes it. They come apart only on a partly satisfied group: 2 of 3 with
    /// one already resolved needs one more, and printing `min` there would say
    /// "Any 2 of these" over the two remaining items, which are both required.
    /// A count that overstates what is left to do is the same defect as listing
    /// the members separately, running one step later.
    static func entries(missing: [SetupRequirement],
                        groups: [CapabilityGroup]) -> [CapabilitySetupEntry] {
        var consumed = Set<SetupRequirement>()
        var out: [CapabilitySetupEntry] = []

        for requirement in missing {
            if consumed.contains(requirement) { continue }
            guard let group = groups.first(where: { $0.capabilities.contains(requirement) }) else {
                out.append(.single(requirement))
                continue
            }
            // In `missing` order, so a card reads in contract order however the
            // group happens to be written.
            let members = missing.filter { group.capabilities.contains($0) }
            consumed.formUnion(members)

            let alreadySatisfied = group.capabilities.count - members.count
            let needed = max(1, group.min - alreadySatisfied)
            // Needing every one that is left is not a choice, it is an AND, and
            // "Any 2 of these" over two items would be a header that changes
            // nothing except to imply one of them is optional.
            if needed >= members.count {
                for member in members { out.append(.single(member)) }
            } else {
                out.append(.anyOf(needed: needed, requirements: members))
            }
        }
        return out
    }
}

/// The one setup surface. Every credential-gated feature shows this instead of
/// inventing its own prompt.
///
/// It exists because several tabs had invented their own and each got it wrong
/// in a different way. Reactor printed a raw provider payload. The domain
/// monitor offered three alternatives at once, one of which was an environment
/// variable. None of those is a thing a stranger can do.
///
/// Contract section 3, and the rule this card is really enforcing: **a missing
/// capability never surfaces as an error.** No alert, no red, no stack trace, no
/// empty view. It names what is missing, says what to do in the contract's own
/// words, and offers the button that goes there.
struct CapabilitySetupCard: View {

    /// The feature this card is standing in for: a sidebar key, or a registry id
    /// for something that is a section rather than a tab.
    ///
    /// Both resolve, because `FeatureRegistry.row(forTab:)` falls through the
    /// alias table to a plain id lookup. That matters for the domain monitor,
    /// which is a tile on the Empire dashboard and has no tab of its own.
    let featureKey: String

    // Deliberately NOT @EnvironmentObject, and this is load-bearing rather than a
    // style preference. This card is the one setup surface in the app, so it has
    // to be safe to place in ANY window. The Empire dashboard is hosted through
    // its own NSHostingController with no AppState injected, so an environment
    // dependency here would not have degraded, it would have hit SwiftUI's
    // missing-EnvironmentObject fatal error the first time somebody without
    // registrar credentials opened that window. AppState is a singleton and the
    // deep link is a global navigation action, so reading the singleton is what
    // this always meant.
    private var state: AppState { AppState.shared }

    private var missing: [SetupRequirement] {
        FeatureRegistry.missing(forTab: featureKey)
    }

    /// What the card actually LISTS, which is not the same length as `missing`
    /// once a group is involved.
    private var entries: [CapabilitySetupEntry] {
        CapabilitySetupLayout.entries(missing: missing,
                                      groups: FeatureRegistry.row(forTab: featureKey)?.anyOf ?? [])
    }

    private var featureLabel: String {
        FeatureRegistry.row(forTab: featureKey)?.label ?? "This feature"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.l) {
            header
            ForEach(entries) { entry in
                switch entry {
                case .single(let requirement):
                    row(requirement)
                case .anyOf(let needed, let requirements):
                    groupRow(needed: needed, requirements: requirements)
                }
            }
            footer
        }
        .padding(GruxSpacing.xl)
        .frame(maxWidth: GruxLayout.contentMax, alignment: .leading)
        // Hugs its content on purpose, and this was wrong in the first build.
        // With maxHeight .infinity the card filled the pane and its background
        // covered the dimmed feature behind it, so the treatment contract
        // section 3 describes was not actually visible. A screenshot showed a
        // black pane where the point is that the user sees what they are
        // unlocking. Sizing to content is what makes the dimmed UI show.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Deliberately not "Error", "Unavailable" or "Failed". The feature is
            // not broken, it has not been set up, and those are different things
            // to read on a first run.
            // Pluralised, because the subtitle below always was and the headline
            // never was. Meetings with two missing items read "Meetings needs one
            // more thing" directly above "2 items are missing", which is the card
            // contradicting itself in the space of two lines.
            // COUNTS ENTRIES, NOT CAPABILITIES, and the difference is the same
            // misreading the grouping below exists to stop. Chat with neither
            // credential is missing two capabilities and needs ONE of them, so
            // counting the raw list put "Chat needs 2 more things" directly
            // above a group headed "Any 1 of these", which is the card
            // contradicting itself in the space of three lines.
            Text(entries.count == 1
                 ? "\(featureLabel) needs one more thing"
                 : "\(featureLabel) needs \(entries.count) more things")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(entries.count == 1
                 ? "One item is missing. Everything else is ready."
                 : "\(entries.count) items are missing. Everything else is ready.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
        }
    }

    /// A single missing capability, in its own box.
    @ViewBuilder
    private func row(_ requirement: SetupRequirement) -> some View {
        boxed { requirementBody(requirement) }
    }

    /// An unsatisfied `anyOf` group, in ONE box, under the line that says how
    /// many of it are actually needed.
    ///
    /// Every member keeps its own label, its own remediation sentence and its
    /// own button, which contract section 3 requires and which is the reason
    /// this is a grouped list rather than a summary: the user still has to pick
    /// one and do it, so each option has to remain a thing they can act on.
    @ViewBuilder
    private func groupRow(needed: Int, requirements: [SetupRequirement]) -> some View {
        boxed {
            VStack(alignment: .leading, spacing: GruxSpacing.m) {
                Text("Any \(needed) of these")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textSecondary)
                ForEach(requirements, id: \.rawValue) { requirement in
                    requirementBody(requirement)
                }
            }
        }
    }

    /// The card's one entry treatment, so a group and a single read as the same
    /// kind of thing rather than as two different designs.
    private func boxed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GruxSpacing.m)
            .background(RoundedRectangle(cornerRadius: 8).fill(GruxTheme.base.opacity(0.35)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(GruxTheme.textTertiary.opacity(0.18), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func requirementBody(_ requirement: SetupRequirement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: GruxSpacing.s) {
                Image(systemName: icon(for: requirement))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GruxTheme.accentPrimary)
                Text(requirement.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer(minLength: 0)
                if let title = actionTitle(for: requirement) {
                    Button(title) { open(requirement) }
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            // The contract's own sentence, verbatim. It is written for exactly
            // this surface, which is why onboarding says something different:
            // "add it in Settings" is right here and wrong when the paste field
            // is already on screen.
            Text(requirement.remediation)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // The re-offer. This line is the difference between a card that
            // introduces something and a card that picks up a conversation.
            //
            // "Offer an inbox as the last skippable step, and if they visit
            // mailbox in future. Same for any steps they skip during
            // onboarding." Without the skip ledger every card would read as a
            // first introduction forever, so a user who deliberately passed on
            // Contacts gets pitched it again in the same words, which is how an
            // app earns the reputation of not listening.
            if OnboardingModel.shared.wasSkipped(requirement) {
                Text("You passed on this during setup. It is still optional.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        Text("Nothing here is required to use the rest of Grux.")
            .font(GruxTheme.Font.caption)
            .foregroundStyle(GruxTheme.textTertiary)
    }

    private func icon(for requirement: SetupRequirement) -> String {
        switch requirement.kind {
        case .key:      return "key.fill"
        case .perm:     return "lock.shield"
        case .endpoint: return "link"
        case .step:     return "checkmark.circle"
        }
    }

    /// Only offers a button where there is somewhere real to go.
    ///
    /// A credential has a field, so it gets "Add it". A permission is granted in
    /// System Settings by the user and Grux cannot do it for them, so it gets a
    /// button that opens the right pane of System Settings rather than a button
    /// that pretends to fix it. A step is completed by the feature itself, so it
    /// gets no button at all and the sentence explains what will happen.
    private func actionTitle(for requirement: SetupRequirement) -> String? {
        switch requirement.kind {
        case .key:      return "Add it"
        case .endpoint: return "Set it up"
        case .perm:     return "Open System Settings"
        case .step:
            // Steps the FEATURE completes still get no button, which is the
            // original rule and still right. A step completed in Settings gets
            // a route, because otherwise its own remediation sends the user
            // somewhere the card cannot take them.
            return SettingsTabAliases.stepDestination(requirement) == nil ? nil : "Open Settings"
        }
    }

    private func open(_ requirement: SetupRequirement) {
        switch requirement.kind {
        case .key, .endpoint:
            // Reuses the deep link that already existed. A capability id resolves
            // to its own row, so this lands on the field rather than the top of
            // a list.
            state.requestedSettingsTab = requirement.rawValue
            state.requestedTab = "settings"
        case .perm:
            openSystemSettings(for: requirement)
        case .step:
            guard let tag = SettingsTabAliases.stepDestination(requirement) else { break }
            state.requestedSettingsTab = tag
            state.requestedTab = "settings"
        }
    }

    private func openSystemSettings(for requirement: SetupRequirement) {
        // The exact Privacy pane, so the user is not left hunting a long list.
        // system_audio deliberately points at Screen Recording, which is where
        // macOS actually grants it and what the contract's own remediation says.
        let anchor: String
        switch requirement {
        case .permScreenRecording, .permSystemAudio: anchor = "Privacy_ScreenCapture"
        case .permMicrophone:                        anchor = "Privacy_Microphone"
        case .permAccessibility:                     anchor = "Privacy_Accessibility"
        case .permCalendar:                          anchor = "Privacy_Calendars"
        case .permContacts:                          anchor = "Privacy_Contacts"
        case .permAutomation:                        anchor = "Privacy_Automation"
        case .permFullDiskAccess:                    anchor = "Privacy_AllFiles"
        case .permNotifications:                     anchor = "Notifications"
        default:                                     anchor = "Privacy"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
