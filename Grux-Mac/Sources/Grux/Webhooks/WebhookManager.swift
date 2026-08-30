import Foundation
import CryptoKit

// Outbound webhook dispatcher. Mirrors the CommandV2PhaseNotifier pattern:
// subscribe to the app's existing NotificationCenter seams, translate each
// event into a signed JSON envelope, and fan it out to every registered +
// enabled endpoint whose filter matches.
//
// Event sources:
//   - .gruxCommandV2PhaseTransitioned  (CommandV2Engine, already posted)
//   - .gruxCommandV2RunFinished        (CommandV2Engine, already posted)
//   - .gruxAgentJobLifecycle           (new seam; AgentService posts on
//                                       status transitions, see the
//                                       integration hook in _bridgeJobUpdate)
//   - .gruxReminderFired               (new seam; GruxReminderState.fire posts)
//
// Wire contract per delivery:
//   POST <config.url>
//   Content-Type: application/json
//   X-Grux-Event: <event raw value>
//   X-Grux-Delivery: <UUID>
//   X-Grux-Signature: sha256=<hex HMAC-SHA256(secret, raw body)>
//   body: WebhookEnvelope.canonicalBody() (sorted-keys JSON)
//
// Reliability: per-delivery retry with exponential backoff (1s, 2s, 4s, 3
// retries after the initial attempt), plus a per-endpoint circuit breaker
// (5 consecutive failed deliveries opens the circuit for 5 minutes;
// half-open lets one trial through after cooldown). Every delivery group is
// recorded to WebhookStore's audit log for the Webhooks view.
//
// Security: payloads carry only identifiers + display names (jobId, title,
// phaseName, status), never prompts, ASC feedback text, file paths, or any
// run state. Same posture as NotificationManager's banner copy.
//
// OUTBOUND ONLY (deliberate): inbound triggers ("POST to Grux to start a
// job") are deferred. Accepting inbound HTTP requires exposing a listener
// through a tunnel; doing that safely needs an auth + replay-protection +
// rate-limit design pass that hasn't happened. Until it does, the surface
// stays closed.
actor WebhookManager {
    static let shared = WebhookManager()

    // Injectable network seam so tests never touch the wire. Returns the
    // HTTP status code and response body.
    typealias Sender = @Sendable (URLRequest) async throws -> (statusCode: Int, body: Data)
    // Injectable sleep so backoff tests run instantly.
    typealias Sleeper = @Sendable (TimeInterval) async -> Void
    // Injectable audit sink; default appends to WebhookStore on the main actor.
    typealias AuditSink = @Sendable (WebhookDelivery) async -> Void

    // MARK: - Retry policy (pure, unit-testable)

    struct RetryPolicy: Sendable {
        // 1 initial attempt + 3 retries.
        var maxAttempts: Int = 4
        var baseDelay: TimeInterval = 1.0

        // Delay to sleep BEFORE the given 1-based attempt number. Attempt 1
        // is immediate; attempts 2/3/4 wait 1s/2s/4s. Past maxAttempts: nil
        // (give up).
        func delay(beforeAttempt attempt: Int) -> TimeInterval? {
            guard attempt >= 2, attempt <= maxAttempts else {
                return attempt == 1 ? 0 : nil
            }
            return baseDelay * pow(2.0, Double(attempt - 2))
        }

        // Retry on transport errors (nil status), 5xx, and 429. Other 4xx
        // mean the request itself is wrong (bad URL path, auth rejected),
        // and retrying the same bytes can't fix that.
        static func shouldRetry(statusCode: Int?) -> Bool {
            guard let code = statusCode else { return true }
            if code >= 500 { return true }
            if code == 429 { return true }
            return false
        }

        static func isSuccess(statusCode: Int) -> Bool {
            (200...299).contains(statusCode)
        }
    }

    // MARK: - Circuit breaker (pure value, per endpoint)

    struct CircuitBreaker: Sendable {
        static let tripThreshold = 5
        static let cooldown: TimeInterval = 300

        var consecutiveFailures: Int = 0
        var openedAt: Date? = nil
        // True while the single half-open trial delivery is in flight, so a
        // burst of queued deliveries cannot all blast a recovering endpoint.
        var halfOpenTrialInFlight: Bool = false
        // Deliveries admitted but not yet resolved. Counted toward the trip
        // decision so a concurrent burst to a down endpoint cannot all pass
        // admission before any of them records a failure (the thundering-herd
        // gap): once consecutiveFailures + inFlight reaches the threshold,
        // further admissions are refused until results come back.
        var inFlight: Int = 0

        // Open means "skip deliveries to this endpoint". After cooldown the
        // circuit goes half-open: admit() lets ONE trial through; a success
        // closes it, a failure re-opens the clock. allowAttempt is the
        // non-mutating read (UI badge, tests).
        func allowAttempt(now: Date = Date()) -> Bool {
            guard let openedAt else { return true }
            return now.timeIntervalSince(openedAt) >= Self.cooldown
        }

        // Mutating admission: claims the half-open trial slot when the
        // circuit is open and the cooldown has elapsed, OR a soft in-flight
        // slot while the circuit is closed. The in-flight gate is what stops
        // a concurrent burst from all blasting a down endpoint before the
        // first failure lands.
        mutating func admit(now: Date = Date()) -> Bool {
            guard openedAt != nil else {
                // Closed: admit only while observed failures plus deliveries
                // already in flight stay under the trip threshold. A burst
                // larger than the threshold has its overflow refused, so the
                // breaker can observe the failures it needs to trip.
                guard consecutiveFailures + inFlight < Self.tripThreshold else { return false }
                inFlight += 1
                return true
            }
            guard allowAttempt(now: now) else { return false }
            guard !halfOpenTrialInFlight else { return false }
            halfOpenTrialInFlight = true
            inFlight += 1
            return true
        }

        mutating func recordSuccess() {
            consecutiveFailures = 0
            openedAt = nil
            halfOpenTrialInFlight = false
            if inFlight > 0 { inFlight -= 1 }
        }

        mutating func recordFailure(now: Date = Date()) {
            consecutiveFailures += 1
            halfOpenTrialInFlight = false
            if inFlight > 0 { inFlight -= 1 }
            if consecutiveFailures >= Self.tripThreshold {
                openedAt = now
            }
        }
    }

    // MARK: - State

    private let sender: Sender
    private let sleeper: Sleeper
    private let auditSink: AuditSink
    private let policy: RetryPolicy
    private var circuits: [UUID: CircuitBreaker] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    private var started = false

    init(
        sender: Sender? = nil,
        sleeper: Sleeper? = nil,
        auditSink: AuditSink? = nil,
        policy: RetryPolicy = RetryPolicy()
    ) {
        self.sender = sender ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (code, data)
        }
        self.sleeper = sleeper ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        self.auditSink = auditSink ?? { delivery in
            await MainActor.run { WebhookStore.shared.recordDelivery(delivery) }
        }
        self.policy = policy
    }

    // MARK: - Signing (pure, unit-testable)

    static func signature(secret: String, body: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "sha256=\(hex)"
    }

    // MARK: - Lifecycle

    // Idempotent, callable from any boot path (GruxApp launch). Registers
    // the NotificationCenter observers that feed publish().
    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default

        observerTokens.append(center.addObserver(
            forName: .gruxCommandV2PhaseTransitioned, object: nil, queue: nil
        ) { note in
            let info = note.userInfo ?? [:]
            guard let commandId = info["commandId"] as? String,
                  let toPhase = info["toPhase"] as? Int,
                  let phaseName = info["phaseName"] as? String else { return }
            let runId = (info["runId"] as? UUID)?.uuidString ?? (info["runId"] as? String ?? "")
            let payload: [String: String] = [
                "commandId": commandId,
                "runId": runId,
                "phaseName": phaseName,
                "phaseIndex": String(toPhase)
            ]
            Task { await WebhookManager.shared.publish(event: .commandPhaseTransitioned, payload: payload) }
        })

        observerTokens.append(center.addObserver(
            forName: .gruxCommandV2RunFinished, object: nil, queue: nil
        ) { note in
            let runId = (note.object as? UUID)?.uuidString ?? ""
            Task { await WebhookManager.shared.publish(event: .commandRunFinished, payload: ["runId": runId]) }
        })

        observerTokens.append(center.addObserver(
            forName: .gruxAgentJobLifecycle, object: nil, queue: nil
        ) { note in
            let info = note.userInfo ?? [:]
            guard let jobId = info["jobId"] as? String,
                  let status = info["status"] as? String else { return }
            var payload: [String: String] = [
                "jobId": jobId,
                "status": status,
                "title": (info["title"] as? String) ?? ""
            ]
            let event: WebhookEvent
            switch status {
            case "running": event = .agentJobStarted
            case "done": event = .agentJobCompleted
            case "failed", "cancelled":
                event = .agentJobFailed
                if let err = info["errorMessage"] as? String, !err.isEmpty {
                    payload["errorMessage"] = err
                }
            default:
                return // queued / waiting / paused are not webhook milestones
            }
            Task { await WebhookManager.shared.publish(event: event, payload: payload) }
        })

        observerTokens.append(center.addObserver(
            forName: .gruxReminderFired, object: nil, queue: nil
        ) { note in
            let info = note.userInfo ?? [:]
            guard let reminderId = info["reminderId"] as? String else { return }
            let payload: [String: String] = [
                "reminderId": reminderId,
                "title": (info["title"] as? String) ?? "",
                "kind": (info["kind"] as? String) ?? ""
            ]
            Task { await WebhookManager.shared.publish(event: .reminderFired, payload: payload) }
        })
    }

    func stop() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens = []
        started = false
    }

    // MARK: - Fan-out

    // Deliver an event to every enabled endpoint subscribed to it. Each
    // endpoint gets its own concurrent delivery task so one slow endpoint
    // never delays the others.
    func publish(event: WebhookEvent, payload: [String: String]) async {
        let targets = await MainActor.run { WebhookStore.shared.targets(for: event) }
        guard !targets.isEmpty else { return }
        for config in targets {
            let secret = WebhookSecretStore.get(account: config.secretAccount)
            Task { await self.deliver(config: config, secret: secret, event: event, payload: payload) }
        }
    }

    // Fire the test event at one endpoint, ignoring its event filter.
    // Returns the delivery record so the UI can show the result inline.
    @discardableResult
    func testFire(config: WebhookConfig) async -> WebhookDelivery {
        let secret = WebhookSecretStore.get(account: config.secretAccount)
        return await deliver(
            config: config,
            secret: secret,
            event: .testFire,
            payload: ["message": "Grux webhook test", "webhookName": config.name]
        )
    }

    // MARK: - Single delivery (retry + circuit breaker + audit)

    @discardableResult
    func deliver(
        config: WebhookConfig,
        secret: String,
        event: WebhookEvent,
        payload: [String: String]
    ) async -> WebhookDelivery {
        // Validation failures (bad URL, missing secret, encode error) say
        // nothing about endpoint health, so they are checked BEFORE circuit
        // admission and never consume the half-open trial slot.
        guard let url = URL(string: config.url), url.scheme?.hasPrefix("http") == true else {
            let record = WebhookDelivery(
                webhookId: config.id,
                webhookName: config.name,
                event: event.rawValue,
                url: config.url,
                attempts: 0,
                outcome: .failed,
                errorMessage: "Invalid URL"
            )
            await auditSink(record)
            return record
        }

        guard !secret.isEmpty else {
            // Refuse to send unsigned payloads, a webhook without a secret
            // gives the receiver no way to authenticate Grux.
            let record = WebhookDelivery(
                webhookId: config.id,
                webhookName: config.name,
                event: event.rawValue,
                url: config.url,
                attempts: 0,
                outcome: .failed,
                errorMessage: "No signing secret set for this webhook"
            )
            await auditSink(record)
            return record
        }

        let envelope = WebhookEnvelope(event: event, payload: payload)
        let body: Data
        do {
            body = try envelope.canonicalBody()
        } catch {
            let record = WebhookDelivery(
                webhookId: config.id,
                webhookName: config.name,
                event: event.rawValue,
                url: config.url,
                attempts: 0,
                outcome: .failed,
                errorMessage: "Envelope encode failed: \(error.localizedDescription)"
            )
            await auditSink(record)
            return record
        }

        // Circuit admission is a single synchronous actor hop (no suspension
        // between read and write), so concurrent deliveries to the same
        // endpoint cannot lose counter updates, and half-open admits exactly
        // one trial per cooldown window.
        let admission = admitAttempt(id: config.id)
        guard admission.allowed else {
            let record = WebhookDelivery(
                webhookId: config.id,
                webhookName: config.name,
                event: event.rawValue,
                url: config.url,
                attempts: 0,
                outcome: .skippedCircuitOpen,
                errorMessage: "Circuit open after \(admission.consecutiveFailures) consecutive failures"
            )
            await auditSink(record)
            return record
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event.rawValue, forHTTPHeaderField: "X-Grux-Event")
        request.setValue(envelope.deliveryId, forHTTPHeaderField: "X-Grux-Delivery")
        request.setValue(Self.signature(secret: secret, body: body), forHTTPHeaderField: "X-Grux-Signature")

        var attempts = 0
        var lastStatus: Int? = nil
        var lastError: String? = nil

        for attempt in 1...policy.maxAttempts {
            if let delay = policy.delay(beforeAttempt: attempt), delay > 0 {
                await sleeper(delay)
            }
            attempts = attempt
            do {
                let (status, _) = try await sender(request)
                lastStatus = status
                lastError = nil
                if RetryPolicy.isSuccess(statusCode: status) {
                    recordResult(id: config.id, success: true)
                    let record = WebhookDelivery(
                        webhookId: config.id,
                        webhookName: config.name,
                        event: event.rawValue,
                        url: config.url,
                        attempts: attempts,
                        statusCode: status,
                        outcome: .delivered
                    )
                    await auditSink(record)
                    return record
                }
                if !RetryPolicy.shouldRetry(statusCode: status) {
                    break // hard 4xx, retrying identical bytes won't help
                }
            } catch {
                lastStatus = nil
                lastError = error.localizedDescription
                // Transport error, retryable, keep looping.
            }
        }

        recordResult(id: config.id, success: false)
        let record = WebhookDelivery(
            webhookId: config.id,
            webhookName: config.name,
            event: event.rawValue,
            url: config.url,
            attempts: attempts,
            statusCode: lastStatus,
            outcome: .failed,
            errorMessage: lastError ?? lastStatus.map { "HTTP \($0)" }
        )
        await auditSink(record)
        return record
    }

    // MARK: - Circuit bookkeeping (synchronous: no suspension points)

    // deliver() suspends many times (backoff sleeps, the network call, the
    // audit sink), so circuit state must never be carried across those
    // suspensions as a local copy. These two helpers do the read-modify-write
    // in one non-suspending hop on the actor.
    private func admitAttempt(id: UUID) -> (allowed: Bool, consecutiveFailures: Int) {
        var circuit = circuits[id] ?? CircuitBreaker()
        let allowed = circuit.admit()
        circuits[id] = circuit
        return (allowed, circuit.consecutiveFailures)
    }

    private func recordResult(id: UUID, success: Bool) {
        var circuit = circuits[id] ?? CircuitBreaker()
        if success {
            circuit.recordSuccess()
        } else {
            circuit.recordFailure()
        }
        circuits[id] = circuit
    }

    // MARK: - Test hooks

    // Inspect a circuit's state (tests + the view's "circuit open" badge).
    func circuitState(for webhookId: UUID) -> CircuitBreaker {
        circuits[webhookId] ?? CircuitBreaker()
    }

    func resetCircuit(for webhookId: UUID) {
        circuits[webhookId] = CircuitBreaker()
    }
}
