import Foundation

// MARK: - SwarmOrchestrator
//
// Owns one AgentJob. Walks the worker DAG. For each batch of ready workers
// (no unmet dependencies), spawns up to maxParallelWorkers concurrently as
// SwarmWorker actors. Persists every event via AgentStore.
//
// Concurrency model:
//   - The orchestrator is itself an actor - single mutator of job state.
//   - Each worker runs in its own SwarmWorker actor (own subprocess).
//   - withTaskGroup parallelizes ready workers up to the cap.

public protocol SwarmOrchestratorObserver: AnyObject, Sendable {
    func orchestratorJobDidUpdate(_ job: AgentJob) async
    func orchestrator(_ jobId: String, didAppend step: AgentStep) async
}

public actor SwarmOrchestrator: SwarmWorkerObserver {

    public let store: AgentStore
    public private(set) var job: AgentJob
    public weak var observer: (any SwarmOrchestratorObserver)?

    private var liveWorkers: [String: SwarmWorker] = [:]
    private var cancelled = false

    public init(
        job: AgentJob,
        store: AgentStore,
        observer: (any SwarmOrchestratorObserver)? = nil
    ) {
        self.job = job
        self.store = store
        self.observer = observer
    }

    // SwarmWorkerObserver
    public func worker(_ workerId: String, didEmit step: AgentStep) async {
        await store.appendStep(jobId: job.id, step: step)
        await observer?.orchestrator(job.id, didAppend: step)
        if let cost = step.costUSD {
            // Aggregate cost into worker + job; saveJob below.
            if let idx = job.workers.firstIndex(where: { $0.id == workerId }) {
                job.workers[idx].spentUSD = max(job.workers[idx].spentUSD, cost)
            }
            let total = job.workers.map(\.spentUSD).reduce(0, +)
            job.spentUSD = total
            job.lastHeartbeatAt = Date()
            try? await store.saveJob(job)
        }
    }

    // MARK: - Main run loop

    public func run() async {
        guard !cancelled else { return }

        job.status = .running
        job.startedAt = job.startedAt ?? Date()
        // Stamp ownership: the running process gets PID-tracked so other
        // processes (e.g., a Grux.app launching while SwarmDemo is mid-run)
        // can detect "this job is alive elsewhere" and not mark it failed.
        job.ownerPID = ProcessInfo.processInfo.processIdentifier
        job.lastHeartbeatAt = Date()
        try? await store.saveJob(job)
        await emitOrchStep(.orchestrator, text: "starting job '\(job.title)' (\(job.workers.count) workers, max parallel=\(job.maxParallelWorkers))")
        await observer?.orchestratorJobDidUpdate(job)

        while !cancelled {
            // Budget is purely informational now - workers run through the
            // user's Claude.ai subscription, not metered API. The budgetUSD
            // field tracks "what this WOULD have cost" via stream-json
            // total_cost_usd for display in the Agents tab. No hard stop.

            // Find ready workers - queued and all dependencies done.
            let ready = job.workers.filter { spec in
                guard spec.status == .queued else { return false }
                return spec.dependsOn.allSatisfy { depId in
                    job.workers.first(where: { $0.id == depId })?.status == .done
                }
            }

            // Anything left running?
            let running = job.workers.contains(where: { $0.status == .running })
            let anyPausedForAuth = job.workers.contains(where: { $0.status == .pausedForAuth })

            if ready.isEmpty && !running {
                // Pause branch wins over fail/done. If ANY worker is parked
                // waiting on an account switch, downstream workers can't run
                // (their deps haven't resolved) and the user might still
                // resume - so we exit the loop with status .waiting and
                // pausedReason .authLimitHit. The job stays alive on disk;
                // resumeJob() re-enters this run loop after the swap.
                if anyPausedForAuth {
                    job.status = .waiting
                    job.pausedReason = .authLimitHit
                    job.lastHeartbeatAt = Date()
                    try? await store.saveJob(job)
                    let pausedLabels = job.workers.filter { $0.status == .pausedForAuth }.map(\.label).joined(separator: ", ")
                    await emitOrchStep(
                        .orchestrator,
                        text: "paused - auth limit hit on account; awaiting switch (\(pausedLabels))"
                    )
                    await observer?.orchestratorJobDidUpdate(job)
                    return
                }
                // Either all done or stuck (some deps failed).
                let allDone = job.workers.allSatisfy { $0.status == .done || $0.status == .skipped }
                let anyFailed = job.workers.contains(where: { $0.status == .failed })
                if anyFailed && !allDone {
                    job.status = .failed
                    job.errorMessage = "workers failed: " + job.workers.filter { $0.status == .failed }.map(\.label).joined(separator: ", ")
                } else if allDone {
                    job.status = .done
                } else {
                    // Stuck - workers queued but their deps will never resolve.
                    job.status = .failed
                    job.errorMessage = "deadlocked - queued workers have unmet dependencies"
                }
                job.completedAt = Date()
                job.lastHeartbeatAt = Date()
            try? await store.saveJob(job)
                await emitOrchStep(.orchestrator, text: "job ended status=\(job.status.rawValue) spent=$\(String(format: "%.4f", job.spentUSD))")
                await observer?.orchestratorJobDidUpdate(job)
                return
            }

            // Cap parallelism by maxParallelWorkers.
            let runningCount = job.workers.filter { $0.status == .running }.count
            let slots = max(0, job.maxParallelWorkers - runningCount)
            let toLaunch = Array(ready.prefix(slots))

            if toLaunch.isEmpty {
                // Wait for at least one running worker to finish.
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            // Launch them in parallel via TaskGroup.
            await withTaskGroup(of: Void.self) { group in
                for spec in toLaunch {
                    // Mark as running first so the next loop iteration sees it.
                    if let idx = job.workers.firstIndex(where: { $0.id == spec.id }) {
                        job.workers[idx].status = .running
                        job.workers[idx].startedAt = Date()
                    }
                    job.lastHeartbeatAt = Date()
            try? await store.saveJob(job)
                    await observer?.orchestratorJobDidUpdate(job)

                    let worker = SwarmWorker(spec: spec, observer: self)
                    liveWorkers[spec.id] = worker

                    group.addTask { [self] in
                        let scaffold = MegapromptScaffold.block()
                        // Per-worker TTL: 1800s default, overridable via env
                        // GRUX_WORKER_TTL_SECONDS so callers (SwarmDemo --ttl-seconds)
                        // can extend for big single-worker Opus runs that
                        // legitimately need 45-60 min.
                        let ttl = (ProcessInfo.processInfo.environment["GRUX_WORKER_TTL_SECONDS"]
                                    .flatMap(Int.init)) ?? 1800
                        let result = await worker.run(scaffold: scaffold, ttlSeconds: ttl)
                        await self.workerCompleted(spec.id, result: result)
                    }
                }
            }
        }
    }

    private func workerCompleted(_ workerId: String, result: SwarmWorkerResult) async {
        liveWorkers.removeValue(forKey: workerId)
        guard let idx = job.workers.firstIndex(where: { $0.id == workerId }) else { return }
        job.workers[idx].completedAt = Date()
        job.workers[idx].spentUSD = max(job.workers[idx].spentUSD, result.costUSD)
        if let interruption = result.interruption, interruption.kind == .authLimitHit {
            // Auth limit hit - park the worker. Don't propagate to .failed
            // because the work itself isn't broken; it just needs the active
            // account swapped out (or a snooze until the limit window rolls).
            job.workers[idx].status = .pausedForAuth
            job.workers[idx].interruption = interruption
            job.workers[idx].errorMessage = result.errorMessage
            // Preserve any partial finalText for the resume sheet's
            // checkpoint preview, but DON'T set lastResultText - downstream
            // workers must NOT consume the limit-hit string as a real output.
        } else if result.success {
            job.workers[idx].status = .done
            job.workers[idx].lastResultText = result.finalText
        } else {
            job.workers[idx].status = .failed
            job.workers[idx].errorMessage = result.errorMessage ?? "unknown failure"
        }
        let total = job.workers.map(\.spentUSD).reduce(0, +)
        job.spentUSD = total
        try? await store.saveJob(job)
        await observer?.orchestratorJobDidUpdate(job)
    }

    // MARK: - Resume after auth-limit pause
    //
    // Re-queue every `.pausedForAuth` worker and re-enter the run loop. The
    // orchestrator drives forward exactly as it did on first launch - so a
    // freshly-paired account with quota left will pick up the worker's
    // original prompt and run it from scratch.
    //
    // Idempotency caveat: workers are mostly idempotent because their outputs
    // are write-to-named-file (brief.md / draft.md / etc) and downstream
    // workers re-read those files. `prepareForResume(workerId:)` moves any
    // partial output aside before the worker re-spawns, so a half-streamed
    // file from the interrupted run can't poison the resume.
    public func resumeJob() async {
        let mutated = await applyResumeMutations()
        guard mutated else { return }
        // Re-enter the main loop. run() flips status to .running on entry.
        await run()
    }

    // The state-mutation half of resumeJob, factored out so tests can verify
    // the resume transformation without triggering an actual `claude --print`
    // subprocess spawn. Production callers always go through resumeJob().
    //
    // Returns true if any pausedForAuth workers were re-queued. The caller
    // (resumeJob) uses that to decide whether to re-enter the run loop.
    @discardableResult
    public func applyResumeMutations() async -> Bool {
        guard job.workers.contains(where: { $0.status == .pausedForAuth }) else {
            return false
        }
        cancelled = false
        for i in job.workers.indices where job.workers[i].status == .pausedForAuth {
            await prepareForResume(workerId: job.workers[i].id)
            job.workers[i].status = .queued
            job.workers[i].interruption = nil
            job.workers[i].errorMessage = nil
            job.workers[i].startedAt = nil
            job.workers[i].completedAt = nil
            job.workers[i].lastResultText = nil
            // spentUSD is intentionally cumulative - the cost incurred on the
            // first attempt is real even if the run restarts. UI can display
            // both attempts' cost in aggregate.
        }
        job.pausedReason = nil
        job.status = .queued
        job.errorMessage = nil
        job.completedAt = nil
        job.lastHeartbeatAt = Date()
        try? await store.saveJob(job)
        await emitOrchStep(.workerResumed, text: "resuming after account switch - re-spawning paused workers")
        await observer?.orchestratorJobDidUpdate(job)
        return true
    }

    // Move any partial outputs from an interrupted worker aside so the resume
    // run starts from a clean slate. v1 implementation is conservative: we
    // create a `.interrupted/<workerId>/` marker directory under the job's
    // workers/ folder so future revisions can land partial-file housekeeping
    // here without changing the public surface. Today the worker actor
    // doesn't track its emitted files, so genuine output reconciliation is
    // deferred - the next worker run starts fresh and overwrites brief.md /
    // draft.md / etc., which is correct for the canned templates.
    public func prepareForResume(workerId: String) async {
        let dir = await store.jobDir(job.id)
            .appendingPathComponent("workers", isDirectory: true)
            .appendingPathComponent(workerId, isDirectory: true)
            .appendingPathComponent(".interrupted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Stamp a marker so later forensics can tell a fresh run from a
        // resume run when reading the worker's log.ndjson.
        let marker = dir.appendingPathComponent("resumed-at-\(Int(Date().timeIntervalSince1970)).txt")
        try? Data("auth-limit resume".utf8).write(to: marker, options: .atomic)
    }

    // MARK: - Cancel

    public func cancel() async {
        cancelled = true
        for (_, w) in liveWorkers {
            await w.cancel()
        }
        for i in job.workers.indices where !job.workers[i].isTerminal {
            job.workers[i].status = .cancelled
        }
        job.status = .cancelled
        job.completedAt = Date()
        try? await store.saveJob(job)
        await emitOrchStep(.orchestrator, text: "cancelled")
        await observer?.orchestratorJobDidUpdate(job)
    }

    private func emitOrchStep(_ kind: AgentStep.Kind, text: String) async {
        let step = AgentStep(kind: kind, text: text)
        await store.appendStep(jobId: job.id, step: step)
        await observer?.orchestrator(job.id, didAppend: step)
    }
}
