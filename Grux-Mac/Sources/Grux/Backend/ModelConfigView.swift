import SwiftUI

/// What the Custom endpoints row offers for moving chat back to Claude, and
/// what it says when the route is falling back.
///
/// THE FAILURE THIS CLOSES (D127). The row offered "Use Claude" whenever
/// another provider was chosen, but Claude answers only with an Anthropic key.
/// With no key, a press either changed nothing (a running local model still
/// takes the turn, `ModelRegistry.anthropicRoute`) or, with no local model,
/// left chat with nothing to send to. The button is offered only when a press
/// makes Claude answer: the route after the press is Claude and
/// `ChatReadiness` says it can send, so neither rule can drift from this one.
enum ClaudeSwitchOffer: Equatable {
    /// Claude is already the choice: nothing to offer.
    case none
    /// A press makes Claude answer.
    case button
    /// No key: a press would not make Claude answer.
    case needsKey

    static let needsKeyLine = "Claude needs an Anthropic API key first. Add one under Anthropic API above, and a Use Claude button appears here."

    static func decide(chosen: ActiveProvider,
                       hasAnthropicKey: Bool,
                       localModelAvailable: Bool) -> ClaudeSwitchOffer {
        guard chosen != .anthropic else { return .none }
        // What a press leaves behind: Claude chosen, routed the way the router
        // routes that choice.
        let routed = ModelRegistry.anthropicRoute(hasKey: hasAnthropicKey,
                                                  hasLocal: localModelAvailable)
        let after = ChatReadiness.evaluate(hasAnthropicKey: hasAnthropicKey,
                                           localModelAvailable: localModelAvailable,
                                           chosenProvider: .anthropic,
                                           routedProvider: routed)
        return routed == .anthropic && after.canSend ? .button : .needsKey
    }

    /// The fallback sentence for a chosen route that cannot serve, nil when
    /// the chosen route is the one in use.
    static func fallbackNote(chosen: ActiveProvider,
                             routed: ActiveProvider,
                             hasAnthropicKey: Bool,
                             localBaseURL: String) -> String? {
        guard chosen != routed else { return nil }
        switch chosen {
        case .anthropic:
            // Unreachable: anthropic always resolves to itself.
            return nil
        case .local:
            return "You chose the local model at \(localBaseURL) and nothing is answering there. Start the server and press Discover local models above, and turns move back on their own."
        case .custom:
            // With no key the fallback has nothing to send to either
            // (`ChatReadiness` reads `.needsModel`), so it must not promise Claude.
            return hasAnthropicKey
                ? "You chose a custom endpoint that has since been removed, so turns fall back to Claude until you pick another one below."
                : "You chose a custom endpoint that has since been removed, so chat has nothing to send to until you pick another one below or add an Anthropic API key under Anthropic API above."
        }
    }
}

// Model + endpoint configuration sections for the Settings window. Designed to
// be dropped INSIDE SettingsView's existing Form, directly after the "Offline
// mode (local model)" section:
//
//     ModelConfigSection()
//
// Two sections render: (1) a model picker fed by ModelRegistry's discovered
// local tags, with an inline incompatibility hint when the selected model
// lacks tool use, and (2) a custom-endpoints manager (OpenRouter, vLLM,
// remote Ollama) with parse + reachability validation before save. API keys
// go to the Keychain via CustomEndpointStore, never into JSON config.
struct ModelConfigSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var modelRegistry = ModelRegistry.shared
    @ObservedObject private var endpointStore = CustomEndpointStore.shared
    @ObservedObject private var health = LocalHealthMonitor.shared

    // Add-endpoint form state.
    @State private var newName: String = ""
    @State private var newBaseURL: String = ""
    @State private var newAPIKey: String = ""
    @State private var showNewKey: Bool = false
    @State private var validating: Bool = false
    @State private var validationMessage: String? = nil
    @State private var validationOK: Bool = false

    var body: some View {
        Group {
            modelPickerSection
            customEndpointsSection
        }
        .onAppear { LocalHealthMonitor.shared.startIfNeeded() }
    }

    // MARK: - Local health status

    // Proactive reachability dot for the local model path. Bound to the shared
    // poller so a companion/Ollama outage shows here instead of only as a silent
    // per-call fallback to Claude. nil = amber (not checked), true = green,
    // false = red.
    private var healthDotColor: Color {
        switch health.reachable {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .orange
        }
    }

    private var healthLabel: String {
        switch health.reachable {
        case .some(true): return "Local model reachable"
        case .some(false): return "Local model unreachable"
        case .none: return "Local model not checked"
        }
    }

    @ViewBuilder
    private var healthStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(healthDotColor)
                .frame(width: 9, height: 9)
            Text(healthLabel)
                .font(.caption)
            Spacer()
            if let checked = health.lastChecked {
                Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if health.reachable == false, let err = health.lastError, !err.isEmpty {
            Text(err)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: - Model picker

    // Picker options: every discovered local model once (the configured name
    // standing for its own, D130), plus the currently configured model when it
    // is not in the discovered list (so the picker never shows an empty
    // selection after a server swap).
    private var pickerOptions: [String] {
        let current = state.config.offlineLLMModel
        var opts = modelRegistry.shownLocalModels(configured: current)
        if !current.isEmpty && !opts.contains(current) {
            opts.insert(current, at: 0)
        }
        return opts
    }

    private var modelPickerSection: some View {
        Section("Local model") {
            healthStatusRow
            if modelRegistry.localTags.isEmpty {
                Text("No local models discovered yet. Use Discover local models in the Offline mode section above, then pick from the dropdown here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Chat model", selection: Binding(
                    get: { state.config.offlineLLMModel },
                    set: { v in
                        state.config.offlineLLMModel = v
                        state.saveConfig()
                    }
                )) {
                    ForEach(pickerOptions, id: \.self) { tag in
                        Text(Cookbook.personName(for: tag)).tag(tag)
                    }
                }
                .pickerStyle(.menu)
            }
            if let hint = EndpointValidator.toolUseHint(forModel: state.config.offlineLLMModel) {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Custom endpoints

    // Where a chat turn actually goes, named on screen.
    //
    // Pressing Use used to write config.ollamaBaseURL and nothing else, so a user
    // who added OpenRouter, pasted a key and pressed Use saw no change anywhere
    // and kept billing Anthropic. The base URL is still written, because the
    // health poller, the cookbook and the local-model tooling all read it, but it
    // is no longer the ONLY signal, and this row is how the answer stops being
    // invisible.
    //
    // READS `resolvedProvider`, THE ROUTE, AND NEVER `activeProvider`, THE
    // CHOICE. The two disagree whenever a choice cannot serve a turn right now,
    // and the reachable case is an ordinary one rather than a corner: Offline
    // mode on with no local server running leaves `ModelRegistry.local` nil,
    // `resolvedProvider` maps that to anthropic, and active(), modelId() and
    // apiKey() all follow it to the cloud. This row used to answer "the local
    // model at http://localhost:11434" in exactly that state, roughly thirty
    // lines under a warning in the same window saying the opposite. A row whose
    // entire job is to tell somebody where their prompts go has to read the same
    // accessor the send path reads.
    private var activeProviderLabel: String {
        switch modelRegistry.resolvedProvider {
        case .anthropic:
            return "Claude (Anthropic)"
        case .local:
            return "the local model at \(state.config.ollamaBaseURL)"
        case .custom(let id):
            // `resolvedProvider` only ever yields .custom for an endpoint the
            // store still holds, so the nil arm is unreachable rather than a
            // real state. It stays a total answer instead of a force unwrap.
            guard let ep = endpointStore.endpoint(id: id) else {
                return "a custom endpoint"
            }
            return "\(ep.name) (\(ep.baseURL))"
        }
    }

    // THE DISAGREEMENT ITSELF, SPELLED OUT, and nil when there is none.
    //
    // Naming the route alone would be honest and useless: it reads as though
    // Grux ignored the setting, with nothing to act on. Naming the choice
    // alongside it is what makes the sentence fixable, and in the local case it
    // is also the privacy answer. Offline mode is the affordance somebody
    // reaches for so prompts stay on the machine, so a fallback that says
    // nothing means they leave it while the switch the user set says they do
    // not.
    private var routingFallbackNote: String? {
        ClaudeSwitchOffer.fallbackNote(chosen: modelRegistry.activeProvider,
                                       routed: modelRegistry.resolvedProvider,
                                       hasAnthropicKey: hasAnthropicKey,
                                       localBaseURL: state.config.ollamaBaseURL)
    }

    private var hasAnthropicKey: Bool {
        !state.anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Gated on the CHOICE rather than the route, deliberately, and it is the one
    // control here that should be. The button writes the choice, and in the
    // fallback state the stored choice is still local or a dead endpoint, so
    // pressing it is what stops a server coming back up from moving turns off
    // Claude again without the user asking. The help text carries that
    // distinction, because next to a row that now correctly says "Claude" the
    // words "Use Claude" would otherwise read as a contradiction.
    private var useClaudeHelp: String {
        modelRegistry.resolvedProvider == .anthropic
            ? "Turns already fall back to Claude. This makes Claude the choice, so a local server coming back up does not move them again without you."
            : "Send chat turns to Claude again, whatever Offline mode is set to"
    }

    @ViewBuilder
    private var activeProviderRow: some View {
        let offer = ClaudeSwitchOffer.decide(chosen: modelRegistry.activeProvider,
                                             hasAnthropicKey: hasAnthropicKey,
                                             localModelAvailable: modelRegistry.localUsable)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Chat routes through \(activeProviderLabel)")
                    .font(.caption)
                Spacer()
                if offer == .button {
                    Button("Use Claude") { modelRegistry.setActiveProvider(.anthropic) }
                        .font(.caption)
                        .help(useClaudeHelp)
                }
            }
            if offer == .needsKey {
                Text(ClaudeSwitchOffer.needsKeyLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = routingFallbackNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The empty state's line (D166 item 7).
    static let fillOpenRouterLabel = "Fill in OpenRouter"
    /// What Fill in OpenRouter puts in the Name and Base URL fields.
    static let openRouterExample = (name: "OpenRouter", baseURL: ModelPaths.openRouterBase)
    /// The Name and Base URL after Fill in OpenRouter: only an empty field is
    /// filled, so what the person typed stays (W54-P3 item 6), and the name
    /// "OpenRouter" goes only beside OpenRouter's own address, never beside
    /// another service's (wave 55 P2-2).
    static func filledOpenRouter(name: String, baseURL: String) -> (name: String, baseURL: String) {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let url = trimmed(baseURL)
        var bare = url.lowercased()
        while bare.hasSuffix("/") { bare.removeLast() }
        let pointsAtOpenRouter = url.isEmpty || bare == openRouterExample.baseURL.lowercased()
        return (trimmed(name).isEmpty && pointsAtOpenRouter ? openRouterExample.name : name,
                url.isEmpty ? openRouterExample.baseURL : baseURL)
    }
    /// Whether Fill in OpenRouter would change a field; the button is off when
    /// it would not, so a click never seems to do nothing (wave 55 P2-2).
    static func fillChangesSomething(name: String, baseURL: String) -> Bool {
        filledOpenRouter(name: name, baseURL: baseURL) != (name, baseURL)
    }
    /// No address in the sentence: a link wrapped at "/api/" and "v1" read as
    /// two (D166 item 7). The button puts it in the field instead.
    static let noEndpointsLine = "No custom endpoints yet. Add a hosted OpenAI-compatible service below with your key. For OpenRouter, \(fillOpenRouterLabel) puts its name and base URL in the empty fields."

    private var customEndpointsSection: some View {
        Section("Custom endpoints") {
            activeProviderRow
            if endpointStore.endpoints.isEmpty {
                Text(Self.noEndpointsLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Self.fillOpenRouterLabel) {
                    (newName, newBaseURL) = Self.filledOpenRouter(name: newName, baseURL: newBaseURL)
                }
                .disabled(!Self.fillChangesSomething(name: newName, baseURL: newBaseURL))
                .buttonStyle(.borderless)
                .font(.caption)
            }
            ForEach(endpointStore.endpoints) { ep in
                endpointRow(ep)
            }

            TextField("Name", text: $newName, prompt: Text("OpenRouter"))
                .textFieldStyle(.roundedBorder)
            TextField("Base URL", text: $newBaseURL, prompt: Text("https://openrouter.ai/api/v1"))
                .textFieldStyle(.roundedBorder)
            HStack {
                if showNewKey {
                    TextField("API key (optional)", text: $newAPIKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API key (optional)", text: $newAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                Button(showNewKey ? "Hide" : "Show") { showNewKey.toggle() }
                    .font(.caption)
            }
            HStack(spacing: 8) {
                Button(validating ? "Checking..." : "Validate & Save") {
                    Task { @MainActor in await validateAndSave() }
                }
                .disabled(validating || newBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let msg = validationMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(validationOK ? Color.secondary : Color.orange)
                }
            }
            Text("API keys are stored in the macOS Keychain, never in JSON config. The base URL is checked for reachability before save and must answer on the OpenAI-compatible /v1 surface (Ollama, vLLM, llama.cpp, OpenRouter).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func endpointRow(_ ep: CustomEndpoint) -> some View {
        let isActive = modelRegistry.activeProvider == .custom(ep.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.name)
                Text(ep.baseURL)
                    .font(.caption).foregroundStyle(.secondary)
                Text(ep.hasAPIKey ? "API key stored in Keychain" : "No API key")
                    .font(.caption2).foregroundStyle(.secondary)
                // The model this endpoint serves. Blank means the local model
                // name, which is right for a second Ollama and wrong for a
                // hosted router, so hosted endpoints name theirs here.
                TextField("Model",
                          text: Binding(
                            get: { ep.modelId ?? "" },
                            set: { endpointStore.setModelId($0, for: ep.id) }),
                          prompt: Text("deepseek/deepseek-v4-flash-0731"))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 360)
            }
            Spacer()
            if isActive {
                Text("In use")
                    .font(.caption).foregroundStyle(.green)
            }
            Button("Use") { useEndpoint(ep) }
                .font(.caption)
                .disabled(isActive)
                .help("Send chat turns to this endpoint and re-run discovery against it")
            Button {
                // Drop the selection with the endpoint. The registry already
                // falls back to Claude for a selection pointing at nothing, but
                // leaving the dead id stored means the row above goes on naming a
                // provider the user just deleted, which is the same class of
                // invisible state this row was added to end.
                DestructiveConfirm.shared.ask(
                    question: "Remove the endpoint \(DestructiveConfirm.quoted(ep.name, or: "with no name"))?",
                    detail: isActive
                        ? "Chat stops using it and goes back to the default model. To use it again, add its address again."
                        : "To use it again, add its address again.",
                    confirmLabel: "Remove endpoint") {
                    if isActive { modelRegistry.clearActiveProvider() }
                    endpointStore.remove(id: ep.id)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove endpoint and delete its Keychain key")
        }
    }

    // MARK: - Actions

    // Route chat through this endpoint. TWO writes, and the second one is the one
    // that was missing: the explicit provider selection is what active(),
    // modelId() and apiKey() branch on, so without it Use changed a base URL and
    // left routing exactly where it was unless an unrelated switch named "Offline
    // mode" happened to be on.
    //
    // The base URL is still written because it is what the local-model surfaces
    // read (the health poller, the cookbook, the Compare tab), and discovery runs
    // against it. Offline mode is deliberately NOT flipped: a hosted endpoint is
    // an ONLINE route, and turning that switch on would also stand down web
    // research and hosted speech for a machine that is not offline at all.
    private func useEndpoint(_ ep: CustomEndpoint) {
        state.config.ollamaBaseURL = ep.baseURL
        state.saveConfig()
        modelRegistry.setActiveProvider(.custom(ep.id))
        Task { @MainActor in await ModelRegistry.shared.discoverLocal() }
    }

    // Parse check first (instant, no network), then a reachability probe, then
    // save. The endpoint is never persisted when either step fails.
    private func validateAndSave() async {
        if let issue = ModelRegistry.baseURLIssue(newBaseURL) {
            validationOK = false
            validationMessage = issue
            return
        }
        validating = true
        defer { validating = false }
        let key = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await ModelRegistry.shared.validateEndpoint(
            baseURL: newBaseURL,
            apiKey: key.isEmpty ? nil : key
        )
        guard result.ok else {
            validationOK = false
            validationMessage = result.detail
            return
        }
        guard let ep = endpointStore.add(
            name: newName,
            baseURL: newBaseURL,
            apiKey: key.isEmpty ? nil : key
        ) else {
            validationOK = false
            validationMessage = "Could not save endpoint."
            return
        }
        validationOK = true
        validationMessage = "Saved \(ep.name). \(result.detail)"
        newName = ""
        newBaseURL = ""
        newAPIKey = ""
    }
}
