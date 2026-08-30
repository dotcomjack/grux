import Foundation

// Top-level autonomous job. One job per user goal. Holds the canonical state
// the orchestrator persists to disk. Workers live under SwarmPlan; their
// per-process state lives in SwarmWorker actors at runtime.
public struct AgentJob: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued
        case running
        case waiting     // gated for user approval OR account switch (see pausedReason)
        case paused
        case done
        case failed
        case cancelled
    }

    // Why the job is in a non-terminal halted state. Set when status is
    // `.waiting` or `.paused`. Nil when running normally or done.
    public enum PausedReason: String, Codable, Sendable {
        case authLimitHit       // a worker hit the Anthropic monthly subscription limit
        case awaitingApproval   // waiting on a user click for an approval-gated step
        case manualPause        // user pressed "pause"
    }

    public let id: String                  // UUID
    public var title: String
    public var goal: String
    public var status: Status
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var budgetUSD: Double
    public var spentUSD: Double
    public var maxParallelWorkers: Int
    public var workers: [SwarmWorkerSpec]
    public var rootDir: String              // each worker's cwd is rooted here or below
    public var errorMessage: String?
    // Set when status == .waiting or .paused. Nil otherwise. The Agents tab
    // and notification system key off this to render the right copy + actions
    // (e.g. "switch account" for .authLimitHit vs "approve" for .awaitingApproval).
    public var pausedReason: PausedReason?
    // PID of the process currently driving this job (SwarmDemo, Grux.app, etc).
    // Set by SwarmOrchestrator.run() before any work, cleared when the job
    // reaches a terminal status. AgentService.bootstrap() uses this with
    // `kill(pid, 0)` to detect "another process owns this job, leave it alone"
    // vs. "owner is dead, mark failed". Optional for legacy jobs without it.
    public var ownerPID: Int32?
    // ISO-8601 wall-clock heartbeat written each time the orchestrator saves
    // job state. A stale heartbeat (>5 min) combined with a missing PID is a
    // strong signal that the owning process died.
    public var lastHeartbeatAt: Date?

    public init(
        id: String = UUID().uuidString,
        title: String,
        goal: String,
        status: Status = .queued,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        budgetUSD: Double = 5.0,
        spentUSD: Double = 0.0,
        maxParallelWorkers: Int = 3,
        workers: [SwarmWorkerSpec] = [],
        rootDir: String,
        errorMessage: String? = nil,
        ownerPID: Int32? = nil,
        lastHeartbeatAt: Date? = nil,
        pausedReason: PausedReason? = nil
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.budgetUSD = budgetUSD
        self.spentUSD = spentUSD
        self.maxParallelWorkers = maxParallelWorkers
        self.workers = workers
        self.rootDir = rootDir
        self.errorMessage = errorMessage
        self.ownerPID = ownerPID
        self.lastHeartbeatAt = lastHeartbeatAt
        self.pausedReason = pausedReason
    }

    public var isTerminal: Bool {
        switch status {
        case .done, .failed, .cancelled: return true
        case .queued, .running, .waiting, .paused: return false
        }
    }
}

// Records what interrupted a worker mid-run so the orchestrator can resume it
// later without losing context. Today the only producer is the
// LimitSignalDetector - when a worker's stream-json contains the synthetic
// "monthly usage limit" event from the claude CLI, the worker is parked with
// a `WorkerInterruption` of kind `.authLimitHit` instead of being marked
// `.failed`. Resume re-spawns the worker fresh against whichever account is
// active at resume time.
public struct WorkerInterruption: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case authLimitHit
        case ttl
        case userCancel
    }
    public let kind: Kind
    public let detectedAt: Date
    // Best-effort: the orgId of the account that hit the limit (read from
    // `claude auth status --json` at the time of pause). Nil if introspection
    // failed. Used to label the resume sheet ("Account A is rate-limited").
    public let claudeAccountId: String?
    // Optional snippet of the last assistant text before the interruption -
    // mostly for the UI step log so the user can see what was happening when
    // the limit hit. Not used for any decision logic.
    public let resumePromptCheckpoint: String?

    public init(
        kind: Kind,
        detectedAt: Date = Date(),
        claudeAccountId: String? = nil,
        resumePromptCheckpoint: String? = nil
    ) {
        self.kind = kind
        self.detectedAt = detectedAt
        self.claudeAccountId = claudeAccountId
        self.resumePromptCheckpoint = resumePromptCheckpoint
    }
}
