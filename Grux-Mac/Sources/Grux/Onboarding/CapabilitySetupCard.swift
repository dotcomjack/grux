import SwiftUI
import GruxAgentCore

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

    /// Observed so the card lists the sign-in the moment an agent run finds it
    /// expired and drops it once a sign-in lands. A singleton, not the
    /// environment, for the reason `state` above gives.
    @ObservedObject private var claudeSignIn = ClaudeSignInState.shared

    /// The restart question for a step only the setup walk answers.
    @State private var confirmingRestart = false

    /// The consent this card is asking right now, if any (D138).
    @State private var asking: SetupRequirement?
    /// Focus log's first capture, shown on the card (D157 item 3).
    @State private var reviewingFrame = false
    /// The mail account form, opened by the mail server's Set it up (D201).
    @State private var addingMailAccount = false
    /// The step whose command was just copied, so its button says so.
    @State private var copied: SetupRequirement?
    /// The outside steps missing at the last re-read.
    @State private var outsideWatch = OutsideStepWatch()

    /// Redraws the card when a step is answered, here or anywhere else.
    @ObservedObject private var setupRevision = SetupRevision.shared

    private var missing: [SetupRequirement] {
        FeatureRegistry.missing(forTab: featureKey)
    }

    /// What the card actually LISTS, which is not the same length as `missing`
    /// once a group is involved.
    private var entries: [CapabilitySetupEntry] {
        CapabilitySetupLayout.entries(missing: missing,
                                      groups: FeatureRegistry.row(forTab: featureKey)?.anyOf ?? [])
    }

    /// Every blocking item of this feature. "Everything else is ready" counts
    /// what is done among these: Mail with no account has nothing done, and
    /// the line over an empty mailbox claimed a readiness nothing had earned
    /// (audit 2026-10-13, item 5).
    private var blocking: [SetupRequirement] {
        guard let row = FeatureRegistry.row(forTab: featureKey) else { return [] }
        return row.requires + row.steps
    }

    private var listsSignIn: Bool {
        Self.listsAgentSignIn(blocking: blocking, missing: missing, signInExpired: claudeSignIn.expired)
    }

    private var cardCopy: (headline: String, subtitle: String) {
        Self.copy(featureLabel: featureLabel, blocking: blocking, listedEntries: entries.count,
                  missing: missing, signInExpired: claudeSignIn.expired)
    }

    /// The line under the headline. The headline is the one place the count
    /// lives (D97: the subtitle counted too, four ways); this line says the
    /// rest is ready only when there is a rest and it is. With nothing ready
    /// yet it says the listed items are all it takes: "Nothing else is
    /// needed." under "Focus log needs 4 more things" read as if the four
    /// were not needed either (D115 item 8).
    static func subtitle(readyBesides: Int, listed: Int) -> String {
        if readyBesides > 0 { return "Everything else is ready." }
        return listed == 1 ? "Once this is done, it is ready." : "Once these are done, it is ready."
    }

    /// D70: the card stands in for a feature that needs the agent, the agent
    /// tool is installed (so it is not listed already), and the last agent run
    /// found the Claude sign-in expired. The tool step alone counts as done
    /// when the binary is on disk, so without this the card called the agent
    /// ready while no agent could run.
    static func listsAgentSignIn(blocking: [SetupRequirement], missing: [SetupRequirement],
                                 signInExpired: Bool) -> Bool {
        signInExpired && blocking.contains(.stepAgentCliInstalled) && !missing.contains(.stepAgentCliInstalled)
    }

    static let agentSignInLabel = "Claude sign-in expired"
    static let agentSignInRemediation = "Agents cannot run until you sign in. Sign in opens Claude's login in Terminal, and it finishes in your browser."
    static let agentSignInButton = "Sign in"

    /// The sign-in line on one feature's card names that feature: Jax
    /// Command's card said "Agents cannot run" (D116 item 3).
    static func agentSignInRemediation(featureLabel: String) -> String {
        if featureLabel == "Agents" { return agentSignInRemediation }
        let name = featureLabel == "This feature" ? "this feature" : featureLabel
        return "What \(name) hands to Claude cannot run until you sign in. "
            + "Sign in opens Claude's login in Terminal, and it finishes in your browser."
    }

    /// The headline and the line under it, counting the sign-in as an item
    /// when it is listed and never as ready.
    static func copy(featureLabel: String, blocking: [SetupRequirement], listedEntries: Int,
                     missing: [SetupRequirement], signInExpired: Bool) -> (headline: String, subtitle: String) {
        let signIn = listsAgentSignIn(blocking: blocking, missing: missing, signInExpired: signInExpired)
        let listed = listedEntries + (signIn ? 1 : 0)
        let ready = max(0, blocking.count - missing.count - (signIn ? 1 : 0))
        let headline = listed == 1 ? "\(featureLabel) needs one more thing"
                                   : "\(featureLabel) needs \(listed) more things"
        return (headline, subtitle(readyBesides: ready, listed: listed))
    }

    /// The sentence under one item on this feature's card: the feature's own
    /// line when it declares one, then the line every card uses for that item,
    /// then the contract's sentence.
    static func line(for requirement: SetupRequirement, featureKey: String) -> String {
        let id = FeatureRegistry.row(forTab: featureKey)?.id ?? featureKey
        return FeatureRegistry.cardLines[id]?[requirement] ?? FeatureRegistry.cardLinesEverywhere[requirement]
            ?? requirement.remediation
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
            if listsSignIn { signInRow }
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
        .confirmationDialog(OnboardingModel.restartQuestion, isPresented: $confirmingRestart,
                            titleVisibility: .visible) {
            Button(OnboardingModel.restartTitle, role: .destructive) { OnboardingModel.shared.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(OnboardingModel.restartDetail)
        }
        // Claude Code is installed in Terminal, so nothing in Grux redraws this
        // card when it lands: re-read it while listed, and on coming back (D160).
        // The first read is on appear, so an install that lands before the
        // first tick is still seen landing (W52-FIX).
        .onAppear { recheckOutsideSteps() }
        .onReceive(Timer.publish(every: Self.recheckSeconds, on: .main, in: .common).autoconnect()) { _ in
            recheckOutsideSteps()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheckOutsideSteps()
        }
        .gruxSheet(isPresented: $reviewingFrame) {
            FirstCaptureReviewSheet { reviewingFrame = false }
        }
        .gruxSheet(isPresented: $addingMailAccount) {
            MailAccountsSheet()
        }
        .onChange(of: addingMailAccount) { _, open in
            if !open { SetupRevision.shared.bump() }
        }
        .confirmationDialog(askedConsent?.title ?? "", isPresented: askingBinding,
                            titleVisibility: .visible, presenting: askedConsent) { consent in
            Button(consent.confirm) {
                if let step = asking { Self.answer(step) }
                asking = nil
            }
            if let tag = consent.settingsTag {
                Button("Open the list in Settings") {
                    asking = nil
                    state.requestedSettingsTab = tag
                    state.requestedTab = "settings"
                }
            }
            Button(RecordingConsent.cancelTitle, role: .cancel) { asking = nil }
        } message: { consent in
            Text(consent.message)
        }
    }

    private var askedConsent: CardConsent? {
        asking.flatMap { Self.consent(for: $0, config: state.config) }
    }

    private var askingBinding: Binding<Bool> {
        Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
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
            Text(cardCopy.headline)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(cardCopy.subtitle)
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
            // The label and its button on one row where both read whole, and
            // the button under the label on a narrow pane, where sharing the
            // row wrapped "Screen Recording" a word per line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: GruxSpacing.s) {
                    requirementLabel(requirement).lineLimit(1)
                    Spacer(minLength: GruxSpacing.s)
                    requirementButton(requirement)
                }
                VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                    requirementLabel(requirement)
                    requirementButton(requirement)
                }
            }
            // The contract's own sentence, verbatim, unless this feature
            // declares its own (CR-40). It is written for exactly this surface,
            // which is why onboarding says something different: "add it in
            // Settings" is right here and wrong when the paste field is already
            // on screen.
            Text(Self.line(for: requirement, featureKey: featureKey))
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let first = Self.waitsOn(requirement, missing: missing) {
                Text(Self.waitingLine(first))
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    private func requirementLabel(_ requirement: SetupRequirement) -> some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: icon(for: requirement))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GruxTheme.accentPrimary)
            Text(requirement.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
        }
    }

    @ViewBuilder
    private func requirementButton(_ requirement: SetupRequirement) -> some View {
        if let title = actionTitle(for: requirement) {
            Button(copied == requirement ? "Copied" : title) { open(requirement) }
                .font(.system(size: 12, weight: .semibold))
                .disabled(Self.waitsOn(requirement, missing: missing) != nil)
        }
    }

    /// The expired sign-in, boxed like every other item, with the same button
    /// the Now row and a failed job on Agents offer.
    private var signInRow: some View {
        boxed {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: GruxSpacing.s) {
                        signInLabel.lineLimit(1)
                        Spacer(minLength: GruxSpacing.s)
                        signInButton
                    }
                    VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                        signInLabel
                        signInButton
                    }
                }
                Text(Self.agentSignInRemediation(featureLabel: featureLabel))
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signInLabel: some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GruxTheme.accentPrimary)
            Text(Self.agentSignInLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
        }
    }

    private var signInButton: some View {
        Button(Self.agentSignInButton) { ClaudeSignInState.shared.startSignIn() }
            .font(.system(size: 12, weight: .semibold))
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
        // NOT a checkmark. Every row on this card is a thing that is MISSING,
        // and `checkmark.circle` is the universal symbol for done, so the one
        // item a person still has to deal with wore the icon that says it is
        // already dealt with. Seen on a real screen 2026-09-24: "Jax Command
        // needs one more thing" directly above a tick. A dashed circle is the
        // same visual family and the opposite claim.
        case .step:     return "circle.dashed"
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
        Self.actionTitle(for: requirement)
    }

    enum StepRoute: Equatable {
        case settings(String)
        case restartOnboarding
        /// The card asks the consent itself (D138 item 1).
        case answerHere
        /// The card shows the first capture itself (D157 item 3).
        case reviewFrame
        /// The card copies a command to paste in Terminal (D160).
        case copy(String)
    }

    /// Steps a person completes outside Grux, which Grux detects on disk: Claude
    /// Code is installed in Terminal. The card re-reads them while it lists one,
    /// so the step clears once the install lands, with no relaunch (D160).
    static let detectedOutsideGrux: Set<SetupRequirement> = [.stepAgentCliInstalled]

    /// How often a listed outside step is re-read. A few file checks.
    static let recheckSeconds: TimeInterval = 3

    /// True when a step this card lists, of the ones done outside Grux, is now
    /// satisfied. Only those are read here: a key or a permission is read when
    /// the card redraws, and reading the Keychain on a timer could raise a prompt.
    static func landedOutsideGrux(listed: [SetupRequirement],
                                  satisfied: (SetupRequirement) -> Bool) -> Bool {
        listed.contains { detectedOutsideGrux.contains($0) && satisfied($0) }
    }

    /// What the card last saw of its outside steps, and whether one has landed
    /// since (W52-FIX: the wiring is tested here, not as text in the view).
    struct OutsideStepWatch {
        /// The outside steps missing at the last read; nil before the first.
        private(set) var missing: [SetupRequirement]?

        /// Records what is missing now, and says whether a step missing at the
        /// last read has landed. The first read only records.
        mutating func tick(nowMissing: [SetupRequirement]) -> Bool {
            defer { missing = nowMissing }
            guard let before = missing else { return false }
            return CapabilitySetupCard.landedOutsideGrux(listed: before, satisfied: { !nowMissing.contains($0) })
        }
    }

    /// Steps the feature completes while its card is up, so the card offers
    /// no button for them and the sentence says what will happen: Meetings
    /// fetches its speech model when it opens. Not the first capture: Focus
    /// log captures nothing until it is reviewed (`FocusWatcher.skipReason`).
    static let completedByUse: Set<SetupRequirement> = [.stepSpeechModelDownloaded]

    /// Steps with no button yet and no way to complete by use. Named so the
    /// debt stays visible and a new step cannot join it unnoticed
    /// (`SetupCardFirstCaptureTests`): Pair iPhone has no Settings home to
    /// route to (`TerminalSessionsOnboardingTests`).
    static let knownWithoutButton: Set<SetupRequirement> = [.stepPhonePaired]

    /// A listed step that cannot run before another listed item (D170 item 3:
    /// a live Review under a Screen Recording not yet allowed opened a sheet
    /// that could only say to grant it). Its button waits, and says on what.
    static func waitsOn(_ requirement: SetupRequirement, missing: [SetupRequirement]) -> SetupRequirement? {
        (SetupOrder.prerequisites[requirement] ?? []).first(where: missing.contains)
    }

    static func waitingLine(_ prerequisite: SetupRequirement) -> String {
        "Comes after \(prerequisite.label) above."
    }

    /// Where a step's button goes. A consent the setup walk asks is asked on
    /// the card itself: restarting the walk (wave 26) put a person back through
    /// every first-run screen to answer one question, and sending them to
    /// Settings (D72) left them hunting for it. `.restartOnboarding` stays for a
    /// first-run step the card has no question for.
    enum EndpointRoute: Equatable {
        case settings(String)
        case mailAccounts
    }

    /// Where Set it up takes an endpoint. A tag Settings does not know resolves to General,
    /// so a mail server and Ollama both landed there, on no form at all, and the Mail
    /// pane, which is only its card until an account exists, had no way in (D201). A mail
    /// account is added in the form Mail's own Accounts button opens, so the card opens
    /// that form itself; Ollama is Connect a model in Settings, Models.
    static func endpointRoute(for requirement: SetupRequirement) -> EndpointRoute {
        switch requirement {
        case .endpointImap: return .mailAccounts
        case .endpointOllama: return .settings("connect")
        default: return .settings(requirement.rawValue)
        }
    }

    static func stepRoute(for requirement: SetupRequirement) -> StepRoute? {
        if requirement == .stepFirstFrameReviewed { return .reviewFrame }
        if requirement == .stepAgentCliInstalled { return .copy(ClaudeBinaryLocator.installCommand) }
        if SettingsTabAliases.stepNeedsFirstRun(requirement) {
            return consent(for: requirement, config: .default) == nil ? .restartOnboarding : .answerHere
        }
        return SettingsTabAliases.stepDestination(requirement).map { .settings($0) }
    }

    /// What a consent card asks: the whole of what is agreed to, the words on
    /// the button that agrees, and where the thing agreed to can be changed.
    struct CardConsent: Equatable {
        let title: String
        let message: String
        let confirm: String
        let settingsTag: String?
    }

    /// The question for a consent step, or nil for any other requirement.
    /// Read from `config` so the exclusions question names this Mac's list.
    static func consent(for requirement: SetupRequirement, config: GruxConfig) -> CardConsent? {
        switch requirement {
        case .stepRecordingConsentAcknowledged:
            // The question Meetings asks before a first recording, word for word.
            return CardConsent(title: RecordingConsent.title, message: RecordingConsent.body,
                               confirm: RecordingConsent.confirmTitle, settingsTag: nil)
        case .stepCaptureExclusionsConfirmed:
            return CardConsent(title: "What Grux never looks at",
                               message: exclusionsMessage(apps: config.captureExcludedBundleIds,
                                                          titleWords: config.captureExcludedTitlePatterns),
                               confirm: "Keep this list", settingsTag: "capture-privacy")
        case .stepCorpusSourcesConfirmed:
            return CardConsent(
                title: "Learning how you write",
                message: "Grux can learn how you write from your messages, notes and sent mail, kept on this Mac. "
                    + "Confirming lets Grux check which of them it can read. Nothing is indexed by confirming.",
                confirm: "Let Grux check", settingsTag: nil)
        default:
            return nil
        }
    }

    /// The exclusions question, true to the list as it stands: the defaults are
    /// described by kind, an edited list by count, and an empty one says so.
    static func exclusionsMessage(apps: [String], titleWords: [String]) -> String {
        let where_ = "You can change it in Settings, Data & Security, Data & Capabilities, Privacy and capture."
        if apps.isEmpty && titleWords.isEmpty {
            return "Your list is empty, so Grux leaves out no app and no window. " + where_
        }
        let isDefault = apps == CapturePrivacy.defaultExcludedBundleIds
            && titleWords == CapturePrivacy.defaultExcludedTitlePatterns
        if isDefault {
            return "Grux never captures \(apps.count) apps: password managers, Keychain Access, Passwords and authenticator apps. "
                + "It also leaves out any window whose title names a password, a bank, a card number or a recovery phrase. "
                + "They are cut out before a frame is taken, even behind other windows. " + where_
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let appsLine = apps.isEmpty ? "Grux captures every app."
            : "Grux never captures \(count(apps.count, "app", "apps")) you listed."
        let wordsLine = titleWords.isEmpty ? "No window is left out by its title."
            : "It also leaves out any window whose title has \(count(titleWords.count, "title word", "title words")) you listed."
        return appsLine + " " + wordsLine + " " + where_
    }

    /// The card's yes. The same writer first run uses (and the Meetings alert,
    /// for the recording consent), so the answer reads the same everywhere.
    static func answer(_ requirement: SetupRequirement) {
        if requirement == .stepRecordingConsentAcknowledged {
            RecordingConsent.acknowledge()
        } else {
            CapabilityResolver.markStepCompleted(requirement)
            WakeLog.shared.log("setup: \(requirement.rawValue) answered on its card")
        }
        OnboardingModel.shared.clearSkip(requirement)
    }

    static func actionTitle(for requirement: SetupRequirement) -> String? {
        switch requirement.kind {
        case .key:      return "Add it"
        case .endpoint: return "Set it up"
        case .perm:     return "Open System Settings"
        case .step:
            // Steps the FEATURE completes still get no button, which is the
            // original rule and still right. A step completed in Settings gets
            // a route, because otherwise its own remediation sends the user
            // somewhere the card cannot take them.
            // A consent step is answered in the setup walk, so the button
            // restarts it, and says so in the words Settings uses. "Open
            // Settings" would land someone on a pane and leave them looking for
            // the choice; "Run setup again" (D72) was read by people who had
            // never walked these steps, and "Confirm" would claim the tap itself
            // confirms.
            // A consent the card asks itself says Review: the tap shows what is
            // agreed to, and only the dialog's own button agrees (D138 item 1).
            switch stepRoute(for: requirement) {
            case .answerHere: return "Review"
            case .reviewFrame: return "Review"
            case .copy: return "Copy the command"
            case .restartOnboarding: return OnboardingModel.restartTitle
            case .settings: return "Open Settings"
            case nil: return nil
            }
        }
    }

    /// Redraws every setup surface once a step done outside Grux lands. Reads
    /// only this feature's outside steps, never `missing` (that reads the
    /// Keychain), and compares with the last tick so a step that was already
    /// done redraws nothing.
    private func recheckOutsideSteps() {
        let nowMissing = blocking.filter {
            Self.detectedOutsideGrux.contains($0) && !CapabilityResolver.isSatisfied($0)
        }
        if outsideWatch.tick(nowMissing: nowMissing) { SetupRevision.shared.bump() }
    }

    private func open(_ requirement: SetupRequirement) {
        switch requirement.kind {
        case .key:
            // Reuses the deep link that already existed. A capability id resolves
            // to its own row, so this lands on the field rather than the top of
            // a list.
            state.requestedSettingsTab = requirement.rawValue
            state.requestedTab = "settings"
        case .endpoint:
            switch Self.endpointRoute(for: requirement) {
            case .mailAccounts:
                addingMailAccount = true
            case .settings(let tag):
                state.requestedSettingsTab = tag
                state.requestedTab = "settings"
            }
        case .perm:
            CapabilityRequest.openSystemSettings(for: requirement)
        case .step:
            switch Self.stepRoute(for: requirement) {
            case .answerHere:
                asking = requirement
            case .reviewFrame:
                reviewingFrame = true
            case .copy(let command):
                OptimizeClipboard.copy(command)
                copied = requirement
            case .restartOnboarding:
                confirmingRestart = true
            case .settings(let tag):
                state.requestedSettingsTab = tag
                state.requestedTab = "settings"
            case nil:
                break
            }
        }
    }
}

/// The first capture, reviewed on Focus log's card: the same frame and text
/// the first-run walk shows, and "Looks right" only once they are on screen.
/// With Screen Recording not granted it shows the walk's grant line instead,
/// and nothing is recorded.
struct FirstCaptureReviewSheet: View {
    let done: () -> Void
    @State private var canConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Text(SetupRequirement.stepFirstFrameReviewed.label)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(SetupRequirement.stepFirstFrameReviewed.remediation)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FirstFrameReview { canConfirm = FirstFrameReview.canConfirm($0) }
            HStack {
                Spacer()
                Button("Not now", role: .cancel) { done() }
                Button("Looks right") {
                    CapabilityResolver.recordFirstFrameReviewedOnCard()
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(GruxSpacing.l)
        .frame(width: 520)
    }
}
