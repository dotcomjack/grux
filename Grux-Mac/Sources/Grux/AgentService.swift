import Foundation
import SwiftUI
import AppKit
import GruxAgentCore

// MARK: - AgentService
//
// Main-app singleton wrapping GruxAgentCore.SwarmOrchestrator. Owns one
// orchestrator per running job, persists everything via AgentStore at
// Persistence.agentsDir. Publishes job + step state to SwiftUI views.
//
// Restoration: on launch, scans agentsDir, marks any non-terminal jobs
// as failed/paused (we don't auto-resume by default - workers held
// subprocesses that are dead now).

@MainActor
final class AgentService: ObservableObject {

    static let shared = AgentService()

    @Published private(set) var jobs: [AgentJob] = []
    @Published private(set) var stepsByJob: [String: [AgentStep]] = [:]

    private let store: AgentStore
    private var orchestrators: [String: SwarmOrchestrator] = [:]
    // Track which paused jobs have already triggered a notification so the
    // bridge's bursty job-update callbacks don't fire the banner repeatedly.
    private var notifiedPausedJobIds: Set<String> = []
    // Snooze schedule: jobId → fireDate. When a fireDate hits, the
    // snoozeTimer wakes the job back into running on the SAME account (no
    // switch) - handy when the user wants to wait out the calendar-window
    // reset rather than swap accounts.
    private var snoozedUntil: [String: Date] = [:]
    private var snoozeTimer: Timer?
    // Guards against the double-bootstrap race: init() kicks one off and
    // GruxApp.applicationDidFinishLaunching kicks another. Two concurrent passes
    // can double-orphan or duplicate jobs. First one wins; the second no-ops.
    private var bootstrapped = false

    private init() {
        self.store = AgentStore(rootDir: Persistence.agentsDir,
                                writeGate: { !Persistence.writesSuspended })
        Task {
            await self.bootstrap()
        }
    }

    // MARK: - Bootstrap (called from GruxApp.applicationDidFinishLaunching)

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        let restored = await store.listJobs()
        var normalized: [AgentJob] = []
        for j in restored {
            if j.isTerminal {
                normalized.append(j)
                continue
            }
            // Job is non-terminal. Before marking it failed, check if another
            // process actually owns and is driving this job (e.g., the user
            // is running SwarmDemo from CLI while Grux.app launches/restarts;
            // both write to the same central agentsDir).
            //
            // Live-owner heuristic:
            //   1. ownerPID is set AND `kill(pid, 0)` succeeds → owner alive → leave it alone
            //   2. lastHeartbeatAt within the past 5 min → orchestrator likely
            //      still ticking, even if PID isn't ours; leave it alone
            //   3. otherwise → genuinely orphaned, mark failed
            //
            // A "leave it alone" decision means: do NOT overwrite the on-disk
            // state. The owning process will continue updating it and the UI
            // will see fresh state on the next refresh tick.
            let myPID = ProcessInfo.processInfo.processIdentifier
            if let pid = j.ownerPID, pid != myPID {
                // kill(pid, 0) returns 0 if the process exists.
                let alive = (kill(pid, 0) == 0)
                if alive {
                    normalized.append(j)
                    continue
                }
            }
            if let hb = j.lastHeartbeatAt, Date().timeIntervalSince(hb) < 300 {
                normalized.append(j)
                continue
            }
            // Auth-limit-paused jobs are DELIBERATELY parked, not orphaned: the
            // orchestrator run loop exits by design when a worker hits the
            // monthly limit, so the owner PID is gone and there is no
            // heartbeat. Killing it here as failed would destroy the resume
            // affordance on the very next app restart. Preserve the paused
            // state so resume-on-current-account and sign-in auto-resume can
            // still re-engage it.
            if j.status == .waiting && j.pausedReason == .authLimitHit {
                normalized.append(j)
                continue
            }
            // Orphaned - owner is dead and no recent heartbeat.
            var updated = j
            updated.status = .failed
            updated.errorMessage = "interrupted (orphaned - owner process died)"
            updated.completedAt = Date()
            for i in updated.workers.indices where !updated.workers[i].isTerminal {
                updated.workers[i].status = .failed
                updated.workers[i].errorMessage = "interrupted (orphaned - owner process died)"
            }
            try? await store.saveJob(updated)
            normalized.append(updated)
        }
        self.jobs = normalized
    }

    // MARK: - Public API

    func startSwarm(
        title: String? = nil,
        goal: String,
        template: SwarmTemplate = .singleWorker,
        rootDir: String,
        budgetUSD: Double = 5.0,
        maxParallelWorkers: Int = 3
    ) async -> AgentJob {
        // THE ONE CHOKE POINT. Every caller reaches a swarm through here:
        // RDWorker asks for 1, GoalPursuitEngine for 3, CommandV2AgentBridge for
        // up to 4, and AgentTools for whatever the model put in max_parallel,
        // which was unbounded. Clamping at each call site would be four places
        // to forget, and the one that was forgotten is the one the model drives.
        let effectiveWorkers = SessionConcurrency.clamp(maxParallelWorkers)

        // Materialize the worker DAG.
        let workers = SwarmPlanFactory.expand(template: template, goal: goal, rootDir: rootDir)
        let job = AgentJob(
            title: title ?? "swarm: \(template.rawValue)",
            goal: goal,
            budgetUSD: budgetUSD,
            maxParallelWorkers: effectiveWorkers,
            workers: workers,
            rootDir: rootDir
        )
        try? await store.saveJob(job)
        await refreshJobs()

        let orch = SwarmOrchestrator(job: job, store: store, observer: AgentServiceBridge.shared)
        orchestrators[job.id] = orch
        // Item 35 webhook seam: fire agent_job_started even if the first
        // bridge callback already arrives as .running.
        NotificationCenter.default.post(name: .gruxAgentJobLifecycle, object: nil, userInfo: [
            "jobId": job.id, "title": job.title, "status": AgentJob.Status.running.rawValue
        ])
        // Run detached - orchestrator drives its own loop until done/failed/cancelled.
        Task.detached { [orch] in
            await orch.run()
        }
        return job
    }

    // MARK: - Pause / Resume

    // Triggered when the user picks an account in the Resume sheet (or via
    // the macOS notification "Switch account & resume" action). Drives
    // AccountSwitcher to swap, then asks the orchestrator to re-spawn the
    // pausedForAuth workers. If the orchestrator instance was lost (Grux
    // restarted while the job was paused), creates a fresh one bound to the
    // persisted job state.
    func resumeWithAccountSwitch(jobId: String, targetAccountId: String) async -> AccountSwitcher.SwitchResult {
        let result = await AccountSwitcher.shared.switchToAccount(id: targetAccountId)
        switch result {
        case .switched, .alreadyActive:
            await ensureOrchestrator(jobId: jobId)
            if let orch = orchestrators[jobId] {
                await orch.resumeJob()
            }
            notifiedPausedJobIds.remove(jobId)
            await refreshJobs()
        case .failed:
            // Leave the job paused so the user can retry - no orchestrator
            // restart yet. The Resume sheet surfaces the failure message.
            break
        }
        return result
    }

    // Resume a limit-paused job on the CURRENTLY ACTIVE account, with NO
    // logout/OAuth swap. This is the missing affordance: the user re-signed in
    // (or the limit window rolled over) on the same account and just wants the
    // paused worker to continue from its last checkpoint. Mirrors
    // resumeWithAccountSwitch's success branch minus the account switch.
    //
    // Returns true if a paused job was re-engaged, false if there was nothing
    // to resume (no orchestrator could be materialized, or no paused workers).
    @discardableResult
    func resumeOnCurrentAccount(jobId: String) async -> Bool {
        await ensureOrchestrator(jobId: jobId)
        guard let orch = orchestrators[jobId] else { return false }
        notifiedPausedJobIds.remove(jobId)
        // Apply the fast state mutation, then run the loop DETACHED (same as
        // startSwarm). Awaiting resumeJob() here would block the caller (the
        // resume sheet, the sign-in observer) for the entire job duration,
        // hanging the UI with a spinner that never dismisses.
        let mutated = await orch.applyResumeMutations()
        guard mutated else { return false }
        await refreshJobs()
        Task.detached { [orch] in
            await orch.run()
        }
        return true
    }

    // Auto-resume hook: re-engage any limit-paused jobs the moment a fresh
    // sign-in is observed. Called by GruxApp's applicationDidBecomeActive /
    // sign-in observer. Refreshes the live auth status first (cheap `claude
    // auth status --json`), and if a logged-in account is present, walks every
    // waiting/authLimitHit job and resumes it in place on that account. The
    // user re-authing - on the same account or any account - is now a signal
    // that immediately re-enters the run loop, instead of being invisible.
    func reengagePausedJobsIfSignedIn() async {
        await AccountSwitcher.shared.refreshActiveStatus()
        guard AccountSwitcher.shared.liveStatus?.loggedIn == true else { return }
        await refreshJobs()
        let paused = jobs.filter { $0.status == .waiting && $0.pausedReason == .authLimitHit }
        guard !paused.isEmpty else { return }
        for job in paused {
            await resumeOnCurrentAccount(jobId: job.id)
        }
    }

    // Snooze a paused job: keep the SAME active account, just sleep the
    // orchestrator for `minutes`, then auto-resume. The Anthropic limit
    // window may have rolled over by then. If the worker hits the limit
    // again post-snooze, the orchestrator will pause it again normally.
    func snoozeJob(jobId: String, minutes: Int = 60) async {
        let fireDate = Date().addingTimeInterval(Double(minutes) * 60.0)
        snoozedUntil[jobId] = fireDate
        ensureSnoozeTimer()
        await emitInfoStep(jobId: jobId, text: "snoozed \(minutes)m - will auto-resume on the same account at \(fireDate)")
    }

    private func ensureSnoozeTimer() {
        if snoozeTimer != nil { return }
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tickSnoozeTimer() }
        }
    }

    private func tickSnoozeTimer() async {
        let now = Date()
        let due = snoozedUntil.filter { $0.value <= now }.map(\.key)
        for jobId in due {
            snoozedUntil.removeValue(forKey: jobId)
            await ensureOrchestrator(jobId: jobId)
            if let orch = orchestrators[jobId] {
                notifiedPausedJobIds.remove(jobId)
                await orch.resumeJob()
            }
        }
        if snoozedUntil.isEmpty {
            snoozeTimer?.invalidate()
            snoozeTimer = nil
        }
        await refreshJobs()
    }

    // Materialize an orchestrator for a job that's not currently running.
    // Used by both resume + snooze paths: the orchestrator instance from the
    // original run is gone if Grux restarted, so we rebuild it from the
    // persisted AgentJob state.
    private func ensureOrchestrator(jobId: String) async {
        if orchestrators[jobId] != nil { return }
        guard let job = await store.loadJob(jobId) else { return }
        let orch = SwarmOrchestrator(job: job, store: store, observer: AgentServiceBridge.shared)
        orchestrators[jobId] = orch
    }

    private func emitInfoStep(jobId: String, text: String) async {
        let step = AgentStep(kind: .info, text: text)
        await store.appendStep(jobId: jobId, step: step)
        _bridgeStepAppend(jobId, step)
    }

    // Called by the bridge when a job update arrives. If the new state is
    // "waiting / authLimitHit" and we haven't already fired the banner for
    // this paused-cycle, fire it now.
    fileprivate func maybeNotifyPaused(_ job: AgentJob) {
        guard job.status == .waiting, job.pausedReason == .authLimitHit else {
            // Job is no longer paused - clear the de-dup flag so a future
            // pause re-fires the banner.
            if notifiedPausedJobIds.contains(job.id) {
                notifiedPausedJobIds.remove(job.id)
            }
            return
        }
        if notifiedPausedJobIds.contains(job.id) { return }
        notifiedPausedJobIds.insert(job.id)

        // Best-effort account label: ask AccountSwitcher for the active
        // account's display name. May be nil on first run.
        let acctLabel = AccountSwitcher.shared.state.accounts.first(where: {
            $0.id == AccountSwitcher.shared.state.activeAccountId
        })?.label
        AccountSwitcher.shared.recordLimitHitOnActiveAccount()

        NotificationManager.shared.sendAgentPaused(
            jobId: job.id, title: job.title, accountLabel: acctLabel
        )

        // Transient orb hint so the desktop surface acknowledges the pause
        // even if the user dismissed the notification banner.
        OrbHintBus.shared.show(
            message: "AGENT PAUSED · TAP TO RESUME",
            state: .thinking,
            duration: 6.0
        )

        // Fan out to the iPhone companion via PhoneChatBridge.
        PhoneReceiverService.shared.notifyAgentPaused(
            jobId: job.id, title: job.title, accountLabel: acctLabel
        )
    }

    func cancel(jobId: String) async {
        guard let orch = orchestrators[jobId] else {
            // Not actively running - flip to cancelled in storage.
            if var j = await store.loadJob(jobId), !j.isTerminal {
                j.status = .cancelled
                j.completedAt = Date()
                try? await store.saveJob(j)
                await refreshJobs()
            }
            return
        }
        await orch.cancel()
    }

    func deleteJob(_ id: String) async {
        await store.deleteJob(id)
        orchestrators.removeValue(forKey: id)
        await refreshJobs()
    }

    // MARK: - Retry failed workers (right-click context menu)
    //
    // Reset every `.failed` worker back to `.queued`, clear the job's terminal
    // state, and re-spawn an orchestrator on the persisted job. The DAG run
    // loop in SwarmOrchestrator skips already-`.done` workers, so this picks
    // up exactly where the failed branch died.
    func retryFailedWorkers(jobId: String) async {
        guard var job = await store.loadJob(jobId) else { return }
        let failedCount = job.workers.filter { $0.status == .failed }.count
        guard failedCount > 0 else { return }
        for i in job.workers.indices where job.workers[i].status == .failed {
            job.workers[i].status = .queued
            job.workers[i].errorMessage = nil
            job.workers[i].startedAt = nil
            job.workers[i].completedAt = nil
            job.workers[i].lastResultText = nil
            // spentUSD stays cumulative - costs already incurred are real.
        }
        if job.isTerminal {
            job.status = .queued
            job.errorMessage = nil
            job.completedAt = nil
        }
        job.lastHeartbeatAt = Date()
        try? await store.saveJob(job)
        await refreshJobs()

        // Drop any stale orchestrator (the previous run is dead) and spawn fresh.
        orchestrators.removeValue(forKey: jobId)
        let orch = SwarmOrchestrator(job: job, store: store, observer: AgentServiceBridge.shared)
        orchestrators[jobId] = orch
        Task.detached { [orch] in
            await orch.run()
        }
    }

    // MARK: - Finder reveal (right-click context menu)

    // Path on disk where AgentStore persists this job's artifacts. Mirror of
    // AgentStore.jobDir(_:) without exposing the store itself.
    nonisolated func jobFolderURL(jobId: String) -> URL {
        Persistence.agentsDir.appendingPathComponent(jobId, isDirectory: true)
    }

    // Reveals the on-disk job folder (`~/Library/Application Support/Grux/agents/<id>/`)
    // in Finder, with the directory itself selected. Falls back to opening the
    // parent agentsDir if the per-job folder hasn't been created yet (e.g.,
    // job is still queued before first heartbeat).
    func revealJobFolderInFinder(jobId: String) {
        let url = jobFolderURL(jobId: jobId)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(Persistence.agentsDir)
        }
    }

    // Reveals the project root the swarm is operating on (the per-worker cwd
    // root from AgentJob.rootDir). For most jobs this is the cloned repo /
    // working tree where workers are writing code or content.
    func revealProjectRootInFinder(jobId: String) async {
        guard let job = await store.loadJob(jobId) else { return }
        let url = URL(fileURLWithPath: job.rootDir)
        await MainActor.run {
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                // Fallback: rootDir doesn't exist anymore (cleaned up); show
                // the parent so the user sees the closest still-valid location.
                let parent = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: parent.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([parent])
                }
            }
        }
    }

    func loadSteps(jobId: String, limit: Int = 200) async -> [AgentStep] {
        await store.loadSteps(jobId: jobId, limit: limit)
    }

    func loadWorkerSteps(jobId: String, workerId: String, limit: Int = 200) async -> [AgentStep] {
        await store.loadWorkerSteps(jobId: jobId, workerId: workerId, limit: limit)
    }

    func refreshJobs() async {
        let list = await store.listJobs()
        await MainActor.run { self.jobs = list }
    }

    // MARK: - Bridge callbacks (called by AgentServiceBridge actor below)

    // Tracks each job's previously-known status so we can fire a one-shot
    // chat CTA the moment the orchestrator transitions us into a terminal
    // state. Without this, the chat agent's "I'll pull the brief once it's
    // done" promise dies - the job ends, but Grux's chat side has no clue
    // it should re-engage. The user ends up asking "did you finish?"
    // repeatedly and the chat response lags reality by minutes.
    private var lastKnownStatus: [String: AgentJob.Status] = [:]

    func _bridgeJobUpdate(_ job: AgentJob) {
        let previousStatus = jobs.first(where: { $0.id == job.id })?.status ?? lastKnownStatus[job.id]
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
        } else {
            jobs.insert(job, at: 0)
        }
        lastKnownStatus[job.id] = job.status
        maybeNotifyPaused(job)
        // Item 35 webhook seam: broadcast status transitions (started/done/
        // failed/cancelled). Dedupe on previousStatus so bursty orchestrator
        // callbacks don't re-fire the same lifecycle event.
        if previousStatus != job.status {
            var info: [String: Any] = [
                "jobId": job.id,
                "title": job.title,
                "status": job.status.rawValue
            ]
            if let err = job.errorMessage { info["errorMessage"] = err }
            NotificationCenter.default.post(name: .gruxAgentJobLifecycle, object: nil, userInfo: info)
        }
        // Chat-completion nudge (empire-dash): on a terminal transition, inject
        // a chat message so the assistant re-engages with the deliverable
        // instead of going silent.
        if previousStatus != job.status, job.isTerminal {
            notifyChatOfJobCompletion(job)
        }
    }

    // When a swarm job finishes, find any obvious deliverable on disk
    // (concept-brief / brief / plan / research / summary .md) inside the
    // job's rootDir and inject a synthetic chat message that nudges the
    // assistant to read the file and post a one-line greenlight CTA.
    // Failed/cancelled jobs get a different nudge so the assistant surfaces
    // the failure instead of going silent. Idempotent: scoped to the
    // status-transition above, so it can't re-fire on subsequent
    // jobs-list refreshes.
    private func notifyChatOfJobCompletion(_ job: AgentJob) {
        let rootDir = (job.rootDir as NSString).expandingTildeInPath
        let candidates = ["concept-brief.md", "brief.md", "plan.md", "research.md", "summary.md", "spec.md"]
        var briefPath: String? = nil
        for name in candidates {
            let p = (rootDir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p) {
                briefPath = p
                break
            }
        }
        // Wording matters. The original passive form ("(system event...) Read
        // that file...") got drowned out the one time it raced with the user
        // typing a new request: chat hop 1 saw both inputs in the same turn
        // and went with theirs, skipping the job's walkthrough. The
        // ⚠️/HANDLE-FIRST/REQUIRED-ACTION framing reliably wins that race -
        // verified 2026-04-30 06:49:51 (immediate fs_read on the brief).
        let injection: String
        switch job.status {
        case .done:
            if let p = briefPath {
                injection = """
                ⚠️ UNPROCESSED COMPLETED BRIEF - HANDLE THIS FIRST, before any other tool call this turn. If anything else arrived in this turn, defer it; come back to it on the next turn.

                The agent_swarm '\(job.title)' (\(job.id.prefix(8))) just finished - status=done, spent=$\(String(format: "%.4f", job.spentUSD)) of $\(String(format: "%.2f", job.budgetUSD)). Deliverable: \(p)

                REQUIRED ACTION:
                1) fs_read the file above.
                2) Post a 4-6 line walkthrough covering: app/output name, one-line pitch (or summary), 2-3 core points in one sentence each, and the unit-economics headline (LTV/infra ratio + did all 6 greenlight checks pass).
                3) End with ONE clear CTA line asking what's next (e.g. "greenlight to scaffold + ship-ios-app", "iterate", or "kill it").

                Do NOT dispatch another swarm. Do NOT call agent_swarm_start. Do NOT ask follow-up questions before the CTA. The brief is on disk - just walk through it.
                """
            } else {
                injection = """
                ⚠️ UNPROCESSED COMPLETED SWARM - HANDLE THIS FIRST, before any other tool call this turn.

                Job '\(job.title)' (\(job.id.prefix(8))) finished status=done, spent=$\(String(format: "%.4f", job.spentUSD)) of $\(String(format: "%.2f", job.budgetUSD)) but no expected deliverable file (concept-brief.md / plan.md / brief.md / research.md / summary.md / spec.md) was found under \(rootDir).

                REQUIRED ACTION: run `ls \(rootDir)` via shell, find what actually landed (the swarm may have used a non-standard filename), fs_read it, summarize in 4-6 lines, end with a one-line CTA. Don't dispatch another swarm.
                """
            }
        case .failed:
            injection = """
            ⚠️ UNPROCESSED FAILED SWARM - HANDLE THIS FIRST, before any other tool call this turn.

            Job '\(job.title)' (\(job.id.prefix(8))) ended status=failed. Error: \(job.errorMessage ?? "no message recorded")

            REQUIRED ACTION: surface the error to me in one line, propose the next move (retry / change scope / abandon), and wait for me to pick. Do NOT auto-retry.
            """
        case .cancelled:
            injection = """
            ⚠️ UNPROCESSED CANCELLED SWARM - HANDLE THIS FIRST, before any other tool call this turn.

            Job '\(job.title)' (\(job.id.prefix(8))) was cancelled. Confirm to me in one line that you're not still tracking it, and ask whether I want to re-fire with a tweaked prompt or move on.
            """
        default:
            return
        }
        let injectFile = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("inject-chat.txt")
        do {
            try injection.write(to: injectFile, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort: if the inject channel is broken (rare), the
            // chat just stays silent like before, not a regression.
        }
    }

    func _bridgeStepAppend(_ jobId: String, _ step: AgentStep) {
        // Cap in-memory tail to last 200 per job to keep UI responsive.
        var arr = stepsByJob[jobId] ?? []
        arr.append(step)
        if arr.count > 400 { arr = Array(arr.suffix(200)) }
        stepsByJob[jobId] = arr
    }
}

// Bridge that conforms to SwarmOrchestratorObserver (which must be Sendable
// + actor-friendly) and forwards to AgentService on the main actor.
public final class AgentServiceBridge: SwarmOrchestratorObserver, @unchecked Sendable {
    public static let shared = AgentServiceBridge()
    private init() {}

    public func orchestratorJobDidUpdate(_ job: AgentJob) async {
        await MainActor.run { AgentService.shared._bridgeJobUpdate(job) }
    }

    public func orchestrator(_ jobId: String, didAppend step: AgentStep) async {
        await MainActor.run { AgentService.shared._bridgeStepAppend(jobId, step) }
    }
}
