import Foundation
import Combine
import GruxAgentCore

// The Foundry's cycle conductor (Phase B/C integration glue). One activate()
// call at startup wires the four seams the builders left open:
//   1. GruxUpdater rollback keeper (crash heartbeat + resume 24h watch).
//   2. FoundryApprovalStore.onApproved -> GruxUpdater.selfInstall, resolving
//      the upgrade worktree from the run handle the build pass recorded.
//   3. FoundryGovernor.runCycle -> the actual sense -> build -> verify ->
//      land pass, then the governor's 60s scheduler tick starts.
//   4. The Self-Upgrade tab's Accept button (FoundryDashboardModel.onAccept,
//      installed by FoundryViewBridge) gains a build kick: accepting a card
//      now starts the RDWorker rail instead of just flipping status.
//
// "Grux, upgrade yourself" routes here too, via the foundry_upgrade_cycle
// chat tool -> triggerManualCycle() -> FoundryGovernor.triggerManual().
//
// All money figures are ESTIMATED API-equivalent spend; the engine runs on
// subscriptions and nothing here bills dollars.
@MainActor
final class FoundryEngine: ObservableObject {

    static let shared = FoundryEngine()

    // Run handles by proposal id, so the approval hook and the escalation
    // seam can find the upgrade worktree after the build pass finished.
    // Persisted (with the escalated-job map) so an approval granted after
    // a relaunch never hits "install parked" with the worktree orphaned.
    private(set) var handles: [UUID: RDRunHandle] = [:]
    // Escalated swarm jobs in flight: AgentJob id -> proposal id. Terminal
    // job states route back onto the verify rail via the lifecycle
    // notification AgentService posts.
    private(set) var escalatedJobs: [String: UUID] = [:]
    // Proposals currently on the rail; guards double-kicks from a cycle
    // overlapping a manual Accept.
    private var building: Set<UUID> = []
    private var activated = false
    private var lifecycleObserver: NSObjectProtocol?

    // MARK: - Persisted engine state

    private struct EngineState: Codable {
        var handles: [UUID: RDRunHandle] = [:]
        var escalatedJobs: [String: UUID] = [:]
    }

    nonisolated static var engineStateURL: URL {
        FoundryPaths.dir.appendingPathComponent("engine-state.json")
    }

    init() {
        let state = Persistence.load(EngineState.self, from: Self.engineStateURL, fallback: EngineState())
        handles = state.handles
        escalatedJobs = state.escalatedJobs
    }

    private func persistEngineState() {
        Persistence.save(
            EngineState(handles: handles, escalatedJobs: escalatedJobs),
            to: Self.engineStateURL
        )
    }

    // MARK: - Repo root resolution

    // The Mac app installs to /Applications, so the source checkout has to be
    // named, not assumed: nobody's clone is anywhere in particular. GRUX_REPO_ROOT
    // is the one answer, and it is validated (Package.swift + .git present) so a
    // stale or mistyped value fails here rather than halfway through a build.
    // Nil means self-upgrade has no source to work from, which callers report.
    nonisolated static func resolveRepoRoot() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["GRUX_REPO_ROOT"], !path.isEmpty else {
            return nil
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: root.appendingPathComponent("Grux-Mac/Package.swift").path),
              fm.fileExists(atPath: root.appendingPathComponent(".git").path)
        else { return nil }
        return root
    }

    // MARK: - Activation (GruxApp launch path)

    func activate() {
        guard !activated else { return }
        activated = true

        // A persisted handle can outlive its worktree: a run interrupted at
        // the session limit, or a sibling cleanup that removed the upgrade
        // checkout out from under a still-open handle, leaves the proposal
        // stuck in .building forever (the worktree-vanished case the
        // build/verify rescue paths never see). Sweep stale handles on launch
        // and reject those proposals with a visible reason.
        Task { @MainActor [weak self] in await self?.reconcileStaleHandles() }

        // Settled-watch cleanup: once a build's 24h watch settles (kept OR
        // rolled back) the worktree is no longer needed; complete() removes
        // it and keeps the upgrade/ branch (history for kept builds,
        // forensics for reverted ones), so installs never leak checkouts
        // under the sibling .worktrees/ directory. Installed BEFORE
        // activate() because resumeWatchIfPending can settle immediately.
        GruxUpdater.shared.onWatchSettled = { [weak self] proposalId, _ in
            self?.cleanupAfterWatch(proposalId: proposalId)
        }

        // Rollback keeper: crash detection heartbeat, clean-shutdown marker,
        // and resuming any 24h pending-watch that survived a relaunch.
        GruxUpdater.shared.activate()

        // Escalated (M/L) swarm jobs: AgentService posts a lifecycle
        // notification on every job status change; terminal states route
        // the proposal back onto the verify rail (done) or reject it
        // (failed/cancelled) so escalations can actually land.
        if lifecycleObserver == nil {
            lifecycleObserver = NotificationCenter.default.addObserver(
                forName: .gruxAgentJobLifecycle, object: nil, queue: .main
            ) { [weak self] note in
                guard let jobId = note.userInfo?["jobId"] as? String,
                      let statusRaw = note.userInfo?["status"] as? String else { return }
                Task { @MainActor [weak self] in
                    await self?.escalatedJobChanged(jobId: jobId, statusRaw: statusRaw)
                }
            }
        }

        // Approval -> install. The worktree resolves from the handle the
        // build pass recorded; a missing handle parks the proposal and logs.
        FoundryApprovalStore.shared.onApproved = { [weak self] _, proposal in
            self?.install(proposalId: proposal.id)
        }

        // Governor decides WHEN; the engine owns the cycle itself.
        FoundryGovernor.shared.runCycle = { [weak self] pass in
            await self?.runCycle(pass)
        }
        FoundryGovernor.shared.start()

        // Accept on a Self-Upgrade card also kicks the build rail. Wrap the
        // hook FoundryViewBridge installed (transition + audit) rather than
        // replacing it, so the audit trail never regresses.
        let prior = FoundryDashboardModel.shared.onAccept
        FoundryDashboardModel.shared.onAccept = { [weak self] card in
            prior?(card)
            guard let id = UUID(uuidString: card.id) else { return }
            Task { @MainActor [weak self] in
                await self?.buildAccepted(id: id)
            }
        }
    }

    // MARK: - Manual trigger ("Grux, upgrade yourself")

    // Kicks a manual cycle through the governor (which still honors the
    // session-limit yield and the one-cycle-at-a-time rule) and returns a
    // status line the chat tool can speak back.
    func triggerManualCycle() -> String {
        switch FoundryGovernor.shared.phase {
        case .running(let pass):
            return "already running a \(pass.displayName.lowercased()), current spend \(FoundryGovernor.shared.currentEstimatedCostLabel)"
        case .idle, .yielded:
            FoundryGovernor.shared.triggerManual()
            switch FoundryGovernor.shared.phase {
            case .running:
                let pending = ProposalStore.shared.proposals.filter { $0.status == .accepted }.count
                return "started: manual upgrade cycle (sense pass + \(pending) accepted proposal\(pending == 1 ? "" : "s") on the build rail)"
            case .yielded(let reason):
                return "yielded: \(reason)"
            case .idle:
                return "could not start a cycle right now"
            }
        }
    }

    // MARK: - The cycle (sense -> build -> verify -> land)

    func runCycle(_ pass: FoundryCyclePass) async {
        WakeLog.shared.log("foundry: \(pass.rawValue) cycle started")

        // Sense: refresh the signal book. Synthesis into fresh proposals is
        // the ProposalEngine's job (Phase A book + later passes); this keeps
        // the evidence stream warm for the next synthesize pass.
        let report = await SignalHarvester.standard().harvest()
        FoundryTimelineStore.shared.append(FoundryTimelineEntry(
            kind: .cycle,
            title: "\(pass.displayName) ran",
            detail: "Harvested \(report.signals.count) signal\(report.signals.count == 1 ? "" : "s")"
                + (report.sourceErrors.isEmpty ? "." : "; \(report.sourceErrors.count) source error(s).")
        ))

        // Build: every accepted proposal rides the rail, one at a time.
        // Stand down mid-cycle on a session limit (the user's work comes first).
        for proposal in ProposalStore.shared.proposals where proposal.status == .accepted {
            let limited = FoundryGovernorDecision.sessionLimited(
                state: AccountSwitcher.shared.state,
                now: Date(),
                cooldownHours: FoundryGovernor.shared.config.limitCooldownHours
            )
            if limited {
                WakeLog.shared.log("foundry: cycle standing down (session limit)")
                break
            }
            // The governor flips to .yielded when recordUsage crosses the
            // hard token cap (or a mid-cycle yield condition appears): stop
            // filing new builds immediately.
            if case .yielded(let reason) = FoundryGovernor.shared.phase {
                WakeLog.shared.log("foundry: cycle standing down (\(reason))")
                break
            }
            await buildAndVerify(proposal)
        }
        WakeLog.shared.log("foundry: \(pass.rawValue) cycle finished")
    }

    // Accept-card kick: build a single just-accepted proposal.
    func buildAccepted(id: UUID) async {
        guard let proposal = ProposalStore.shared.proposal(id: id),
              proposal.status == .accepted else { return }
        await buildAndVerify(proposal)
    }

    // MARK: - Build rail (RDWorker -> RDVerifier -> approval/install)

    func buildAndVerify(_ proposal: UpgradeProposal) async {
        guard !building.contains(proposal.id) else { return }
        guard let repoRoot = Self.resolveRepoRoot() else {
            WakeLog.shared.log("foundry: no repo root found (set GRUX_REPO_ROOT); skipping build of '\(proposal.title)'")
            return
        }
        building.insert(proposal.id)
        defer { building.remove(proposal.id) }

        let worker = RDWorker(config: .init(repoRoot: repoRoot))
        let (outcome, handle) = await worker.run(proposal)
        if let handle {
            handles[proposal.id] = handle
            persistEngineState()
        }

        switch outcome {
        case .success:
            guard let handle else { return }
            await verifyAndRoute(proposal: proposal, handle: handle)
        case .escalated(let jobId):
            // The SwarmOrchestrator owns it now; it surfaces in the Agents
            // tab and the worktree handle stays recorded. The lifecycle
            // observer picks the job back up at its terminal state.
            escalatedJobs[jobId] = proposal.id
            persistEngineState()
            WakeLog.shared.log("foundry: '\(proposal.title)' escalated to swarm job \(jobId)")
        case .pausedForLimit:
            WakeLog.shared.log("foundry: '\(proposal.title)' paused on usage limit")
            await rejectStrandedBuild(
                proposal: proposal,
                detail: "Paused on Anthropic usage limit before verify. Re-propose after an account swap."
            )
        case .stuck(let detail):
            WakeLog.shared.log("foundry: '\(proposal.title)' stuck: \(detail)")
            await rejectStrandedBuild(
                proposal: proposal,
                detail: "Build watchdog stopped a stalled session: \(detail)"
            )
        case .failed(let message):
            WakeLog.shared.log("foundry: '\(proposal.title)' build failed: \(message)")
            await rejectStrandedBuild(
                proposal: proposal,
                detail: "Build failed: \(message)"
            )
        }
    }

    // A non-success headless build (paused / stuck / failed) left the proposal
    // in .building, whose ONLY legal next moves are .verifying or .rejected.
    // Neither fired before this fix, so the proposal sat in .building forever
    // and the Self-Upgrade card read ACCEPTED with no progress, error, or
    // retry. Mirror the failed-verify recovery: transition to .rejected (the
    // legal escape) with a visible reason, and abandon the worktree/branch so a
    // future proposal files fresh. The card now reads a clear REJECTED with the
    // cause instead of a silent one-way door.
    // Launch-time sweep: any handle whose worktree no longer exists on disk
    // cannot ever complete, so its proposal is stranded. Reject those (the
    // legal escape from .building / .verifying) and drop the dead handle.
    func reconcileStaleHandles() async {
        let fm = FileManager.default
        for (id, handle) in handles {
            guard !fm.fileExists(atPath: handle.worktreePath) else { continue }
            handles.removeValue(forKey: id)
            persistEngineState()
            guard let proposal = ProposalStore.shared.proposal(id: id),
                  proposal.status == .building || proposal.status == .verifying else { continue }
            if let updated = ProposalStore.shared.transition(id: id, to: .rejected) {
                FoundryViewBridge.mirror(
                    action: .rejected,
                    proposal: updated,
                    detail: "Worktree no longer on disk (run interrupted or checkout removed). Re-file to retry."
                )
            }
        }
    }

    private func rejectStrandedBuild(proposal: UpgradeProposal, detail: String) async {
        if let updated = ProposalStore.shared.transition(id: proposal.id, to: .rejected) {
            FoundryViewBridge.mirror(action: .rejected, proposal: updated, detail: detail)
        }
        if let handle = handles.removeValue(forKey: proposal.id) {
            persistEngineState()
            await RDWorker(config: .init(repoRoot: handle.repoRoot)).abandon(handle)
        }
    }

    // Shared verify pipeline: headless successes come here directly, and
    // escalated swarm jobs come here when their AgentJob reaches .done.
    private func verifyAndRoute(proposal: UpgradeProposal, handle: RDRunHandle) async {
        let verifier = RDVerifier.standard(
            baseline: RDBaselineStore.shared.baseline,
            baseRef: handle.baseRef ?? "main"
        )
        let report = await verifier.verify(
            proposal: proposal,
            worktreeRoot: URL(fileURLWithPath: handle.worktreePath)
        )
        RDVerifier.attach(report, proposalStore: .shared, verificationStore: .shared)
        if report.passed {
            routePassedVerify(proposalId: proposal.id)
        } else {
            // Failed verify: reject, demote-track via the ledger, keep
            // the worktree on disk for forensics.
            ProposalStore.shared.transition(id: proposal.id, to: .rejected)
            if let fresh = ProposalStore.shared.proposal(id: proposal.id) {
                FoundryViewBridge.mirror(
                    action: .rejected,
                    proposal: fresh,
                    detail: "Verify failed: \(report.summaryLine)"
                )
            }
        }
    }

    // MARK: - Escalated swarm jobs (terminal-state routing)

    func escalatedJobChanged(jobId: String, statusRaw: String) async {
        guard let proposalId = escalatedJobs[jobId],
              let status = AgentJob.Status(rawValue: statusRaw) else { return }
        switch status {
        case .done:
            escalatedJobs.removeValue(forKey: jobId)
            persistEngineState()
            guard let proposal = ProposalStore.shared.proposal(id: proposalId),
                  let handle = handles[proposalId] else {
                WakeLog.shared.log("foundry: swarm job \(jobId) done but proposal/handle missing; cannot verify")
                // The handle was lost across relaunch, so the worktree can't be
                // verified. Don't let the proposal evaporate in .building: move
                // it to .rejected (the legal escape) with a visible reason so
                // the card stops reading ACCEPTED forever and the user can
                // re-propose. Worktree cleanup is best-effort and skipped here
                // since the handle is exactly what's missing.
                if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
                    FoundryViewBridge.mirror(
                        action: .rejected,
                        proposal: updated,
                        detail: "Swarm job \(jobId) finished but its worktree handle was lost across a relaunch; nothing to verify. Re-propose to rebuild."
                    )
                }
                return
            }
            ProposalStore.shared.transition(id: proposalId, to: .verifying)
            WakeLog.shared.log("foundry: swarm job \(jobId) done; verifying '\(proposal.title)'")
            await verifyAndRoute(proposal: proposal, handle: handle)
        case .failed, .cancelled:
            escalatedJobs.removeValue(forKey: jobId)
            persistEngineState()
            if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
                FoundryViewBridge.mirror(
                    action: .rejected,
                    proposal: updated,
                    detail: "Escalated swarm job \(jobId) ended \(statusRaw); nothing to verify."
                )
            }
            // Nothing verified landed on the branch: abandon removes the
            // worktree AND the upgrade/ branch (a retry files fresh).
            if let handle = handles.removeValue(forKey: proposalId) {
                persistEngineState()
                await RDWorker(config: .init(repoRoot: handle.repoRoot)).abandon(handle)
            }
        case .queued, .running, .waiting, .paused:
            break
        }
    }

    // MARK: - Worktree cleanup after a settled watch

    private func cleanupAfterWatch(proposalId: UUID) {
        guard let handle = handles.removeValue(forKey: proposalId) else { return }
        persistEngineState()
        Task { @MainActor in
            // complete(): worktree removed, upgrade/ branch kept (history
            // for kept builds, forensics for reverted ones).
            await RDWorker(config: .init(repoRoot: handle.repoRoot)).complete(handle)
        }
    }

    // Tier routing after a green verify: Auto-Land installs straight behind
    // the rollback keeper; everything else files a one-tap approval card
    // (Mac panel + phone over the 0x40 channel). Protected never installs.
    //
    // The gate consults the EARNED TrustLedger tier at decision time, per
    // the ledger's documented contract (min(earned, tierRequired)): a
    // proposal stamped tierRequired=autoLand never self-installs until the
    // (lane, domain) pair has actually climbed the ladder, and a mid-build
    // demotion (rollback / two rejections) routes the proposal back to a
    // manual approval card instead of honoring the frozen field.
    nonisolated static func shouldAutoLand(earnedTier: TrustTier, proposal: UpgradeProposal) -> Bool {
        let effective = min(earnedTier, proposal.tierRequired)
        return effective >= .autoLand && proposal.riskClass != .protected
    }

    private func routePassedVerify(proposalId: UUID) {
        guard let stored = ProposalStore.shared.proposal(id: proposalId) else { return }
        // Defensive re-pin: protected zones never auto-land, even if a
        // record on disk predates the pinning rules or was hand-edited.
        let proposal = TrustLedger.applyProtectedPinning(to: stored)
        let earned = TrustLedger.shared.tier(lane: proposal.lane, domain: proposal.domain)
        if Self.shouldAutoLand(earnedTier: earned, proposal: proposal) {
            install(proposalId: proposal.id)
        } else {
            FoundryApprovalStore.shared.requestApproval(for: proposal)
        }
    }

    // MARK: - Install (approval approved, or Tier 2 auto-land)

    func install(proposalId: UUID) {
        guard let proposal = ProposalStore.shared.proposal(id: proposalId) else { return }
        guard let handle = handles[proposalId] else {
            WakeLog.shared.log("foundry: no run handle for '\(proposal.title)'; cannot resolve worktree, install parked")
            // The approval was already consumed but the worktree handle is
            // gone (lost across relaunch). Don't strand the proposal in
            // .verifying limbo with only a log line: reject it (the legal
            // escape from .verifying) with a visible reason so the user knows
            // the green-verified upgrade did NOT land and can re-propose to
            // rebuild a fresh worktree.
            if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
                FoundryViewBridge.mirror(
                    action: .rejected,
                    proposal: updated,
                    detail: "Install could not run: the verified worktree handle was lost across a relaunch. Re-propose to rebuild and re-verify."
                )
            }
            return
        }
        // Green-land gate, run OFF the main thread so the multi-minute build
        // never freezes the UI: re-prove this exact worktree builds green
        // right now, then hop back to @MainActor to land it. If the breaker is
        // already paused, refuse up front without spending a build.
        if GruxUpdater.shared.isAutoLandPaused() {
            WakeLog.shared.log("foundry: install refused for '\(proposal.title)': auto-land paused")
            if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
                FoundryViewBridge.mirror(
                    action: .rejected,
                    proposal: updated,
                    detail: "Install refused: auto-land is paused after a crash loop. Clear the pause to resume."
                )
            }
            return
        }
        let worktreeURL = URL(fileURLWithPath: handle.worktreePath)
        Task.detached(priority: .utility) {
            let green = GruxUpdater.shared.verifyBuildsGreen(worktree: worktreeURL)
            await MainActor.run {
                guard green.ok else {
                    WakeLog.shared.log("foundry: green-land gate REFUSED '\(proposal.title)': \(green.reason)")
                    if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
                        FoundryViewBridge.mirror(
                            action: .rejected,
                            proposal: updated,
                            detail: "Worktree did not build green at install time: \(green.reason) Re-propose to rebuild and re-verify."
                        )
                    }
                    return
                }
                do {
                    try GruxUpdater.shared.selfInstall(
                        fromWorktree: worktreeURL,
                        proposal: proposal,
                        alreadyVerifiedGreen: true
                    )
                } catch {
                    WakeLog.shared.log("foundry: selfInstall failed for '\(proposal.title)': \(error)")
                    // selfInstall threw: the upgrade did not land. Same dead-end
                    // class as a missing handle. Reject with the error surfaced
                    // so the card reflects the failure instead of silently
                    // sitting in .verifying.
                    if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
                        FoundryViewBridge.mirror(
                            action: .rejected,
                            proposal: updated,
                            detail: "Self-install failed: \(error.localizedDescription). Re-propose to rebuild and re-verify."
                        )
                    }
                }
            }
        }
    }

    // MARK: - Status line (chat tool readback)

    func statusLine() -> String {
        let proposals = ProposalStore.shared.proposals
        let counts = Dictionary(grouping: proposals, by: \.status).mapValues(\.count)
        let pendingApprovals = FoundryApprovalStore.shared.pending.count
        var parts: [String] = []
        switch FoundryGovernor.shared.phase {
        case .idle: parts.append("governor idle")
        case .running(let pass): parts.append("running \(pass.displayName.lowercased()), spend \(FoundryGovernor.shared.currentEstimatedCostLabel)")
        case .yielded(let reason): parts.append("yielded (\(reason))")
        }
        let order: [ProposalStatus] = [.proposed, .accepted, .building, .verifying, .landed, .rejected, .rolledBack]
        let summary = order.compactMap { status -> String? in
            guard let n = counts[status], n > 0 else { return nil }
            return "\(n) \(status.rawValue)"
        }.joined(separator: ", ")
        parts.append(summary.isEmpty ? "no proposals yet" : summary)
        if pendingApprovals > 0 {
            parts.append("\(pendingApprovals) install approval\(pendingApprovals == 1 ? "" : "s") waiting")
        }
        return parts.joined(separator: "; ")
    }
}
