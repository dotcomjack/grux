import XCTest
@testable import Grux

/// Which provider a chat turn actually reaches, and the three ways it used to be
/// decided by something other than the user's choice.
///
/// 1. DISCOVERY SENT NO KEY. `discoverLocal()` asked `{base}/api/tags` and its
///    fallback asked `{base}/v1/models` with no Authorization header, while
///    `EndpointValidator.checkReachability` sent one. So "Validate and Save"
///    reported the endpoint reachable, discovery then got a 401, set `local` to
///    nil, and routing quietly returned to Anthropic and stayed there. Every
///    hosted provider that authenticates its model list was affected; only
///    OpenRouter worked, because its model list is public. The lookup was also
///    duplicated between `apiKey()` and `localApiKey()`, and a third copy is how
///    two copies become three, so the tests here pin that there is ONE.
///
/// 2. A CUSTOM ENDPOINT ONLY WORKED IF AN UNRELATED SWITCH WAS ON. `Use` wrote
///    `config.ollamaBaseURL` and nothing else, and routing keyed off
///    `offlineMode && local != nil`, so adding OpenRouter, pasting a key and
///    pressing Use left chat billing Anthropic with nothing on screen to say so.
///    The explicit `ActiveProvider` selection replaces that, and `offlineMode`
///    stays the LEGACY INPUT so an install that never chose sees no change.
///
/// 3. A SETTINGS TYPO CRASHED THE APP. `OpenAICompatBackend.chatCompletionsURL`
///    force-unwrapped `URL(string:)` while the Settings "Base URL" field wrote
///    into config with no validation, so one space in that field took the process
///    down. The proof below is not that the code reads better: it calls the real
///    entry points and asserts they throw.
///
/// Everything here is pure. No socket is opened: the one base URL that reaches a
/// network call points at a port nothing listens on, and the request is refused
/// before it is built anyway.
@MainActor
final class ProviderRoutingTests: XCTestCase {

    private var savedOffline = false
    private var savedBaseURL = ""
    private var savedWritesSuspended = false

    override func setUp() async throws {
        try await super.setUp()
        savedOffline = AppState.shared.offlineMode
        savedBaseURL = AppState.shared.config.ollamaBaseURL
        savedWritesSuspended = Persistence.writesSuspended
        // Nothing listens on port 1, so the discovery Task that offlineMode's
        // didSet kicks off fails fast and cannot populate `local` underneath an
        // assertion that depends on it being nil.
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:1"
        // These tests only need in-memory state. Suspending writes keeps the real
        // config.json and custom-endpoints.json out of the run entirely, so a
        // crash mid-test cannot leave a probe endpoint behind on the machine.
        Persistence.writesSuspended = true
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() async throws {
        ModelRegistry.shared.resetLocalForTest()
        AppState.shared.offlineMode = savedOffline
        AppState.shared.config.ollamaBaseURL = savedBaseURL
        Persistence.writesSuspended = savedWritesSuspended
        try await super.tearDown()
    }

    // MARK: - The selection itself

    func testTheSelectionSurvivesTheStoredStringRoundTrip() {
        let id = UUID()
        for provider in [ActiveProvider.anthropic, .local, .custom(id)] {
            XCTAssertEqual(ActiveProvider(storedValue: provider.storedValue), provider,
                           "\(provider.storedValue) did not decode back to the case that wrote it")
        }
        XCTAssertNil(ActiveProvider(storedValue: "custom:not-a-uuid"))
        XCTAssertNil(ActiveProvider(storedValue: "some-future-provider"),
                     "an unrecognised stored value must decode to nil so routing falls back to the "
                     + "legacy derivation, rather than trapping on a string a newer build wrote")
    }

    func testTheSelectionIsPersistedRatherThanHeldInMemory() {
        let registry = ModelRegistry.shared
        let id = UUID()
        registry.setActiveProvider(.custom(id))

        let stored = UserDefaults.standard.string(forKey: ModelRegistry.providerDefaultsKey)
        XCTAssertEqual(stored, "custom:\(id.uuidString)",
                       "a choice that only lives in memory is forgotten at the next launch, which "
                       + "is exactly the behaviour this replaces")
        XCTAssertEqual(ActiveProvider(storedValue: stored ?? ""), ActiveProvider.custom(id),
                       "what a fresh launch reads back has to be the case that was chosen")

        registry.clearActiveProvider()
        XCTAssertNil(UserDefaults.standard.string(forKey: ModelRegistry.providerDefaultsKey))
        XCTAssertNil(registry.providerSelection)
    }

    // MARK: - The resolution table

    /// The upgrade path. An install that has never chosen a provider derives it
    /// from the switch, and `offlineReady` still reads exactly what it used to
    /// read, `offlineMode && local != nil`, for the callers outside the registry
    /// that ask it.
    func testOfflineModeStillDecidesWhenNothingHasBeenChosen() {
        let registry = ModelRegistry.shared
        registry.clearActiveProvider()

        AppState.shared.offlineMode = false
        XCTAssertEqual(registry.activeProvider, .anthropic)
        XCTAssertEqual(registry.resolvedProvider, .anthropic)
        XCTAssertFalse(registry.offlineReady)
        assertTheTrioAgrees()

        AppState.shared.offlineMode = true
        XCTAssertEqual(registry.activeProvider, .local,
                       "the switch is still the input on an install that has never chosen")
        XCTAssertEqual(registry.resolvedProvider, .anthropic,
                       "offline is pinned but nothing was discovered, so a turn has to land somewhere")
        XCTAssertFalse(registry.offlineReady,
                       "offlineReady was `offlineMode && local != nil` before an explicit selection "
                       + "existed and must still read exactly that with nothing stored")
        assertTheTrioAgrees()
    }

    func testAnExplicitChoiceOutranksTheSwitch() {
        let registry = ModelRegistry.shared
        AppState.shared.offlineMode = true

        registry.setActiveProvider(.anthropic)
        XCTAssertEqual(registry.activeProvider, .anthropic)
        XCTAssertFalse(registry.offlineReady)
        assertTheTrioAgrees()

        registry.clearActiveProvider()
        XCTAssertEqual(registry.activeProvider, .local,
                       "clearing the choice has to hand the decision back to the switch")
    }

    /// A selection can outlive the thing it points at: the endpoint gets deleted
    /// and the stored UUID stays in defaults. A turn still has to land somewhere.
    func testACustomChoiceWhoseEndpointIsGoneFallsBackToClaude() {
        let registry = ModelRegistry.shared
        registry.setActiveProvider(.custom(UUID()))

        XCTAssertEqual(registry.resolvedProvider, .anthropic)
        XCTAssertFalse(registry.offlineReady)
        XCTAssertTrue(registry.active() === registry.anthropic)
        assertTheTrioAgrees()
    }

    /// THE ONE THAT WOULD HAVE CAUGHT IT. Offline mode is OFF, a saved endpoint is
    /// chosen, and the turn must route there. Needing an unrelated switch is the
    /// defect, and a hosted endpoint is an online route anyway: flipping offline
    /// mode on for it would also stand down web research and hosted speech.
    func testASavedEndpointRoutesChatWithTheOfflineSwitchOff() {
        let store = CustomEndpointStore.shared
        let base = "http://127.0.0.1:59999/probe-\(UUID().uuidString)"
        guard let endpoint = store.add(name: "Probe", baseURL: base, apiKey: nil) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: endpoint.id) }

        AppState.shared.offlineMode = false
        let registry = ModelRegistry.shared
        registry.setActiveProvider(.custom(endpoint.id))

        XCTAssertEqual(registry.resolvedProvider, .custom(endpoint.id))
        XCTAssertTrue(registry.offlineReady)
        XCTAssertFalse(registry.active() === registry.anthropic,
                       "chat still routed to Anthropic after the endpoint was chosen")
        XCTAssertEqual(registry.modelId(), AppState.shared.config.offlineLLMModel,
                       "a compat route must send the local model id, never the Claude one")
        assertTheTrioAgrees()
    }

    /// The pin strings live in saved preset JSON (`PresetModels.providerOverride`),
    /// so they have to keep meaning what they meant whatever the registry's own
    /// selection says.
    func testPresetProviderPinsStillMeanWhatTheyMeant() {
        let registry = ModelRegistry.shared
        registry.setActiveProvider(.custom(UUID()))   // a choice that resolves to Anthropic

        let pinnedCloud = registry.resolvedRouting(provider: "anthropic", modelOverride: nil)
        XCTAssertTrue(pinnedCloud.backend === registry.anthropic)
        XCTAssertEqual(pinnedCloud.modelId, AppState.shared.config.model)
        XCTAssertEqual(pinnedCloud.apiKey, AppState.shared.anthropicKey)

        let pinnedLocal = registry.resolvedRouting(provider: "local", modelOverride: "llama3.1")
        XCTAssertFalse(pinnedLocal.backend === registry.anthropic,
                       "a local pin must not fall back to Anthropic; the user chose local explicitly")
        XCTAssertEqual(pinnedLocal.modelId, "llama3.1")
        XCTAssertEqual(pinnedLocal.apiKey, registry.localApiKey())

        let inherited = registry.resolvedRouting(provider: nil, modelOverride: nil)
        XCTAssertEqual(inherited.modelId, registry.modelId())
        XCTAssertEqual(inherited.apiKey, registry.apiKey())
        XCTAssertTrue(inherited.backend === registry.active())
    }

    // MARK: - The override cannot outrank the route

    /// THE OTHER ONE THAT WOULD HAVE CAUGHT IT, and the reason this file needed
    /// it: every case above passes `modelOverride: nil`, so the argument that
    /// decides the model id had never once been exercised against a compat
    /// route, and the file-scan in BackendSweepTests asserts only that a swept
    /// file contains the string "resolvedRouting(".
    ///
    /// The backend sweep converted five sites that expressed a TIER (cheap and
    /// fast, or highest quality) by hardcoding a "claude-" id as the override,
    /// and `resolvedRouting` returned that id verbatim AFTER the backend had
    /// already resolved. A local install was POSTed
    /// {"model":"claude-sonnet-4-6"} and answered 404 model not found, on
    /// exactly the machine the sweep was written to fix. That is the same
    /// invariant `testASavedEndpointRoutesChatWithTheOfflineSwitchOff` states
    /// one screen up, so it is asserted here in the same words: the override is
    /// simply the second way to break it.
    func testAnAnthropicOverrideIsDroppedOnACompatRouteAndKeptOnTheAnthropicOne() {
        let localModel = AppState.shared.config.offlineLLMModel
        XCTAssertFalse(ModelRegistry.isAnthropicModelId(localModel),
                       "the configured local model is itself a claude- id, so nothing below can "
                       + "tell a dropped override from the routed model and this proves nothing")

        let store = CustomEndpointStore.shared
        let base = "http://127.0.0.1:59994/probe-\(UUID().uuidString)"
        guard let endpoint = store.add(name: "Probe", baseURL: base, apiKey: nil) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: endpoint.id) }

        let registry = ModelRegistry.shared
        AppState.shared.offlineMode = false
        registry.setActiveProvider(.custom(endpoint.id))
        XCTAssertEqual(registry.resolvedProvider, .custom(endpoint.id),
                       "control: the route under test is not the compat one, so the assertions "
                       + "below are about something else entirely")

        let dropped = registry.resolvedRouting(provider: nil, modelOverride: "claude-sonnet-4-6")
        XCTAssertFalse(dropped.backend === registry.anthropic,
                       "the backend moved to Anthropic, so the model id below agrees for the "
                       + "wrong reason")
        XCTAssertEqual(dropped.modelId, localModel,
                       "a compat route must send the local model id, never the Claude one. An "
                       + "override is the second way to break that, and it is the 404 the sweep "
                       + "shipped to every local install")

        // A NON-Anthropic override is a real choice about which of the
        // endpoint's own models to use, and it still wins. The rule drops
        // Anthropic ids on a compat route, not every override, or pinning a
        // second local model would quietly stop working.
        let honored = registry.resolvedRouting(provider: nil, modelOverride: "llama3.1")
        XCTAssertEqual(honored.modelId, "llama3.1")

        // The same override on the Anthropic route is legitimate, and is how
        // FocusWatcher, ColdEmail and PersonMemory pin a tier.
        registry.setActiveProvider(.anthropic)
        XCTAssertEqual(registry.resolvedProvider, .anthropic, "control: the route is not Anthropic")
        let kept = registry.resolvedRouting(provider: nil, modelOverride: "claude-sonnet-4-6")
        XCTAssertTrue(kept.backend === registry.anthropic)
        XCTAssertEqual(kept.modelId, "claude-sonnet-4-6",
                       "dropping the override here would silently downgrade every site that pins "
                       + "a deliberate tier on the hosted route")
    }

    /// The preset pin has the same trap from the other side: `local` pinned in
    /// saved preset JSON alongside a Claude `modelIdOverride` would post an
    /// Anthropic id to Ollama, and the user explicitly asked for local.
    func testAnAnthropicOverrideIsDroppedOnAPinnedLocalRouteToo() {
        let registry = ModelRegistry.shared
        let pinned = registry.resolvedRouting(provider: "local",
                                              modelOverride: "claude-haiku-4-5-20251001")
        XCTAssertFalse(pinned.backend === registry.anthropic,
                       "a local pin must not fall back to Anthropic; the user chose local")
        XCTAssertEqual(pinned.modelId, AppState.shared.config.offlineLLMModel,
                       "a compat route must send the local model id, never the Claude one")
    }

    /// The rule is a PREFIX rule rather than a list of exact ids, because a list
    /// is stale the day the next model ships. A prefix has one edge worth
    /// pinning: the namespaced slug a gateway actually wants is NOT an Anthropic
    /// id for this purpose, and swallowing it would break the one case where a
    /// Claude model on a compat backend is correct.
    func testTheAnthropicModelIdRuleIsAPrefixRuleAndKnowsItsOwnEdge() {
        XCTAssertTrue(ModelRegistry.isAnthropicModelId("claude-sonnet-4-6"))
        XCTAssertTrue(ModelRegistry.isAnthropicModelId("claude-haiku-4-5-20251001"))
        XCTAssertTrue(ModelRegistry.isAnthropicModelId("CLAUDE-Opus-4-8"),
                      "the model field is typed by hand in Settings, so the rule cannot be case "
                      + "sensitive")
        XCTAssertTrue(ModelRegistry.isAnthropicModelId("  claude-haiku-4-5  "))
        XCTAssertFalse(ModelRegistry.isAnthropicModelId("llama3.1"))
        XCTAssertFalse(ModelRegistry.isAnthropicModelId(GruxConfig.defaultLocalModel))
        XCTAssertFalse(ModelRegistry.isAnthropicModelId(""))
        XCTAssertFalse(ModelRegistry.isAnthropicModelId("anthropic/claude-haiku-4.5"),
                       "a namespaced slug is exactly what an OpenAI-compatible gateway wants, so "
                       + "it has to reach the wire unchanged")
    }

    // MARK: - One key lookup

    /// Discovery, `apiKey()` and `localApiKey()` all answer from the same function
    /// for the same base URL. The duplication is the finding: two copies drifted
    /// into a third that was never written at all, which is why discovery sent no
    /// credential.
    func testOneKeyLookupAnswersDiscoveryAndTheChatPath() throws {
        let store = CustomEndpointStore.shared
        let base = "http://127.0.0.1:59998/probe-\(UUID().uuidString)"
        let probeKey = "probe-key-\(UUID().uuidString)"
        guard let endpoint = store.add(name: "Probe", baseURL: base, apiKey: probeKey) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: endpoint.id) }
        try XCTSkipUnless(store.apiKey(for: endpoint.id) == probeKey,
                          "could not write to the keychain in this environment")

        XCTAssertEqual(ModelRegistry.endpointKey(forBaseURL: base), probeKey)
        XCTAssertEqual(ModelRegistry.compatKey(forBaseURL: base), probeKey)
        XCTAssertEqual(ModelRegistry.endpointKey(forBaseURL: base + "/v1/"), probeKey,
                       "the raw config value and the saved record are written by different screens, "
                       + "so the lookup has to normalize before it matches or the key goes missing "
                       + "over a trailing slash")
        XCTAssertEqual(ModelRegistry.discoveryAuthorization(forBaseURL: base), "Bearer \(probeKey)",
                       "discovery has to present the same credential the chat call presents, or the "
                       + "probe is answering a question nobody asked")

        AppState.shared.config.ollamaBaseURL = base
        ModelRegistry.shared.setActiveProvider(.custom(endpoint.id))
        XCTAssertEqual(ModelRegistry.shared.apiKey(), probeKey)
        XCTAssertEqual(ModelRegistry.shared.localApiKey(), probeKey,
                       "the two accessors read one lookup, so they cannot answer differently")

        // A base URL with nothing saved against it gets NO header, which is not the
        // same as a header holding the placeholder a chat call sends.
        let unknown = "http://127.0.0.1:59997"
        XCTAssertNil(ModelRegistry.endpointKey(forBaseURL: unknown))
        XCTAssertNil(ModelRegistry.discoveryAuthorization(forBaseURL: unknown))
        XCTAssertEqual(ModelRegistry.compatKey(forBaseURL: unknown), "ollama")
    }

    // MARK: - A bad base URL throws, it does not crash

    func testABadBaseURLThrowsFromEveryEntryPointInsteadOfCrashing() async {
        // A space is the realistic typo: it survives a paste, it looks fine in a
        // text field, and it is the exact input that made URL(string:) return nil.
        let typo = "http://local host:11434"
        XCTAssertNil(EndpointValidator.normalizeBaseURL(typo),
                     "control: if this parsed, the backend would never hold the raw string and this "
                     + "test would pass for the wrong reason")
        let backend = OpenAICompatBackend(baseURL: typo)

        await expectInvalidBaseURL(typo) {
            _ = try await backend.complete(apiKey: "k", model: "m", system: nil, messages: [])
        }
        await expectInvalidBaseURL(typo) {
            _ = try await backend.completeVision(apiKey: "k", model: "m", system: nil,
                                                 userText: "what is this",
                                                 imageJPEG: Data([0xFF, 0xD8]))
        }
        await expectInvalidBaseURL(typo) {
            _ = try await backend.completeWithTools(apiKey: "k", model: "m", system: nil,
                                                    messages: [], tools: [])
        }
        // The streaming path cannot throw synchronously, so the failure has to
        // arrive as the stream finishing with the error. A stream that finishes
        // CLEANLY would look to ChatService like a model that said nothing.
        await expectInvalidBaseURL(typo) {
            let stream = await backend.streamCompleteWithTools(apiKey: "k", model: "m",
                                                               systemBlocks: [], messages: [],
                                                               tools: [])
            for try await _ in stream {
                XCTFail("an unusable base URL yielded a stream event")
            }
            XCTFail("the stream finished cleanly instead of failing")
        }
    }

    func testAUsableBaseURLStillBuildsARequest() async {
        // The negative case above proves nothing on its own: a backend that threw
        // for every base URL would pass it.
        let backend = OpenAICompatBackend(baseURL: "http://127.0.0.1:59995")
        do {
            _ = try await backend.complete(apiKey: "k", model: "m", system: nil, messages: [])
            XCTFail("nothing listens on that port, so the call cannot have succeeded")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("cannot build a request URL"),
                           "a well formed base URL must fail at the socket, not at URL construction")
        }
    }

    // MARK: - The cookbook and the picker hint agree

    func testTheCookbookAndTheToolUseHintCannotContradictEachOther() {
        XCTAssertGreaterThan(Cookbook.catalog.count, 5,
                             "the catalog is empty or tiny, so the sweep below proves nothing")
        XCTAssertFalse(Cookbook.catalog.contains { $0.id.lowercased().contains("embed") },
                       "an embedding model in the catalog would hit the embedding branch, which "
                       + "deliberately outranks the catalog. This assertion is here so that day "
                       + "fails loudly instead of quietly changing what the sweep below means")

        for model in Cookbook.catalog {
            let hint = EndpointValidator.toolUseHint(forModel: model.id)
            if model.supportsTools {
                XCTAssertNil(hint,
                             "Settings warns that \(model.id) has no tool use while the cookbook "
                             + "recommends it as a tool-capable model, in the same window")
            } else {
                XCTAssertNotNil(hint,
                                "\(model.id) is catalogued as having no tool use and the picker "
                                + "says nothing about it")
            }
        }
    }

    func testTheFamilyHeuristicStillCoversTagsTheCatalogHasNeverHeardOf() {
        // gemma4 is catalogued with tools; gemma2 is not catalogued at all, and
        // "gemma" is in the no-tools family list, which is the prefix match that
        // was swallowing gemma4 whole.
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: "gemma4:12b"))
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: "GEMMA4:12B"),
                     "the catalog lookup has to be case-insensitive like the heuristic it precedes")
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "gemma2:9b"))
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "phi3:mini"))
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: "llama3.1"))
    }

    func testEmbeddingModelsAreStillCaughtAheadOfEverythingElse() {
        XCTAssertTrue(EndpointValidator.toolUseHint(forModel: "nomic-embed-text")?
                        .contains("embedding model") ?? false)
        XCTAssertTrue(EndpointValidator.toolUseHint(forModel: "all-minilm")?
                        .contains("embedding model") ?? false)
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: ""))
    }

    // MARK: - Helpers

    /// `active()`, `modelId()` and `apiKey()` must all be describing the same
    /// route. The failure this pins is the mixed one: the Anthropic backend handed
    /// a local model id (a guaranteed 401), or a compat backend handed the
    /// Anthropic key, or a stored endpoint key posted to api.anthropic.com.
    private func assertTheTrioAgrees(file: StaticString = #filePath, line: UInt = #line) {
        let registry = ModelRegistry.shared
        let onClaude = registry.resolvedProvider == .anthropic

        XCTAssertEqual(registry.active() === registry.anthropic, onClaude,
                       "active() disagrees with resolvedProvider", file: file, line: line)
        XCTAssertEqual(registry.modelId(),
                       onClaude ? AppState.shared.config.model : AppState.shared.config.offlineLLMModel,
                       "modelId() disagrees with resolvedProvider", file: file, line: line)
        if onClaude {
            XCTAssertEqual(registry.apiKey(), AppState.shared.anthropicKey,
                           "the Anthropic backend was handed something other than the Anthropic key",
                           file: file, line: line)
        } else {
            XCTAssertNotEqual(registry.apiKey(), AppState.shared.anthropicKey,
                              "a compat endpoint was handed the Anthropic key",
                              file: file, line: line)
        }
    }

    private func expectInvalidBaseURL(_ base: String,
                                     _ body: () async throws -> Void,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async {
        do {
            try await body()
            XCTFail("an unusable base URL did not fail the call", file: file, line: line)
        } catch {
            XCTAssertTrue(error is ClaudeError,
                          "the failure has to arrive as a ClaudeError the chat path already handles, "
                          + "got \(type(of: error))", file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains(base),
                          "the message has to name the base URL the user typed, got: "
                          + error.localizedDescription, file: file, line: line)
        }
    }
}
