import XCTest
@testable import Grux

// Coverage for the webhook subsystem's pure decision logic plus the deliver
// loop with an injected sender, no network, no Keychain, no real store.
//
//   - signature(secret:body:)       , HMAC-SHA256 known-vector + format
//   - WebhookEnvelope.canonicalBody , deterministic sorted-keys encoding
//   - RetryPolicy                   , backoff schedule + retryable decision
//   - CircuitBreaker                , trip / reset / half-open transitions
//   - deliver(...)                  , attempt counting, retry-then-success,
//                                      hard-4xx short-circuit, no-secret
//                                      refusal, circuit-open skip
final class WebhookManagerTests: XCTestCase {

    // MARK: - Signing

    func test_signature_matchesKnownVector() {
        // python3: hmac.new(b"whsec_test_secret", b"hello grux", sha256)
        let sig = WebhookManager.signature(
            secret: "whsec_test_secret",
            body: Data("hello grux".utf8)
        )
        XCTAssertEqual(
            sig,
            "sha256=bf3e41784c6dc90207063f344ec3c9cba84d6a9b3a9634bcc3fa87b38bbfdce2"
        )
    }

    func test_signature_changesWithSecretAndBody() {
        let body = Data("payload".utf8)
        let a = WebhookManager.signature(secret: "one", body: body)
        let b = WebhookManager.signature(secret: "two", body: body)
        let c = WebhookManager.signature(secret: "one", body: Data("payload2".utf8))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.hasPrefix("sha256="))
        // sha256= + 64 hex chars
        XCTAssertEqual(a.count, 7 + 64)
    }

    func test_envelope_canonicalBody_isDeterministic() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let e1 = WebhookEnvelope(
            event: .agentJobCompleted,
            payload: ["jobId": "j1", "title": "Build site", "status": "done"],
            deliveryId: id,
            date: date
        )
        let e2 = WebhookEnvelope(
            event: .agentJobCompleted,
            payload: ["status": "done", "jobId": "j1", "title": "Build site"],
            deliveryId: id,
            date: date
        )
        let b1 = try e1.canonicalBody()
        let b2 = try e2.canonicalBody()
        XCTAssertEqual(b1, b2, "sorted-keys encoding must be insertion-order independent")
        // Signature over the canonical bytes is therefore stable too.
        XCTAssertEqual(
            WebhookManager.signature(secret: "s", body: b1),
            WebhookManager.signature(secret: "s", body: b2)
        )
    }

    // MARK: - Retry policy

    func test_retryPolicy_backoffSchedule() {
        let policy = WebhookManager.RetryPolicy()
        XCTAssertEqual(policy.delay(beforeAttempt: 1), 0, "first attempt is immediate")
        XCTAssertEqual(policy.delay(beforeAttempt: 2), 1.0)
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 2.0)
        XCTAssertEqual(policy.delay(beforeAttempt: 4), 4.0)
        XCTAssertNil(policy.delay(beforeAttempt: 5), "past maxAttempts means give up")
    }

    func test_retryPolicy_retryableStatuses() {
        XCTAssertTrue(WebhookManager.RetryPolicy.shouldRetry(statusCode: nil), "transport error retries")
        XCTAssertTrue(WebhookManager.RetryPolicy.shouldRetry(statusCode: 500))
        XCTAssertTrue(WebhookManager.RetryPolicy.shouldRetry(statusCode: 503))
        XCTAssertTrue(WebhookManager.RetryPolicy.shouldRetry(statusCode: 429))
        XCTAssertFalse(WebhookManager.RetryPolicy.shouldRetry(statusCode: 400))
        XCTAssertFalse(WebhookManager.RetryPolicy.shouldRetry(statusCode: 401))
        XCTAssertFalse(WebhookManager.RetryPolicy.shouldRetry(statusCode: 404))
        XCTAssertFalse(WebhookManager.RetryPolicy.shouldRetry(statusCode: 410))
    }

    // MARK: - Circuit breaker

    func test_circuitBreaker_tripsAtThreshold() {
        var c = WebhookManager.CircuitBreaker()
        let now = Date()
        for _ in 0..<(WebhookManager.CircuitBreaker.tripThreshold - 1) {
            c.recordFailure(now: now)
            XCTAssertTrue(c.allowAttempt(now: now), "below threshold stays closed")
        }
        c.recordFailure(now: now)
        XCTAssertFalse(c.allowAttempt(now: now), "threshold failure opens the circuit")
    }

    func test_circuitBreaker_successResets() {
        var c = WebhookManager.CircuitBreaker()
        let now = Date()
        for _ in 0..<WebhookManager.CircuitBreaker.tripThreshold {
            c.recordFailure(now: now)
        }
        XCTAssertFalse(c.allowAttempt(now: now))
        c.recordSuccess()
        XCTAssertTrue(c.allowAttempt(now: now))
        XCTAssertEqual(c.consecutiveFailures, 0)
    }

    func test_circuitBreaker_halfOpenAfterCooldown() {
        var c = WebhookManager.CircuitBreaker()
        let openTime = Date()
        for _ in 0..<WebhookManager.CircuitBreaker.tripThreshold {
            c.recordFailure(now: openTime)
        }
        let duringCooldown = openTime.addingTimeInterval(WebhookManager.CircuitBreaker.cooldown - 1)
        XCTAssertFalse(c.allowAttempt(now: duringCooldown))
        let afterCooldown = openTime.addingTimeInterval(WebhookManager.CircuitBreaker.cooldown + 1)
        XCTAssertTrue(c.allowAttempt(now: afterCooldown), "cooldown elapsed means half-open trial allowed")
    }

    func test_circuitBreaker_halfOpenAdmitsExactlyOneTrial() {
        var c = WebhookManager.CircuitBreaker()
        let openTime = Date()
        for _ in 0..<WebhookManager.CircuitBreaker.tripThreshold {
            c.recordFailure(now: openTime)
        }
        let afterCooldown = openTime.addingTimeInterval(WebhookManager.CircuitBreaker.cooldown + 1)
        XCTAssertTrue(c.admit(now: afterCooldown), "first caller claims the half-open trial slot")
        XCTAssertFalse(c.admit(now: afterCooldown), "concurrent callers are rejected while the trial is in flight")
        // A failed trial re-opens the clock: still gated afterwards.
        c.recordFailure(now: afterCooldown)
        XCTAssertFalse(c.admit(now: afterCooldown))
        // A successful trial closes the circuit fully.
        var c2 = WebhookManager.CircuitBreaker()
        for _ in 0..<WebhookManager.CircuitBreaker.tripThreshold {
            c2.recordFailure(now: openTime)
        }
        XCTAssertTrue(c2.admit(now: afterCooldown))
        c2.recordSuccess()
        XCTAssertTrue(c2.admit(now: afterCooldown))
        XCTAssertTrue(c2.admit(now: afterCooldown), "closed circuit admits everyone")
    }

    // Thundering herd: a burst of concurrent deliveries to a down endpoint
    // must not all pass admission before any failure lands. Once the in-flight
    // count plus observed failures reaches the trip threshold, the breaker
    // refuses the overflow, so at most `tripThreshold` of a burst hit the wire.
    func test_circuitBreaker_burstAdmissionCappedByInFlight() {
        var c = WebhookManager.CircuitBreaker()
        let now = Date()
        let threshold = WebhookManager.CircuitBreaker.tripThreshold
        // 20 concurrent admissions before any result is recorded.
        var admitted = 0
        for _ in 0..<20 where c.admit(now: now) { admitted += 1 }
        XCTAssertEqual(admitted, threshold,
                       "in-flight gate caps the herd at the trip threshold instead of admitting all 20")
        // Resolving the in-flight slots as failures opens the circuit.
        for _ in 0..<threshold { c.recordFailure(now: now) }
        XCTAssertFalse(c.allowAttempt(now: now), "the observed failures trip the breaker")
    }

    // MARK: - Deliver loop (injected sender, no network)

    // Scripted sender: pops the next status from the list; throws when the
    // scripted status is nil (simulates a transport error). Records every
    // request it sees so tests can assert headers + body.
    private actor ScriptedSender {
        private var script: [Int?]
        private(set) var requests: [URLRequest] = []

        init(_ script: [Int?]) { self.script = script }

        func next(_ request: URLRequest) throws -> (Int, Data) {
            requests.append(request)
            let status = script.isEmpty ? 500 : script.removeFirst()
            guard let status else {
                throw URLError(.cannotConnectToHost)
            }
            return (status, Data())
        }

        func callCount() -> Int { requests.count }
        func request(at idx: Int) -> URLRequest? {
            idx < requests.count ? requests[idx] : nil
        }
    }

    private func makeManager(script: [Int?]) -> (WebhookManager, ScriptedSender) {
        let scripted = ScriptedSender(script)
        let manager = WebhookManager(
            sender: { req in try await scripted.next(req) },
            sleeper: { _ in /* instant, no real backoff sleeps in tests */ },
            auditSink: { _ in /* drop, assertions use the returned record */ }
        )
        return (manager, scripted)
    }

    private func makeConfig() -> WebhookConfig {
        WebhookConfig(
            name: "Test endpoint",
            url: "https://example.com/hooks/grux",
            events: [.agentJobCompleted]
        )
    }

    func test_deliver_successFirstAttempt() async {
        let (manager, scripted) = makeManager(script: [200])
        let record = await manager.deliver(
            config: makeConfig(),
            secret: "whsec_test_secret",
            event: .agentJobCompleted,
            payload: ["jobId": "j1"]
        )
        XCTAssertEqual(record.outcome, .delivered)
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.statusCode, 200)
        let calls = await scripted.callCount()
        XCTAssertEqual(calls, 1)

        // Wire contract: signed, typed, event-tagged.
        let req = await scripted.request(at: 0)
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-Grux-Event"), "agent_job_completed")
        XCTAssertNotNil(req?.value(forHTTPHeaderField: "X-Grux-Delivery"))
        let sig = req?.value(forHTTPHeaderField: "X-Grux-Signature")
        XCTAssertTrue(sig?.hasPrefix("sha256=") == true)
        // Signature verifies against the exact body bytes that went out.
        if let body = req?.httpBody, let sig {
            XCTAssertEqual(WebhookManager.signature(secret: "whsec_test_secret", body: body), sig)
        } else {
            XCTFail("request missing body or signature")
        }
    }

    func test_deliver_retriesThenSucceeds() async {
        let (manager, scripted) = makeManager(script: [500, nil, 200])
        let record = await manager.deliver(
            config: makeConfig(),
            secret: "s",
            event: .agentJobCompleted,
            payload: [:]
        )
        XCTAssertEqual(record.outcome, .delivered)
        XCTAssertEqual(record.attempts, 3, "500 then transport error then 200 means 3 attempts")
        XCTAssertEqual(record.statusCode, 200)
        let calls = await scripted.callCount()
        XCTAssertEqual(calls, 3)
    }

    func test_deliver_exhaustsRetries() async {
        let (manager, scripted) = makeManager(script: [500, 500, 500, 500, 500])
        let record = await manager.deliver(
            config: makeConfig(),
            secret: "s",
            event: .agentJobCompleted,
            payload: [:]
        )
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.attempts, 4, "1 initial + 3 retries, then stop")
        XCTAssertEqual(record.statusCode, 500)
        let calls = await scripted.callCount()
        XCTAssertEqual(calls, 4, "must not exceed maxAttempts")
    }

    func test_deliver_hard4xxDoesNotRetry() async {
        let (manager, scripted) = makeManager(script: [404, 200])
        let record = await manager.deliver(
            config: makeConfig(),
            secret: "s",
            event: .agentJobCompleted,
            payload: [:]
        )
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.attempts, 1, "404 is non-retryable; the scripted 200 must never be reached")
        XCTAssertEqual(record.statusCode, 404)
        let calls = await scripted.callCount()
        XCTAssertEqual(calls, 1)
    }

    func test_deliver_refusesWithoutSecret() async {
        let (manager, scripted) = makeManager(script: [200])
        let record = await manager.deliver(
            config: makeConfig(),
            secret: "",
            event: .agentJobCompleted,
            payload: [:]
        )
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.attempts, 0, "unsigned payloads never go on the wire")
        let calls = await scripted.callCount()
        XCTAssertEqual(calls, 0)
    }

    func test_deliver_rejectsInvalidURL() async {
        let (manager, scripted) = makeManager(script: [200])
        var config = makeConfig()
        config.url = "not a url"
        let record = await manager.deliver(
            config: config,
            secret: "s",
            event: .agentJobCompleted,
            payload: [:]
        )
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.attempts, 0)
        let calls = await scripted.callCount()
        XCTAssertEqual(calls, 0)
    }

    func test_deliver_skipsWhenCircuitOpen() async {
        // 5 failed delivery groups trip the breaker (each group records one
        // circuit failure); group 6 must be skipped without touching the wire.
        let failingScript = Array(repeating: Optional<Int>(500), count: 4 * 5)
        let (manager, scripted) = makeManager(script: failingScript)
        let config = makeConfig()

        for _ in 0..<WebhookManager.CircuitBreaker.tripThreshold {
            let r = await manager.deliver(
                config: config, secret: "s",
                event: .agentJobCompleted, payload: [:]
            )
            XCTAssertEqual(r.outcome, .failed)
        }
        let callsAfterTrip = await scripted.callCount()
        XCTAssertEqual(callsAfterTrip, 20, "5 groups x 4 attempts")

        let skipped = await manager.deliver(
            config: config, secret: "s",
            event: .agentJobCompleted, payload: [:]
        )
        XCTAssertEqual(skipped.outcome, .skippedCircuitOpen)
        XCTAssertEqual(skipped.attempts, 0)
        let callsAfterSkip = await scripted.callCount()
        XCTAssertEqual(callsAfterSkip, 20, "open circuit means zero network calls")

        // Manual reset closes it again.
        await manager.resetCircuit(for: config.id)
        let state = await manager.circuitState(for: config.id)
        XCTAssertTrue(state.allowAttempt())
    }

    // MARK: - Store filtering (fan-out targets)

    @MainActor
    func test_store_targetsFilterByEventAndEnabled() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-webhook-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WebhookStore(
            configsURL: dir.appendingPathComponent("webhooks.json"),
            deliveriesURL: dir.appendingPathComponent("deliveries.json")
        )

        let subscribed = WebhookConfig(name: "a", url: "https://a.example.com", events: [.agentJobCompleted])
        let otherEvent = WebhookConfig(name: "b", url: "https://b.example.com", events: [.reminderFired])
        var disabled = WebhookConfig(name: "c", url: "https://c.example.com", events: [.agentJobCompleted])
        disabled.enabled = false

        store.upsert(subscribed)
        store.upsert(otherEvent)
        store.upsert(disabled)

        let targets = store.targets(for: .agentJobCompleted)
        XCTAssertEqual(targets.map { $0.id }, [subscribed.id])

        try? FileManager.default.removeItem(at: dir)
    }
}
