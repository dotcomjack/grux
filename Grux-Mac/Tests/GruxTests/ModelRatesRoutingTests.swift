import XCTest
@testable import Grux

/// Pricing decided by ROUTE, not by the model's name.
///
/// The bug these tests exist for: `ModelRates` used to read local-versus-paid off
/// the model id string. It split the id on "/", kept the tail, and returned a zero
/// rate whenever that tail began with "deepseek", "llama", "qwen", "mistral",
/// "gemma", "command-r" and thirteen other tokens. Every one of those names is
/// also a namespaced id on a hosted aggregator, and the endpoints pane in Settings
/// suggests OpenRouter by name, so a billed turn was priced at $0 on the exact
/// line onboarding promises will show "the estimated cost of your next send at API
/// rates". `openai/gpt-4o` matched nothing and landed on the cheapest-paid Haiku
/// rate instead, roughly 2.5x under.
///
/// Every number below is asserted literally rather than compared to the table it
/// came from, so a future rate edit has to be a deliberate act with a test change
/// attached, not a silent one.
///
/// Pure: no network, no disk, no MainActor.
final class ModelRatesRoutingTests: XCTestCase {

    // The six aggregator ids whose tails collide with the legacy local-prefix
    // list, plus the two the collision did not save. Each is a real OpenRouter id
    // shape: vendor namespace, slash, model.
    private static let openRouterFreeLookingIDs = [
        "deepseek/deepseek-chat",
        "meta-llama/llama-3.3-70b-instruct",
        "qwen/qwen3-max",
        "mistralai/mistral-large",
        "google/gemma-3-27b-it",
        "cohere/command-r-plus",
    ]

    private static let hostedURL = "https://openrouter.ai/api"

    private var hosted: ModelRates.RateSource { .hostedCompat(baseURL: Self.hostedURL) }

    // MARK: - The P0: a hosted route never prices at zero

    func test_hosted_freeLookingAggregatorIDs_areNeverFree() {
        for id in Self.openRouterFreeLookingIDs {
            let r = ModelRates.rates(forModelID: id, source: hosted)
            XCTAssertFalse(r.isZero, "\(id) is billed by the aggregator and must not price at $0")
            // No cited rate for these, so they take the floor and read like the
            // placeholder it is. Asserted exactly: if a real rate is ever added
            // for one of them, this line is where that decision gets recorded.
            XCTAssertEqual(r, ModelRates.hostedFloor, "\(id) should take the hosted floor")
            XCTAssertEqual(r.input, 1.00, "\(id) input")
            XCTAssertEqual(r.output, 5.00, "\(id) output")
        }
    }

    // The legacy id-only path still answers $0 for these ids, and that is the
    // whole reason nothing that can name its route may use it. Pinning it here
    // makes the delegation a measured fact rather than an assumption, and turns
    // any future attempt to route a hosted turn back through the guess into a
    // red test in this file instead of a wrong number in the composer.
    func test_legacyIDOnlyPath_stillGuessesFree_whichIsWhyItIsLegacyOnly() {
        for id in Self.openRouterFreeLookingIDs {
            XCTAssertTrue(ModelRates.rates(forModelID: id).isZero,
                          "\(id) documents the legacy guess this fix routes around")
        }
    }

    func test_hosted_gpt4o_usesItsPublishedRate_notTheHaikuFloor() {
        let r = ModelRates.rates(forModelID: "openai/gpt-4o", source: hosted)
        XCTAssertEqual(r.input, 2.50)
        XCTAssertEqual(r.output, 10.00)
        XCTAssertEqual(r.cacheRead, 1.25)
        // No write premium: a cache miss is billed as an ordinary input token.
        XCTAssertEqual(r.cacheWrite, 2.50)
        // The old answer, and the size of the error it produced.
        XCTAssertEqual(r.input, ModelRates.cheapestPaid.input * 2.5, accuracy: 1e-9)
    }

    func test_hosted_gpt4oMini_isNotSwallowedByTheGpt4oPrefix() {
        let mini = ModelRates.rates(forModelID: "openai/gpt-4o-mini", source: hosted)
        XCTAssertEqual(mini.input, 0.15)
        XCTAssertEqual(mini.output, 0.60)
        XCTAssertEqual(mini.cacheRead, 0.075)
        XCTAssertEqual(mini.cacheWrite, 0.15)
        XCTAssertNotEqual(mini, ModelRates.rates(forModelID: "openai/gpt-4o", source: hosted))
    }

    func test_hosted_unknownID_fallsBackToPaid_neverFree() {
        let r = ModelRates.rates(forModelID: "some-vendor/some-mystery-model-x", source: hosted)
        XCTAssertFalse(r.isZero, "an unrecognized hosted model must never read $0")
        XCTAssertEqual(r, ModelRates.hostedFloor)
        XCTAssertEqual(r.input, 1.00)
        XCTAssertEqual(r.output, 5.00)

        // Including one whose bare name is a local model's name with no namespace
        // at all. On a hosted route, the name is not evidence about anything.
        let bare = ModelRates.rates(forModelID: "llama3.1", source: hosted)
        XCTAssertFalse(bare.isZero)
        XCTAssertEqual(bare, ModelRates.hostedFloor)
    }

    func test_hosted_aggregatorFrontingAnthropic_billsAnthropicListPrice() {
        // The aggregator passes Anthropic's price through, so the ladder this file
        // already owns is reused rather than copied into a second table that could
        // drift from it.
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-opus-4-8", source: hosted).input, 5.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-opus-4-8", source: hosted).output, 25.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-3.5-sonnet", source: hosted).input, 3.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-haiku-4-5", source: hosted).input, 1.00)
    }

    // MARK: - The same ids are genuinely free on a local route

    func test_local_sameIDs_areFree() {
        for id in Self.openRouterFreeLookingIDs {
            XCTAssertTrue(ModelRates.rates(forModelID: id, source: .local).isZero,
                          "\(id) served locally bills nobody")
        }
        // And so is anything else, including ids that are unambiguously paid
        // models elsewhere. A process on this machine charges nothing whatever it
        // decided to call itself.
        XCTAssertTrue(ModelRates.rates(forModelID: "openai/gpt-4o", source: .local).isZero)
        XCTAssertTrue(ModelRates.rates(forModelID: "claude-opus-4-8", source: .local).isZero)
        XCTAssertTrue(ModelRates.rates(forModelID: "some-mystery-model-x", source: .local).isZero)
    }

    // MARK: - The classifier

    func test_isLocalBaseURL_loopback() {
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://127.0.0.1:11434"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://127.1.2.3:8000"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://localhost:11434"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("https://localhost"))
        // The Settings box is free text and routinely holds no scheme at all.
        // URLComponents reads this as scheme "localhost" with host nil, which is
        // why the host split is hand-rolled.
        XCTAssertTrue(ModelRates.isLocalBaseURL("localhost:11434"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://[::1]:11434"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("::1"))
    }

    func test_isLocalBaseURL_bonjourName() {
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://studio.local:11434"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://workshop.local"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("studio.local:11434"))
    }

    func test_isLocalBaseURL_rfc1918LAN() {
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://192.168.1.50:8000"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://10.0.0.7:11434"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://172.16.4.4:11434"))
        XCTAssertTrue(ModelRates.isLocalBaseURL("http://172.31.255.254:11434"))
        // Just outside 172.16.0.0/12, on both sides. This is the range people
        // get wrong by assuming the whole 172. block is private.
        XCTAssertFalse(ModelRates.isLocalBaseURL("http://172.15.0.1:11434"))
        XCTAssertFalse(ModelRates.isLocalBaseURL("http://172.32.0.1:11434"))
    }

    func test_isLocalBaseURL_publicHostsAreHosted() {
        XCTAssertFalse(ModelRates.isLocalBaseURL("https://openrouter.ai/api"))
        XCTAssertFalse(ModelRates.isLocalBaseURL("https://openrouter.ai/api/v1"))
        XCTAssertFalse(ModelRates.isLocalBaseURL("https://api.together.xyz"))
        XCTAssertFalse(ModelRates.isLocalBaseURL("http://8.8.8.8:11434"))
        // A public hostname whose first label merely LOOKS like a private range.
        // Matching on the string prefix instead of parsed octets would call this
        // free, which is the same class of mistake one layer down.
        XCTAssertFalse(ModelRates.isLocalBaseURL("https://10.example.com"))
        XCTAssertFalse(ModelRates.isLocalBaseURL("https://192.168.example.com"))
        XCTAssertFalse(ModelRates.isLocalBaseURL("https://localhost.evil.example.com"))
    }

    func test_isLocalBaseURL_unknownIsTreatedAsHosted() {
        // Nothing to judge means we cannot claim free. The failure that costs
        // money is the one that says $0.
        XCTAssertFalse(ModelRates.isLocalBaseURL(""))
        XCTAssertFalse(ModelRates.isLocalBaseURL("   "))
        XCTAssertFalse(ModelRates.isLocalBaseURL("http://"))
    }

    // MARK: - The Anthropic ladder did not move

    // Byte-identical to the pre-provenance behaviour for every id in the ladder,
    // asserted twice: once against the literal published numbers, once against the
    // legacy entry point the session-JSONL replay and the Foundry accounting still
    // call. Both must agree or the migration moved a historical dollar figure.
    func test_anthropic_ladderUnchanged() {
        let expected: [(String, Double, Double, Double, Double)] = [
            ("claude-fable-5",   10.00, 50.00, 1.00, 12.50),
            ("claude-opus-4-8",   5.00, 25.00, 0.50,  6.25),
            ("claude-opus-4-7",  15.00, 75.00, 1.50, 18.75),
            ("claude-opus-4-6",  15.00, 75.00, 1.50, 18.75),
            ("claude-sonnet-5",   3.00, 15.00, 0.30,  3.75),
            ("claude-sonnet-4-6", 3.00, 15.00, 0.30,  3.75),
            ("claude-sonnet-4-5", 3.00, 15.00, 0.30,  3.75),
            ("claude-haiku-4-5",  1.00,  5.00, 0.10,  1.25),
        ]
        for (id, input, output, cacheRead, cacheWrite) in expected {
            let r = ModelRates.rates(forModelID: id, source: .anthropic)
            XCTAssertEqual(r.input, input, "\(id) input")
            XCTAssertEqual(r.output, output, "\(id) output")
            XCTAssertEqual(r.cacheRead, cacheRead, "\(id) cacheRead")
            XCTAssertEqual(r.cacheWrite, cacheWrite, "\(id) cacheWrite")
            XCTAssertEqual(r, ModelRates.rates(forModelID: id),
                           "\(id) must price identically on the legacy id-only path")
        }
    }

    func test_anthropic_datedSuffixAndFamilyFallbacksUnchanged() {
        // A dated id still resolves through the ladder prefix.
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-haiku-4-5-20251001", source: .anthropic).input, 1.00)
        // Family fallbacks for ids the ladder misses.
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-opus-9-9", source: .anthropic).input, 15.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "claude-opus-9-9", source: .anthropic).output, 75.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-3.5-sonnet", source: .anthropic).input, 3.00)
        XCTAssertEqual(ModelRates.rates(forModelID: "anthropic/claude-opus-4-8", source: .anthropic).input, 5.00)
        // Unknown Anthropic-side id keeps the cheapest-known policy: an
        // unrecognized id must never inflate a figure on this side.
        XCTAssertEqual(ModelRates.rates(forModelID: "some-mystery-model-x", source: .anthropic),
                       ModelRates.cheapestPaid)
    }

    func test_legacyKnownRates_contractUnchanged() {
        // nil-for-unknown, which ClaudeSessionJSONL depends on to bill $0 rather
        // than a fallback rate.
        XCTAssertNil(ModelRates.knownRates(forModelID: "some-mystery-model-x"))
        XCTAssertEqual(ModelRates.knownRates(forModelID: "claude-opus-4-8")?.input, 5.00)
        XCTAssertTrue(ModelRates.knownRates(forModelID: "qwen3:8b")?.isZero == true)
    }

    // MARK: - CostMeter passes the route through

    func test_rateSource_mapsProviderAndURL() {
        XCTAssertEqual(CostMeter.rateSource(forProvider: "anthropic", localBaseURL: nil), .anthropic)
        XCTAssertEqual(CostMeter.rateSource(forProvider: "local", localBaseURL: "http://localhost:11434"), .local)
        XCTAssertEqual(CostMeter.rateSource(forProvider: "local", localBaseURL: "http://192.168.1.50:8000"), .local)
        XCTAssertEqual(CostMeter.rateSource(forProvider: "local", localBaseURL: Self.hostedURL),
                       .hostedCompat(baseURL: Self.hostedURL))
        // No URL to judge keeps the pre-provenance assumption, for the call sites
        // that predate the parameter.
        XCTAssertEqual(CostMeter.rateSource(forProvider: "local", localBaseURL: nil), .local)
    }

    func test_estimate_hostedRouteIsPriced_notAnnouncedAsFree() {
        // The shipped failure end to end: provider tagged "local" because an
        // OpenAI-compatible server answered, model id that looks local, real
        // dollars being spent.
        let est = CostMeter.estimate(inputTokens: 20_000, maxOutputTokens: 2_000,
                                     modelId: "deepseek/deepseek-chat",
                                     provider: "local",
                                     source: .hostedCompat(baseURL: Self.hostedURL))
        XCTAssertGreaterThan(est.estimatedUSD ?? 0, 0, "a billed hosted turn must not read $0")
        XCTAssertFalse(est.label.contains("free"), "label was: \(est.label)")
        // 20,000 in at $1.00/MTok plus 2,000 out at $5.00/MTok, on the floor.
        XCTAssertEqual(est.estimatedUSD ?? 0, 0.02 + 0.01, accuracy: 1e-9)
    }

    func test_estimate_localRouteStaysFree() {
        let est = CostMeter.estimate(inputTokens: 20_000, maxOutputTokens: 2_000,
                                     modelId: "deepseek/deepseek-chat",
                                     provider: "local",
                                     source: .local)
        XCTAssertEqual(est.estimatedUSD, 0)
        XCTAssertTrue(est.label.contains("free"), "label was: \(est.label)")
    }

    func test_estimate_subscriptionStaysFreeOnAnAnthropicRoute() {
        // Plan quota, not dollars. Unchanged by the provenance work.
        let est = CostMeter.estimate(inputTokens: 20_000, maxOutputTokens: 2_000,
                                     modelId: "claude-opus-4-8",
                                     provider: "subscriptionCLI",
                                     source: .anthropic)
        XCTAssertEqual(est.estimatedUSD, 0)
        XCTAssertTrue(est.label.contains("subscription"), "label was: \(est.label)")
    }

    func test_estimate_hostedRouteOffersNoCheaperHaiku_becauseTheFloorIsAlreadyHaiku() {
        // The floor equals the cheapest paid rate, so there is no cheaper route to
        // name and the composer must not invent one.
        let est = CostMeter.estimate(inputTokens: 20_000, maxOutputTokens: 2_000,
                                     modelId: "qwen/qwen3-max",
                                     provider: "local",
                                     source: .hostedCompat(baseURL: Self.hostedURL))
        XCTAssertNil(est.cheaperAlternative)

        // A genuinely pricier hosted model still gets the Haiku suggestion.
        let pricey = CostMeter.estimate(inputTokens: 20_000, maxOutputTokens: 2_000,
                                        modelId: "openai/gpt-4o",
                                        provider: "local",
                                        source: .hostedCompat(baseURL: Self.hostedURL))
        XCTAssertEqual(pricey.cheaperAlternative?.modelId, CostMeter.haikuModelId)
    }
}

/// The other half of the same fix: the composer's dollar figure has to be
/// decided by the URL the REQUEST goes to, not by the Settings field that used to
/// be the only URL there was.
///
/// `ModelRates.RateSource` closed the model-id half of the $0 bug. The base-URL
/// half survived it. `CostMeter.publishChatEstimate` read
/// `AppState.shared.config.ollamaBaseURL` for provenance, on the stated ground
/// that every non-Anthropic backend was built from that one setting. The
/// explicit provider selection falsified that: `.custom(id)` builds its backend
/// and its key from the saved endpoint's own base URL, and nothing re-syncs the
/// config field when the selection moves or clears the selection when the field
/// is edited. Add a hosted endpoint, press Use, then set the "Base URL" box back
/// to http://localhost:11434 (a natural move, since the health poller, the
/// cookbook and the Compare tab all read that box), and every turn bills the
/// hosted endpoint with the hosted key while the composer reads "$0 estimated
/// (local, free)".
///
/// These exercise the LIVE estimator seam rather than the pure statics, because
/// the pure statics were already green: the whole defect was which URL got handed
/// to them. Nothing here opens a socket and nothing reaches disk (writes are
/// suspended, and the one base URL that could be probed is a port nothing
/// listens on).
@MainActor
final class CostMeterRouteProvenanceTests: XCTestCase {

    // A hosted endpoint that is guaranteed not to collide with anything this
    // machine has actually saved, so adding it cannot update, and removing it
    // cannot delete, a real record in the shared store.
    private var hostedProbeURL = ""

    private var savedOffline = false
    private var savedBaseURL = ""
    private var savedPresetId: UUID?
    private var savedEstimate: ChatRunEstimate?
    private var savedWritesSuspended = false

    override func setUp() async throws {
        try await super.setUp()
        hostedProbeURL = "https://probe-\(UUID().uuidString.lowercased()).example.com"
        savedOffline = AppState.shared.offlineMode
        savedBaseURL = AppState.shared.config.ollamaBaseURL
        savedPresetId = PresetStore.shared.activeChatPresetId
        savedEstimate = CostMeter.shared.chatEstimate
        savedWritesSuspended = Persistence.writesSuspended
        // In-memory only. The real config.json and custom-endpoints.json stay out
        // of the run, so a crash mid-test cannot leave a probe endpoint behind.
        Persistence.writesSuspended = true
        // A preset pinned to "local" is one of the two routes the "local" tag
        // stands for, and whichever preset this machine happens to have active is
        // not this test's input. Cleared here and restored in tearDown.
        if savedPresetId != nil { PresetStore.shared.setActiveChat(id: nil) }
        AppState.shared.offlineMode = false
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() async throws {
        // Nothing listens on port 1, so restoring the switch cannot start a real
        // discovery probe against whatever this machine actually runs.
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:1"
        AppState.shared.offlineMode = savedOffline
        ModelRegistry.shared.resetLocalForTest()
        AppState.shared.config.ollamaBaseURL = savedBaseURL
        PresetStore.shared.setActiveChat(id: savedPresetId)
        CostMeter.shared.chatEstimate = savedEstimate
        Persistence.writesSuspended = savedWritesSuspended
        try await super.tearDown()
    }

    // Publish an estimate through the live seam with an EMPTY prompt, so the only
    // token count that can move between machines is the two characters of "[]"
    // the system-block array serializes to, scaled by whatever calibration factor
    // this machine has learned. The output budget carries the assertable dollars.
    private func publish(modelId: String, provider: String) throws -> ChatRunEstimate {
        CostMeter.shared.publishChatEstimate(
            systemBlocks: [], messages: [], tools: [],
            modelId: modelId, provider: provider, maxOutputTokens: 2_000)
        return try XCTUnwrap(CostMeter.shared.chatEstimate, "no estimate was published")
    }

    // 2,000 output tokens at the hosted floor's $5.00 per million, plus the empty
    // prompt at its $1.00 per million. The prompt term is written out rather than
    // rounded away because `calibrationFactor()` is read from disk, so a bare
    // $0.01 would fail on any machine that has ever chatted.
    private func hostedFloorUSD(inputTokens: Int) -> Double {
        0.01 + Double(inputTokens) * 1.00 / 1_000_000
    }

    // MARK: - A hosted endpoint is priced from the endpoint, not from the field

    func test_customEndpointRoute_isPricedFromTheEndpointURL_notTheConfigField() throws {
        let store = CustomEndpointStore.shared
        guard let ep = store.add(name: "Probe", baseURL: hostedProbeURL, apiKey: nil) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: ep.id) }

        AppState.shared.config.ollamaBaseURL = "http://localhost:11434"
        ModelRegistry.shared.setActiveProvider(.custom(ep.id))

        // Controls. Without these the assertion below could pass because the
        // route was never the endpoint in the first place.
        XCTAssertEqual(ModelRegistry.shared.resolvedProvider, .custom(ep.id))
        XCTAssertTrue(ModelRegistry.shared.offlineReady,
                      "offlineReady is what makes ChatService tag this turn \"local\"")
        XCTAssertEqual(ModelRegistry.shared.routedBaseURL(provider: nil), hostedProbeURL,
                       "the route's URL is the endpoint record's, not the Settings field's")

        let est = try publish(modelId: "deepseek/deepseek-chat", provider: "local")
        XCTAssertEqual(est.estimatedUSD ?? 0, hostedFloorUSD(inputTokens: est.inputTokens),
                       accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(est.estimatedUSD ?? 0, 0.01)
        XCTAssertFalse(est.label.contains("free"), "label was: \(est.label)")
    }

    // MARK: - The stale field does not buy a free turn

    func test_staleLocalhostConfigField_doesNotPriceAHostedRouteAsFree() throws {
        let store = CustomEndpointStore.shared
        guard let ep = store.add(name: "Probe", baseURL: hostedProbeURL, apiKey: nil) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: ep.id) }

        // Exactly the shipped state: Use was pressed on the hosted endpoint, then
        // the Base URL box was edited back to the local server. Nothing in the
        // app clears the selection when that box changes.
        let staleField = "http://localhost:11434"
        AppState.shared.config.ollamaBaseURL = staleField
        ModelRegistry.shared.setActiveProvider(.custom(ep.id))

        // The counterfactual, pinned so the regression is named rather than
        // implied: judged by the config field this turn reads free, and that is
        // the answer the composer used to print while the endpoint billed.
        XCTAssertEqual(CostMeter.rateSource(forProvider: "local", localBaseURL: staleField), .local)

        let est = try publish(modelId: "llama3.1", provider: "local")
        XCTAssertNotEqual(est.estimatedUSD, 0, "a billed hosted turn must not read $0")
        XCTAssertFalse(est.label.contains("free"), "label was: \(est.label)")
        // A local-looking model id on a hosted route takes the hosted floor, so
        // the number is the same one a namespaced aggregator id would produce.
        XCTAssertEqual(est.estimatedUSD ?? 0, hostedFloorUSD(inputTokens: est.inputTokens),
                       accuracy: 1e-9)
    }

    // MARK: - A genuinely local route is still free

    func test_loopbackRoute_isStillPricedFree() throws {
        let store = CustomEndpointStore.shared
        // A loopback server saved as an endpoint is how a resolved `.custom`
        // route reaches a genuinely free one. A plain `.local` selection cannot
        // be exercised here: with no server to discover, `resolvedProvider`
        // degrades it to `.anthropic`, so a free verdict would come from the
        // nil-URL branch rather than from the route, and would prove nothing.
        guard let ep = store.add(name: "Probe", baseURL: "http://127.0.0.1:59996", apiKey: nil) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: ep.id) }

        // The field points somewhere else entirely, to prove the free answer came
        // from the route rather than from the field agreeing by luck.
        AppState.shared.config.ollamaBaseURL = hostedProbeURL
        ModelRegistry.shared.setActiveProvider(.custom(ep.id))

        let est = try publish(modelId: "openai/gpt-4o", provider: "local")
        XCTAssertEqual(est.estimatedUSD, 0, "a loopback route bills nobody, whatever the id says")
        XCTAssertTrue(est.label.contains("free"), "label was: \(est.label)")
    }

    // MARK: - The inverse, which the fix must not introduce

    /// Reading the route's URL for every turn tagged "local" would be wrong in the
    /// other direction, because that tag stands for two different routes. A preset
    /// pinned "local" is built from `config.ollamaBaseURL` by `resolvedRouting`
    /// and never falls back, whatever the registry's own selection says. So with a
    /// hosted field and a loopback endpoint selected, the pinned turn is BILLED
    /// and a route-only reading would have called it free: the same $0 defect,
    /// entered from the other side.
    func test_aPresetPinnedLocal_isPricedFromTheFieldItActuallyRoutesThrough() throws {
        let store = CustomEndpointStore.shared
        guard let ep = store.add(name: "Probe", baseURL: "http://127.0.0.1:59995", apiKey: nil) else {
            return XCTFail("the probe endpoint did not save, so the rest of this proves nothing")
        }
        defer { store.remove(id: ep.id) }

        AppState.shared.config.ollamaBaseURL = hostedProbeURL
        ModelRegistry.shared.setActiveProvider(.custom(ep.id))

        XCTAssertEqual(ModelRegistry.shared.routedBaseURL(provider: "local"), hostedProbeURL,
                       "a \"local\" pin routes through the config field, so that is the URL to price")
        XCTAssertEqual(ModelRegistry.shared.routedBaseURL(provider: nil), "http://127.0.0.1:59995",
                       "with no pin the registry's own selection decides, and the two disagree here")
        XCTAssertNil(ModelRegistry.shared.routedBaseURL(provider: "anthropic"),
                     "an Anthropic route has no compat base URL and is never priced off one")

        let pinned = CostMeter.rateSource(
            forProvider: "local",
            localBaseURL: ModelRegistry.shared.routedBaseURL(provider: "local"))
        XCTAssertEqual(pinned, .hostedCompat(baseURL: hostedProbeURL))
        XCTAssertFalse(ModelRates.rates(forModelID: "llama3.1", source: pinned).isZero,
                       "the pinned turn is billed, so nothing on this path may price it at zero")
    }
}
