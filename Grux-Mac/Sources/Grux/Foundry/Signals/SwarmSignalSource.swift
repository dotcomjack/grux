import Foundation
import GruxAgentCore

// Swarm lane of the Sense pass. Reads AgentStore's on-disk layout
// (<agentsDir>/<jobId>/job.json + log.ndjson) for jobs that ended badly or
// stalled out:
//
//   - failed jobs (with errorMessage)
//   - cancelled jobs
//   - interrupted jobs: parked on authLimitHit, or running/queued with a
//     stale heartbeat (the owning process likely died mid-flight)
//   - error steps inside otherwise-finished jobs (a done job with 12 error
//     steps still has something to teach)
struct SwarmSignalSource: FoundrySignalSource {

    let sourceName = "swarm"

    var agentsDir: URL
    var lookback: TimeInterval
    var staleHeartbeat: TimeInterval
    var now: @Sendable () -> Date

    init(
        agentsDir: URL = Persistence.agentsDir,
        lookback: TimeInterval = 14 * 24 * 3600,
        staleHeartbeat: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.agentsDir = agentsDir
        self.lookback = lookback
        self.staleHeartbeat = staleHeartbeat
        self.now = now
    }

    func harvest() async throws -> [FoundrySignal] {
        let store = AgentStore(rootDir: agentsDir)
        let cutoff = now().addingTimeInterval(-lookback)
        let jobs = await store.listJobs().filter { $0.createdAt >= cutoff }
        var signals: [FoundrySignal] = []
        for job in jobs {
            let steps = await store.loadSteps(jobId: job.id)
            signals += Self.signals(for: job, steps: steps, staleHeartbeat: staleHeartbeat, now: now())
        }
        return signals.sorted { $0.summary < $1.summary }
    }

    // Exposed for tests: pure function over one job + its step log.
    static func signals(
        for job: AgentJob,
        steps: [AgentStep],
        staleHeartbeat: TimeInterval = 10 * 60,
        now: Date = Date()
    ) -> [FoundrySignal] {
        var out: [FoundrySignal] = []
        let errorSteps = steps.filter { $0.kind == .error }
        let errorExcerpt = errorSteps.suffix(3)
            .map { String($0.text.prefix(160)) }
            .joined(separator: "\n")

        switch job.status {
        case .failed:
            out.append(FoundrySignal(
                source: "swarm",
                severity: .high,
                summary: "Swarm job failed: '\(job.title)'",
                evidence: [
                    "goal: \(String(job.goal.prefix(160)))",
                    "error: \(job.errorMessage ?? "unknown")",
                    errorExcerpt
                ].filter { !$0.isEmpty }.joined(separator: "\n"),
                suggestedLane: .reliability,
                suggestedDomain: "swarm"
            ))
        case .cancelled:
            out.append(FoundrySignal(
                source: "swarm",
                severity: .low,
                summary: "Swarm job cancelled: '\(job.title)'",
                evidence: "goal: \(String(job.goal.prefix(160)))",
                suggestedLane: .reliability,
                suggestedDomain: "swarm"
            ))
        case .waiting, .paused:
            if job.pausedReason == .authLimitHit {
                out.append(FoundrySignal(
                    source: "swarm",
                    severity: .medium,
                    summary: "Swarm job interrupted by auth/session limit: '\(job.title)'",
                    evidence: [
                        "goal: \(String(job.goal.prefix(160)))",
                        "pausedReason: authLimitHit",
                        errorExcerpt
                    ].filter { !$0.isEmpty }.joined(separator: "\n"),
                    suggestedLane: .cost,
                    suggestedDomain: "swarm"
                ))
            }
        case .running, .queued:
            // Timeout-shaped: a live status whose heartbeat went stale means
            // the owning process likely died without marking the job terminal.
            if let hb = job.lastHeartbeatAt, now.timeIntervalSince(hb) > staleHeartbeat {
                out.append(FoundrySignal(
                    source: "swarm",
                    severity: .high,
                    summary: "Swarm job stalled (stale heartbeat): '\(job.title)'",
                    evidence: [
                        "status: \(job.status.rawValue)",
                        "lastHeartbeatAt: \(hb)",
                        "ownerPID: \(job.ownerPID.map(String.init) ?? "nil")"
                    ].joined(separator: "\n"),
                    suggestedLane: .reliability,
                    suggestedDomain: "swarm"
                ))
            }
        case .done:
            break
        }

        // Error steps inside any job, including done ones, are worth a line
        // when they cluster.
        if errorSteps.count >= 3 {
            out.append(FoundrySignal(
                source: "swarm",
                severity: errorSteps.count >= 8 ? .high : .medium,
                summary: "Swarm job '\(job.title)' logged \(errorSteps.count) error steps",
                evidence: errorExcerpt,
                suggestedLane: .reliability,
                suggestedDomain: "swarm"
            ))
        }
        return out
    }
}
