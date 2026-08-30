import Foundation
import GruxAgentCore

// MARK: - CommandV2AgentBridge
//
// Bridges Commands V2 phase actions (claudeAgent / claudeAgentSwarm) to the
// real GruxAgentCore swarm runtime - replacing the V2.0 stubs that just
// printed "would run agent with prompt: …" and immediately marked the
// phase success without doing any work.
//
// Design:
//   • runSingleAgent → spawns ONE SwarmWorker actor directly (skip the
//     full AgentStore/Orchestrator overhead - single worker, single result).
//   • runSwarm        → builds an AgentJob with N parallel workers, feeds it
//     through a fresh SwarmOrchestrator, persists progress under
//     v2-runs/<runId>/swarm/. Streams worker step output back into the V2
//     phase log via the observer.
//
// Both paths inherit SwarmWorker's env-strip → claude CLI runs against the
// user's Claude.ai Max subscription (OAuth), NOT the metered API.
@MainActor
enum CommandV2AgentBridge {

    struct AgentResult {
        let text: String
        let success: Bool
        let costUSD: Double
        let durationSec: Double
        let workerCount: Int
        let pausedForAuth: Bool
    }

    // MARK: - Single agent

    static func runSingleAgent(
        prompt: String,
        cwd: String,
        model: String = "claude-sonnet-4-6",
        ttlSeconds: Int = 1800,
        runId: UUID
    ) async -> AgentResult {
        let label = "v2-agent-\(runId.uuidString.prefix(6))"
        let spec = SwarmWorkerSpec(
            role: .generic,
            label: label,
            goal: prompt,
            cwd: cwd,
            model: model,
            budgetUSD: 5.0  // informational only - OAuth subscription path
        )
        WakeLog.shared.log("v2: claudeAgent → spawning worker label=\(label) cwd=\(cwd) model=\(model) ttl=\(ttlSeconds)s")

        let logger = PhaseLogObserver(runId: runId, label: label)
        let worker = SwarmWorker(spec: spec, observer: logger)
        let started = Date()
        let result = await worker.run(scaffold: MegapromptScaffold.block(), ttlSeconds: ttlSeconds)
        let dur = Date().timeIntervalSince(started)

        let pausedForAuth = (result.interruption?.kind == .authLimitHit)
        let finalText = result.finalText.isEmpty
            ? (result.errorMessage ?? "(no output)")
            : result.finalText
        WakeLog.shared.log("v2: claudeAgent → worker exit=\(result.exitCode) success=\(result.success) cost=$\(String(format: "%.4f", result.costUSD)) dur=\(Int(dur))s pausedForAuth=\(pausedForAuth)")
        return AgentResult(
            text: finalText,
            success: result.success && !pausedForAuth,
            costUSD: result.costUSD,
            durationSec: dur,
            workerCount: 1,
            pausedForAuth: pausedForAuth
        )
    }

    // MARK: - Swarm (N parallel agents)

    static func runSwarm(
        prompts: [String],
        cwd: String,
        model: String = "claude-sonnet-4-6",
        ttlSeconds: Int = 1800,
        runId: UUID,
        title: String
    ) async -> AgentResult {
        guard !prompts.isEmpty else {
            return AgentResult(text: "(no prompts)", success: true, costUSD: 0, durationSec: 0, workerCount: 0, pausedForAuth: false)
        }
        let workers: [SwarmWorkerSpec] = prompts.enumerated().map { (i, p) in
            SwarmWorkerSpec(
                role: .implementor,
                label: "swarm-\(i + 1)",
                goal: p,
                cwd: cwd,
                model: model,
                budgetUSD: 5.0
            )
        }
        let job = AgentJob(
            id: "v2-\(runId.uuidString)-swarm",
            title: title,
            goal: prompts.first ?? "",
            budgetUSD: 50.0,
            maxParallelWorkers: min(prompts.count, 4),
            workers: workers,
            rootDir: cwd
        )
        // Persist swarm state alongside the V2 run, not under ~/Library/.../agents/
        // (which is the human-visible Agents tab feed). Keeps Workflows-driven
        // swarm churn from cluttering the standalone Agents view.
        let storeURL = Persistence.supportDir
            .appendingPathComponent("v2-runs", isDirectory: true)
            .appendingPathComponent(runId.uuidString, isDirectory: true)
            .appendingPathComponent("swarm", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let store = AgentStore(rootDir: storeURL, writeGate: { !Persistence.writesSuspended })
        try? await store.saveJob(job)

        let observer = PhaseSwarmObserver(runId: runId, title: title)
        let orch = SwarmOrchestrator(job: job, store: store, observer: observer)
        WakeLog.shared.log("v2: claudeAgentSwarm → orchestrator starting jobId=\(job.id) workers=\(workers.count)")

        let started = Date()
        // Bound the entire swarm by N × per-worker TTL ceiling. SwarmOrchestrator
        // already TTL-bounds individual workers; we just await its loop here.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await orch.run() }
        }
        let dur = Date().timeIntervalSince(started)

        let finalJob = await store.loadJob(job.id) ?? job
        let totalCost = finalJob.workers.map(\.spentUSD).reduce(0, +)
        let pausedForAuth = (finalJob.status == .waiting && finalJob.pausedReason == .authLimitHit)
        let success = (finalJob.status == .done) && !pausedForAuth
        let lastTexts = finalJob.workers.compactMap { $0.lastResultText }.suffix(3).joined(separator: "\n---\n")
        let summary = "swarm \(workers.count) workers → status=\(finalJob.status.rawValue) ($\(String(format: "%.2f", totalCost)), \(Int(dur))s)\n\(String(lastTexts.suffix(800)))"
        WakeLog.shared.log("v2: claudeAgentSwarm → finished status=\(finalJob.status.rawValue) cost=$\(String(format: "%.4f", totalCost)) dur=\(Int(dur))s")

        return AgentResult(
            text: summary,
            success: success,
            costUSD: totalCost,
            durationSec: dur,
            workerCount: workers.count,
            pausedForAuth: pausedForAuth
        )
    }
}

// MARK: - Phase-log observer for single agent

// Funnels each interesting AgentStep from the running worker into the V2
// run's WakeLog. Cheap & noisy by design - operators want to SEE the model
// thinking when a phase is running, not just final results.
public final class PhaseLogObserver: SwarmWorkerObserver, @unchecked Sendable {
    let runId: UUID
    let label: String
    init(runId: UUID, label: String) { self.runId = runId; self.label = label }

    public func worker(_ workerId: String, didEmit step: AgentStep) async {
        let prefix = "v2[\(runId.uuidString.prefix(8))][\(label)]"
        switch step.kind {
        case .toolUse:
            WakeLog.shared.log("\(prefix) tool: \(step.toolName ?? "?") \(String(step.text.prefix(120)))")
        case .toolResult:
            WakeLog.shared.log("\(prefix) tool→ \(String(step.text.prefix(120)))")
        case .assistantText:
            WakeLog.shared.log("\(prefix) say: \(String(step.text.prefix(160)))")
        case .error:
            WakeLog.shared.log("\(prefix) ERROR \(String(step.text.prefix(200)))")
        default:
            WakeLog.shared.log("\(prefix) \(step.kind.rawValue): \(String(step.text.prefix(120)))")
        }
    }
}

// MARK: - Phase-log observer for the swarm orchestrator

public final class PhaseSwarmObserver: SwarmOrchestratorObserver, @unchecked Sendable {
    let runId: UUID
    let title: String
    init(runId: UUID, title: String) { self.runId = runId; self.title = title }

    public func orchestratorJobDidUpdate(_ job: AgentJob) async {
        WakeLog.shared.log("v2[\(runId.uuidString.prefix(8))][\(title)] job: status=\(job.status.rawValue) workers=\(job.workers.map { "\($0.label)=\($0.status.rawValue)" }.joined(separator: ","))")
    }

    public func orchestrator(_ jobId: String, didAppend step: AgentStep) async {
        // Forward to the per-worker logger format.
        let label = step.workerId ?? "orch"
        let prefix = "v2[\(runId.uuidString.prefix(8))][\(label)]"
        WakeLog.shared.log("\(prefix) \(step.kind.rawValue): \(String(step.text.prefix(160)))")
    }
}
