import Foundation

// Data model for the outbound webhook subsystem. Grux POSTs signed JSON
// envelopes to user-registered URLs when interesting things happen (agent
// job lifecycle, Commands V2 phase transitions, reminders firing).
//
// OUTBOUND ONLY. Inbound triggers ("hit a URL to make Grux do X") are
// deliberately deferred: accepting inbound HTTP means exposing a listener
// through the Cloudflare tunnel that GruxPhone uses, and that needs its own
// auth + replay-protection design pass before we widen the attack surface.
// The phone channel today is a paired, ECDHE-encrypted WS, bolting a
// generic HTTP trigger endpoint onto it without that design would be a
// regression. See docs note in WebhookManager.swift.

// MARK: - Events

// The catalog of events a webhook can subscribe to. Raw values are the wire
// strings carried in the envelope's `event` field, snake_case to match the
// JSON convention webhook consumers expect.
enum WebhookEvent: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case agentJobStarted = "agent_job_started"
    case agentJobCompleted = "agent_job_completed"
    case agentJobFailed = "agent_job_failed"
    case commandPhaseTransitioned = "command_phase_transitioned"
    case commandRunFinished = "command_run_finished"
    case reminderFired = "reminder_fired"
    // Sent by the "Test fire" button in WebhooksView so users can verify
    // their endpoint + secret without waiting for a real event.
    case testFire = "test_fire"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agentJobStarted: return "Agent job started"
        case .agentJobCompleted: return "Agent job completed"
        case .agentJobFailed: return "Agent job failed"
        case .commandPhaseTransitioned: return "Workflow phase transitioned"
        case .commandRunFinished: return "Workflow run finished"
        case .reminderFired: return "Reminder fired"
        case .testFire: return "Test fire"
        }
    }

    // Events offered in the add/edit form. testFire is internal-only.
    static var subscribable: [WebhookEvent] {
        allCases.filter { $0 != .testFire }
    }
}

// MARK: - Config

// One registered webhook endpoint. The signing secret is NOT stored here.
// It lives in the macOS Keychain under service `com.gruxai.grux.webhooks`,
// account = `secretAccount`. This struct is what lands in webhooks.json on
// disk, so keeping the secret out of it follows the same posture as
// KeychainStore (no secrets in Application Support JSON).
struct WebhookConfig: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: String
    // Keychain account name holding the HMAC secret. Derived from the id so
    // it's stable across edits and unique per webhook.
    var secretAccount: String
    var events: Set<WebhookEvent>
    var enabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        events: Set<WebhookEvent>,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.secretAccount = "webhook-secret-\(id.uuidString)"
        self.events = events
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

// MARK: - Envelope

// The JSON body POSTed to the endpoint. `payload` is a flat string map so
// the body shape stays stable and simple for consumers (no nested typed
// blobs that change per event). The canonical encoding sorts keys so the
// HMAC signature is deterministic for a given envelope.
struct WebhookEnvelope: Codable, Sendable {
    let event: String
    let deliveryId: String
    let timestamp: String   // ISO-8601, UTC
    let payload: [String: String]

    init(event: WebhookEvent, payload: [String: String], deliveryId: UUID = UUID(), date: Date = Date()) {
        self.event = event.rawValue
        self.deliveryId = deliveryId.uuidString
        self.timestamp = WebhookEnvelope.iso8601.string(from: date)
        self.payload = payload
    }

    // Deterministic body: sorted keys, no pretty-printing. The signature is
    // computed over EXACTLY these bytes and the same bytes go on the wire,
    // so consumers can verify by HMACing the raw request body.
    func canonicalBody() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Delivery audit record

// One attempt-group at delivering an envelope to one endpoint. Appended to
// the audit log in WebhookStore regardless of outcome so the Webhooks view
// can show "recent deliveries with status".
struct WebhookDelivery: Codable, Identifiable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case delivered           // got a 2xx
        case failed              // exhausted retries or hit a non-retryable status
        case skippedCircuitOpen  // endpoint's circuit breaker was open; not attempted
    }

    let id: UUID
    let webhookId: UUID
    let webhookName: String
    let event: String
    let url: String
    let timestamp: Date
    var attempts: Int
    var statusCode: Int?
    var outcome: Outcome
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        webhookId: UUID,
        webhookName: String,
        event: String,
        url: String,
        timestamp: Date = Date(),
        attempts: Int = 0,
        statusCode: Int? = nil,
        outcome: Outcome,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.webhookId = webhookId
        self.webhookName = webhookName
        self.event = event
        self.url = url
        self.timestamp = timestamp
        self.attempts = attempts
        self.statusCode = statusCode
        self.outcome = outcome
        self.errorMessage = errorMessage
    }
}

// MARK: - Event-source notifications

// New NotificationCenter seams the webhook subsystem listens on. The
// CommandsV2 names already exist (CommandV2Engine.swift); these two cover
// the seams that don't broadcast yet. AgentService and GruxReminderState
// post them via one-line integration hooks (see WebhookManager header).
extension Notification.Name {
    // userInfo: ["jobId": String, "title": String, "status": String
    // (AgentJob.Status rawValue), "errorMessage": String (optional)]
    static let gruxAgentJobLifecycle = Notification.Name("gruxAgentJobLifecycle")
    // userInfo: ["reminderId": String, "title": String, "kind": String]
    static let gruxReminderFired = Notification.Name("gruxReminderFired")
}
