import XCTest
@testable import Grux

/// COMPACTION AND TITLING WERE HARDWIRED TO ANTHROPIC, SO THE LOCAL-ONLY USER
/// WAS THE ONE USER WHO NEVER GOT EITHER.
///
/// `compactActiveThread` opened with `let keyForCall = anthropicKey` and bailed
/// out on an empty one, `autoTitleIfNeeded` did the same, and both then passed
/// `config.model`, a claude- id, into the compactor. Somebody routing chat
/// through a local model has no Anthropic key by design: that is the whole point
/// of the local path. So their thread grew without bound until it overflowed
/// into a provider error about conversation length they could do nothing about,
/// and their sidebar stayed a wall of "New chat". The user with the smallest
/// context window of anyone was the only one whose context was never compacted.
///
/// And readiness disagreed with the router in the same shape: `evaluate` read
/// the offline switch and `local != nil` directly, so a selected custom endpoint
/// with no Anthropic key resolved to `.needsModel`, Send stayed disabled, and
/// the copy said Grux was not using a model it was in fact about to use.
///
/// Everything here is pure or in-memory. No socket is opened: the compactor
/// tests hand it a recording backend, and the routing tests point every base URL
/// at a port nothing listens on.

// MARK: - A backend that records instead of sending

private struct BackendNotExercised: Error {}

/// Records what a call was handed. Conforms to `ModelBackend` in full because
/// the protocol is what the compactor now takes, and a fake that only
/// implements the one method would not prove the real type can be substituted.
private actor RecordingBackend: ModelBackend {

    struct Call: Equatable {
        let apiKey: String
        let model: String
        let system: String?
        let maxTokens: Int
    }

    private(set) var calls: [Call] = []
    private let reply: String

    init(reply: String) { self.reply = reply }

    func complete(apiKey: String, model: String, system: String?,
                  messages: [ClaudeMessage], maxTokens: Int, temperature: Double,
                  spanName: String, feature: String) async throws -> String {
        calls.append(Call(apiKey: apiKey, model: model, system: system, maxTokens: maxTokens))
        return reply
    }

    func completeVision(apiKey: String, model: String, system: String?,
                        userText: String, imageJPEG: Data, mediaType: String,
                        maxTokens: Int, temperature: Double,
                        spanName: String, feature: String) async throws -> String {
        throw BackendNotExercised()
    }

    func streamCompleteWithTools(apiKey: String, model: String,
                                 systemBlocks: [[String: Any]], messages: [[String: Any]],
                                 tools: [ClaudeTool], maxTokens: Int, temperature: Double,
                                 spanName: String, feature: String)
        -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream<ClaudeStreamEvent, Error> { $0.finish(throwing: BackendNotExercised()) }
    }

    func completeWithTools(apiKey: String, model: String, system: String?,
                           messages: [[String: Any]], tools: [ClaudeTool],
                           maxTokens: Int, temperature: Double,
                           spanName: String, feature: String) async throws -> ClaudeToolsResponse {
        throw BackendNotExercised()
    }

    func usageSnapshot() -> (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        (0, 0, 0, 0)
    }
}

// MARK: - The compactor spends the route it is handed

final class ChatCompactorBackendTests: XCTestCase {

    private var transcript: [ChatMessage] {
        [ChatMessage(role: .user, content: "we agreed to ship the compactor this week"),
         ChatMessage(role: .assistant, content: "noted, the threshold is 40 messages"),
         ChatMessage(role: .user, content: "and the title should stop saying New chat")]
    }

    /// AN EMPTY KEY IS NORMAL ON A LOCAL ROUTE, not a reason to skip. The old
    /// signature took an apiKey and a model and reached a cloud client under its
    /// own steam, so there was nowhere to put a local route even if the caller
    /// had one.
    func testSummarizingRunsOnTheHandedBackendWithAnEmptyKeyAndALocalModelId() async {
        let backend = RecordingBackend(reply: "  the user shipped the compactor  ")

        let summary = await ChatCompactor.summarize(
            messages: transcript,
            priorSummary: nil,
            backend: backend,
            model: "llama3.1",
            apiKey: ""
        )

        XCTAssertEqual(summary, "the user shipped the compactor",
                       "the summary the routed backend produced never came back")
        let calls = await backend.calls
        XCTAssertEqual(calls.count, 1, "the compactor did not call the backend it was handed")
        XCTAssertEqual(calls.first?.model, "llama3.1",
                       "compaction sent a model id the routed server has never heard of")
        XCTAssertEqual(calls.first?.apiKey, "",
                       "an empty key was substituted for, which is how a local route ends up "
                       + "authenticating against a cloud one")
        XCTAssertEqual(calls.first?.system, ChatCompactor.systemPrompt,
                       "the summarizer prompt did not survive the move to the routed backend")
    }

    /// Titling is the same defect and needs the same proof: a sidebar of
    /// "New chat" is what the local-only user actually saw.
    func testTitlingRunsOnTheHandedBackendWithAnEmptyKeyAndALocalModelId() async {
        let backend = RecordingBackend(reply: "\"shipping the compactor\"")

        let title = await ChatCompactor.generateTitle(
            messages: transcript,
            backend: backend,
            model: "llama3.1",
            apiKey: ""
        )

        XCTAssertEqual(title, "shipping the compactor")
        let calls = await backend.calls
        XCTAssertEqual(calls.count, 1, "titling did not call the backend it was handed")
        XCTAssertEqual(calls.first?.model, "llama3.1")
        XCTAssertEqual(calls.first?.apiKey, "")
        XCTAssertEqual(calls.first?.maxTokens, 32,
                       "a 2 to 5 word title is being billed for a full-length completion")
    }
}

// MARK: - Readiness agrees with the router

final class ChatReadinessRouterAgreementTests: XCTestCase {

    /// THE ONE THAT WOULD HAVE CAUGHT THE CAPPED FEATURE. A saved endpoint is
    /// selected, it resolves, and it carries its own credential, so an empty
    /// Anthropic key is not an obstacle on that route.
    func testARoutedCustomEndpointIsReadyWithNoAnthropicKey() {
        let id = UUID()
        let r = ChatReadiness.evaluate(hasAnthropicKey: false,
                                       localModelAvailable: false,
                                       chosenProvider: .custom(id),
                                       routedProvider: .custom(id))
        XCTAssertEqual(r, .ready,
                       "routing works and the composer refuses to send, which caps the whole "
                       + "custom-endpoint feature")
        XCTAssertTrue(r.canSend)
        XCTAssertTrue(r.headline.isEmpty, "a working route is being scolded")
    }

    /// The same for a discovered local model the router is actually using.
    func testARoutedLocalModelIsReadyWithNoAnthropicKey() {
        XCTAssertEqual(ChatReadiness.evaluate(hasAnthropicKey: false,
                                              localModelAvailable: true,
                                              chosenProvider: .local,
                                              routedProvider: .local),
                       .ready)
    }

    /// A selection can outlive the endpoint it points at: the endpoint is
    /// deleted and the stored id stays in defaults, so the router falls back to
    /// Anthropic. With no key that is the same dead end as nothing attached, and
    /// readiness must not report green off a choice that no longer resolves.
    func testACustomChoiceWhoseEndpointIsGoneIsOnlyReadyIfAKeyCanCarryIt() {
        let id = UUID()
        XCTAssertEqual(ChatReadiness.evaluate(hasAnthropicKey: false,
                                              localModelAvailable: false,
                                              chosenProvider: .custom(id),
                                              routedProvider: .anthropic),
                       .needsModel)
        XCTAssertEqual(ChatReadiness.evaluate(hasAnthropicKey: true,
                                              localModelAvailable: false,
                                              chosenProvider: .custom(id),
                                              routedProvider: .anthropic),
                       .ready)
    }

    /// AND THE FOUR STATES DID NOT REGRESS. Every combination of the three
    /// legacy facts, with the answer each one gave before the router became an
    /// input. A fix that quietly rewrites an existing verdict is a second bug.
    func testTheOldInputCombinationsStillProduceTheSameFourStates() {
        let table: [(key: Bool, local: Bool, offline: Bool, expected: ChatReadiness)] = [
            (false, false, false, .needsModel),
            (false, true,  false, .localModelFoundButNotRouted),
            (true,  false, false, .ready),
            (true,  true,  false, .ready),
            (false, false, true,  .offlinePinnedButNoLocalModel),
            (false, true,  true,  .ready),
            (true,  false, true,  .offlinePinnedButNoLocalModel),
            (true,  true,  true,  .ready)
        ]
        for row in table {
            XCTAssertEqual(
                ChatReadiness.evaluate(hasAnthropicKey: row.key,
                                       localModelAvailable: row.local,
                                       offlineMode: row.offline),
                row.expected,
                "key=\(row.key) local=\(row.local) offline=\(row.offline) changed verdict")
        }
    }
}

// MARK: - The route the background calls take, and the switch that moves it

@MainActor
final class ChatBackgroundRoutingTests: XCTestCase {

    private var savedOffline = false
    private var savedBaseURL = ""
    private var savedWritesSuspended = false

    override func setUp() async throws {
        try await super.setUp()
        savedOffline = AppState.shared.offlineMode
        savedBaseURL = AppState.shared.config.ollamaBaseURL
        savedWritesSuspended = Persistence.writesSuspended
        // Nothing listens on port 1, so the discovery Task the offline switch
        // kicks off fails fast and cannot populate `local` underneath an
        // assertion that depends on it being nil.
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:1"
        // In-memory state only. Suspending writes keeps the real config.json and
        // custom-endpoints.json out of the run, so a crash mid-test cannot leave
        // a probe endpoint or a flipped switch behind on the machine.
        Persistence.writesSuspended = true
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() async throws {
        AppState.shared.offlineMode = savedOffline
        AppState.shared.config.ollamaBaseURL = savedBaseURL
        Persistence.writesSuspended = savedWritesSuspended
        // Last, because restoring the switch above now records a provider
        // choice. Clearing it leaves the machine deriving from the switch, which
        // is the state an install that has never chosen is in.
        ModelRegistry.shared.resetLocalForTest()
        try await super.tearDown()
    }

    /// THE HEADLINE FIX. The background calls resolve through the router, so a
    /// selected endpoint gets the endpoint's model and the endpoint's key rather
    /// than a claude- id and whatever the Keychain holds.
    func testCompactionResolvesThroughTheRouterRatherThanTheAnthropicKey() throws {
        let store = CustomEndpointStore.shared
        let base = "http://127.0.0.1:59999/probe-\(UUID().uuidString)"
        guard let endpoint = store.add(name: "Probe", baseURL: base, apiKey: nil) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: endpoint.id) }

        let savedLocalModel = AppState.shared.config.offlineLLMModel
        AppState.shared.config.offlineLLMModel = "probe-local-model"
        defer { AppState.shared.config.offlineLLMModel = savedLocalModel }

        // The switch stays OFF on purpose: a hosted endpoint is an online route,
        // and needing an unrelated offline toggle was the defect.
        AppState.shared.offlineMode = false
        ModelRegistry.shared.setActiveProvider(.custom(endpoint.id))

        let routing = try XCTUnwrap(
            AppState.shared.chatBackgroundRouting(),
            "compaction and titling are skipped on a fully routed endpoint, which is the "
            + "unbounded-thread bug with an extra step")
        XCTAssertFalse(routing.backend === ModelRegistry.shared.anthropic,
                       "the summary is still being written by Anthropic on an install that "
                       + "chose something else")
        XCTAssertEqual(routing.modelId, "probe-local-model",
                       "a claude- model id went to a compat endpoint, which is a guaranteed 400")
        XCTAssertEqual(routing.apiKey, ModelRegistry.compatKey(forBaseURL: base),
                       "the endpoint got a key belonging to a different provider")
    }

    /// AND THE GUARD IS STILL A GUARD. Offline is pinned with nothing to run, so
    /// there is no route and skipping remains right.
    ///
    /// Reached without touching anyone's Keychain, for the reason
    /// `ChatSendGuardIntegrationTests` gives: the obvious setup, "no API key",
    /// means deleting the operator's real credential, and a test that vandalises
    /// the machine it runs on is not a test. This is the other state whose
    /// readiness cannot send, and it is reachable from pure in-memory state.
    func testWithNoRouteAtAllTheBackgroundCallsAreStillSkipped() {
        AppState.shared.offlineMode = true
        ModelRegistry.shared.resetLocalForTest()

        XCTAssertFalse(ChatReadiness.current().canSend,
                       "control: the state under test can send, so the nil below would prove nothing")
        XCTAssertNil(AppState.shared.chatBackgroundRouting(),
                     "the fix removed the guard instead of widening it, so compaction now spends "
                     + "a call that cannot possibly succeed")

        // And the literal no-key-no-local case, which only the pure form can
        // reach on a machine that has credentials.
        XCTAssertFalse(ChatReadiness.evaluate(hasAnthropicKey: false,
                                              localModelAvailable: false,
                                              offlineMode: false).canSend)
    }

    /// THE OFFLINE SWITCH WAS INERT. The active provider became an explicit
    /// stored choice that falls back to the switch only while nothing has been
    /// chosen, so after one press of "Use Claude" or "Use", moving the switch
    /// changed nothing about where a turn went.
    func testTheOfflineSwitchMovesTheRouterEvenAfterAnExplicitChoice() {
        let registry = ModelRegistry.shared
        // Start from a known position, because the switch only decides anything
        // when it MOVES: leaving it where the machine happened to have it would
        // make the flip below a no-op and pass on nothing.
        AppState.shared.offlineMode = false
        registry.setActiveProvider(.custom(UUID()))

        AppState.shared.offlineMode = true
        XCTAssertEqual(registry.activeProvider, .local,
                       "the visible switch says offline and the router is still on the old choice")

        AppState.shared.offlineMode = false
        XCTAssertEqual(registry.activeProvider, .anthropic,
                       "turning offline mode off left the router pinned to local")
    }

    /// AND IT MUST NOT FIRE AT LAUNCH. `load()` writes the switch while
    /// restoring the persisted value, so a provider write there would overwrite
    /// the user's explicit choice on every single launch.
    func testRestoringTheSwitchAtLaunchDoesNotOverwriteAnExplicitProviderChoice() {
        let state = AppState.shared
        let savedConfig = state.config
        let savedTasks = state.tasks
        let savedEvents = state.events
        let savedCurrentTask = state.currentTaskId
        let savedChat = state.chat
        let savedThreads = state.threads
        let savedThreadId = state.activeThreadId
        let savedSummary = state.activeThreadSummary
        defer {
            state.config = savedConfig
            state.tasks = savedTasks
            state.events = savedEvents
            state.currentTaskId = savedCurrentTask
            state.chat = savedChat
            state.threads = savedThreads
            state.activeThreadId = savedThreadId
            state.activeThreadSummary = savedSummary
        }

        // load() restores config.offlineMode, so the switch has to be sitting on
        // the OTHER value or the didSet never runs and this proves nothing.
        let persisted = Persistence.load(GruxConfig.self, from: Persistence.configURL, fallback: .default)
        state.offlineMode = !persisted.offlineMode

        let chosen = ActiveProvider.custom(UUID())
        ModelRegistry.shared.setActiveProvider(chosen)

        state.load()

        XCTAssertEqual(state.offlineMode, persisted.offlineMode,
                       "control: load() did not move the switch, so the restore guard was never "
                       + "exercised")
        XCTAssertEqual(ModelRegistry.shared.providerSelection, chosen,
                       "restoring the persisted switch at launch overwrote the explicit provider "
                       + "choice, so a chosen endpoint survives exactly until the next launch")
    }

    /// The call sites have to USE the seam. Testing the seam alone is how a rule
    /// stays green while nothing calls it, which this repo has already been bitten
    /// by three times.
    func testBothBackgroundCallSitesGoThroughTheRouterSeam() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/AppState.swift"), encoding: .utf8)

        for (name, from, to) in [
            ("auto-titling", "private func autoTitleIfNeeded", "private func autoCompactIfNeeded"),
            ("compaction", "func compactActiveThread", "func isWithinActiveHours")
        ] {
            let start = try XCTUnwrap(src.range(of: from), "\(name) moved, so this checks nothing")
            let end = try XCTUnwrap(src.range(of: to, range: start.upperBound..<src.endIndex),
                                    "\(name) has no end anchor any more")
            let body = String(src[start.upperBound..<end.lowerBound])
            XCTAssertTrue(body.contains("chatBackgroundRouting()"),
                          "\(name) does not resolve its route, so it cannot reach a local model")
            XCTAssertFalse(body.contains("anthropicKey"),
                           "\(name) still reads the Anthropic key directly, which is the guard "
                           + "that shut the local-only user out")
        }
    }
}
