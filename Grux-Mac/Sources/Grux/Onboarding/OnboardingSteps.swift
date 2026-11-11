import SwiftUI

// The screens added when onboarding grew from three gates to a chosen-depth
// flow. `OnboardingView` keeps the original three; these are the new ones.
//
// One copy rule governs all of them and it is the reason the flow is shaped this
// way: NOTHING HERE IS REQUIRED. Every screen says so, every screen can be left,
// and leaving one is recorded rather than forgotten. A first run that reads as a
// checklist of demands teaches a stranger that Grux is something to get through.

// MARK: - Screen 0, how much of this do you want

/// The first thing a stranger sees, and it asks rather than assumes.
///
/// Deliberately not a progress bar over a fixed flow. The decision recorded for
/// this build was "no screen budget, configure everything upfront", with the
/// first screen choosing the depth, which is a different idea: somebody who
/// wants to hand Grux everything up front should be able to, and somebody who
/// wants a working app in a minute should not have to decline eight permissions
/// to get there. Both are legitimate, so the flow asks which one this is.
struct LevelStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @State private var choice: OnboardingModel.Level = .plusPermissions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How much do you want to set up now?")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            Text("You can change any of this later, and nothing here is permanent. Anything you skip gets offered again the first time it would actually be used.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(OnboardingModel.Level.allCases) { level in
                    levelRow(level)
                }
            }

            HStack {
                Spacer()
                Button("Continue") { model.chooseLevel(choice) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func levelRow(_ level: OnboardingModel.Level) -> some View {
        Button {
            choice = level
        } label: {
            HStack(alignment: .top, spacing: GruxSpacing.m) {
                Image(systemName: choice == level ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == level ? GruxTheme.accentPrimary : GruxTheme.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: GruxSpacing.s) {
                        Text(level.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(GruxTheme.textPrimary)
                        Text(level.estimate)
                            .font(GruxTheme.Font.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                    Text(level.summary)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(GruxSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(choice == level ? GruxTheme.accentPrimary.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(choice == level ? GruxTheme.accentPrimary.opacity(0.55)
                                            : GruxTheme.textTertiary.opacity(0.20), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - How Grux works

/// The explainer. Six things a person should know before Grux does anything,
/// and the autonomy ladder is the one that actually matters.
///
/// All three autonomy tiers are shown on ONE screen rather than introduced when
/// each is reached, because the ladder only makes sense as a ladder: TIER 2
/// lands code automatically, and somebody who meets that idea for the first time
/// when it is already switched on has been ambushed. Seeing all three while
/// sitting safely at TIER 0 is what makes the top of the ladder a choice.
struct HowItWorksStep: View {
    @ObservedObject private var model = OnboardingModel.shared

    /// It said "the moment it has a model key", read on first run by people
    /// whose chat already runs on a local model with no key (D116).
    static let mostTabsNeedNothing =
        "The majority of Grux works the moment it has a model, a local model on this Mac or a key. Where a tab does need something, it says so on the tab, in place, and never as an error."

    /// D166 item 4: it said "the capture layer redacts before anything is
    /// sent", jargon that also promised more than the code does. W53-FIX: the
    /// first rewrite said screen and mail text was blanked out, while
    /// `read_screen` sends a screenshot as it is; the second dropped the
    /// model that sorts new mail (`MailStore.judgeNeedsYou`) and notifications
    /// (`TriageClassifier`) unasked, and Focus's screenshots (`FocusWatcher`).
    /// Round 3 added listening (`AmbientMemoryExtractor`,
    /// `AmbientHourlySummarizer`), whose transcript is fenced, not redacted.
    /// Mail and notification text pass `SecretRedactor`; screenshots do not;
    /// `FilesystemTool` refuses a file that holds a key.
    static let whatStaysHere =
        "Your notes, mail, contacts and files are read on this Mac. A model gets what you ask and the context it needs to answer, which can be your mail or a picture of your screen. Grux can also have a model sort new mail and notifications, note what it hears while listening is on, and, once Focus is set up, look at your screen now and then. Passwords and keys are taken out of mail and notification text first; what it hears and a picture of your screen go as they are. When a model asks to read a file, Grux refuses one that holds an API key. Once a day Grux checks GitHub's public release page for a new version; it sends nothing about you, and Settings, General turns it off."

    enum Part { case selfUpgradeLadder, point(Wayfinding) }

    /// The screen, top to bottom. D166 item 4: it opened on the self-upgrade
    /// ladder, the one thing here that is off and stays off for a stranger, so
    /// the first words a new person read were about Grux rewriting its own
    /// code. The ladder still shows whole (see below), with the other things
    /// that are off until you say so.
    @MainActor
    static var parts: [Part] {
        [.point(Wayfinding(title: "What stays here", body: whatStaysHere)),
         .point(Wayfinding(title: "Most tabs need nothing", body: mostTabsNeedNothing)),
         .point(Wayfinding(title: "Core and labs",
                           body: "Core features are finished. Labs features are the ones being built, and they are labelled so you know which is which before you rely on one.")),
         .point(Wayfinding(title: "What it costs",
                           body: "You pay your model provider directly, per use. Chat shows the estimated cost of your next send at API rates, and a local model costs nothing. Terminal sessions are the exception: they run on whatever your agent CLI is already signed in to, so on a subscription they draw from that plan instead of billing you per use. There is no Grux subscription.")),
         // NAMED AT FIRST RUN, per the house rule, and this one earns the
         // slot more than most: the moment a user is most likely to want
         // it is right after being told there are more credentials and
         // permissions waiting.
         .point(Wayfinding(title: "You can hand the rest to your agent",
                           body: "The setup left over is mostly mechanical, and Grux will write a prompt describing exactly what this Mac still needs. Copy it from Settings, paste it into whatever coding agent you already use, and it does the parts it can. It never asks it for a credential or a permission, because it cannot get either.")),
         // REWRITTEN FOR 3.0 (P-F-1). It said two voice features ship
         // off; 3.0 has one Listening control, and the microphone opens
         // only once the person turns it on and macOS has asked. The wake
         // word is NAMED AT FIRST RUN here (measured 2026-08-22: it appeared
         // zero times in this flow while the chat empty state told every
         // user to say it).
         .point(Wayfinding(title: "What is off until you say so",
                           body: "Listening is off until you turn it on, and macOS asks for the microphone only when you do. You choose Always on, which is Ambient mode: Grux hears you all the time on this Mac and decides, in under a second, whether you were talking to it. Or you choose after the wake word, \"\(WakeWordListener.spokenPhrase)\", which is the app's name and does not change when you rename the assistant. With Always on, what it hears is kept as text on this Mac. Any model Grux uses, on this Mac or at your model provider, can read that text, for example to remember plans, facts, people and decisions you mention, passwords said aloud included. Always on's audio never leaves this Mac; the wake word uses Apple's speech recognition, which may send short audio to Apple. Change it any time in Tuning, under Acts on what I say.")),
         .point(Wayfinding(title: "Screen control is off too",
                           body: "Screen control lets Grux click, type and scroll for you through the macOS Accessibility API, so it can finish a task hands-free once it can see the screen. It ships off and stays off until you turn it on in Settings and grant Accessibility. With it off, Grux never moves your pointer or keyboard.")),
         .selfUpgradeLadder,
         // NAMED AT FIRST RUN, per the house rule. It renames the
         // person's own files, so the promise of what it never does is
         // half the point. No permission is asked here: macOS asks for
         // the folders only when the person turns it on in Settings.
         .point(Wayfinding(title: "Files can name themselves",
                           body: "Grux can rename a new screenshot, or a download with a machine-made name like IMG_4471, from the text it shows, so it reads as Acme Invoice Oct 2026 in Finder. It ships off and stays off until you turn it on in Settings. The text is read on this Mac by a model running on this Mac, and nothing about the file leaves it. It never moves a file, never renames one you named yourself, and every rename can be undone.")),
         // NAMED AT FIRST RUN, per the house rule. Grux runs a real shell on
         // the user's machine and spends a credential they are signed in to.
         // Deliberately states the MECHANISM (which credential, what
         // concurrency does) and never predicts an account consequence we
         // cannot substantiate.
         .point(Wayfinding(title: "Grux can run a terminal for you",
                           body: "Parts of Grux work by opening a headless terminal session on this Mac and driving the agent CLI you already have installed, so it can finish long jobs without you sitting there. It uses whatever that CLI is already signed in to, so on a subscription the work comes out of that plan, and Grux strips API key variables out of the session so it cannot quietly bill an API account instead. Running several sessions at once is what pushes a plan into its rate limits, so Grux caps how many it starts for you, and Settings is where you raise or lower that cap.")),
        ] + wayfinding.map { Part.point($0) } + [
         .point(Wayfinding(title: "How to stop it",
                           body: "Every autonomous loop has an off switch in Settings, and the menu bar icon quits the app outright. Nothing continues after you quit.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How Grux works")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .selfUpgradeLadder: autonomy.padding(.vertical, 6)
                    case .point(let p): point(p.title, p.body)
                    }
                }
            }
        }
        // PINNED. This screen needs about 1100pt to lay out, so its only exit
        // was always the furthest thing from the reader.
        .onboardingPrimary("Got it", stage: .howItWorks) { model.advance(from: .howItWorks) }
    }

    struct Wayfinding: Hashable { let title: String; let body: String }

    /// P-F-1, Task F4: where things live, named once during the flow, because
    /// "named at first run" is the part of the discoverability lock that rots
    /// silently. Tuning joined when it existed (P-E-2); the Decisions key is
    /// named here and offered again in setup's extras, as decided.
    @MainActor
    static var wayfinding: [Wayfinding] {
        [
            Wayfinding(title: OptimizeCopy.title,
                       body: "The card in the panel. Four doors: tune how Grux behaves, say what you want changed and Grux writes a work order your own coding agent builds, hand your setup to that agent as a bundle, or let Grux propose its own upgrades."),
            Wayfinding(title: "Now",
                       body: "The short list under the input. Only things with an action: an approval, mail that needs you, a job running, the next thing on your day, something left to set up. Empty means nothing needs you."),
            Wayfinding(title: "The command palette",
                       body: "Press \(PaletteHotkeyConfig.spokenShortcut) anywhere: every surface, the microphone and your workflows, a few letters away. Anything you open earns a spot in Recent at the foot of the panel."),
            Wayfinding(title: TuningCopy.title,
                       body: "How sure Grux must be before it acts, how often it may interrupt you, what it may spend and what it remembers, on one page. The first door under Optimize Grux, or right click the orb."),
            Wayfinding(title: HowItWorksCopy.decisionsKeyTitle, body: HowItWorksCopy.decisionsKeyBody),
            // R10.2: the only first-run statement of how to turn this door on.
            Wayfinding(title: "The Developer door",
                       body: DoorsCopy.developer.body + " The switch is in Settings, under General."),
            Wayfinding(title: "The Labs door", body: DoorsCopy.labs.body + " Reach it from the palette."),
        ]
    }

    private var autonomy: some View {
        let c = AppState.shared.config
        let card = HowItWorksCopy.autonomy(enabled: c.foundryEnabled, tier: c.selfUpgradeMaxTier,
                                              earned: TrustLedger.shared.highestTier.rawValue)
        return VStack(alignment: .leading, spacing: 8) {
            Text(card.intro)
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            tier("TIER 0", "Proposes", "Grux writes up what it would change and waits. Nothing is built and nothing lands.", current: card.current == 0)
            tier("TIER 1", "Builds", "Grux writes the change and runs the tests, then waits for you to look at it.", current: card.current == 1)
            tier("TIER 2", "Lands", "Grux merges its own work once the tests pass, without asking each time.", current: card.current == 2)

            Text(card.caption)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GruxSpacing.m)
        .background(RoundedRectangle(cornerRadius: 8).fill(GruxTheme.base.opacity(0.35)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(GruxTheme.textTertiary.opacity(0.18), lineWidth: 1)
        )
    }

    private func tier(_ name: String, _ verb: String, _ detail: String, current: Bool) -> some View {
        HStack(alignment: .top, spacing: GruxSpacing.s) {
            Text(name)
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(current ? GruxTheme.accentPrimary : GruxTheme.textTertiary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verb)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                Text(detail)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if current {
                Text("you are here")
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.accentPrimary)
            }
        }
    }

    private func point(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(body)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Permissions, one at a time, reason first

/// Levels 2 and 3. One permission per screen, its reason shown BEFORE macOS is
/// allowed to ask.
///
/// The ordering here is the entire design. A macOS permission dialog is modal,
/// written by Apple, and gives an app one line to explain itself, so a user who
/// meets the dialog cold is being asked to decide with almost no information and
/// will sensibly say no. Showing the contract's own reason on a screen they can
/// read at their own pace turns the dialog into a confirmation of something
/// already understood.
///
/// Skipping is a first-class answer and is RECORDED, not forgotten. The
/// capability then renders needs-setup wherever it is used, and the setup card
/// says the user passed on it earlier rather than introducing it as though the
/// conversation never happened.
struct PermissionsStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @State private var index = 0
    @State private var busy = false
    /// Set when a prompt returned and the permission still is not granted, which
    /// is the case that reads as a broken button if it is not spoken to.
    @State private var declined = false

    private var queue: [SetupRequirement] { CapabilityRequest.onboardingOrder }
    private var current: SetupRequirement? { index < queue.count ? queue[index] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let req = current {
                Text(req.label)
                    .font(GruxTheme.Font.display)
                    .foregroundStyle(GruxTheme.textPrimary)

                // The case for granting it, from contract section 1.2.1, shown
                // BEFORE the system prompt is raised. `rationale` is the first
                // sentence of the 140-character remediation, which is the right
                // length for a setup card and too short to answer "what do I
                // get and what do I lose" at the moment of consent. macOS gives
                // Grux one usage-description line inside its own modal and no
                // more, so this screen is the only place the question can be
                // answered. Falls back to the card text for any capability with
                // no `why`, so a new one is thin rather than blank.
                Text(req.why.isEmpty ? req.rationale : req.why)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if CapabilityRequest.style(for: req) == .systemSettingsOnly {
                    Text(req.instructions)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if declined {
                    // A DEAD END IS NOT AN ANSWER. This used to say only "still not granted,
                    // that is a fine answer" and stop, which reads as a broken button:
                    // measured during a first-run walkthrough, the person pressed Allow, saw
                    // nothing happen, and was told it was fine without being told where the
                    // switch is. It IS fine to decline, and it is not fine to be unable to
                    // find the control.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Still not granted. Nothing here is required, so you can carry on without it.")
                            .font(GruxTheme.Font.caption)
                            .foregroundStyle(GruxTheme.warnAmber)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(CapabilityRequest.howToGrant(req))
                            .font(GruxTheme.Font.caption)
                            .foregroundStyle(GruxTheme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("\(index + 1) of \(queue.count). None of these are required.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)

                // Spaced, because at the default spacing "Skip" and "Skip the
                // rest" abut into something that reads as one control with a
                // stutter in it. Seen on the Mini, not in a test.
                HStack(spacing: GruxSpacing.l) {
                    Button("Skip") { skip(req) }
                        .buttonStyle(.plain)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                    Button("Skip the rest") { finish() }
                        .buttonStyle(.plain)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    // ONCE A PROMPT HAS COME BACK EMPTY, THE PROMPT IS NOT THE ANSWER.
                    // macOS shows most of these once; pressing Allow a second time does
                    // nothing at all, which is exactly what looked broken. After a decline
                    // the button becomes the thing that CAN still work.
                    Button(CapabilityRequest.style(for: req) == .prompt && !declined
                           ? "Allow" : "Open System Settings") { grant(req) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                }
            } else {
                Color.clear.onAppear { finish() }
            }
        }
        .onAppear(perform: skipPastAlreadyGranted)
        // RE-CHECK WHEN THEY COME BACK. Sending somebody to System Settings and then making
        // them find their way back to a screen that still says "not granted" is the same
        // dead end one step later. Notifications is the one capability whose answer is
        // cached, so it is refreshed live rather than re-read from the cache.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await recheck() }
        }
        // AND POLL, because coming back is not the only way a grant lands.
        //
        // Waiting for `didBecomeActive` assumes the person returns to Grux to
        // find out whether Grux noticed. The owner granted Automation in System
        // Settings, toggled it off and on again to make something happen, and
        // watched a card that had already been told everything it needed and
        // was simply not looking. macOS permission panes update live and this
        // one has to as well.
        //
        // Safe to poll: every probe behind `isSatisfied` asks TCC what it has
        // ALREADY decided and none of them can raise a dialog. Cancelled with
        // the view, so it runs only while this screen is up.
        .task {
            while !Task.isCancelled {
                await recheck()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Re-read the CURRENT requirement and move on if it has been granted.
    ///
    /// Two capabilities cannot simply be re-read, because neither has a live
    /// answer available synchronously, and both had the same bug: a card that
    /// sent somebody to grant something and then consulted a value nothing ever
    /// updated. Notifications was cached and stale; Automation was worse, since
    /// the key it read had no writer at all.
    private func recheck() async {
        guard let req = current, !busy else { return }
        let move = await PermissionsRecheck.shouldAdvance(req, refresh: { req in
            if req == .permNotifications {
                _ = await CapabilityRequest.refreshedNotificationAuthorization()
            }
            if req == .permAutomation {
                // Off the main actor: this runs from a 2 s poll, and the probe blocks while
                // the screen is locked.
                await CapabilityResolver.refreshAutomationObservationInBackground()
            }
        }, isSatisfied: CapabilityResolver.isSatisfied, current: { current })
        guard move else { return }
        // Granted, whether they came back to tell us or not. Clear any skip recorded
        // earlier, exactly as the Allow path does, so the ledger does not keep
        // re-offering something they have now given.
        model.clearSkip(req)
        next()
    }

    /// Never ask for something the user has already granted. A returning user
    /// re-running this flow from Settings would otherwise be walked through
    /// eight screens confirming permissions they gave months ago.
    private func skipPastAlreadyGranted() {
        while index < queue.count, CapabilityResolver.isSatisfied(queue[index]) {
            index += 1
        }
    }

    private func grant(_ req: SetupRequirement) {
        declined = false
        if CapabilityRequest.style(for: req) == .systemSettingsOnly {
            CapabilityRequest.openSystemSettings(for: req)
            // Deliberately does NOT advance. The user is now in System Settings
            // and will come back; advancing would leave them returning to a
            // screen about something else entirely.
            return
        }
        busy = true
        Task {
            let granted = await CapabilityRequest.request(req)
            busy = false
            if granted {
                model.clearSkip(req)
                next()
            } else {
                declined = true
            }
        }
    }

    private func skip(_ req: SetupRequirement) {
        model.markSkipped(req)
        next()
    }

    private func next() {
        declined = false
        index += 1
        skipPastAlreadyGranted()
        if index >= queue.count { finish() }
    }

    /// Leaving early records EVERY remaining permission as skipped, not just the
    /// one on screen. Otherwise "skip the rest" would silently mean "and forget
    /// I ever offered these", and the re-offer that the whole skip ledger exists
    /// for would never happen for the ones after this.
    private func finish() {
        for req in queue[min(index, queue.count)...] where !CapabilityResolver.isSatisfied(req) {
            model.markSkipped(req)
        }
        model.advance(from: .permissions)
    }
}

/// The permissions step's re-check decision, apart from the view, so the probe can be
/// stubbed.
@MainActor
enum PermissionsRecheck {
    /// Refresh, then advance only if the requirement is granted AND still the card showing.
    ///
    /// The probe is awaited, and the person can press Skip while it is out. Deciding from
    /// the card that was showing when the probe started cleared that card's skip and called
    /// `next()` a second time, passing the card after it unseen. Read `current` afterwards,
    /// as the setup step does.
    static func shouldAdvance(_ requirement: SetupRequirement,
                              refresh: (SetupRequirement) async -> Void,
                              isSatisfied: (SetupRequirement) -> Bool,
                              current: () -> SetupRequirement?) async -> Bool {
        await refresh(requirement)
        guard current() == requirement else { return false }
        return isSatisfied(requirement)
    }
}

// MARK: - Connections, inbox last

/// Level 3. The accounts, with the inbox deliberately at the end.
///
/// The inbox is last because it is the heaviest ask in the flow: it wants a mail
/// server, an address and an app password, which is several minutes of somebody
/// else's website. Putting it anywhere but last means the people who stall on it
/// never reach the things that take five seconds.
struct ConnectionsStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @State private var drafts: [String: String] = [:]
    @State private var saved: Set<String> = []
    @State private var choices: [String: Bool] = [:]
    @State private var companionDrafts: [String: String] = [:]
    @State private var rejected: Set<String> = []

    /// Inbox LAST. The list lives on the model so a test can assert that.
    private var connections: [SetupRequirement] { OnboardingModel.connectionOrder }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your accounts")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            Text("Each of these switches on the tabs that use it. Skip anything you do not want, and Grux will offer it again the first time you open the tab that needs it.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(connections, id: \.rawValue) { req in
                row(req)
            }

            // C12: the door to the brand-scoped rows, named before they exist.
            AddBrandRow()

            HStack {
                Spacer()
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func row(_ req: SetupRequirement) -> some View {
        let companion = CapabilityResolver.companion(for: req)
        let done = OnboardingModel.connectionDone(savedHere: saved.contains(req.rawValue),
                                                  satisfied: CapabilityResolver.isSatisfied(req),
                                                  hasCompanion: companion != nil)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: GruxSpacing.s) {
                Text(req.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                Spacer(minLength: 0)
                // A switch shows its own state, so a badge beside it would say
                // the same thing twice, and "connected" is the wrong word for a
                // choice that connects no account.
                if done && req.kind != .step {
                    Text("connected")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.successMint)
                }
            }
            Text(purpose(for: req))
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if req.kind == .step {
                // Rendered whether or not it is already on, unlike the rows
                // above. A credential is a one way door, so hiding its field
                // once it is filled is right; a switch that vanishes the moment
                // somebody flips it takes away the only place they can change
                // their mind.
                Toggle("Use this", isOn: stepBinding(req))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
            } else if !done {
                if req.kind == .key {
                    // A paste field, because a key IS one value and sending
                    // somebody to Settings mid-flow to paste it would be
                    // theatre.
                    if !keySet(req) {
                        HStack(spacing: GruxSpacing.s) {
                            SecureField("", text: binding(req), prompt: Text("paste here"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                                .onSubmit { save(req) }
                            Button("Save") { save(req) }
                                .controlSize(.small)
                                .disabled(draft(req).isEmpty)
                        }
                    }
                    // The second half (W57-FIX 3), as Settings, Credentials asks for it.
                    if let companion, !companion.isSatisfied() {
                        HStack(spacing: GruxSpacing.s) {
                            Text(companion.title)
                                .font(GruxTheme.Font.caption)
                                .foregroundStyle(GruxTheme.textSecondary)
                            TextField("", text: companionBinding(req), prompt: Text(companion.placeholder))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .frame(maxWidth: 200)
                                .onSubmit { saveCompanion(req, companion) }
                            Button("Save") { saveCompanion(req, companion) }
                                .controlSize(.small)
                                .disabled(companionDraft(req).isEmpty)
                        }
                        if rejected.contains(req.rawValue) {
                            Text("Not accepted, check the format.")
                                .font(GruxTheme.Font.caption)
                                .foregroundStyle(GruxTheme.warnAmber)
                        }
                    }
                } else {
                    // An endpoint is several fields and sometimes a server, so
                    // the honest offer is to say where it lives rather than to
                    // fake a one-line version of it here.
                    Text(req.instructions)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(GruxSpacing.m)
        .background(RoundedRectangle(cornerRadius: 8).fill(GruxTheme.base.opacity(0.35)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(GruxTheme.textTertiary.opacity(0.18), lineWidth: 1)
        )
    }

    /// What this connection is FOR, written for a screen that already has the
    /// paste field on it.
    ///
    /// Not the contract remediation, and the difference is not pedantry. Every
    /// remediation is written for the setup card and therefore tells the reader
    /// to go to Settings: `key.slack` reads "Connect Slack in Settings so Grux
    /// can read and post in your workspace". Rendered here, above a box that
    /// takes the token, it sends somebody to another screen to do the thing they
    /// are already looking at.
    ///
    /// `ModelKeyStep` had already worked this out and says so in a comment,
    /// which makes this a mistake the codebase had documented before it was
    /// repeated. Caught by rendering the screen and reading it.
    ///
    /// These do not drift from the contract because they are not saying the same
    /// thing: the contract says how to fix a missing capability, and these say
    /// what it does. The setup card still reads from the contract, and a test
    /// holds these to never containing an instruction.
    private func purpose(for req: SetupRequirement) -> String {
        OnboardingModel.connectionPurpose(for: req)
    }

    private func draft(_ req: SetupRequirement) -> String {
        drafts[req.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func binding(_ req: SetupRequirement) -> Binding<String> {
        Binding(get: { drafts[req.rawValue] ?? "" },
                set: { drafts[req.rawValue] = $0 })
    }

    /// The switch behind a `step.` row.
    ///
    /// It mirrors into view state rather than reading the resolver on every
    /// render, because the resolver answers a step out of UserDefaults and
    /// SwiftUI is not watching that: flipping the switch would write the choice
    /// and leave the control drawn in its old position. The mirror is dropped
    /// the moment this screen goes away, and the resolver is the truth again.
    private func stepBinding(_ req: SetupRequirement) -> Binding<Bool> {
        Binding(
            get: { choices[req.rawValue] ?? CapabilityResolver.isSatisfied(req) },
            set: { on in
                choices[req.rawValue] = on
                CapabilityResolver.markStepCompleted(req, on)
                if on { model.clearSkip(req) }
            })
    }

    private func save(_ req: SetupRequirement) {
        let value = draft(req)
        guard !value.isEmpty, let slot = CapabilityResolver.keychainKey(for: req) else { return }
        _ = KeychainStore.set(slot, value)
        drafts[req.rawValue] = ""
        saved.insert(req.rawValue)
        model.clearSkip(req)
    }

    /// The key itself is stored, saved here or before.
    private func keySet(_ req: SetupRequirement) -> Bool {
        if saved.contains(req.rawValue) { return true }
        guard let slot = CapabilityResolver.keychainKey(for: req) else { return false }
        return !KeychainStore.get(slot).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func companionDraft(_ req: SetupRequirement) -> String {
        companionDrafts[req.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func companionBinding(_ req: SetupRequirement) -> Binding<String> {
        Binding(get: { companionDrafts[req.rawValue] ?? "" },
                set: { companionDrafts[req.rawValue] = $0 })
    }

    private func saveCompanion(_ req: SetupRequirement, _ companion: CredentialCompanion) {
        let value = companionDraft(req)
        guard !value.isEmpty else { return }
        if companion.save(value) {
            companionDrafts[req.rawValue] = ""
            rejected.remove(req.rawValue)
            model.clearSkip(req)
        } else {
            rejected.insert(req.rawValue)
        }
    }

    /// Everything still unconnected is recorded as skipped, so each one can be
    /// offered again on the tab that needs it.
    private func finish() {
        for req in connections where !OnboardingModel.connectionDone(
            savedHere: saved.contains(req.rawValue), satisfied: CapabilityResolver.isSatisfied(req),
            hasCompanion: CapabilityResolver.companion(for: req) != nil) {
            model.markSkipped(req)
        }
        model.advance(from: .connections)
    }
}

// MARK: - The update phase

/// Runs at the end of every level, and asks for nothing.
///
/// The decision that produced this screen was for "an update phase after
/// onboarding that refreshes model knowledge, availability, and which local
/// models this machine can actually run", with a machine-specific honest warning
/// that local models lower quality.
///
/// It refreshes rather than assumes. Ollama may have been installed between
/// downloading Grux and finishing setup, and the hardware is measured here
/// rather than guessed from a tier name, so the numbers on screen are this Mac's
/// and a reader can check them against About This Mac.
///
/// The warning is the reason this is not a marketing screen. A local model is a
/// real option and Grux says so plainly, but somebody who switches to one
/// because it is free and then finds Grux markedly worse has been misled by
/// omission. `ModelUpdateReport.qualityWarning` says which of the four honest
/// situations this machine is in.
struct UpdateStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var ollama = OllamaManager.shared

    @State private var report: ModelUpdateReport?
    @State private var refreshing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What Grux found on this Mac")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            if refreshing && report == nil {
                HStack(spacing: GruxSpacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Checking models and hardware")
                        .font(GruxTheme.Font.body)
                        .foregroundStyle(GruxTheme.textSecondary)
                }
            } else if let report {
                ModelUpdateSummary(report: report)
            }

        }
        .task { await refresh() }
        // NEVER disabled, and it was for one revision. Gating the only exit on
        // an async refresh means a stalled localhost probe can strand somebody
        // on the last screen of onboarding with no way out, and this flow's own
        // rule is that every screen can be left. The report is information, not
        // a gate: the worst case for pressing this early is that Grux starts
        // without having told you which local models fit, which the Local
        // Models tab will say whenever you ask it.
        .onboardingPrimary("Start Grux", stage: .update) { model.advance(from: .update) }
    }

    /// Refreshes availability before reporting it, which is the "update" half of
    /// the name. Reading the cached state instead would describe the machine as
    /// it was when the app launched, which for a first run is before the user
    /// had a chance to install anything.
    private func refresh() async {
        refreshing = true
        ollama.detectBinary()
        await ollama.refresh()
        report = ModelUpdateReport.build(
            profile: HardwareProfile.detect(),
            hasCloudModel: CapabilityResolver.isSatisfied(.keyAnthropic),
            // The REAL route, not an inference from the key. Somebody who chose
            // "Use a local model instead" two screens ago was being told here
            // that Grux uses their cloud model by default.
            routesToCloud: ModelRegistry.shared.resolvedProvider == .anthropic,
            localServerRunning: await ollama.isHealthy(),
            installedTags: ollama.installedTags,
            chatModel: ModelRegistry.shared.resolvedProvider == .local ? ModelRegistry.shared.modelId() : nil)
        refreshing = false
    }
}

/// The report, rendered. Split out from `UpdateStep` so it can be shown with a
/// fabricated report.
///
/// That split is a verification requirement rather than tidiness. `UpdateStep`
/// fills itself from a `.task`, and a headless render lays out before that task
/// completes, so photographing it only ever captured the spinner. Every claim on
/// this screen is machine-specific, which makes "does it read correctly with
/// real content in it" exactly the question a screenshot should answer.
struct ModelUpdateSummary: View {
    let report: ModelUpdateReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                line("Your Mac", report.machineSummary)
                line("Cloud model", report.cloudSummary)
                line("Local models", report.localServerSummary)
                line("Best fit for this Mac", report.capabilitySummary)
                if let chat = report.chatSummary { line("Chat uses", chat) }
            }

            // The honest part, in its own box so it does not read as one more
            // status line.
            Text(report.qualityWarning)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(GruxSpacing.m)
                .background(RoundedRectangle(cornerRadius: 8).fill(GruxTheme.base.opacity(0.35)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(GruxTheme.textTertiary.opacity(0.18), lineWidth: 1)
                )

            if report.offersLocalOption {
                Text(HowItWorksCopy.localModelsLine(door: FeatureRegistry.disposition(for: "cookbook"),
                                                    developerUnlocked: AppState.shared.config.developerSurfacesUnlocked))
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(value)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Teach Grux the user's own voice, from writing they already have.
///
/// This is the step that makes the assistant sound like the person using it
/// rather than like a product. It indexes what they have ALREADY written, which
/// is the only thing that works on a first launch: a clone mined from Grux's own
/// transcripts would have nothing to read on day one, because on day one there
/// are none.
///
/// Three rules this screen keeps, and each one was a way to get it wrong:
///
///   1. IT NEVER BLOCKS. Indexing a mailbox is minutes of work. The user picks,
///      the ingest starts behind them, and onboarding moves on. A setup flow
///      that sits on a progress bar is a setup flow people force quit.
///   2. IT PROMISES ONLY WHAT IT CAN READ. A source behind a permission the user
///      has not granted is shown, disabled, with the actual reason, and is not
///      counted in what the button offers to do. When nothing is available the
///      primary action says so instead of pretending.
///   3. SKIPPING IS A REAL ANSWER, offered as a peer of continuing rather than
///      as fine print, and recorded so the capability system re-offers it in
///      context later instead of nagging or silently dropping it.
struct CloneStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var corpus = CorpusCoordinator.shared

    /// Whether the async permission probe has returned.
    ///
    /// NOT what drives the "checking" line. Statuses are restored from
    /// status.json the moment the coordinator exists, so gating that line on
    /// this flag rendered "Checking what is available" directly beside a fully
    /// populated list and a live Index button, which contradicts itself. The
    /// line asks `hasAnyStatus` instead: have we got anything to show yet.
    @State private var probed = false
    /// Explicit user choices. Absent means "use the default for this source",
    /// which is on when it is readable and off when it is not.
    @State private var picked: [CorpusSource: Bool] = [:]

    private var sources: [CorpusSource] { CorpusSource.allCases }

    private func status(_ s: CorpusSource) -> CorpusCoordinator.SourceStatus? { corpus.statuses[s] }
    private func isReady(_ s: CorpusSource) -> Bool { status(s)?.permission == .ready }
    private func isOn(_ s: CorpusSource) -> Bool { picked[s] ?? isReady(s) }

    private var hasAnyStatus: Bool { !corpus.statuses.isEmpty }
    private var readyCount: Int { sources.filter { isReady($0) }.count }
    private var selected: [CorpusSource] { sources.filter { isReady($0) && isOn($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Teach Grux your voice")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            Text("Grux can read writing you have already done and learn how you actually sound, so its answers come back in your words instead of a generic assistant's. This runs on this Mac. Nothing is uploaded anywhere, and nothing is read until you choose it below.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Said BEFORE the click, not toasted after it. Indexing a mailbox
            // takes minutes and this screen is about to disappear, so a user who
            // was not told would reasonably conclude the button did nothing.
            Text("Indexing keeps running in the background. You can carry on setting up.")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(sources, id: \.rawValue) { source in
                row(source)
            }

            if probed && hasAnyStatus && readyCount == 0 {
                // Honest dead end. Every source is behind something the user has
                // not granted or has no data for, so there is nothing to offer
                // and the button below says exactly that.
                Text("Nothing is readable yet. Grant the access above whenever you like, then index from Jax Command's Memory card. Grux works fine without this.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: GruxSpacing.s) {
                // A peer of the primary action, not fine print. The whole point
                // of the step is that it is optional.
                Button("Skip for now") { skip() }

                Spacer()

                if !hasAnyStatus {
                    Text("Checking what is available...")
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                }

                Button(primaryTitle) { build() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .task {
            // Cheap and side-effect free by contract: probe() reports whether a
            // source COULD be read without reading any of it.
            await corpus.refreshPermissions()
            probed = true
        }
    }

    private var primaryTitle: String {
        switch selected.count {
        case 0: return "Nothing to index"
        case 1: return "Index 1 source"
        default: return "Index \(selected.count) sources"
        }
    }

    @ViewBuilder
    private func row(_ source: CorpusSource) -> some View {
        let ready = isReady(source)
        let st = status(source)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: GruxSpacing.s) {
                Text(source.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                if ready, let n = st?.totalIndexed, n > 0 {
                    Text("\(n) already indexed")
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.successMint)
                }
                Spacer(minLength: GruxSpacing.s)
                Toggle("", isOn: Binding(
                    get: { isOn(source) },
                    set: { picked[source] = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!ready)
            }

            // The REAL reason, from the ingester's own probe, not a guess. A
            // greyed out switch with no explanation is the thing people file
            // bugs about.
            if !ready {
                Text(st?.permission.humanReason ?? "Checking...")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Start the work behind the user and move on immediately.
    private func build() {
        let chosen = selected
        guard !chosen.isEmpty else { return }
        CapabilityResolver.markStepCompleted(.stepCorpusSourcesConfirmed)
        model.clearSkip(.stepCorpusSourcesConfirmed)
        // Detached from this view's lifetime on purpose: the screen is about to
        // go away and the indexing must not go with it.
        Task { @MainActor in
            for source in chosen {
                _ = await CorpusCoordinator.shared.run(source)
            }
        }
        model.advance(from: .clone)
    }

    private func skip() {
        // Recorded rather than merely not-done, which is what lets the setup
        // card tell "never discussed" from "declined once" and re-offer this in
        // context instead of nagging.
        model.markSkipped(.stepCorpusSourcesConfirmed)
        model.advance(from: .clone)
    }
}

// MARK: - Welcome back, the one screen that admits it does not know

/// Shown when a model key exists but `onboarding.json` does not.
///
/// This screen exists because the branch it replaced answered a question it
/// could not actually answer. "Has this person set Grux up?" was tested by
/// "is there a key in the Keychain", and onboarding writes that key at step 3
/// of 10, so every person who got as far as pasting one passes the test whether
/// they finished or quit. Deleting an app leaves Keychain items behind and takes
/// Application Support with it, which makes the reinstall the ordinary case for
/// landing here rather than the exotic one.
///
/// So it asks. Two buttons, no wrong answer, and neither one deletes anything.
///
/// "Run setup" is the default action on purpose. Pressing Return without reading
/// is the single most likely thing to happen on this screen, and the failure it
/// used to cause is precisely the bug being fixed: somebody mid-flow silently
/// marked complete. Re-running the flow costs a veteran a few clicks and the
/// model key gate offers "Keep the key I have", so the cheap mistake is the
/// recoverable one.
struct WelcomeBackStep: View {
    @ObservedObject private var model = OnboardingModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome back")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            Text("Grux found your saved model key, but none of the rest of your setup. That is what a reinstall looks like from in here, and it is also what an interrupted first run looks like. Grux cannot tell those two apart, so it would rather ask than assume.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Nothing is deleted either way, and your key stays where it is. Setup offers to keep it rather than asking you to paste it again.")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                // SECONDARY, not tertiary. This is one of the two real answers on
                // the screen, and at tertiary weight on the Mini it was almost
                // invisible against the background: the same "present but nobody
                // finds it" failure that hid "Run it again" from the owner.
                Button("I am already set up") { model.keepExistingSetup() }
                    .buttonStyle(.plain)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                Spacer()
                Button("Run setup") { model.reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Copy for How Grux works that another surface or a test also reads.
enum HowItWorksCopy {
    /// The self-upgrade card: what it says and which tier it marks "you are here".
    struct Autonomy: Equatable {
        let intro: String
        /// The tier marked "you are here"; nil marks none.
        let current: Int?
        let caption: String
    }

    /// Where first run's last screen sends a person for the full local model list.
    /// It said "The Local Models tab" while Local Models sat behind the Developer
    /// door, which is off on a new install, so a stranger looked for a tab the rail
    /// did not show (D134). Every surface also opens from the palette.
    static func localModelsLine(door: FeatureRow.Disposition, developerUnlocked: Bool) -> String {
        let list = "has the full list and can download any of them"
        switch door {
        case .rail:
            return "The Local Models tab \(list)."
        case .developer where developerUnlocked:
            // "door" is the code's word; the sidebar row reads Developer (D138 item 5).
            return "Local Models, under Developer in the sidebar, \(list)."
        default:
            return "Local Models \(list). Open it from the command palette, \(PaletteHotkeyConfig.spokenShortcut)."
        }
    }

    /// It marked "TIER 0 Proposes" as "you are here" on every new install, where
    /// self-upgrade is off and Grux proposes nothing (D133). With it off no tier is
    /// marked. `tier` is Tuning's ceiling ("Self-upgrade, at most"), not where Grux
    /// is: every lane starts at TIER 0 and earns its way up to it
    /// (`FoundryEngine.cappedTier`), and a tier the governor does not know reads as
    /// TIER 0, as `TrustTier(rawValue:)` does there.
    /// `earned` is the furthest any part has climbed (`TrustLedger.highestTier`). On a
    /// re-run from Settings the card names it rather than "starting at TIER 0" (W38-FIX
    /// P3 5), but marks the tier a filed proposal acts at: the lower of the earned tier,
    /// capped as the governor caps it, and `ProposalSynthesizer.filedTier`, which
    /// `FoundryEngine.shouldAutoLand` also takes. An earned tier is a fact, never a
    /// promise to build or land, on or off (wave 39 rounds 1 and 2).
    static func autonomy(enabled: Bool, tier: Int, earned: Int = 0) -> Autonomy {
        let ceiling = TrustTier(rawValue: tier)?.rawValue ?? 0
        let earnedTier = TrustTier(rawValue: earned) ?? .propose
        let reached = FoundryEngine.cappedTier(earned: earnedTier, ceiling: ceiling).rawValue
        let acts = min(FoundryEngine.cappedTier(earned: earnedTier, ceiling: ceiling), ProposalSynthesizer.filedTier).rawValue
        let fact: String? = earnedTier == .propose ? nil
            : earnedTier.rawValue > reached ? "A part of Grux has earned TIER \(earnedTier.rawValue), and Tuning holds it to TIER \(reached)."
            : reached == ceiling ? "A part of Grux has earned TIER \(reached), the most Tuning allows."
            : "A part of Grux has earned TIER \(reached)."
        let waits = acts == 0
        // It said "until you raise it in Tuning" and "the most Tuning allows", and first
        // run never said what in Tuning holds a tier or how one is earned (D138 item 6).
        // Both name Tuning's own dial and the trust ledger's own streak.
        let dial = "\"\(TuningCopy.selfUpgradeDial)\""
        let earns = "a part of Grux moves up a tier each time \(TrustLedger.promotionStreak) of its changes in a row are approved and kept"
        let held = "stays there while \(dial) in Tuning is set to \(TuningCopy.selfUpgradeChoices[0]). Raise that limit and \(earns)."
        let climbs = earns.prefix(1).uppercased() + earns.dropFirst()
            + ", as far as TIER \(ceiling), the limit \(dial) sets in Tuning."
        guard enabled else {
            let intro = "Grux can improve its own code once you switch self-upgrade on. It is off, so Grux "
                + "proposes nothing and spends nothing on it. Turn it on in Settings or Self-Upgrade."
            if let fact {
                return Autonomy(intro: intro, current: nil,
                                caption: fact + (waits ? " Switched on, every proposal still waits for your OK before it is built."
                                                       : " Switched on, Grux works at TIER \(acts)."))
            }
            return Autonomy(
                intro: intro,
                current: nil,
                caption: ceiling == 0
                    ? "Switched on, it starts at TIER 0 and \(held)"
                    : "Switched on, it starts at TIER 0. \(climbs)")
        }
        if let fact {
            return Autonomy(intro: "Grux can improve its own code. You choose how far that goes.",
                            current: acts,
                            caption: fact + (waits ? " Every proposal still waits for your OK before it is built, so Grux works at TIER 0."
                                                   : " Grux works at TIER \(acts)."))
        }
        return Autonomy(intro: "Grux can improve its own code. You choose how far that goes.",
                        current: 0,
                        caption: ceiling == 0
                            ? "You are starting at TIER 0. It \(held)"
                            : "You are starting at TIER 0. \(climbs)")
    }

    static let decisionsKeyTitle = "The Decisions key"
    static let decisionsKeyBody = "Grux decides what you meant on this Mac, for free, matching what you say word for word. "
        + "A Decisions key (Jev, from TypeSafe) also judges what you meant when you put it another way: a busy day of "
        + "265 decisions measured $0.02. Add one in Integrations, "
        + "or in the extras at the end of setup."
}
