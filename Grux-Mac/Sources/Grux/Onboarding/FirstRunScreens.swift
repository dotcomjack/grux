import SwiftUI
import AVFoundation

/// P-F-1: the question path's three screens, shape A as accepted
/// (`docs/superpowers/visuals/first-run-a.png`, accepted 2026-09-22), and more
/// than one step, as the operator asked: personal from the first answer.
///
///   1. The question alone (`FirstPromptStep`).
///   2. "Here's your Grux" (`YourGruxStep`): what the answer picked, shown
///      before anything is asked, and changeable.
///   3. After the name, the model and How Grux works: setup (`SetupStep`), what
///      those features need in `SetupOrder`'s order, one thing at a time for
///      everyone, the Decisions key among the extras.
///
/// No macOS prompt fires before a screen has said what it is for: the
/// microphone button explains itself before dictation asks macOS, and every
/// permission in setup is its own screen with its reason above the button.

// MARK: - 1. The question

struct FirstPromptStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var voice = VoiceInput.shared
    @State private var text = OnboardingModel.shared.answer
    @State private var picking = false
    /// The microphone's explanation, shown before macOS is asked.
    @State private var micExplained = false
    /// True only while THIS screen started dictation, so a transcript from
    /// anywhere else never lands in the field.
    @State private var dictating = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 40)
            Text(FirstPrompt.question)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(GruxTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                TextField(FirstPrompt.placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .lineLimit(1...5)
                    .onSubmit(submit)
                    .disabled(picking)
                micButton
                Button(action: submit) {
                    Group {
                        if picking { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.right") }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(GruxTheme.accentPrimary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(picking)
                .accessibilityLabel("Continue")
            }
            .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(GruxTheme.accentPrimary.opacity(0.65), lineWidth: 1.5))

            if micExplained { micExplanation }
            if dictating, let err = voice.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.warnAmber)
            }

            HStack(alignment: .top, spacing: 12) {
                Circle().fill(GruxTheme.textTertiary).frame(width: 8, height: 8).padding(.top, 6)
                (Text(FirstPrompt.listening.lead + " ").bold().foregroundColor(GruxTheme.textPrimary)
                    + Text(FirstPrompt.listening.body).foregroundColor(GruxTheme.textSecondary))
                    .font(GruxTheme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(FirstPrompt.pickFromAList) { model.pickFromAList() }
                .buttonStyle(.plain)
                .font(GruxTheme.Font.caption)
                .underline()
                .foregroundStyle(GruxTheme.textTertiary)
            Spacer(minLength: 40)
        }
        .onChange(of: voice.transcript) { _, new in
            guard dictating else { return }
            let said = new.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { text = said }
        }
        .onChange(of: voice.isRecording) { _, recording in
            if !recording && !voice.isTranscribing { dictating = false }
        }
    }

    private var micButton: some View {
        Button {
            if voice.isRecording { voice.stop(); return }
            // THE SCREEN EXPLAINS BEFORE MACOS ASKS. Only an undecided
            // microphone gets the explanation; a granted one starts, and a
            // refused one says where the switch is.
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: startDictation()
            default: micExplained = true
            }
        } label: {
            Image(systemName: voice.isRecording && dictating ? "waveform" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(voice.isRecording && dictating ? .white : GruxTheme.textSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(voice.isRecording && dictating
                                          ? GruxTheme.accentPrimary : GruxTheme.accentPrimary.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .disabled(picking)
        .accessibilityLabel(voice.isRecording ? "Stop dictating" : "Say it instead")
    }

    private var micExplanation: some View {
        let refused = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted
        return VStack(alignment: .leading, spacing: 10) {
            Text(refused ? FirstPrompt.micRefused : FirstPrompt.micExplanation)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Type instead") { micExplained = false }
                    .buttonStyle(.plain).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                if refused {
                    Button("Open System Settings") { CapabilityRequest.openSystemSettings(for: .permMicrophone) }
                } else {
                    Button("Use the microphone") { micExplained = false; startDictation() }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    private func startDictation() {
        dictating = true
        Task { await voice.start() }
    }

    private func submit() {
        guard !picking else { return }
        if voice.isRecording { voice.stop() }
        picking = true
        let said = text
        Task {
            let ids = await IntentToFeatures.select(answer: said, engine: DecisionEngine.shared,
                                                    threshold: IntentToFeatures.threshold)
            picking = false
            model.submitAnswer(said, features: ids)
        }
    }
}

// MARK: - 2. Here's your Grux

/// Every chosen feature, what it is for, and whether it already works. Nothing
/// here asks for anything; it is the answer, shown back, and changeable.
struct YourGruxStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @State private var picked: [String] = []
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(YourGrux.title)
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)
            Text(YourGrux.lead(answer: model.answer, count: YourGrux.shown(picked).count))
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(YourGrux.shown(picked), id: \.self) { id in
                    row(id, on: true)
                }
            }

            Button(showMore ? "Hide the rest" : YourGrux.addMore(count: YourGrux.others(picked).count)) {
                withAnimation(.easeInOut(duration: 0.15)) { showMore.toggle() }
            }
            .buttonStyle(.plain)
            .font(GruxTheme.Font.caption)
            .foregroundStyle(GruxTheme.accentPrimaryLight)

            if showMore {
                VStack(spacing: 8) {
                    ForEach(YourGrux.others(picked), id: \.self) { id in row(id, on: false) }
                }
            }

            Text(YourGrux.footnote)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

        }
        .onAppear {
            picked = FeatureSelection.stored().map { YourGrux.inRegistryOrder($0) }
                ?? IntentToFeatures.keyless(answer: model.answer)
        }
        // PINNED, not in the list. Eight features are taller than the default
        // window, and this button used to go with them.
        .onboardingPrimary("Continue", stage: .yourGrux) {
            model.setFeatures(YourGrux.withRequired(picked))
            model.advance(from: .yourGrux)
        }
    }

    private func row(_ id: String, on: Bool) -> some View {
        let label = FeatureRegistry.row(id: id)?.label ?? id
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary)
                Text(YourGrux.purpose(id)).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if on {
                Text(YourGrux.status(id)).font(GruxTheme.Font.caption)
                    .foregroundStyle(YourGrux.isReady(id) ? GruxTheme.successMint : GruxTheme.textTertiary)
            }
            if !YourGrux.required.contains(id) {
                Button {
                    picked = on ? picked.filter { $0 != id } : YourGrux.inRegistryOrder(Set(picked + [id]))
                } label: {
                    Image(systemName: on ? "minus.circle" : "plus.circle.fill")
                        .foregroundStyle(on ? GruxTheme.textTertiary : GruxTheme.accentPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Remove \(label)" : "Add \(label)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(on ? 0.04 : 0.02)))
    }
}

/// What "Here's your Grux" says, pure, so a test can hold it.
@MainActor
enum YourGrux {
    static let title = "Here's your Grux"

    /// Rows every Grux has, not offered for removal: Chat is where it lives.
    static let required: Set<String> = ["chat"]

    static let footnote = "Everything else is still in the sidebar, set up the first time you open it. "
        + "Change this list any time in Settings."

    /// Lines for the floor, which the decision wording does not describe.
    static let floorPurposes: [String: String] = [
        "chat": "talk or type to Grux, and it does the rest",
        "mailbox": "shows only the mail that needs a reply",
        "calendar": "your day, and what is next",
        "notes": "notes Grux can read, write and find again",
        "tasks": "what you are doing now, and what comes next",
    ]

    static func lead(answer: String, count: Int) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Grux starts with the basics: \(count) things it sets up first. Add or remove anything."
        }
        return "From what you said, these \(count) come first. Add or remove anything; nothing is asked for yet."
    }

    static func addMore(count: Int) -> String { "Add something else (\(count) more)" }

    /// The chosen rows a person would recognise, without the plumbing every
    /// answer carries (Today, Approvals, Settings).
    static func shown(_ picked: [String]) -> [String] {
        picked.filter { !IntentToFeatures.always.contains($0) }
    }

    static func others(_ picked: [String]) -> [String] {
        let chosen = Set(picked)
        return FeatureRegistry.rows.map(\.id).filter { !chosen.contains($0) && !IntentToFeatures.always.contains($0) }
    }

    static func inRegistryOrder(_ ids: Set<String>) -> [String] {
        IntentToFeatures.ordered(IntentToFeatures.withDependencies(ids))
    }

    /// What is saved: the picks, what they depend on, and the rows every
    /// answer carries.
    static func withRequired(_ picked: [String]) -> [String] {
        inRegistryOrder(Set(picked).union(IntentToFeatures.always).union(required))
    }

    static func purpose(_ id: String) -> String {
        let raw = floorPurposes[id] ?? IntentToFeatures.purposes[id] ?? ""
        return raw.prefix(1).uppercased() + raw.dropFirst() + (raw.isEmpty ? "" : ".")
    }

    static func isReady(_ id: String) -> Bool {
        guard let row = FeatureRegistry.row(id: id) else { return true }
        return FeatureRegistry.unmetBlocking(of: row)
            .filter { !SetupOrder.handledByTheModelGate.contains($0) }.isEmpty
    }

    static func status(_ id: String) -> String {
        guard let row = FeatureRegistry.row(id: id) else { return "Ready" }
        let n = FeatureRegistry.unmetBlocking(of: row).filter { !SetupOrder.handledByTheModelGate.contains($0) }.count
        return n == 0 ? "Ready" : (n == 1 ? "Needs 1 thing" : "Needs \(n) things")
    }
}

// MARK: - 3. Setup, one thing at a time

/// The plan for the chosen features, walked screen by screen. The plan is
/// frozen when the screen appears, so an item that becomes satisfied does
/// not shift everything under the person's cursor; it shows done instead.
struct SetupStep: View {
    @ObservedObject private var model = OnboardingModel.shared
    @State private var plan: SetupOrder.Plan?
    @State private var index = 0
    @State private var oneAtATime = true
    @State private var extrasAccepted = false
    /// Bumped after an action so live states redraw.
    @State private var tick = 0
    @State private var working = false
    /// One draft PER ITEM. The whole list draws several key cards at once, and a single
    /// shared string put a key dictated into one field into every field, with every Save
    /// enabled and able to write it into the wrong service's keychain slot.
    @State private var drafts = SetupDrafts()
    @State private var decisionsKeyDraft = ""
    /// The listening choice made on THIS run, "off" included. A saved mode
    /// from before is not an answer to a question this run has not asked.
    @State private var listeningChosen = false
    /// Prompt-style permissions macOS has refused on THIS run. A second ask shows no
    /// dialog, so the button becomes the one that can still work.
    @State private var declined: Set<SetupRequirement> = []

    private var screens: [SetupOrder.Screen] {
        guard let plan else { return [] }
        return Setup.screens(for: plan, oneAtATime: oneAtATime, extrasAccepted: extrasAccepted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(Setup.title).font(GruxTheme.Font.display).foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                Toggle(Setup.wholeList, isOn: Binding(get: { !oneAtATime }, set: { oneAtATime = !$0; index = 0 }))
                    .toggleStyle(.switch).controlSize(.small).font(GruxTheme.Font.caption)
                    // The switch drew its title beside it and exposed none of its own,
                    // so it could not be named by voice. Measured in the AX tree.
                    .accessibilityLabel(Setup.wholeList)
            }
            if let screen = screens[safe: index] {
                if screen.remaining > 0 {
                    Text(Setup.left(screen.remaining))
                        .font(GruxTheme.Font.caption.monospacedDigit())
                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                }
                content(screen)
            } else {
                // TWO DIFFERENT THINGS REACH THIS BRANCH and only one of them
                // means the step is over: the plan has not been built yet, or
                // the person has walked past the last screen. `plan != nil` on
                // its own cannot tell them apart, and it resolved the wrong way
                // every time.
                //
                // The parent's `onAppear` builds the plan, and SwiftUI fires
                // this child's `onAppear` after it, while the body still shows
                // the branch chosen when there was no plan. So the guard saw a
                // plan, concluded the step was finished, and left, with nine
                // screens waiting behind it. Measured twice on a wiped Mac: the
                // step that says "set up what you picked" never appeared, on an
                // install where four of the eight picks needed something.
                //
                // The index is what actually distinguishes them.
                Color.clear.onAppear {
                    if plan != nil, index >= screens.count { finish() }
                }
            }
        }
        .id(tick)
        .onAppear {
            // COMPUTE THE PLAN, THEN DECIDE FROM THAT VALUE, never from the
            // `@State` it was just written to.
            //
            // This read `if screens.isEmpty { finish() }` on the line after
            // `plan = Setup.livePlan()`, and `screens` opens with
            // `guard let plan else { return [] }`. So the skip decision was
            // taken against whatever the state had propagated by that instant,
            // and when it had not, an empty list meant "nothing to set up"
            // rather than "not asked yet" and the whole step finished itself.
            //
            // Measured 2026-09-22 walking a first run: eleven features were
            // stored, four of them saying "Needs 1 thing" or "Needs 2 things"
            // on the screen immediately before, and setup was never shown. With
            // eleven rows that outcome is impossible on the merits, because a
            // feature is either ready, and lands in `plan.ready`, or it is not,
            // and lands in `plan.required`; either way there is a screen. The
            // only way to an empty list was a nil plan.
            let live = plan ?? Setup.livePlan()
            if plan == nil { plan = live }
            if Setup.screens(for: live, oneAtATime: oneAtATime,
                             extrasAccepted: extrasAccepted).isEmpty {
                finish()
            }
        }
        // "GRUX CHECKS AGAIN WHEN YOU COME BACK" is printed on these cards, so it has to be
        // true here as well as on the permissions step. This screen used to re-read an item
        // only right after its button, which is before anybody could have granted anything,
        // and never read Automation's observation or the Notifications cache at all.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await recheck() }
        }
        // And on every new screen, so a refusal macOS has already recorded shows the honest
        // button at once instead of after the next poll tick.
        .onChange(of: index) { _, _ in
            Task { await recheck() }
        }
        // And poll while the screen is up, because a grant lands in System Settings whether
        // or not the person comes back to tell us. Every probe asks TCC what it has already
        // decided and none raises a dialog. Cancelled with the view.
        .task {
            while !Task.isCancelled {
                await recheck()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Screens

    @ViewBuilder
    private func content(_ screen: SetupOrder.Screen) -> some View {
        switch screen {
        case .ready(let ids):
            Text(Setup.readyLead).font(GruxTheme.Font.body).foregroundStyle(GruxTheme.textSecondary)
            ForEach(ids, id: \.self) { id in
                Label(Setup.name(of: id), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(GruxTheme.successMint)
                    .font(GruxTheme.Font.body)
            }
            nextRow(primary: "Continue")
        case .one(let item, _):
            itemCard(item, walking: true)
        case .all(let items, _), .extras(let items, _):
            ForEach(items, id: \.requirement) { itemCard($0, walking: false) }
            nextRow(primary: "Continue")
        case .offerExtras(let count, _):
            Text(Setup.extrasOffer(count)).font(GruxTheme.Font.body).foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip them all") {
                    for item in plan?.optional ?? [] { model.markSkipped(item.requirement) }
                    finish()
                }
                .buttonStyle(.plain).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                Button("Go through them") { extrasAccepted = true; index += 1 }
                    .keyboardShortcut(.defaultAction)
            }
        case .decisionsKey:
            decisionsKeyCard
        }
    }

    private func done(_ item: SetupOrder.Item) -> Bool {
        Setup.isDone(item, listeningChosen: listeningChosen, micGranted: CapabilityResolver.isSatisfied(.permMicrophone))
    }

    private func itemCard(_ item: SetupOrder.Item, walking: Bool) -> some View {
        let finished = done(item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Setup.title(of: item)).font(.system(size: 15, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary)
                Spacer()
                if finished { Label("Done", systemImage: "checkmark.circle.fill").font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.successMint) }
            }
            Text(Setup.forWhom(item)).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.accentPrimaryLight)
            Text(Setup.why(item)).font(GruxTheme.Font.body).foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !finished { action(item, walking: walking) }
            if walking {
                nextRow(primary: finished ? "Continue" : nil, skip: finished ? nil : "Skip for now")
            }
        }
        .padding(walking ? 0 : 14)
        .background(walking ? nil : RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
    }

    /// The one control an item needs, by what it costs.
    @ViewBuilder
    private func action(_ item: SetupOrder.Item, walking: Bool) -> some View {
        let req = item.requirement
        if Setup.isListening(item) && !listeningChosen {
            // The listening item: its own consent, then macOS asks for the
            // microphone. Declining the consent is an answer, and leaves it off.
            HStack(spacing: 8) {
                Button("Listen all the time") { listen(.alwaysOn, walking: walking) }
                    .keyboardShortcut(walking ? .defaultAction : nil)
                Button("Only after \u{201C}Hey Grux\u{201D}") { listen(.wakeWord, walking: walking) }
                Button("Keep it off") { listen(.off, walking: walking) }
                    .buttonStyle(.plain).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
            }
            .disabled(working)
            Text(MicConsent.runningNote).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if req == .stepFirstFrameReviewed {
            FirstFrameReview()
            HStack {
                Spacer()
                Button("Looks right") {
                    model.recordFirstLookReviewed()
                    CapabilityResolver.markStepCompleted(req)
                    advanceAfterAction(walking)
                }
                .keyboardShortcut(walking ? .defaultAction : nil)
            }
        } else if req.rawValue.hasPrefix("perm.") {
            let control = Setup.permissionControl(
                style: CapabilityRequest.style(for: req),
                declined: declined.contains(req) || CapabilityRequest.recordedDenial(req))
            if control.showsHowTo {
                Text(CapabilityRequest.howToGrant(req)).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(control.label) {
                    working = true
                    Task {
                        let result = await SetupAsk.press(
                            req, control: control, request: { await CapabilityRequest.request($0) },
                            openSettings: { CapabilityRequest.openSystemSettings(for: $0) },
                            isDone: { done(item) }, isShowing: { currentItem == item })
                        working = false
                        if result.declined { declined.insert(req) }
                        if done(item) { model.clearSkip(req) }
                        if result.outcome == .advance { next() } else { tick += 1 }
                    }
                }
                .keyboardShortcut(walking ? .defaultAction : nil)
                .disabled(working)
                // On the whole list several of these sit on one screen, so each is named
                // after its item. The name starts with the words on the button.
                .accessibilityLabel(Setup.actionName(control.label, for: item, walking: walking))
            }
        } else if req.rawValue.hasPrefix("step.") && SetupOrder.cost(of: req) == .toggle {
            HStack {
                Spacer()
                Button("Turn it on") {
                    CapabilityResolver.markStepCompleted(req)
                    model.clearSkip(req)
                    advanceAfterAction(walking)
                }
                .keyboardShortcut(walking ? .defaultAction : nil)
            }
        } else if CapabilityResolver.keychainKey(for: req) != nil {
            HStack {
                SecureField("Paste it here", text: $drafts[req]).textFieldStyle(.roundedBorder).font(GruxTheme.Font.mono)
                    .accessibilityLabel(Setup.fieldName(item))
                Button("Save") {
                    guard let slot = CapabilityResolver.keychainKey(for: req) else { return }
                    let value = drafts.trimmed(req)
                    guard !value.isEmpty else { return }
                    _ = KeychainStore.set(slot, value)
                    drafts.clear(req)
                    model.clearSkip(req)
                    advanceAfterAction(walking)
                }
                .keyboardShortcut(walking ? .defaultAction : nil)
                .disabled(drafts.trimmed(req).isEmpty)
                .accessibilityLabel(Setup.saveName(item))
            }
        } else {
            // Minutes on somebody else's website, or an address Grux cannot
            // take here. Said plainly, and left for the tab that needs it.
            Text(req.instructions).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var decisionsKeyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Setup.decisionsKeyTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary)
            Text(Setup.decisionsKeyWhy).font(GruxTheme.Font.body).foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Paste a Decisions key", text: $decisionsKeyDraft)
                    .textFieldStyle(.roundedBorder).font(GruxTheme.Font.mono)
                Button("Save") {
                    let value = decisionsKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    _ = KeychainStore.set(.typesafeApiKey, value)
                    decisionsKeyDraft = ""
                    next()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(decisionsKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            nextRow(primary: nil, skip: "Skip for now")
        }
    }

    /// The move-on row, published to the pinned bar rather than drawn in the
    /// content. Setup's own screens are short one at a time, but "See the whole
    /// list" puts every remaining item on one screen, and that is exactly the
    /// shape that pushed the button off the bottom on "Here's your Grux".
    ///
    /// An empty title means there is no primary on this screen, only a skip,
    /// which several of these screens genuinely want.
    ///
    /// BOTH BUTTONS RUN `moveOn`, WHICH READS THE SCREEN WHEN PRESSED. The bar keeps
    /// an action until one arrives that READS differently, because closures cannot
    /// be compared, so two item cards in a row that both say "Skip for now" share
    /// the FIRST card's closure. A closure that captured its own item therefore
    /// skipped the wrong one: measured walking extras on a live first run, four
    /// "Skip for now" presses and a whole-list Continue over five unfinished items
    /// left the skip ledger empty, so nothing was offered again later.
    private func nextRow(primary: String?, skip: String? = nil) -> some View {
        Color.clear
            .frame(height: 0)
            .onboardingPrimary(primary ?? "", stage: .setup, enabled: primary != nil,
                               secondary: skip, runSecondary: moveOn, run: moveOn)
    }

    /// Record every unfinished item on the CURRENT screen as skipped, then move on.
    /// A screen with no items (the ready list, the Decisions key) just moves on.
    private func moveOn() {
        for item in itemsOnScreen where !done(item) { model.markSkipped(item.requirement) }
        next()
    }

    // MARK: Actions

    private func listen(_ mode: ListeningMode, walking: Bool) {
        working = true
        Task {
            AppState.shared.config.listeningMode = mode
            AppState.shared.saveConfig()
            await ListeningController.shared.apply()
            working = false
            listeningChosen = true
            // Off, while another picked feature still needs the microphone,
            // stays on this item: its Allow is the next thing it shows.
            if let item = currentItem, done(item) { advanceAfterAction(walking) } else { tick += 1 }
        }
    }

    /// The items the screen is showing right now, one when walking, several on the list.
    private var itemsOnScreen: [SetupOrder.Item] {
        switch screens[safe: index] {
        case .one(let item, _)?: return [item]
        case .all(let items, _)?, .extras(let items, _)?: return items
        default: return []
        }
    }

    /// Re-read the permissions on screen, with the stale answers refreshed first, and move
    /// on when one has been granted. Also notices a refusal macOS has recorded, so the
    /// button stops offering a prompt that will not appear.
    private func recheck() async {
        guard !working else { return }
        var redraw = false
        for item in SetupRecheck.worthRechecking(itemsOnScreen, isDone: done) {
            let req = item.requirement
            let granted = await CapabilityRequest.isSatisfiedAfterRefresh(req)
            // The person may have moved on while the probe was out.
            guard !working, itemsOnScreen.contains(item) else { return }
            let newlyDeclined = !granted && CapabilityRequest.recordedDenial(req) && !declined.contains(req)
            if newlyDeclined { declined.insert(req) }
            // Whether it is STILL the one item on screen, read after the probe came back, not
            // before it: the person may have switched to the whole list in the meantime.
            switch SetupRecheck.outcome(nowDone: done(item), showing: currentItem == item,
                                        declinedChanged: newlyDeclined) {
            case .advance:
                model.clearSkip(req)
                advanceAfterAction(true)
                return
            case .redraw:
                if done(item) { model.clearSkip(req) }
                redraw = true
            case .nothing:
                break
            }
        }
        if redraw { tick += 1 }
    }

    private var currentItem: SetupOrder.Item? {
        if case .one(let item, _)? = screens[safe: index] { return item }
        return nil
    }

    private func advanceAfterAction(_ walking: Bool) {
        if walking { next() } else { tick += 1 }
    }

    private func next() {
        drafts.clearAll()
        if index + 1 < screens.count { index += 1 } else { finish() }
    }

    private func finish() { model.advance(from: .setup) }
}

/// What setup says and decides, pure where it can be.
@MainActor
enum Setup {
    static let title = "Set up what you picked"
    static let wholeList = "See the whole list"
    static let readyLead = "Already working, nothing to do:"
    static let decisionsKeyTitle = "A Decisions key"
    static let decisionsKeyWhy = "Grux decides on this Mac for free, so this is optional. A Decisions key (Jev, from "
        + "TypeSafe) makes those calls faster and surer: a busy day of 265 decisions measured $0.02. "
        + "It lives in Integrations if you add it later, and Tuning shows what it spends."

    static func left(_ n: Int) -> String { n == 1 ? "1 left" : "\(n) left" }

    /// Names for controls that repeat on the whole list, each starting with the words the
    /// person sees, so "Click Save the Notion token" reaches the right one by voice.
    /// The field's name opens with its visible placeholder, so "Click Paste it here" still
    /// reaches it under Voice Control, and then says which key it is for.
    static func fieldName(_ item: SetupOrder.Item) -> String { "Paste it here, \(title(of: item))" }
    static func saveName(_ item: SetupOrder.Item) -> String { "Save the \(title(of: item))" }
    static func actionName(_ label: String, for item: SetupOrder.Item, walking: Bool) -> String {
        walking ? label : "\(label) for \(title(of: item))"
    }

    /// What a permission card's one button says and does.
    struct PermissionControl: Equatable {
        let label: String
        /// The where-to-go sentence, shown whenever the button sends them to System Settings.
        let showsHowTo: Bool
        let opensSettings: Bool
    }

    /// Allow only while a prompt can still appear. After macOS has refused once, asking
    /// again returns at once with no dialog, which is a button that does nothing; the one
    /// that can still work opens the pane and says where the switch is.
    static func permissionControl(style: CapabilityRequest.Style, declined: Bool) -> PermissionControl {
        let settings = style != .prompt || declined
        return PermissionControl(label: settings ? "Open System Settings" : "Allow",
                                 showsHowTo: settings, opensSettings: settings)
    }

    static func extrasOffer(_ n: Int) -> String {
        "\(n == 1 ? "One extra" : "\(n) extras") that make what you picked better. None is needed. "
            + "Go through them one at a time, or skip them all; each is offered again on the tab it helps."
    }

    /// Offered whenever no Decisions key is saved.
    static var offersDecisionsKey: Bool { !DecisionEngine.shared.hasSavedKey }

    /// ONE definition of what this step shows, so the view's list and the
    /// decision to skip the step entirely cannot disagree. They did: the skip
    /// went through a `@State` that had not been written yet, and a step that
    /// had nine screens to show closed itself instead.
    static func screens(for plan: SetupOrder.Plan,
                        oneAtATime: Bool,
                        extrasAccepted: Bool) -> [SetupOrder.Screen] {
        SetupOrder.screens(for: plan, oneAtATime: oneAtATime,
                           extrasAccepted: extrasAccepted,
                           decisionsKey: offersDecisionsKey)
    }

    static func livePlan() -> SetupOrder.Plan {
        let chosen = FeatureSelection.stored() ?? Set(IntentToFeatures.floor)
        let rows = FeatureRegistry.rows.filter { chosen.contains($0.id) }
        let c = AppState.shared.config
        return SetupOrder.plan(features: rows,
                               listening: true,
                               listeningStarted: c.listeningModeInEffect != .off,
                               satisfied: CapabilityResolver.isSatisfied)
    }

    static func isListening(_ item: SetupOrder.Item) -> Bool {
        item.requirement == .permMicrophone && item.neededBy.contains(SetupOrder.listeningId)
    }

    /// Whether an item is finished. The listening item is finished once the
    /// person has chosen on this run, AND, when another picked feature also
    /// needs the microphone, once the microphone is granted: "keep listening
    /// off" answers listening, not Meetings.
    static func isDone(_ item: SetupOrder.Item, listeningChosen: Bool, micGranted: Bool) -> Bool {
        if isListening(item) {
            let others = item.neededBy.contains { $0 != SetupOrder.listeningId }
            return listeningChosen && (!others || micGranted)
        }
        return CapabilityResolver.isSatisfied(item.requirement)
    }

    static func title(of item: SetupOrder.Item) -> String {
        isListening(item) ? ListeningSection.copy.title : item.requirement.label
    }

    /// EVERY CARD SAYS SOMETHING. `requirement.why` is written for the things
    /// macOS grants and is empty for everything that is merely configured, so
    /// the cards that ask for a server or a key fell through to nothing at all.
    /// The ask is the fallback, because a card that names a thing and then
    /// explains nothing is worse than not asking.
    static func why(_ item: SetupOrder.Item) -> String {
        if isListening(item) {
            return ListeningMode.alwaysOn.explanation + " " + ListeningSection.copy.body
        }
        let written = item.requirement.why
        return written.isEmpty ? item.requirement.ask : written
    }

    static func name(of id: String) -> String {
        id == SetupOrder.listeningId ? ListeningSection.copy.title : (FeatureRegistry.row(id: id)?.label ?? id)
    }

    static func forWhom(_ item: SetupOrder.Item) -> String {
        let names = item.neededBy.map(name(of:))
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") : names.joined()
        return "For \(list)"
    }
}

/// What a setup re-check decides, apart from the probing, so it can be checked without
/// putting a Mac into a particular permission state first.
enum SetupRecheck {
    enum Outcome: Equatable {
        case nothing
        /// Redraw so a row flips to Done, or a button to Open System Settings.
        case redraw
        /// The one item on screen is finished: move to the next screen.
        case advance
    }

    /// Only permissions are granted outside Grux, so only they can change while the screen
    /// waits; an item already done has nothing left to notice.
    static func worthRechecking(_ items: [SetupOrder.Item],
                                isDone: (SetupOrder.Item) -> Bool) -> [SetupOrder.Item] {
        items.filter { $0.requirement.rawValue.hasPrefix("perm.") && !isDone($0) }
    }

    /// `showing` is whether the item is STILL the one item on screen, read after any await.
    static func outcome(nowDone: Bool, showing: Bool, declinedChanged: Bool) -> Outcome {
        if nowDone { return showing ? .advance : .redraw }
        return declinedChanged ? .redraw : .nothing
    }
}

/// What a permission card's button does, apart from the view, so its timing can be tested
/// with a stubbed request.
@MainActor
enum SetupAsk {
    struct Result: Equatable {
        /// macOS refused, so the button should stop offering a prompt.
        let declined: Bool
        let outcome: SetupRecheck.Outcome
    }

    /// Ask or open the pane, THEN read where the person is. A prompt stays up for as long
    /// as they take to answer it, and pressing "Skip for now" meanwhile moves the screen
    /// on; a decision taken before the await advanced a second time when they answered,
    /// passing a screen they never saw.
    static func press(_ requirement: SetupRequirement,
                      control: Setup.PermissionControl,
                      request: (SetupRequirement) async -> Bool,
                      openSettings: (SetupRequirement) -> Void,
                      isDone: () -> Bool,
                      isShowing: () -> Bool) async -> Result {
        var refused = false
        if control.opensSettings {
            openSettings(requirement)
        } else if await !request(requirement) {
            refused = true
        }
        return Result(declined: refused,
                      outcome: SetupRecheck.outcome(nowDone: isDone(), showing: isShowing(),
                                                    declinedChanged: refused))
    }
}

/// The key cards' drafts, one per requirement.
struct SetupDrafts: Equatable {
    private var values: [SetupRequirement: String] = [:]

    subscript(_ requirement: SetupRequirement) -> String {
        get { values[requirement] ?? "" }
        set { values[requirement] = newValue }
    }

    func trimmed(_ requirement: SetupRequirement) -> String {
        self[requirement].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func clear(_ requirement: SetupRequirement) { values[requirement] = nil }
    mutating func clearAll() { values = [:] }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
