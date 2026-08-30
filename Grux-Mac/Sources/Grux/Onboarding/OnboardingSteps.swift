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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How Grux works")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            autonomy

            VStack(alignment: .leading, spacing: 10) {
                point("What stays here",
                      "Your notes, mail, contacts and files are read on this Mac. What goes to a model is the text of what you asked and the context it needs, and the capture layer redacts before anything is sent.")
                point("Most tabs need nothing",
                      "The majority of Grux works the moment it has a model key. Where a tab does need something, it says so on the tab, in place, and never as an error.")
                point("Core and labs",
                      "Core features are finished. Labs features are the ones being built, and they are labelled so you know which is which before you rely on one.")
                point("What it costs",
                      "You pay your model provider directly, per use. Chat shows the estimated cost of your next send at API rates, and a local model costs nothing. Terminal sessions are the exception: they run on whatever your agent CLI is already signed in to, so on a subscription they draw from that plan instead of billing you per use. There is no Grux subscription.")
                // NAMED AT FIRST RUN, which the house rule requires and which
                // nothing did. Measured 2026-08-22: the wake word appeared ZERO
                // times in this entire flow while `config.wakeWordEnabled`
                // shipped false, and the chat empty state told every user to say
                // "hey grux" from anywhere. So the one place the phrase appeared
                // was an instruction to use something switched off that had
                // never been introduced. The rule wants three things and this is
                // the missing one: named here, a permanent home in Settings, and
                // its off state explained.
                // NAMED AT FIRST RUN, per the house rule, and this one earns the
                // slot more than most: the moment a user is most likely to want
                // it is right after being told there are more credentials and
                // permissions waiting.
                point("You can hand the rest to your agent",
                      "The setup left over is mostly mechanical, and Grux will write a prompt describing exactly what this Mac still needs. Copy it from Settings, paste it into whatever coding agent you already use, and it does the parts it can. It never asks it for a credential or a permission, because it cannot get either.")
                point("What is off until you say so",
                      "Two voice features ship switched off, so Grux is not listening until you turn one on. The wake word answers to \"\(WakeWordListener.spokenPhrase)\", which is the app's name and does not change when you rename the assistant. Ambient mode transcribes continuously on this Mac and takes the same microphone, so it replaces the wake word while it runs. Both are in Settings.")
                point("Screen control is off too",
                      "Screen control lets Grux click, type and scroll for you through the macOS Accessibility API, so it can finish a task hands-free once it can see the screen. It ships off and stays off until you turn it on in Settings and grant Accessibility. With it off, Grux never moves your pointer or keyboard.")
                // NAMED AT FIRST RUN, per the house rule, and this is the one
                // that was missing entirely. Grux runs a real shell on the
                // user's machine and spends a credential they are signed in to,
                // and onboarding said nothing about either. Deliberately states
                // the MECHANISM (which credential, what concurrency does) and
                // never predicts an account consequence we cannot substantiate.
                point("Grux can run a terminal for you",
                      "Parts of Grux work by opening a headless terminal session on this Mac and driving the agent CLI you already have installed, so it can finish long jobs without you sitting there. It uses whatever that CLI is already signed in to, so on a subscription the work comes out of that plan, and Grux strips API key variables out of the session so it cannot quietly bill an API account instead. Running several sessions at once is what pushes a plan into its rate limits, so Grux caps how many it starts for you, and Settings is where you raise or lower that cap.")
                point("How to stop it",
                      "Every autonomous loop has an off switch in Settings, and the menu bar icon quits the app outright. Nothing continues after you quit.")
            }

            HStack {
                Spacer()
                Button("Got it") { model.advance(from: .howItWorks) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var autonomy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grux can improve its own code. You choose how far that goes.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            tier("TIER 0", "Proposes", "Grux writes up what it would change and waits. Nothing is built and nothing lands.", current: true)
            tier("TIER 1", "Builds", "Grux writes the change and runs the tests, then waits for you to look at it.", current: false)
            tier("TIER 2", "Lands", "Grux merges its own work once the tests pass, without asking each time.", current: false)

            Text("You are starting at TIER 0. It stays there until you move it in Settings.")
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
        if req == .permNotifications {
            _ = await CapabilityRequest.refreshedNotificationAuthorization()
        }
        if req == .permAutomation {
            CapabilityResolver.refreshAutomationObservation()
        }
        guard CapabilityResolver.isSatisfied(req) else { return }
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

            HStack {
                Spacer()
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func row(_ req: SetupRequirement) -> some View {
        let done = saved.contains(req.rawValue) || CapabilityResolver.isSatisfied(req)
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
                    HStack(spacing: GruxSpacing.s) {
                        SecureField("", text: binding(req), prompt: Text("paste here"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit { save(req) }
                        Button("Save") { save(req) }
                            .controlSize(.small)
                            .disabled(draft(req).isEmpty)
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

    /// Everything still unconnected is recorded as skipped, so each one can be
    /// offered again on the tab that needs it.
    private func finish() {
        for req in connections where !CapabilityResolver.isSatisfied(req) && !saved.contains(req.rawValue) {
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

            HStack {
                Spacer()
                // NEVER disabled, and it was for one revision. Gating the only
                // exit on an async refresh means a stalled localhost probe can
                // strand somebody on the last screen of onboarding with no way
                // out, and this flow's own rule is that every screen can be
                // left. The report is information, not a gate: the worst case
                // for pressing this early is that Grux starts without having
                // told you which local models fit, which the Local Models tab
                // will say whenever you ask it.
                Button("Start Grux") { model.advance(from: .update) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task { await refresh() }
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
            installedTags: ollama.installedTags)
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
                line("What runs here", report.capabilitySummary)
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
                Text("The Local Models tab has the full list and can download any of them.")
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
/// is the only thing that works on a first launch: the other clone path in this
/// codebase mines Grux's own transcripts and correctly returns nothing on day
/// one, because on day one there are none.
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
                Text("Nothing is readable yet. Grant the access above whenever you like, or come back from Settings. Grux works fine without this.")
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
