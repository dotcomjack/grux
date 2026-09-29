import SwiftUI

/// The first-run flow. Three screens, each one thing.
///
/// Copy rules, which are the actual design work here and are easy to lose in a
/// later edit:
///
/// - **Second person, always.** "Your key", never the previous owner's name and
///   never a templated one. The whole reason this flow exists is that Grux used
///   to greet a stranger by somebody else's name.
/// - **Say what happens to the data, on the screen where it is asked for.** The
///   key screen says the key stays in the Keychain. The look screen says
///   nothing has left the Mac yet. Trust claims belong next to the ask, not in
///   a privacy policy nobody opens.
/// - **Every screen can be left, and that now includes gate 1.** The skip is
///   visible, never a greyed-out afterthought. A flow you cannot leave is a flow
///   people quit by force quitting, and then Grux has taught them it is
///   adversarial. This bullet used to carve gate 1 out as the one exception, on
///   the grounds that with no key there is no Grux to leave the flow into. THAT
///   WAS FALSE, and the README's own first paragraph is the proof: "It talks to
///   a model you pay for directly, or to a local model with no key at all", and
///   later, "install Ollama, pull a model, and Grux will use it". Somebody who
///   does exactly that has a working Grux and could not get past the first
///   screen, because Continue needed a key, submit posted it to Anthropic, and
///   the only way out required a key already in the Keychain. The free path the
///   project leads with was unreachable on a first run. Gate 1 now has three
///   ways out: paste a key, keep the key already stored, or point Grux at a
///   local model.
/// - **No progress dots.** Three screens is short enough that a counter reads
///   as a warning about length.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var model = OnboardingModel.shared

    /// The bar under the scroll area. Screens publish it with
    /// `.onboardingPrimary`; see `OnboardingFooter.swift` for why it cannot
    /// live inside the content.
    @State private var primary: OnboardingPrimaryAction?

    var body: some View {
        ZStack {
            GruxTheme.base.ignoresSafeArea()
            // SCROLLS, because two of these screens are taller than the window
            // is allowed to be. The flow declares minHeight 520, and "How Grux
            // works" needs about 1100pt to lay out its three autonomy tiers and
            // five explanations. Rendered at the 840x560 floor it clipped its
            // own title off the top and put "Got it" on the bottom edge, so at
            // the smallest supported size the user could not reach the button
            // that leaves the screen.
            //
            // Found by rendering the view and looking at it. Nothing else would
            // have: it compiles, it passes every behavioural test, and at a
            // comfortable window size it looks finished.
            VStack(spacing: 0) {
            ScrollView {
                Self.column(for: model.stage)
            }
            // Shown at rest, not only while scrolling. A screen that overflows
            // has to LOOK like it overflows; the walk that produced the footer
            // found content cut off mid-sentence with nothing indicating it.
            .scrollIndicators(.visible)
            if let primary {
                OnboardingFooterBar(action: primary)
            }
            }
        }
        .onPreferenceChange(OnboardingPrimaryActionKey.self) { primary = $0 }
        .frame(minWidth: GruxLayout.onboardingMinWidth, minHeight: GruxLayout.onboardingMinHeight)
        // Tint once here so every control in all three gates inherits it.
        // Without this the buttons render in the SYSTEM accent, which is blue
        // by default: `.keyboardShortcut(.defaultAction)` makes macOS fill
        // Continue with the system colour, and the link-styled buttons follow
        // the same accent. The result was that the FIRST screen a stranger ever
        // sees, before any of the app's own surfaces, was the one screen not
        // wearing the app's colour. Tinting the container rather than each
        // button also means a new control in any gate cannot forget.
        .tint(GruxTheme.accentPrimary)
    }
}

extension OnboardingView {
    /// One stage's screen inside the flow's content column, exactly as the
    /// scroll area shows it. Static so the pane-fit sweep renders every stage
    /// through the same builder (PaneFitSweepTests).
    @ViewBuilder
    static func column(for stage: OnboardingModel.Stage) -> some View {
        Group {
            switch stage {
            case .level:       LevelStep()
            case .modelKey:    ModelKeyStep()
            case .identity:    IdentityStep()
            case .howItWorks:  HowItWorksStep()
            case .permissions: PermissionsStep()
            case .firstLook:   FirstLookStep()
            case .clone:       CloneStep()
            case .connections: ConnectionsStep()
            case .update:      UpdateStep()
            case .welcomeBack: WelcomeBackStep()
            case .prompt:      FirstPromptStep()
            case .yourGrux:    YourGruxStep()
            case .setup:       SetupStep()
            case .done:        Color.clear
            }
        }
        // The question is the accepted shape A: one wide field, centred.
        .frame(maxWidth: stage == .prompt ? 640 : 520)
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Gate 1, the model key

/// The gate that decides what chat talks to. 15 registry rows name
/// `key.anthropic` in some slot, so without a model attached Grux is an empty
/// shell and pretending otherwise wastes the user's first two minutes.
///
/// **It blocks until SOMETHING is attached, and a key is only one of the two
/// things that count.** This used to be written as "the only genuinely blocking
/// gate" and it blocked on the key specifically: Continue was disabled while the
/// field was empty, submit required `validate(key:)` which posts to
/// api.anthropic.com, and the single escape below needed a key already in the
/// Keychain. A user who followed the README's own instruction, install Ollama,
/// pull a model, run Grux with no account anywhere, hit a screen with no way
/// forward at all. The one path the project advertises as free was the one path
/// first run refused, and nothing in the flow said so.
///
/// So there are three ways out now and they close three different states:
///
///   1. Paste a key. The original path, unchanged.
///   2. Keep the key you already have. Only when one is stored, which means only
///      when this flow was re-run from Settings. For that user a hard block is
///      not a gate, it is a lock: the flow replaces the whole shell including
///      Settings, the stage persists across relaunch, and an Anthropic key is
///      displayed exactly once at creation, so "paste it again" can be
///      impossible. Worse, `validate` accepts anything when the provider is
///      unreachable, so the fastest way out was to type a garbage string OVER
///      the working key.
///   3. Use a local model. Probes the configured host, and on an answer turns
///      offline mode on AND records local as the provider, so the router
///      actually uses what it found.
///
/// **Path 3 agrees with `ChatReadiness` exactly, and that is the whole design
/// constraint rather than a detail.** Discovery on its own does not route
/// anything: `ModelRegistry` needs a provider selection as well as a discovered
/// server before a turn goes anywhere but Anthropic, so finding a model and
/// leaving the routing alone would send the next turn to Anthropic with an empty
/// key. Readiness calls that state `.localModelFoundButNotRouted`, not `.ready`,
/// and letting somebody leave this gate into it would have swapped a visible
/// dead end for an invisible one. So path 3 writes the selection OUTRIGHT
/// instead of leaning on the offline switch's `didSet` to write it as a side
/// effect, because that `didSet` returns on its first line when the value has
/// not changed and this screen is re-runnable from Settings with the switch
/// already on. Then it reads the route back before it closes the gate: routing
/// the model is the difference between finding one and using it, and a write
/// nobody checked is not a route.
///
/// None of the three writes anything to the Keychain except path 1, which is the
/// only one holding a secret to write.
struct ModelKeyStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var model = OnboardingModel.shared
    // Observed, or the download percentage below never redraws.
    @ObservedObject private var ollama = OllamaManager.shared
    @State private var key = ""

    // Read once. This is about what was stored before the screen appeared, and
    // re-reading it after `submit` writes would make the button flicker in.
    @State private var hasStoredKey = KeychainStore.exists(.anthropicApiKey)

    // The local-model probe, held here rather than on OnboardingModel because it
    // is about one screen's button and dies with the screen. `keyError` lives on
    // the model instead, and deliberately: a rejected key has to survive a quit
    // and relaunch on the same stage, where a half-finished probe must not.
    @State private var probingLocal = false
    @State private var localError: String?

    /// WHAT THIS MAC ALREADY HAS, looked up before the screen asks for
    /// anything. The gate used to open with "Paste an Anthropic API key"
    /// whatever was true here, so somebody already running Ollama, which is
    /// the free path the README leads with, was asked for a key they had
    /// deliberately not got, with the local option as grey text below the
    /// fold of the primary row. The probe is one request to a loopback
    /// address and it changes what the screen leads with.
    @State private var probe: ModelGate.Probe = .none

    // The model being fetched, so the screen can say WHICH one and how big
    // rather than spinning silently through a multi-gigabyte download.
    @State private var pulling: CookbookModel?

    // P-F-1, the third path the operator chose: an OpenRouter key.
    @State private var showOpenRouter = false
    @State private var openRouterKey = ""
    @State private var probingOpenRouter = false
    @State private var openRouterError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect a model")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            // LEAD WITH WHAT IS ALREADY TRUE ON THIS MAC. Shown only when the
            // probe answered, so a Mac with no local server sees exactly the
            // screen it saw before.
            if let found = probe.model {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ModelGate.foundTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GruxTheme.textPrimary)
                    Text(ModelGate.foundDetail(model: found))
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(GruxTheme.accentPrimary.opacity(0.10)))
            }

            // Onboarding copy, deliberately NOT SetupRequirement.remediation.
            // That sentence is written for a setup card and says to add the key
            // "in Settings", which is the wrong instruction for someone standing
            // in this flow with the paste field directly below it. The capability
            // remediation stays contract-verbatim for the cards; this says what
            // is true here.
            Text("Paste an Anthropic API key. Grux stores it in your Mac's Keychain and sends it nowhere else.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-...", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(GruxTheme.Font.mono)
                .disabled(model.validating)
                // Same reason as the name field: a focused field eats Return,
                // and pasting a key then pressing Return is the whole gesture
                // this screen exists for.
                .onSubmit { if primaryEnabled { runPrimary() } }

            // The rejected-key case. Inline and adjacent, not an alert: an
            // alert would take the key out of view at the exact moment the
            // user needs to compare it against what they copied.
            if let err = model.keyError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.warnAmber)
            }

            HStack {
                Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(GruxTheme.Font.caption)
                    // SwiftUI paints Link with NSColor.linkColor and ignores
                    // .tint, so without this it is system blue: the only blue
                    // pixels in the whole flow, on the one screen that asks a
                    // stranger to paste a credential.
                    .gruxLink()
                // Only for someone who already has a working key, which means
                // only when this flow was re-run from Settings. On a real first
                // run there is nothing to keep and the gate still blocks.
                if hasStoredKey {
                    Button("Keep the key I have") { model.completeModelKey() }
                        .buttonStyle(.plain)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .disabled(model.validating)
                }
                Spacer()
                if model.validating {
                    ProgressView().controlSize(.small)
                }
                // Continue is PINNED below the scroll area now, so it cannot be
                // pushed off the bottom by an error line or the local-model
                // card above it.
            }

            // THE FREE PATH, and it belongs on this screen because it is the one
            // the project leads with. It sits BELOW the primary row rather than
            // beside "Get a key", partly because a third control in that HStack
            // does not fit the 520pt column the flow lays out at, and partly
            // because this is an alternative to the whole ask above it rather
            // than a variation on it.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Use a local model instead") { useLocalModel() }
                        .buttonStyle(.plain)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                        .disabled(model.validating || probingLocal)
                    if probingLocal {
                        ProgressView().controlSize(.small)
                        // NAMES THE MODEL AND THE SIZE. A multi-gigabyte
                        // download behind the word "Looking" is how a person
                        // decides the app has hung and quits it halfway.
                        Text(pullLabel)
                            .font(GruxTheme.Font.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                }

                Text("Runs on this Mac. No key, no account, and nothing leaves the machine. "
                     + "If there is no model here yet, Grux fetches the best one this Mac can run.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // THE UPSELL, said once and said honestly.
                //
                // A local model is what makes Grux work without an account, and
                // it is genuinely slower and weaker than Claude. Saying so here
                // is worth more than saying it later: somebody whose first
                // impression is a small local model judging Grux by it, without
                // ever being told there is a better setting, is the outcome this
                // sentence exists to prevent.
                Text("A key is worth adding when you have one. Claude is faster, "
                     + "noticeably sharper, and it is what the rest of Grux is tuned for. "
                     + "You can add one any time in Settings, Models.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // NAMES WHAT WAS PROBED, and deliberately does not offer the key
                // field as the way out. Somebody who pressed this button has
                // already told Grux which path they want, and "add a key
                // instead" is the one instruction that is certainly wrong for
                // them. The host is in the sentence because the failure is
                // almost always that the server is not up yet, and a message
                // that does not say WHERE Grux looked cannot be acted on.
                if let err = localError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.warnAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            openRouterPath
        }
        .task { await probeForLocalModel() }
        .onboardingPrimary(primaryTitle, stage: .modelKey, enabled: primaryEnabled, run: runPrimary)
    }

    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The pinned button follows what the person actually has. With a key
    /// typed it submits the key; with no key and a model already running here
    /// it uses that, which is the whole point of looking first. With neither it
    /// stays disabled, exactly as Continue always did.
    private var primaryTitle: String {
        typedKey.isEmpty && probe.model != nil ? ModelGate.useFound : "Continue"
    }

    private var primaryEnabled: Bool {
        guard !model.validating, !probingLocal, !probingOpenRouter else { return false }
        return !typedKey.isEmpty || probe.model != nil
    }

    private func runPrimary() {
        if !typedKey.isEmpty {
            submit()
        } else if probe.model != nil {
            useLocalModel()
        }
    }

    /// Ask the loopback host whether something is already serving, before the
    /// screen asks the person for anything.
    ///
    /// Only reports a model that is BOTH reachable and already pulled. A server
    /// answering with nothing on it is not something to lead with, because
    /// taking that path starts a multi-gigabyte download, and `useLocalModel`
    /// already handles that case properly for somebody who chooses it.
    private func probeForLocalModel() async {
        guard probe == .none, !hasStoredKey else { return }
        await ModelRegistry.shared.discoverLocal()
        guard ModelRegistry.shared.local != nil else { return }
        await OllamaManager.shared.refreshInstalled()
        guard let usable = GruxConfig.usableLocalModels(OllamaManager.shared.installedTags).first
        else { return }
        probe = .found(usable)
    }

    /// The third way in: one key for many models, billed by OpenRouter.
    private var openRouterPath: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(ModelPaths.openRouterButton) { withAnimation { showOpenRouter.toggle() } }
                .buttonStyle(.plain)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.accentPrimaryLight)
                .disabled(model.validating || probingLocal || probingOpenRouter)
            if showOpenRouter {
                Text(ModelPaths.openRouterBody)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("sk-or-...", text: $openRouterKey)
                        .textFieldStyle(.roundedBorder)
                        .font(GruxTheme.Font.mono)
                        .disabled(probingOpenRouter)
                    if probingOpenRouter { ProgressView().controlSize(.small) }
                    Button("Use OpenRouter") { useOpenRouter() }
                        .disabled(openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || probingOpenRouter)
                }
                Link("Get an OpenRouter key", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(GruxTheme.Font.caption)
                    .gruxLink()
                if let err = openRouterError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.warnAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Check the key, add OpenRouter as the endpoint chat routes through, and
    /// leave the gate only once the route is read back, as the local path does.
    /// Nothing is saved for a key OpenRouter refused.
    private func useOpenRouter() {
        let key = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        openRouterError = nil
        probingOpenRouter = true
        Task {
            defer { probingOpenRouter = false }
            switch await ModelPaths.checkOpenRouterKey(key) {
            case .reject(let why):
                openRouterError = why
                return
            case .accept:
                break
            }
            let store = CustomEndpointStore.shared
            guard let ep = store.add(name: "OpenRouter", baseURL: ModelPaths.openRouterBase, apiKey: key) else {
                openRouterError = "Grux could not save OpenRouter as an endpoint. Add it in Settings, Models."
                return
            }
            if ep.modelId == nil { store.setModelId(ModelPaths.openRouterModel, for: ep.id) }
            AppState.shared.config.ollamaBaseURL = ep.baseURL
            AppState.shared.saveConfig()
            ModelRegistry.shared.setActiveProvider(.custom(ep.id))
            await ModelRegistry.shared.discoverLocal()
            // POST-CONDITION, read back: chat routes to OpenRouter, and its
            // model list answered, which is what lets Chat open without a card.
            guard ModelRegistry.shared.resolvedProvider == .custom(ep.id), ModelRegistry.shared.local != nil else {
                openRouterError = "OpenRouter took the key, but Grux could not list its models to route chat there. "
                    + "Check the connection and press Use OpenRouter again."
                return
            }
            openRouterKey = ""
            model.completeModelKey()
        }
    }

    /// What the spinner is actually doing right now.
    private var pullLabel: String {
        guard let pulling else { return "Looking for a local model" }
        let progress = ollama.pulls[pulling.id]
        if let fraction = progress?.fraction {
            return String(format: "Downloading %@, %.1f GB, %d%%",
                          pulling.displayName, pulling.diskGB, Int(fraction * 100))
        }
        return String(format: "Downloading %@, %.1f GB", pulling.displayName, pulling.diskGB)
    }

    /// Where discovery looks, read for the failure sentence rather than assumed.
    ///
    /// `AppState.shared` rather than the `state` environment object, and that is
    /// load-bearing rather than a style choice: `OnboardingRenderTests` hosts
    /// each step directly with no `.environmentObject`, so any read of `state`
    /// from a body or a button action crashes the render harness rather than the
    /// app. The two are the same object at runtime.
    private var localHost: String {
        let configured = AppState.shared.config.ollamaBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "your local model host" : configured
    }

    /// Probe, and only leave the gate on an answer.
    ///
    /// The order matters. Discovery has to come first, because turning offline
    /// mode on with nothing discovered is the state `ChatReadiness` calls
    /// `.offlinePinnedButNoLocalModel`: the user would have left this screen
    /// into a chat that refuses to send and a switch they never knowingly
    /// touched. So a failed probe leaves everything exactly as it was, including
    /// the switch, and says what happened.
    ///
    /// The residual hole is named rather than papered over, and it is the same
    /// one contract section 6 records against `compare`: a server that answers
    /// while holding zero pulled models satisfies this and still cannot serve a
    /// turn, because reachability is not model availability. Closing it needs
    /// discovery to report the tag count as a first-class outcome, which is a
    /// larger change than this one and is not made here.
    private func useLocalModel() {
        localError = nil
        probingLocal = true
        Task {
            // ONE RESET, ON EVERY PATH. This method now has six exits, and
            // clearing the spinner at each of them is a rule somebody has to
            // remember at every future edit. It was already wrong once: moving
            // the reset below the first guard left the post-condition failure
            // returning with the spinner still turning, so the screen would have
            // sat there working forever on a run that had already stopped.
            defer { probingLocal = false }
            await ModelRegistry.shared.discoverLocal()
            probingLocal = false
            guard ModelRegistry.shared.local != nil else {
                // SAYS WHAT OLLAMA IS. "Start Ollama" assumes the reader has
                // heard of Ollama, and the person most likely to press a button
                // labelled "no key, no account" is exactly the person who has
                // not. The old sentence was a dead end dressed as a hint.
                //
                // Grux cannot install it for them: OllamaManager DISCOVERS a
                // binary at /opt/homebrew/bin or /usr/local/bin and never
                // fetches one. Saying so plainly beats implying otherwise.
                localError = "Nothing answered at \(localHost), where Grux looks for Ollama. "
                    + "Ollama is a free app that serves models on your own Mac. Install it "
                    + "from ollama.com and open it, then press this again and Grux will "
                    + "fetch a model that fits this machine."
                return
            }

            // REACHABILITY IS NOT AVAILABILITY, and this is the hole the comment
            // above used to name and leave open: a server that answers while
            // holding zero pulled models satisfied this gate and still could not
            // serve a single turn. Somebody would have left this screen believing
            // they were set up and found out at the first message they sent,
            // which is precisely how the workspace-scoped key went wrong on the
            // same flow the same day.
            //
            // Closing it needs the tag count, which OllamaManager already has.
            await OllamaManager.shared.refreshInstalled()
            // USABLE, not merely present. A server holding only the superseded
            // model has nothing Grux can drive, so it takes the fetch path.
            if GruxConfig.usableLocalModels(OllamaManager.shared.installedTags).isEmpty {
                guard let pick = Cookbook.headline(for: HardwareProfile.detect()) else {
                    localError = "There is a local server at \(localHost) but no model on it, "
                        + "and this Mac does not have the memory for any of the ones Grux "
                        + "knows how to fetch. Paste a key instead."
                    return
                }
                if let refusal = await OllamaManager.shared.pullRefusal(for: pick.id),
                   !refusal.fits {
                    localError = String(
                        format: "%@ needs %.1f GB free and %@ has %.1f GB. "
                            + "Free some space, or paste a key instead.",
                        pick.displayName, refusal.requiredGB,
                        refusal.measuredPath, refusal.availableGB)
                    return
                }
                // THE ACTUAL WIRING UP. The pick is the headline model for THIS
                // Mac, scored against its real memory budget, so a stranger gets
                // the best thing their machine can run rather than a fixed tag
                // chosen for somebody else's hardware.
                pulling = pick
                await OllamaManager.shared.pull(pick.id)
                pulling = nil
                await OllamaManager.shared.refreshInstalled()
                guard !GruxConfig.usableLocalModels(OllamaManager.shared.installedTags).isEmpty else {
                    localError = OllamaManager.shared.lastError
                        ?? "Downloading \(pick.displayName) did not finish. Try again, or paste a key."
                    return
                }
                // Re-discover, so the registry knows about what was just pulled.
                await ModelRegistry.shared.discoverLocal()
            }
            // AND POINT IT AT A MODEL THAT IS ACTUALLY HERE.
            //
            // The last hole in this sequence, and the one that still shipped a
            // broken chat. Discovery proved a server answers, the tag check
            // proved it holds something, and neither proved that the thing it
            // holds is the thing Grux asks for. On the Mac Mini the config said
            // `llama3.2:3b`, which is the shipped default and not a fact about
            // anybody's machine, while the server held qwen3:8b and qwen2.5:7b.
            //
            // Both fields, because they are one idea to a reader and two to the
            // code: chat reads `offlineLLMModel` through the registry, and the
            // background local path reads `localLLMModel`.
            if let adopt = GruxConfig.installedModelToAdopt(
                configured: AppState.shared.config.offlineLLMModel,
                installed: OllamaManager.shared.installedTags,
                headline: Cookbook.headline(for: HardwareProfile.detect())?.id) {
                AppState.shared.config.offlineLLMModel = adopt
                AppState.shared.config.localLLMModel = adopt
                AppState.shared.saveConfig()
            }

            // The switch, set exactly the way the Settings toggle sets it: its
            // `didSet` mirrors the value into GruxConfig and saves, so the choice
            // survives relaunch. Nothing here touches the Keychain, because
            // nothing here is a secret.
            AppState.shared.offlineMode = true

            // AND THE ROUTE, WRITTEN OUTRIGHT RATHER THAN AS A SIDE EFFECT OF
            // THAT VALUE CHANGING.
            //
            // `offlineMode.didSet` opens with `guard offlineMode != oldValue
            // else { return }`, so writing true over true fires nothing at all,
            // including the `setActiveProvider` call inside it. A genuine first
            // run is unaffected, because the switch really does move. This
            // screen is re-runnable from Settings ("Start over"), though, and
            // `OnboardingModel.reset()` clears the stage without clearing the
            // provider selection, so somebody who had pressed "Use Claude" or
            // "Use" on a hosted endpoint while offline mode was already on left
            // this gate with a discovered local model and their turns still
            // going wherever they had been: Claude with no key, or an endpoint
            // that keeps sending prompts off the machine under a button
            // subtitled "nothing leaves the machine". The button has to write
            // the thing it promises, not depend on a value happening to change.
            ModelRegistry.shared.setActiveProvider(.local)

            // POST-CONDITION, CHECKED RATHER THAN ASSUMED. Two separate writes
            // are what make the promise true and either could be weakened by a
            // later edit, exactly as the `didSet` route already was. So the one
            // screen whose whole purpose is to leave somebody on a working local
            // route reads the route back before it believes it, and stays put
            // with a sentence naming the problem if it did not take. Cheap, and
            // it converts a silent regression into a visible one on the screen
            // where it costs the most.
            guard ModelRegistry.shared.resolvedProvider == .local else {
                localError = "Found a model at \(localHost), but Grux is still routing chat somewhere else. Open Settings, then Models, and press Use on the local model."
                return
            }
            model.completeModelKey()
        }
    }

    private func submit() {
        let pasted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            guard await model.validate(key: pasted) else { return }
            // Keychain, never the config file on disk. KeychainStore is the
            // only sanctioned home for a secret in this app.
            _ = KeychainStore.set(.anthropicApiKey, pasted)
            model.completeModelKey()
        }
    }
}

// MARK: - Gate 2, who are you

/// One field. This is the moment Grux stops being somebody else's app, which
/// is worth a whole screen even though it costs four seconds.
struct IdentityStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var model = OnboardingModel.shared
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What should Grux call you?")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            Text("Used in your briefing and when Grux talks to you. It stays on this Mac.")
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(GruxTheme.Font.body)
                // RETURN HAS TO WORK FROM THE FIELD, and that needs BOTH of
                // these. `onSubmit` only fires on a field that holds focus, and
                // measured on a wiped Mac this screen held focus nowhere: the
                // field never took it, so Return reached neither the field's
                // submit nor the pinned button's default action, and typing a
                // name and pressing Return did nothing at all. Every other
                // screen was fine, which is why it took a walk to find.
                //
                // Focusing it is the fix and it is better anyway: the field
                // arrives filled in and ready to be typed over.
                .focused($nameFocused)
                .onSubmit { commit() }
        }
        // ALREADY FILLED IN, because macOS already knows. This field shipped
        // empty while `NSFullUserName()` sat one call away, so the first thing
        // Grux did was ask for something it could have read. Only when it looks
        // like a name: see `Identity.suggestedName`.
        .onAppear {
            if name.isEmpty { name = Identity.systemSuggestion }
            nameFocused = true
        }
        // Skippable on purpose. An empty name renders a greeting with no name,
        // which is a finished sentence, so nothing downstream needs a
        // placeholder.
        .onboardingPrimary("Continue", stage: .identity, secondary: "Skip",
                           runSecondary: { model.completeIdentity() },
                           run: commit)
    }

    /// One definition, so the pinned button and the Return key cannot drift.
    private func commit() {
        state.config.userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.saveConfig()
        model.completeIdentity()
    }
}

// MARK: - Gate 3, the first useful moment

/// `step.first_frame_reviewed`. The only screen that gives before it asks: one
/// real frame, the exact redacted text Grux would send, and an explicit
/// statement that nothing has left the machine yet.
///
/// This is deliberately the demo AND the privacy proof in one surface. Showing
/// a stranger the literal bytes that would be transmitted, before transmitting
/// them, is a stronger claim than any sentence about respecting their privacy,
/// and it costs one screen.
struct FirstLookStep: View {
    @ObservedObject private var model = OnboardingModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("See what Grux would send")
                .font(GruxTheme.Font.display)
                .foregroundStyle(GruxTheme.textPrimary)

            Text(SetupRequirement.stepFirstFrameReviewed.remediation)
                .font(GruxTheme.Font.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            FirstFrameReview()

            HStack {
                // Declining is a legitimate answer. The focus loop stays in
                // needs-setup and says why; it never becomes an error, because
                // the contract forbids a missing capability surfacing as one.
                // Advances rather than finishing outright, because at Level 3
                // there is a connections screen after this one. Finishing here
                // was correct when this was the last of three gates and became
                // wrong the moment the flow could continue: it would have
                // dropped a user who chose "everything" straight out of the flow
                // without ever offering them an inbox.
                Button("Not now") {
                    model.recordFirstLookSkipped()
                    model.advance(from: .firstLook)
                }
                    .buttonStyle(.plain)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                Button("Continue") {
                    model.recordFirstLookReviewed()
                    model.advance(from: .firstLook)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The OpenRouter path's words and its key check, pure where it can be.
enum ModelPaths {
    static let openRouterBase = "https://openrouter.ai/api/v1"
    /// DeepSeek V4 Flash: tool use, and about $0.04 per million input tokens,
    /// measured from OpenRouter's own model list on 2026-09-21. Changeable in
    /// Settings, Models, like any endpoint's model.
    static let openRouterModel = "deepseek/deepseek-v4-flash-0731"
    static let openRouterButton = "Use an OpenRouter key instead"
    static let openRouterBody = "One key for hundreds of models, billed by OpenRouter. Grux starts on DeepSeek V4 "
        + "Flash, which uses tools and is inexpensive, and you can pick any other model in Settings, Models. "
        + "The key stays in your Mac's Keychain."

    /// What OpenRouter's key endpoint says about a key. The model list is
    /// public, so reachability alone cannot tell a good key from a bad one.
    static func verdict(status: Int) -> OnboardingModel.KeyVerdict {
        switch status {
        case 200..<300: return .accept
        case 401, 403: return .reject("OpenRouter rejected that key. Check you copied all of it.")
        case 402: return .reject("That OpenRouter account has no credit left. Add some at openrouter.ai, then try again.")
        default: return .reject("OpenRouter did not answer normally (\(status)). Try again in a moment.")
        }
    }

    static func checkOpenRouterKey(_ key: String) async -> OnboardingModel.KeyVerdict {
        guard !key.isEmpty, let url = URL(string: openRouterBase + "/key") else {
            return .reject("Paste a key to continue.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return verdict(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .reject("Could not reach OpenRouter. Check the connection, or use one of the other two.")
        }
    }
}
