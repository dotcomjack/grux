import Foundation

// Which provider a chat turn is routed to. This is the CHOICE, not the route:
// `ModelRegistry.resolvedProvider` turns a choice into something that can
// actually serve a turn right now, and every accessor reads that.
//
// `custom` carries the endpoint's id rather than its base URL. A base URL is an
// editable text field, so keying the selection on it would mean that fixing a
// typo in a saved endpoint silently unselects it, with nothing on screen to say
// why chat went back to Claude.
enum ActiveProvider: Equatable {
    case anthropic
    case local
    case custom(UUID)

    private static let customPrefix = "custom:"

    // Stored as a string so the value stays readable in `defaults read`.
    var storedValue: String {
        switch self {
        case .anthropic: return "anthropic"
        case .local: return "local"
        case .custom(let id): return "\(Self.customPrefix)\(id.uuidString)"
        }
    }

    // An UNRECOGNISED string decodes to nil rather than trapping, so a value
    // written by a newer build, or a hand-edited defaults entry, degrades to the
    // legacy offlineMode derivation instead of taking chat down at launch.
    init?(storedValue: String) {
        switch storedValue {
        case "anthropic": self = .anthropic
        case "local": self = .local
        default:
            guard storedValue.hasPrefix(Self.customPrefix),
                  let id = UUID(uuidString: String(storedValue.dropFirst(Self.customPrefix.count)))
            else { return nil }
            self = .custom(id)
        }
    }
}

// Single decision point for which ModelBackend a chat turn routes through.
// ChatService.send() resolves active()/modelId()/apiKey() ONCE per turn (before
// entering the streaming Task) so there's no cross-actor hop inside the SSE
// loop. The anthropic backend is the canonical default and stays byte-identical
// to what it always was. A local or custom OpenAI-compat endpoint takes over
// only when the resolved provider says so, and a resolution that cannot serve a
// turn falls back to anthropic so chat never crashes, with Settings surfacing
// why.
@MainActor
final class ModelRegistry: ObservableObject {
    static let shared = ModelRegistry()

    // Canonical default. ClaudeClient conforms to ModelBackend via the
    // retroactive `extension ClaudeClient: ModelBackend {}` in ModelBackend.swift.
    let anthropic: ModelBackend = ClaudeClient()

    // Discovered local backend (Ollama / OpenAI-compat). nil until discoverLocal()
    // succeeds. @Published so Settings can react to discovery state.
    @Published private(set) var local: OpenAICompatBackend? = nil

    // Model tags reported by the local server's /api/tags. Surfaced in Settings
    // so the user can see what's installed and pick one.
    @Published private(set) var localTags: [String] = []

    // Last discovery outcome string for the Settings UI ("found 3 models", "no
    // local server reachable", etc.). nil before the first attempt.
    @Published private(set) var localStatus: String? = nil

    // The explicit provider choice, nil until the user makes one. @Published so
    // the Settings row that names the active provider redraws the moment Use is
    // pressed, which is the whole point of having an explicit selection: the old
    // Use button wrote a base URL and showed nothing.
    @Published private(set) var providerSelection: ActiveProvider? = nil

    // Namespaced to match the `grux.` defaults convention SessionConcurrency and
    // CapabilityResolver already use.
    //
    // In UserDefaults rather than in GruxConfig deliberately. GruxConfig is a
    // Codable struct every install decodes at launch, so a new key there is a
    // migration on the hot path, and the failure mode of a MISSING key here is
    // exactly the behaviour this change has to preserve (derive from offlineMode)
    // rather than a decode error.
    static let providerDefaultsKey = "grux.model.active_provider"

    // Compat backends built on demand, keyed by normalized base URL. A backend
    // owns a URLSession, and active() is asked once per turn, so building a new
    // one every time would hand out a fresh connection pool per message and
    // invalidate none of them.
    private var compatBackends: [String: OpenAICompatBackend] = [:]

    private init() {
        self.providerSelection = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
            .flatMap(ActiveProvider.init(storedValue:))
    }

    // MARK: - Which provider a turn routes through

    // THE CHOICE. `offlineMode` is the LEGACY INPUT to it, and it stays that way
    // on purpose: an install that predates the explicit selection has nothing
    // stored, derives its provider from the switch exactly as before, and sees no
    // change at all on upgrade.
    //
    // The reason an explicit selection exists: a HOSTED provider used to be
    // configured by writing a field named ollamaBaseURL underneath a switch named
    // "Offline mode", so adding OpenRouter, pasting a key and pressing Use left
    // chat billing Anthropic with nothing visible to say so. Those are two
    // different facts, "route my turns through this OpenAI-compatible endpoint"
    // and "this machine is offline", and the second one also turns off web
    // research and hosted speech. Conflating them is what made a correctly
    // configured endpoint look like a broken one.
    var activeProvider: ActiveProvider {
        if let providerSelection { return providerSelection }
        return AppState.shared.offlineMode ? .local : .anthropic
    }

    // THE ROUTE. A choice that cannot serve a turn right now resolves to
    // something that can: local with nothing discovered falls back to anthropic,
    // and anthropic with no key falls forward to local.
    //
    // THE SECOND HALF IS THE ONE THAT WAS MISSING, and it cost a real first run.
    // Every branch here used to end at `.anthropic`, including the branch taken
    // when there is no key at all, so a Mac with a local model already serving
    // and nothing in the Keychain still routed every turn to a provider it could
    // not authenticate with. The owner finished setup, sent "Hi Grux", and got an
    // HTTP 400 back from Anthropic on a machine that had qwen3:8b loaded and
    // idle. The chat footer was even printing "cheaper: qwen3:8b free" underneath
    // the failure, which is the app naming the answer while routing away from it.
    //
    // "No key" is a fact this can check for free and cannot get wrong, unlike
    // "the key works", which is only knowable by spending a request. A key that
    // exists and is refused is a different problem and belongs at the gate that
    // validates it, not here.
    /// Where an Anthropic selection actually goes, in all four combinations.
    ///
    /// Pure and separate because the interesting case needs a Mac with no key in
    /// the Keychain AND a local server answering, which is not a state a test can
    /// arrange without rewriting somebody's credentials.
    ///
    /// A key with no local model still routes to Anthropic, deliberately: the
    /// key may be fine and the failure would then be invented. And no key with no
    /// local model still routes to Anthropic, because there is nowhere else to
    /// go and `ChatReadiness` already has a sentence for that, which is better
    /// than a route that silently points at nothing.
    nonisolated static func anthropicRoute(hasKey: Bool, hasLocal: Bool) -> ActiveProvider {
        (!hasKey && hasLocal) ? .local : .anthropic
    }

    var resolvedProvider: ActiveProvider {
        switch activeProvider {
        case .anthropic:
            return Self.anthropicRoute(hasKey: KeychainStore.exists(.anthropicApiKey),
                                       hasLocal: local != nil)
        case .local:
            return local == nil ? .anthropic : .local
        case .custom(let id):
            return CustomEndpointStore.shared.endpoint(id: id) == nil ? .anthropic : .custom(id)
        }
    }

    // Kept for the callers outside this file that ask "is chat on the
    // OpenAI-compat path". Before the explicit selection existed this read
    // `offlineMode && local != nil`, and with nothing stored it still resolves to
    // exactly that, so those callers are unchanged on every existing install.
    var offlineReady: Bool { resolvedProvider != .anthropic }

    // Record an explicit choice. From here on the switch is no longer the input:
    // the row in Settings names the provider chat actually routes through, so a
    // user who moves the offline switch and sees no change can read why.
    func setActiveProvider(_ provider: ActiveProvider) {
        providerSelection = provider
        UserDefaults.standard.set(provider.storedValue, forKey: Self.providerDefaultsKey)
    }

    // Forget the explicit choice and go back to deriving from offlineMode.
    func clearActiveProvider() {
        providerSelection = nil
        UserDefaults.standard.removeObject(forKey: Self.providerDefaultsKey)
    }

    // The backend a turn should route through right now.
    //
    // active(), modelId(), apiKey() and resolvedRouting() ALL switch on
    // resolvedProvider and on nothing else, so the trio can never disagree: in
    // the fallback state every accessor resolves to the anthropic backend with
    // the Claude model id and the Anthropic key, instead of sending a local model
    // id (guaranteed 401) or a stored custom-endpoint key to api.anthropic.com.
    func active() -> ModelBackend {
        switch resolvedProvider {
        case .anthropic: return anthropic
        case .local: return local ?? anthropic
        case .custom(let id): return customBackend(id) ?? anthropic
        }
    }

    // The model id to send for the active backend.
    func modelId() -> String {
        switch resolvedProvider {
        case .anthropic: return AppState.shared.config.model      // claude-haiku-4-5-...
        case .local, .custom: return AppState.shared.config.offlineLLMModel   // e.g. "llama3.1"
        }
    }

    // The api key for the active backend. Plain local servers ignore it; "ollama"
    // is a conventional placeholder. When the base URL matches a saved custom
    // endpoint with a Keychain key (OpenRouter, authenticated vLLM), that key
    // goes instead. OpenAICompatBackend already forwards any non-empty key as a
    // Bearer token.
    func apiKey() -> String {
        switch resolvedProvider {
        case .anthropic:
            return AppState.shared.anthropicKey
        case .local:
            return Self.compatKey(forBaseURL: AppState.shared.config.ollamaBaseURL)
        case .custom(let id):
            let base = CustomEndpointStore.shared.endpoint(id: id)?.baseURL
                ?? AppState.shared.config.ollamaBaseURL
            return Self.compatKey(forBaseURL: base)
        }
    }

    // Is `id` one of Anthropic's model ids? A PREFIX RULE, and it says so
    // rather than pretending to be a catalogue: a list of exact ids
    // ("claude-sonnet-4-6", "claude-haiku-4-5-20251001") is stale the day the
    // next model ships, and what matters here is the FAMILY, not the version.
    //
    // A gateway slug like "anthropic/claude-haiku-4.5" is deliberately NOT
    // matched. That string is exactly what an OpenAI-compatible gateway wants,
    // so it is the one case where a Claude model on a compat backend is
    // correct, and a rule that swallowed it would break the case it exists to
    // protect. Pure and internal so a test can assert the rule directly.
    static func isAnthropicModelId(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("claude-")
    }

    // Overrides already dropped, so the log line below is written once per
    // distinct id rather than once per dictated phrase.
    private var droppedOverrides: Set<String> = []

    // THE BACKSTOP. `modelOverride` is what the CALLER would prefer; the
    // resolved backend is where the turn is actually going. When the two
    // disagree the backend wins, because a model id is a preference and a 404
    // is not.
    //
    // This exists for a regression that already shipped, not a hypothetical
    // one. Five sites converted to routing expressed a TIER (cheap and fast, or
    // highest quality) by hardcoding a "claude-" id as the override, and the
    // default branch below returned that id verbatim AFTER the backend had
    // already resolved to a local server. Ollama was POSTed
    // {"model":"claude-sonnet-4-6"} and answered 404 model not found, on
    // exactly the install the sweep was written to fix, and nothing in the
    // suite could see it. Those sites now pass nil; this is what stops the next
    // one arriving.
    //
    // On the Anthropic route an override rides through untouched. That case is
    // legitimate and is how FocusWatcher, ColdEmail and PersonMemory pin a tier.
    private func honoredOverride(_ modelOverride: String?, onAnthropic: Bool) -> String? {
        guard let modelOverride, !onAnthropic, Self.isAnthropicModelId(modelOverride) else {
            return modelOverride
        }
        if droppedOverrides.insert(modelOverride).inserted {
            WakeLog.shared.log(
                "ModelRegistry: dropped the model override \(modelOverride) because this turn "
                + "routes to a non-Anthropic backend, which cannot serve an Anthropic model id. "
                + "Sending the routed model id instead.")
        }
        return nil
    }

    // Resolve (backend, modelId, apiKey) for one turn, honoring an optional
    // per-preset provider pin and model override. provider nil -> the registry's
    // current default routing. A pin that is not actually available (local with
    // no discovered server) falls back to Anthropic so a turn never strands.
    //
    // The pin strings come from PresetModels.providerOverride and are part of
    // saved preset JSON, so "anthropic" and "local" mean here exactly what they
    // always meant, whatever the registry's own selection says.
    //
    // An override naming an ANTHROPIC model is dropped when the turn does not
    // route to Anthropic, see honoredOverride: the caller gets the routed model
    // id rather than a guaranteed model-not-found on somebody's local server.
    func resolvedRouting(provider: String?, modelOverride: String?) -> (backend: ModelBackend, modelId: String, apiKey: String) {
        let cfg = AppState.shared.config
        switch provider {
        case "anthropic":
            return (anthropic, modelOverride ?? cfg.model, AppState.shared.anthropicKey)
        case "local":
            // Use the discovered backend when present; otherwise build one
            // directly from ollamaBaseURL so a local-pinned preset actually hits
            // the local model even when discovery has not run yet (e.g. Ollama
            // started after launch). The user explicitly chose local, so we do
            // NOT silently fall back to Anthropic; a down server surfaces via the
            // normal chat error path. Kick discovery so later turns reuse `local`.
            if local == nil { Task { await discoverLocal() } }
            let backend = local ?? compatBackend(forBaseURL: cfg.ollamaBaseURL)
            return (backend,
                    honoredOverride(modelOverride, onAnthropic: false) ?? cfg.offlineLLMModel,
                    localApiKey())
        default:
            return (active(),
                    honoredOverride(modelOverride,
                                    onAnthropic: resolvedProvider == .anthropic) ?? modelId(),
                    apiKey())
        }
    }

    // MARK: - Backends

    // The backend for a selected custom endpoint. Reuses the discovered `local`
    // when discovery already ran against this endpoint's base URL, otherwise
    // builds one directly so pressing Use routes the very NEXT turn instead of
    // waiting on a discovery round trip that may never succeed: a provider whose
    // model list is private answers 401 to a list request and 200 to a chat.
    private func customBackend(_ id: UUID) -> OpenAICompatBackend? {
        guard let ep = CustomEndpointStore.shared.endpoint(id: id) else { return nil }
        if let local,
           let epBase = EndpointValidator.normalizeBaseURL(ep.baseURL),
           EndpointValidator.normalizeBaseURL(AppState.shared.config.ollamaBaseURL) == epBase {
            return local
        }
        return compatBackend(forBaseURL: ep.baseURL)
    }

    private func compatBackend(forBaseURL raw: String) -> OpenAICompatBackend {
        let base = EndpointValidator.normalizeBaseURL(raw)
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = compatBackends[base] { return cached }
        let backend = OpenAICompatBackend(baseURL: base)
        compatBackends[base] = backend
        return backend
    }

    // MARK: - Endpoint key lookup

    // THE ONE ENDPOINT KEY LOOKUP. apiKey(), localApiKey() and discovery all ask
    // this and nothing else.
    //
    // It used to be two identical copies in apiKey() and localApiKey(), and
    // discovery had no copy at all. That is the whole of the defect: "Validate
    // and Save" sends the key and reports the endpoint reachable, then discovery
    // asks the SAME server for its model list with no Authorization header, gets
    // a 401, sets local = nil, and active() quietly returns the Anthropic backend
    // forever. Every hosted provider that authenticates its model list was
    // affected, and only OpenRouter worked, because its model list is public.
    // A third copy is how the next one drifts, so there is one.
    //
    // nil means "nothing stored for this base URL", which is NOT the same as the
    // "ollama" placeholder a plain local server ignores: discovery has to send no
    // header at all rather than a header it invented.
    static func endpointKey(forBaseURL raw: String) -> String? {
        let base = EndpointValidator.normalizeBaseURL(raw)
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ep = CustomEndpointStore.shared.endpoints.first(where: { $0.baseURL == base }),
              ep.hasAPIKey else { return nil }
        let key = CustomEndpointStore.shared.apiKey(for: ep.id)
        return key.isEmpty ? nil : key
    }

    // The key a CHAT call sends to an OpenAI-compatible endpoint: the stored one
    // when there is one, otherwise the conventional placeholder.
    static func compatKey(forBaseURL raw: String) -> String {
        endpointKey(forBaseURL: raw) ?? "ollama"
    }

    // The Authorization header value DISCOVERY sends, or nil when nothing is
    // stored. Split out as a pure function so a test can prove discovery and the
    // chat path read the same lookup without opening a socket.
    static func discoveryAuthorization(forBaseURL raw: String) -> String? {
        endpointKey(forBaseURL: raw).map { "Bearer \($0)" }
    }

    // Key for the local compat path, independent of the offlineMode gate (a
    // preset can pin local even when global offline mode is off). Internal, not
    // private, so a test can assert it agrees with apiKey() rather than assuming
    // the two lookups stayed the same shape.
    func localApiKey() -> String {
        Self.compatKey(forBaseURL: AppState.shared.config.ollamaBaseURL)
    }

    // MARK: - Test control

    // Clears discovered local-model state AND the stored provider selection, for
    // tests only.
    //
    // `local` is `private(set)`, and it is populated by whichever test happened to
    // trigger discovery first. `ChatRecoveryTests` asserts the offline-with-no-
    // local-model path and its own comment admitted the dependency: "no
    // discoverLocal() ran, so local == nil". That held in isolation and broke in
    // the full suite the moment any earlier test discovered a model, so the suite
    // was order-dependent and failed on a change that touched neither file.
    //
    // The provider selection is worse in the same way, because UserDefaults
    // outlives the PROCESS: a selection stored by one test would change routing
    // for every later test and for every run afterwards on that machine, which
    // reads as a flake that reproduces only on one Mac.
    //
    // A test that cannot control the state it asserts on is not deterministic, and
    // this makes it controllable rather than hopeful.
    func resetLocalForTest() {
        self.local = nil
        self.localTags = []
        self.localStatus = nil
        clearActiveProvider()
    }

    // MARK: - Discovery

    // GET {ollamaBaseURL}/api/tags -> populate `local` + `localTags`. Best-effort:
    // any failure leaves `local` nil so active() falls back to anthropic. Safe to
    // call repeatedly (launch + every offlineMode flip).
    func discoverLocal() async {
        let baseURL = AppState.shared.config.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/api/tags") else {
            self.local = nil
            self.localTags = []
            self.localStatus = "invalid local base URL"
            return
        }
        // DISCOVERY AUTHENTICATES, because the probe and the chat call have to
        // present the same credential or the probe answers a question nobody
        // asked. Without this header every hosted provider that guards its model
        // list answered 401 here, discovery recorded "no local server reachable",
        // and routing silently stayed on Anthropic while Settings showed a
        // reachable endpoint with a stored key.
        let auth = Self.discoveryAuthorization(forBaseURL: baseURL)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 4   // local server is on localhost; fail fast if down
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: cfg)
        // Non-shared sessions must be invalidated or they leak their
        // connection pool and worker resources (Apple's documented contract).
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            guard let http, (200..<300).contains(http.statusCode) else {
                await failOverToOpenAICompat(baseURL: baseURL, session: session,
                                             auth: auth, tagsStatus: http?.statusCode)
                return
            }
            // Ollama /api/tags shape: { "models": [ { "name": "llama3.1:latest", ... } ] }
            var tags: [String] = []
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = obj["models"] as? [[String: Any]] {
                tags = models.compactMap { $0["name"] as? String }
            }
            self.local = compatBackend(forBaseURL: baseURL)
            self.localTags = tags
            self.localStatus = tags.isEmpty
                ? "local server reachable, no models installed"
                : "found \(tags.count) local model\(tags.count == 1 ? "" : "s")"

            // THE CATALOG TOLD AND NEVER ACTED, and this is the one line that
            // makes it act. `Cookbook.headline(for:)` has computed the right
            // local model for the machine since the day that file was written,
            // and the shipped default was a single hardcoded tag handed alike
            // to an 8 GB laptop and a 128 GB workstation. Discovery is the
            // right place for the write because it is the only moment the app
            // knows BOTH facts it needs: what the hardware can afford, and what
            // is actually installed.
            //
            // `tags.contains(picked)` IS LOAD BEARING and it is deliberately
            // not folded into the pure function. The hardware pick is very
            // often a model the user has never pulled: a 64 GB Mac scores
            // qwen3.5:35b as the headline whether or not those 24 GB were ever
            // downloaded. Writing an uninstalled tag into `offlineLLMModel`
            // would leave chat pointing at a model the server answers 404 for,
            // so the next turn breaks and the user has no idea why the field
            // changed. The pure function decides what is BEST; this line is the
            // only thing that knows what is PRESENT, and it keeps the two
            // responsibilities in the files that can test them.
            //
            // `userHasChosenModel` is what stops this running away with the
            // field. Anything other than the shipped default counts as somebody
            // decided, including a value written here on an earlier launch, so
            // this fires once per install and then leaves the config alone
            // forever rather than re-deciding on every discovery.
            if !tags.isEmpty {
                let cfg = AppState.shared.config
                let picked = Cookbook.defaultModelID(for: HardwareProfile.detect(),
                                                     userHasChosen: Cookbook.userHasChosenModel(cfg.offlineLLMModel),
                                                     current: cfg.offlineLLMModel)
                if picked != cfg.offlineLLMModel, tags.contains(picked) {
                    AppState.shared.config.offlineLLMModel = picked
                    AppState.shared.saveConfig()
                }
            }
        } catch {
            await failOverToOpenAICompat(baseURL: baseURL, session: session,
                                         auth: auth, tagsStatus: nil)
        }
    }

    // What the /v1/models probe found. A rejection is deliberately NOT folded
    // into "no answer": they need different sentences, see recordAuthRejection.
    private enum CompatProbe: Equatable {
        case populated
        case rejected(Int)
        case noAnswer
    }

    // The /api/tags probe failed, so this is not an Ollama server (or not one
    // that will talk to us). Try the OpenAI-standard GET {base}/v1/models (vLLM,
    // llama.cpp, OpenRouter, every hosted compat provider) and record whichever
    // outcome the pair of probes produced.
    private func failOverToOpenAICompat(baseURL: String, session: URLSession,
                                        auth: String?, tagsStatus: Int?) async {
        switch await discoverOpenAICompat(baseURL: baseURL, session: session, auth: auth) {
        case .populated:
            return
        case .rejected(let code):
            recordAuthRejection(baseURL: baseURL, code: code, keySent: auth != nil)
        case .noAnswer:
            if let tagsStatus, tagsStatus == 401 || tagsStatus == 403 {
                recordAuthRejection(baseURL: baseURL, code: tagsStatus, keySent: auth != nil)
            } else {
                self.local = nil
                self.localTags = []
                self.localStatus = "no local server reachable at \(baseURL)"
            }
        }
    }

    // A 401 or 403 is the server ANSWERING, so "no local server reachable at X"
    // is the wrong sentence and it sends the user to debug the wrong thing: they
    // go looking for a dead server while a live one is refusing their key. The
    // two cases are also not the same fix, which is why they are two strings.
    private func recordAuthRejection(baseURL: String, code: Int, keySent: Bool) {
        self.local = nil
        self.localTags = []
        self.localStatus = keySent
            ? "endpoint at \(baseURL) rejected the stored API key (HTTP \(code)). Check the key on that endpoint under Custom endpoints."
            : "endpoint at \(baseURL) needs an API key (HTTP \(code)). Add one to that endpoint under Custom endpoints."
    }

    // Try the OpenAI-standard GET {base}/v1/models. Returns .populated when the
    // endpoint answered and `local` was set.
    private func discoverOpenAICompat(baseURL: String, session: URLSession, auth: String?) async -> CompatProbe {
        guard let mURL = URL(string: "\(baseURL)/v1/models") else { return .noAnswer }
        var mReq = URLRequest(url: mURL)
        mReq.httpMethod = "GET"
        if let auth { mReq.setValue(auth, forHTTPHeaderField: "Authorization") }
        mReq.timeoutInterval = 4
        guard let (mData, mResp) = try? await session.data(for: mReq),
              let mHTTP = mResp as? HTTPURLResponse else {
            return .noAnswer
        }
        guard (200..<300).contains(mHTTP.statusCode) else {
            return (mHTTP.statusCode == 401 || mHTTP.statusCode == 403)
                ? .rejected(mHTTP.statusCode)
                : .noAnswer
        }
        var tags: [String] = []
        if let obj = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
           let arr = obj["data"] as? [[String: Any]] {
            tags = arr.compactMap { $0["id"] as? String }
        }
        self.local = compatBackend(forBaseURL: baseURL)
        self.localTags = tags
        self.localStatus = "OpenAI-compat endpoint reachable, \(tags.count) model\(tags.count == 1 ? "" : "s")"
        return .populated
    }
}
