import SwiftUI

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

    // Picker options: every discovered local tag, plus the currently
    // configured model when it is not in the discovered list (so the picker
    // never shows an empty selection after a server swap).
    private var pickerOptions: [String] {
        var opts = modelRegistry.localTags
        let current = state.config.offlineLLMModel
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
                        Text(tag).tag(tag)
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
        let chosen = modelRegistry.activeProvider
        guard chosen != modelRegistry.resolvedProvider else { return nil }
        switch chosen {
        case .anthropic:
            // Unreachable: anthropic always resolves to itself.
            return nil
        case .local:
            return "You chose the local model at \(state.config.ollamaBaseURL) and nothing is answering there. Start the server and press Discover local models above, and turns move back on their own."
        case .custom:
            return "You chose a custom endpoint that has since been removed, so turns fall back to Claude until you pick another one below."
        }
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Chat routes through \(activeProviderLabel)")
                    .font(.caption)
                Spacer()
                if modelRegistry.activeProvider != .anthropic {
                    Button("Use Claude") { modelRegistry.setActiveProvider(.anthropic) }
                        .font(.caption)
                        .help(useClaudeHelp)
                }
            }
            if let note = routingFallbackNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var customEndpointsSection: some View {
        Section("Custom endpoints") {
            activeProviderRow
            if endpointStore.endpoints.isEmpty {
                Text("No custom endpoints yet. Add a hosted OpenAI-compatible service below, for example OpenRouter at https://openrouter.ai/api/v1 with your key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(endpointStore.endpoints) { ep in
                endpointRow(ep)
            }

            TextField("Name (e.g. OpenRouter)", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("Base URL (e.g. https://openrouter.ai/api/v1)", text: $newBaseURL)
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
                if isActive { modelRegistry.clearActiveProvider() }
                endpointStore.remove(id: ep.id)
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
