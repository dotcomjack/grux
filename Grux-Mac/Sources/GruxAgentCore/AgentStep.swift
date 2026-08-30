import Foundation

// Append-only step events streamed from running workers. Persisted as NDJSON
// to <agentsDir>/<jobId>/log.ndjson and per-worker streams in workers/<id>/log.ndjson.
public struct AgentStep: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case workerStart
        case workerEnd
        case assistantText
        case toolUse
        case toolResult
        case usage
        case error
        case orchestrator   // orchestrator-level transitions (queued, scheduled, completed)
        case approvalRequested
        case approvalGranted
        case info
        // Account-switch / auth-limit lifecycle. Emitted by SwarmWorker /
        // SwarmOrchestrator / AgentService.
        case authLimitDetected   // worker classified as .pausedForAuth
        case accountSwitched     // user picked a different claude account, swap completed
        case workerResumed       // pausedForAuth worker re-spawned after switch
    }

    public let id: String
    public let ts: Date
    public let workerId: String?         // nil for orchestrator-level events
    public let kind: Kind
    public let toolName: String?
    public let text: String              // human-readable summary
    public let payloadJSON: String?      // full JSON for replay/debug
    public let costUSD: Double?

    public init(
        id: String = UUID().uuidString,
        ts: Date = Date(),
        workerId: String? = nil,
        kind: Kind,
        toolName: String? = nil,
        text: String,
        payloadJSON: String? = nil,
        costUSD: Double? = nil
    ) {
        self.id = id
        self.ts = ts
        self.workerId = workerId
        self.kind = kind
        self.toolName = toolName
        self.text = text
        self.payloadJSON = payloadJSON
        self.costUSD = costUSD
    }
}
