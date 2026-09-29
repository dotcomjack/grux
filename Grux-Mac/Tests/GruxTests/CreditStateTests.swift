import XCTest
import SwiftUI
import Combine
@testable import Grux

/// P-R-3: a credit running out is KNOWN from the provider's own response,
/// never guessed from a failure, and the person who was using it is told once.
///
/// Nothing here touches the Keychain, the network or the operator's state:
/// every monitor is built by the test with its own file (or none), every HTTP
/// answer comes from `CreditStubProtocol` on a session the test owns, and no
/// monitor here has a real `notify`, so no notification is ever posted.
@MainActor
final class CreditStateTests: XCTestCase {

    // MARK: - Fixtures, each from the provider's own documentation (2026-09-21)

    /// https://openrouter.ai/docs/api_reference/errors-and-debugging: the
    /// ErrorResponse shape, with the 402 sentence from the status table.
    private let openRouterOut = #"{"error":{"code":402,"message":"Your account or API key has insufficient credits. Add more credits and retry the request."}}"#
    /// https://openrouter.ai/docs/api_reference/limits: the key's own cap.
    private let openRouterKeyLimit = #"{"error":{"code":402,"message":"Key limit exceeded","metadata":{"limit_source":"openrouter_key_limit","remedy_hint":"Raise the key's credit limit."}}}"#
    /// Same page, verbatim example: transient, the balance is positive.
    private let openRouterInFlight = #"{"error":{"code":402,"message":"This request would exceed your available credits given your current in-flight requests. Retry after in-flight requests settle, or add credits.","metadata":{"reason":"in_flight_budget_exhausted","limit_source":"openrouter_in_flight_budget","remedy_hint":"Retry after your in-flight requests settle (see the Retry-After header). Adding credits at https://openrouter.ai/settings/credits raises your in-flight budget, up to a capped ceiling."}}}"#
    /// Same page: one request too big for a positive balance.
    private let openRouterTooBig = #"{"error":{"code":402,"message":"Request too expensive","metadata":{"reason":"weight_exceeds_budget","limit_source":"openrouter_credits"}}}"#
    /// Same page, verbatim 429 example.
    private let openRouterRateLimited = #"{"error":{"code":429,"message":"Rate limit exceeded","metadata":{"error_type":"rate_limit_exceeded"}}}"#
    private let openRouterBadKey = #"{"error":{"code":401,"message":"No auth credentials found"}}"#

    /// https://elevenlabs.io/docs/eleven-api/resources/errors: type
    /// payment_required, code insufficient_credits, HTTP 402.
    private let elevenOut = #"{"detail":{"type":"payment_required","code":"insufficient_credits","message":"Your account does not have enough credits for this operation.","request_id":"3c807fc4c3a1705f9638ecc764a91c01"}}"#
    /// https://elevenlabs.io/docs/help-center/technical/api-error-code-400-or-401
    private let elevenQuota = #"{"detail":{"status":"quota_exceeded","message":"You have insufficient quota to complete the request."}}"#
    private let elevenBadKey = #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#
    private let elevenBadKeyTyped = #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"The provided API key is invalid."}}"#
    private let elevenRateLimited = #"{"detail":{"type":"rate_limit_error","code":"rate_limit_exceeded","message":"Too many requests."}}"#

    /// Anthropic's empty balance, as this install received it on 2026-08-23
    /// and again in the week before 2026-09-21: a 400 of the same type as a malformed request,
    /// told apart only by its sentence. Envelope per
    /// https://platform.claude.com/docs/en/api/errors ("Error shapes").
    private let anthropicOut = #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fy"}"#
    /// Same page: a genuinely malformed request, the same status and type.
    private let anthropicBadRequest = #"{"type":"error","error":{"type":"invalid_request_error","message":"This model does not support assistant message prefill. The conversation must end with a user message."}}"#
    /// Same page: 402 billing_error, "an issue with your billing or payment
    /// information". A card problem is not an empty balance.
    private let anthropicBilling = #"{"type":"error","error":{"type":"billing_error","message":"There's an issue with your billing or payment information."}}"#
    private let anthropicRateLimited = #"{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}"#
    private let anthropicBadKey = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
    private let anthropicOverloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#

    /// What an undocumented provider MIGHT send. Plausible is not known.
    private let plausibleButUndocumented = #"{"error":"Insufficient credits","status":402}"#

    /// Bodies that are not a documented anything.
    private let malformed = ["", "<html><body>502 Bad Gateway</body></html>", #"{"error":"#, "[]",
                             #"{"error":"insufficient credits"}"#, #"{"detail":"quota_exceeded"}"#]

    private var files: [URL] = []

    override func tearDown() {
        for f in files { try? FileManager.default.removeItem(at: f) }
        files = []
        CreditStubProtocol.reply = .http(200, "{}")
        super.tearDown()
    }

    private func tempFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("credits-\(UUID().uuidString).json")
        files.append(url)
        return url
    }

    /// A monitor that records what it would have told the person.
    private func monitor(storeURL: URL? = nil,
                         detector: @escaping (CreditProvider, Int, Data) -> Bool = CreditSignature.isExhausted)
        -> (CreditMonitor, Box) {
        let m = CreditMonitor(storeURL: storeURL, isExhaustedResponse: detector)
        let told = Box()
        m.notify = { told.notices.append($0) }
        return (m, told)
    }

    final class Box { var notices: [CreditNotice] = [] }

    private func d(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - The detectors: we must KNOW

    func test_eachDocumentedOutOfCreditResponseIsRecognised() {
        XCTAssertTrue(CreditSignature.openRouter(status: 402, body: d(openRouterOut)))
        XCTAssertTrue(CreditSignature.openRouter(status: 402, body: d(openRouterKeyLimit)))
        XCTAssertTrue(CreditSignature.elevenLabs(status: 402, body: d(elevenOut)))
        XCTAssertTrue(CreditSignature.elevenLabs(status: 401, body: d(elevenQuota)))
        XCTAssertTrue(CreditSignature.elevenLabs(status: 400, body: d(elevenQuota)))
        XCTAssertTrue(CreditSignature.anthropic(status: 400, body: d(anthropicOut)))
    }

    /// Anthropic sends an empty balance as a 400 invalid_request_error, the
    /// status and type every malformed request also gets, so only its own
    /// sentence decides. The same sentence anywhere else is not that response.
    func test_anthropicKnowsAnEmptyBalanceOnlyFromItsOwnSentence() {
        XCTAssertFalse(CreditSignature.anthropic(status: 400, body: d(anthropicBadRequest)), "a malformed request read as out of credit")
        XCTAssertFalse(CreditSignature.anthropic(status: 402, body: d(anthropicBilling)), "a billing problem read as an empty balance")
        XCTAssertFalse(CreditSignature.anthropic(status: 429, body: d(anthropicRateLimited)))
        XCTAssertFalse(CreditSignature.anthropic(status: 401, body: d(anthropicBadKey)))
        XCTAssertFalse(CreditSignature.anthropic(status: 529, body: d(anthropicOverloaded)))
        for status in [200, 401, 402, 429, 500, 529] {
            XCTAssertFalse(CreditSignature.anthropic(status: status, body: d(anthropicOut)),
                           "the credit sentence at HTTP \(status) is not the documented response")
        }
        // Not the envelope: the sentence as bare text, or under another type.
        XCTAssertFalse(CreditSignature.anthropic(status: 400, body: d("Your credit balance is too low to access the Anthropic API.")))
        XCTAssertFalse(CreditSignature.anthropic(status: 400, body: d(anthropicOut.replacingOccurrences(of: "invalid_request_error", with: "api_error"))))
        // Grux's own stand-down refusal travels the same paths as a provider
        // body and must never read back as a fresh exhaustion.
        XCTAssertFalse(CreditSignature.anthropic(status: 400, body: d(ProviderHealth.standDownMessage)))
        // Every other provider's out of credit body is not Anthropic's.
        for body in [openRouterOut, elevenOut, elevenQuota, plausibleButUndocumented] {
            for status in [400, 402] {
                XCTAssertFalse(CreditSignature.anthropic(status: status, body: d(body)))
            }
        }
    }

    /// The rule the operator set: a 500, a 401 bad key, a 429 rate limit and a
    /// body that is not the documented one never say the credit is out, for
    /// any provider. (A timeout has no response at all; it is proven at the
    /// provider below.)
    func test_aServerErrorABadKeyARateLimitOrAMalformedBodyNeverMeansOutOfCredit() {
        for p in CreditProvider.allCases {
            XCTAssertFalse(CreditSignature.isExhausted(p, status: 500, body: d(#"{"error":{"code":500,"message":"Internal"}}"#)), "\(p) read a 500 as out of credit")
            XCTAssertFalse(CreditSignature.isExhausted(p, status: 503, body: d("")), "\(p) read a 503 as out of credit")
            XCTAssertFalse(CreditSignature.isExhausted(p, status: 401, body: d(openRouterBadKey)), "\(p) read a bad key as out of credit")
            XCTAssertFalse(CreditSignature.isExhausted(p, status: 401, body: d(elevenBadKey)), "\(p) read a bad key as out of credit")
            XCTAssertFalse(CreditSignature.isExhausted(p, status: 401, body: d(elevenBadKeyTyped)), "\(p) read a bad key as out of credit")
            XCTAssertFalse(CreditSignature.isExhausted(p, status: 429, body: d(openRouterRateLimited)), "\(p) read a rate limit as out of credit")
            XCTAssertFalse(CreditSignature.isExhausted(p, status: 429, body: d(elevenRateLimited)), "\(p) read a rate limit as out of credit")
            for body in malformed {
                for status in [400, 401, 402] {
                    XCTAssertFalse(CreditSignature.isExhausted(p, status: status, body: d(body)),
                                   "\(p) read HTTP \(status) with a malformed body \(body.prefix(30)) as out of credit")
                }
            }
        }
        // The right body at the wrong status is not the documented response.
        XCTAssertFalse(CreditSignature.openRouter(status: 200, body: d(openRouterOut)))
        XCTAssertFalse(CreditSignature.openRouter(status: 400, body: d(openRouterOut)))
        XCTAssertFalse(CreditSignature.elevenLabs(status: 500, body: d(elevenOut)))
        XCTAssertFalse(CreditSignature.elevenLabs(status: 429, body: d(elevenQuota)))
    }

    /// OpenRouter's own docs split the 402: two of its cases are a positive
    /// balance, and telling that person to refill would be a lie.
    func test_openRouterTransientOrTooLargeRequestIsNotAnEmptyBalance() {
        XCTAssertFalse(CreditSignature.openRouter(status: 402, body: d(openRouterInFlight)))
        XCTAssertFalse(CreditSignature.openRouter(status: 402, body: d(openRouterTooBig)))
    }

    /// Jev and Replicate document no out of credit response, so even a
    /// perfectly plausible one is not known, and their detectors stay off.
    func test_undocumentedProvidersNeverClaimToKnow() {
        for body in [plausibleButUndocumented, openRouterOut, elevenOut] {
            XCTAssertFalse(CreditSignature.jev(status: 402, body: d(body)))
            XCTAssertFalse(CreditSignature.replicate(status: 402, body: d(body)))
        }
    }

    // MARK: - The episode

    func test_noNoticeWithoutAPriorSuccess() {
        let (m, told) = monitor()
        XCTAssertTrue(m.recordFailure(.openRouter, status: 402, body: d(openRouterOut)))
        XCTAssertTrue(m.state(.openRouter).isExhausted, "the exhaustion itself is still known")
        XCTAssertTrue(told.notices.isEmpty, "a key that never worked here told the person it ran out")
        XCTAssertNil(m.statusLine, "a key that never worked here put a line on the Usage card")
    }

    func test_exactlyOneNoticePerEpisode_andASuccessEndsIt() {
        let (m, told) = monitor()
        m.recordSuccess(.elevenLabs)
        for _ in 0..<5 { m.recordFailure(.elevenLabs, status: 402, body: d(elevenOut)) }
        m.recordFailure(.elevenLabs, status: 401, body: d(elevenQuota))
        XCTAssertEqual(told.notices, [CreditNotice.for(.elevenLabs)], "one episode, one notice")

        m.recordSuccess(.elevenLabs)
        XCTAssertFalse(m.state(.elevenLabs).isExhausted, "a success did not end the episode")
        XCTAssertNil(m.statusLine)

        m.recordFailure(.elevenLabs, status: 402, body: d(elevenOut))
        XCTAssertEqual(told.notices.count, 2, "a new episode after a refill was not told")
    }

    /// The "we must know" rule at the monitor: a key in use that fails every
    /// other way stays exactly as it was.
    func test_otherFailuresChangeNothingAndTellNobody() {
        let (m, told) = monitor()
        m.recordSuccess(.openRouter)
        let before = m.states
        var failures: [(Int, String)] = [(500, #"{"error":{"code":500,"message":"x"}}"#), (401, openRouterBadKey),
                                         (429, openRouterRateLimited), (402, openRouterInFlight), (402, openRouterTooBig)]
        failures += malformed.map { (402, $0) }
        for (status, body) in failures {
            XCTAssertFalse(m.recordFailure(.openRouter, status: status, body: d(body)), "HTTP \(status) \(body.prefix(30))")
        }
        XCTAssertEqual(m.states, before)
        XCTAssertTrue(told.notices.isEmpty)
        XCTAssertNil(m.statusLine)
    }

    /// Each provider has its own episode: one running out tells nothing about
    /// another, and the card names only the one that is out.
    func test_providersAreIndependent() {
        let (m, told) = monitor()
        m.recordSuccess(.openRouter)
        m.recordSuccess(.elevenLabs)
        m.recordFailure(.openRouter, status: 402, body: d(openRouterOut))
        XCTAssertEqual(told.notices.map(\.provider), [.openRouter])
        XCTAssertEqual(m.statusLine, CreditNotice.for(.openRouter).statusLine)
        XCTAssertFalse(m.state(.elevenLabs).isExhausted)
    }

    /// Told stays told across a relaunch, and the card still says so.
    func test_theEpisodeSurvivesARelaunch() {
        let file = tempFile()
        let (first, toldFirst) = monitor(storeURL: file)
        first.recordSuccess(.openRouter)
        first.recordFailure(.openRouter, status: 402, body: d(openRouterOut))
        XCTAssertEqual(toldFirst.notices.count, 1)

        let (second, toldSecond) = monitor(storeURL: file)
        XCTAssertEqual(second.state(.openRouter), first.state(.openRouter))
        XCTAssertNotNil(second.statusLine, "the card forgot the outage on relaunch")
        second.recordFailure(.openRouter, status: 402, body: d(openRouterOut))
        XCTAssertTrue(toldSecond.notices.isEmpty, "a relaunch told the person a second time")

        second.recordSuccess(.openRouter)
        let (third, _) = monitor(storeURL: file)
        XCTAssertFalse(third.state(.openRouter).isExhausted)
        XCTAssertTrue(third.state(.openRouter).hasSucceeded)
    }

    /// Every Jev decision reports a success, so a healthy key must cost
    /// nothing after its first one: no publish (which would redraw the card)
    /// and no write.
    func test_aSuccessOnAHealthyKeyPublishesAndWritesNothing() throws {
        let file = tempFile()
        let (m, _) = monitor(storeURL: file)
        var publishes = 0
        let sub = m.$states.dropFirst().sink { _ in publishes += 1 }
        m.recordSuccess(.jev)
        XCTAssertEqual(publishes, 1)
        let written = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        for _ in 0..<50 { m.recordSuccess(.jev) }
        XCTAssertEqual(publishes, 1, "a success on a healthy key published a change")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a success on a healthy key rewrote the file")
        XCTAssertFalse(written.isEmpty)
        sub.cancel()
    }

    // MARK: - The Usage card's one status line

    func test_theUsageCardLineAppearsWhenACreditRunsOutAndGoesAwayOnRecovery() {
        let (m, _) = monitor()
        let usage = DecisionUsageModel(ledger: DecisionLedger(storeURL: nil))
        XCTAssertNil(UsageCard(usage: usage, credits: m).statusLine, "a fresh install has a status line")

        m.recordSuccess(.openRouter)
        XCTAssertNil(UsageCard(usage: usage, credits: m).statusLine)

        m.recordFailure(.openRouter, status: 402, body: d(openRouterOut))
        let line = CreditNotice.for(.openRouter).statusLine
        XCTAssertEqual(UsageCard(usage: usage, credits: m).statusLine, line)
        // Rendered, not only computed: the card grows by exactly the one row.
        let quiet = height(UsageCard(usage: usage, credits: CreditMonitor(storeURL: nil)))
        let out = height(UsageCard(usage: usage, credits: m))
        XCTAssertEqual(out - quiet, height(UsageCard.statusRow(line)), accuracy: 0.5,
                       "the card did not render the credit line in its status slot")

        m.recordSuccess(.openRouter)
        XCTAssertNil(UsageCard(usage: usage, credits: m).statusLine, "the line stayed after the refill")
        XCTAssertEqual(height(UsageCard(usage: usage, credits: m)), quiet, accuracy: 0.5)
    }

    /// The copy: blunt, what got worse, where to refill, and none of the
    /// characters the house bans.
    func test_theCopyNamesWhatGotWorseAndWhereToRefill() {
        let refill = [CreditProvider.jev: "https://console.typesafe.ai",
                      .openRouter: "https://openrouter.ai/settings/credits",
                      .elevenLabs: "https://elevenlabs.io/app/subscription",
                      .replicate: "https://replicate.com/account/billing",
                      .anthropic: "https://platform.claude.com/settings/billing"]
        for p in CreditProvider.allCases {
            let n = CreditNotice.for(p)
            XCTAssertEqual(n.provider, p)
            XCTAssertTrue(n.title.hasSuffix("is out of credit"), n.title)
            XCTAssertTrue(n.body.contains(refill[p]!), "\(p) does not say where to refill")
            for banned in ["\u{2014}", "\u{2013}"] {
                XCTAssertFalse(n.title.contains(banned) || n.body.contains(banned), "\(p) copy has a dash character")
            }
        }
        let anthropic = CreditNotice.for(.anthropic).body
        for worse in ["chat when it runs on a Claude model", "focus checks", "Compare", "Design Studio"] {
            XCTAssertTrue(anthropic.contains(worse), "the Anthropic notice does not say that \(worse) stopped")
        }
        let jev = CreditNotice.for(.jev).body
        for worse in ["exact phrases", "room talk", "mail", "notifications"] {
            XCTAssertTrue(jev.contains(worse), "the Jev notice does not say that \(worse) got worse")
        }
    }

    // MARK: - Wired into the providers, end to end

    /// Jev: the provider reads every answered response, a success is a
    /// decision that parsed, and the engine still falls through to this Mac.
    func test_jevReportsSuccessesAndFailuresButNeverAGuess() async {
        let (m, told) = monitor()
        let provider = JevDecisionProvider(apiKey: "k", session: CreditStubProtocol.session(), credits: m)
        let q: [String: DecisionQuestion] = ["q": .noul(instructions: "?")]

        // A 2xx that is not a decision is not a success on the key.
        CreditStubProtocol.reply = .http(200, "not json")
        _ = try? await provider.decide(state: "x", questions: q)
        XCTAssertFalse(m.state(.jev).hasSucceeded, "a malformed 2xx counted as a success")

        CreditStubProtocol.reply = .http(200, #"{"model":"jev-1.13.0","answers":{}}"#)
        let decided = try? await provider.decide(state: "x", questions: q)
        XCTAssertNotNil(decided, "the stubbed call did not succeed")
        XCTAssertTrue(m.state(.jev).hasSucceeded)

        for reply: CreditStubProtocol.Reply in [.http(500, "{}"), .http(401, #"{"detail":"Invalid API key"}"#),
                                                 .http(429, "{}"), .http(402, plausibleButUndocumented),
                                                 .http(200, "not json"), .fail(.timedOut)] {
            CreditStubProtocol.reply = reply
            _ = try? await provider.decide(state: "x", questions: q)
            XCTAssertFalse(m.state(.jev).isExhausted, "Jev marked out of credit on \(reply)")
        }
        XCTAssertTrue(told.notices.isEmpty)
        XCTAssertNil(m.statusLine)
    }

    /// The day Jev's shape is known, the detector is the whole change: a
    /// monitor armed with a detector proves every other piece is wired, and
    /// that the engine keeps working on this Mac through the outage.
    func test_jevWiringTellsOnceAndFallsThroughWhenTheShapeIsKnown() async {
        let (m, told) = monitor(detector: { p, status, _ in p == .jev && status == 402 })
        let session = CreditStubProtocol.session()
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil),
                                    remote: { JevDecisionProvider(apiKey: $0, session: session, credits: m) })
        let q: [String: DecisionQuestion] = ["intent": .choice(instructions: "?", criteria: ["close_all": "close everything",
                                                                                               "not_a_command": "chatter"])]
        CreditStubProtocol.reply = .http(200, #"{"answers":{"intent":{"type":"choice","choice":"close_all","confidence":0.9}}}"#)
        let first = await engine.decide(surface: "t", state: "close everything", questions: q)
        XCTAssertEqual(first.provider, .jev)

        CreditStubProtocol.reply = .http(402, "{}")
        for _ in 0..<3 {
            let r = await engine.decide(surface: "t", state: "close everything", questions: q)
            XCTAssertEqual(r.provider, .local, "Grux stopped deciding when the credit ran out")
        }
        XCTAssertEqual(told.notices, [CreditNotice.for(.jev)])
        XCTAssertEqual(m.statusLine, CreditNotice.for(.jev).statusLine)
    }

    /// A keyless install never calls the provider, so it can never be told.
    func test_aKeylessInstallSeesNothing() async {
        let (m, told) = monitor(detector: { _, _, _ in true })
        let session = CreditStubProtocol.session()
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil),
                                    remote: { JevDecisionProvider(apiKey: $0, session: session, credits: m) })
        CreditStubProtocol.reply = .http(402, "{}")
        _ = await engine.decide(surface: "t", state: "x", questions: ["q": .noul(instructions: "?")])
        XCTAssertTrue(m.states.isEmpty)
        XCTAssertTrue(told.notices.isEmpty)
        XCTAssertNil(m.statusLine)
    }

    /// OpenRouter through the real chat backend: its documented 402 is known
    /// and told once after a success; a local server's identical 402 is not
    /// OpenRouter and reports nothing.
    func test_openRouterChatBackendKnowsItsOwnOutOfCredit() async {
        let (m, told) = monitor()
        let session = CreditStubProtocol.session()
        let openRouter = OpenAICompatBackend(baseURL: "https://openrouter.ai/api", session: session, credits: m)
        let msgs = [ClaudeMessage(role: "user", content: "hi")]

        CreditStubProtocol.reply = .http(200, #"{"choices":[{"message":{"content":"hello"}}]}"#)
        let reply = try? await openRouter.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
        XCTAssertEqual(reply, "hello")
        XCTAssertTrue(m.state(.openRouter).hasSucceeded)

        for (status, body) in [(500, "{}"), (401, openRouterBadKey), (429, openRouterRateLimited), (402, openRouterInFlight), (402, "<html>")] {
            CreditStubProtocol.reply = .http(status, body)
            _ = try? await openRouter.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
        }
        CreditStubProtocol.reply = .fail(.timedOut)
        _ = try? await openRouter.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
        XCTAssertFalse(m.state(.openRouter).isExhausted, "a non-credit failure marked OpenRouter out")
        XCTAssertTrue(told.notices.isEmpty)

        CreditStubProtocol.reply = .http(402, openRouterOut)
        for _ in 0..<2 {
            do {
                _ = try await openRouter.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
                XCTFail("a 402 answered")
            } catch ClaudeError.http(let code, _) {
                XCTAssertEqual(code, 402, "the chat path's own error changed")
            } catch {
                XCTFail("the chat path's own error changed: \(error)")
            }
        }
        XCTAssertEqual(told.notices, [CreditNotice.for(.openRouter)])

        let (localMonitor, localTold) = monitor()
        let local = OpenAICompatBackend(baseURL: "http://localhost:11434", session: session, credits: localMonitor)
        _ = try? await local.complete(apiKey: "ollama", model: "m", system: nil, messages: msgs)
        XCTAssertTrue(localMonitor.states.isEmpty, "a local server was treated as a credit")
        XCTAssertTrue(localTold.notices.isEmpty)
    }

    /// Anthropic through the real Claude client, on every path that spends
    /// the credit: the plain, cached, vision and tool calls and the chat
    /// stream. A success is the key working; only the empty-balance 400 marks
    /// it out, once; every other failure, and a timeout, marks nothing.
    func test_anthropicClientKnowsItsOwnOutOfCredit() async throws {
        defer { ProviderHealth.shared.resetForTesting() }
        let (m, told) = monitor()
        let claude = ClaudeClient(session: CreditStubProtocol.session(), credits: m)
        let msgs = [ClaudeMessage(role: "user", content: "hi")]
        let ok = #"{"content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":3,"output_tokens":1}}"#

        CreditStubProtocol.reply = .http(200, ok)
        let reply = try? await claude.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
        XCTAssertEqual(reply, "hello")
        XCTAssertTrue(m.state(.anthropic).hasSucceeded, "a Claude success was not reported")

        for (status, body) in [(500, #"{"type":"error","error":{"type":"api_error","message":"Internal"}}"#),
                               (400, anthropicBadRequest), (402, anthropicBilling), (401, anthropicBadKey),
                               (429, anthropicRateLimited), (529, anthropicOverloaded), (400, "<html>")] {
            CreditStubProtocol.reply = .http(status, body)
            _ = try? await claude.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
        }
        CreditStubProtocol.reply = .fail(.timedOut)
        _ = try? await claude.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
        XCTAssertFalse(m.state(.anthropic).isExhausted, "a non-credit failure marked Anthropic out")
        XCTAssertTrue(told.notices.isEmpty)

        CreditStubProtocol.reply = .http(400, anthropicOut)
        do {
            _ = try await claude.complete(apiKey: "k", model: "m", system: nil, messages: msgs)
            XCTFail("an empty balance answered")
        } catch ClaudeError.http(let code, _) {
            XCTAssertEqual(code, 400, "the client's own error changed")
        } catch {
            XCTFail("the client's own error changed: \(error)")
        }
        _ = try? await claude.completeCached(apiKey: "k", model: "m", cachedSystem: "s", tailSystem: nil, messages: msgs)
        _ = try? await claude.completeWithTools(apiKey: "k", model: "m", system: nil, messages: [["role": "user", "content": "hi"]], tools: [])
        XCTAssertTrue(m.state(.anthropic).isExhausted, "the empty-balance 400 was not known")
        XCTAssertEqual(told.notices, [CreditNotice.for(.anthropic)], "one episode, one notice")
        XCTAssertEqual(m.statusLine, CreditNotice.for(.anthropic).statusLine)

        // The chat stream is how a person usually meets it, and a stream that
        // opens is the success that ends the episode.
        CreditStubProtocol.reply = .http(200, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        for try await _ in await claude.streamCompleteWithTools(apiKey: "k", model: "m", systemBlocks: [], messages: [], tools: []) {}
        XCTAssertFalse(m.state(.anthropic).isExhausted, "an opened chat stream did not end the episode")

        CreditStubProtocol.reply = .http(400, anthropicOut)
        do {
            for try await _ in await claude.streamCompleteWithTools(apiKey: "k", model: "m", systemBlocks: [], messages: [], tools: []) {}
        } catch {}
        XCTAssertTrue(m.state(.anthropic).isExhausted, "the chat stream's empty-balance 400 was not known")
        XCTAssertEqual(told.notices.count, 2, "a new episode after a success was not told")
    }

    /// Every place the Claude client reads a failed status feeds the credit,
    /// so a sixth path added later cannot quietly skip it.
    func test_everyClaudeFailureReportsItsCredit() throws {
        let claude = try source("Sources/Grux/Claude.swift")
        let failures = claude.components(separatedBy: "ProviderHealth.shared.record(failureBody:").dropFirst()
        XCTAssertEqual(failures.count, 5)
        for (i, after) in failures.enumerated() {
            XCTAssertTrue(after.prefix(260).contains("noteCredit("), "Claude failure path \(i + 1) does not report its credit")
        }
    }

    /// ElevenLabs and Replicate report from inside code a test cannot drive
    /// without a real key, so their wiring is held at the source: both speech
    /// calls (the ones that spend credit) report and the voices list does not;
    /// the Replicate submit reports.
    func test_speechAndMediaReportTheCallsThatSpendCredit() throws {
        let speech = try source("Sources/Grux/SpeechEngine.swift")
        let voices = try XCTUnwrap(speech.range(of: "func fetchVoices"))
        XCTAssertEqual(speech.components(separatedBy: "noteCredit(resp, data)").count - 1, 1,
                       "the streamed speech call does not report its credit")
        XCTAssertEqual(speech.components(separatedBy: "noteCredit(response, data)").count - 1, 1,
                       "the one-shot speech call does not report its credit")
        XCTAssertFalse(speech[voices.lowerBound...].prefix(1_200).contains("noteCredit"),
                       "the voices list reports, and its free 200 would end an episode")

        let replicate = try source("Sources/Grux/Creative/ReplicateClient.swift")
        XCTAssertTrue(replicate.contains("CreditMonitor.observe(.replicate, status: http.statusCode, body: submitData)"),
                      "the Replicate submit does not report its credit")
    }

    // MARK: - Helpers

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) { view }
            .frame(width: 520, alignment: .leading))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 800)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}

/// Answers every request on a session the test owns, so no call leaves the
/// process. Set on `configuration.protocolClasses`, never registered globally.
final class CreditStubProtocol: URLProtocol {
    enum Reply: CustomStringConvertible {
        case http(Int, String)
        case fail(URLError.Code)
        var description: String {
            switch self {
            case .http(let s, let b): return "HTTP \(s) \(b.prefix(40))"
            case .fail(let c): return "transport failure \(c.rawValue)"
            }
        }
    }

    private static let lock = NSLock()
    private static var _reply: Reply = .http(200, "{}")
    static var reply: Reply {
        get { lock.lock(); defer { lock.unlock() }; return _reply }
        set { lock.lock(); _reply = newValue; lock.unlock() }
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CreditStubProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.reply {
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
