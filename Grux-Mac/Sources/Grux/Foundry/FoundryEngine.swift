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
    // Published, with `building`, so Self-Upgrade's cards redraw the moment a
    // build leaves the rail (wave 13 round 2: "Waiting to build" outlived it).
    @Published private(set) var escalatedJobs: [String: UUID] = [:]
    // Proposals currently on the rail; guards double-kicks from a cycle
    // overlapping a manual Accept.
    @Published private var building: Set<UUID> = []
    private var activated = false
    private var lifecycleObserver: NSObjectProtocol?
    private var jobsWatch: AnyCancellable?

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
    // is the first answer, and it is validated (Package.swift + .git present) so a
    // stale or mistyped value fails here rather than halfway through a build.
    //
    // It was the ONLY answer, and that made Build it dead on arrival: a GUI launch
    // from /Applications carries no shell environment, so the variable is never
    // set for the app a person actually clicks. build.sh had already recorded the
    // checkout it installed from in ~/.grux/source.json for Optimize Grux's work
    // orders, so that file is the fallback, validated the same way. Nil means
    // self-upgrade has no source to work from, which the card now says.
    nonisolated static func resolveRepoRoot() -> URL? {
        resolveRepoRoot(environment: ProcessInfo.processInfo.environment, sourceFile: recordedSourceFile)
    }

    /// The file build.sh writes; one definition shared with WorkOrderContext.
    nonisolated static var recordedSourceFile: URL { WorkOrderContext.sourceFile }

    nonisolated static func resolveRepoRoot(environment: [String: String], sourceFile: URL) -> URL? {
        if let path = environment["GRUX_REPO_ROOT"], !path.isEmpty,
           let root = validatedCheckout(at: path) {
            return root
        }
        guard let data = try? Data(contentsOf: sourceFile),
              let source = try? JSONDecoder().decode(WorkOrderSource.self, from: data)
        else { return nil }
        return validatedCheckout(at: source.path)
    }

    // Accepts the repo root or its Grux-Mac package folder: build.sh runs
    // from Grux-Mac and records that folder, so the root is one level up.
    nonisolated static func validatedCheckout(at path: String) -> URL? {
        let fm = FileManager.default
        let given = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let candidates = given.lastPathComponent == "Grux-Mac"
            ? [given.deletingLastPathComponent(), given]
            : [given]
        return candidates.first { root in
            fm.fileExists(atPath: root.appendingPathComponent("Grux-Mac/Package.swift").path)
                && fm.fileExists(atPath: root.appendingPathComponent(".git").path)
        }
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
        // A job that ended while Grux was not running posts no notification
        // (restore marks an orphan failed and saves it), so the job list is
        // watched too: any escalation whose job is seen ended is routed the
        // same way. escalatedJobChanged drops the entry first, so a job seen
        // both ways routes once.
        if jobsWatch == nil {
            jobsWatch = AgentService.shared.$jobs.sink { [weak self] jobs in
                let statuses = Dictionary(jobs.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for settled in Self.settledEscalations(self.escalatedJobs, jobs: statuses) {
                        await self.escalatedJobChanged(jobId: settled.jobId, statusRaw: settled.status)
                    }
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
    // "Grux, upgrade yourself" with self-upgrade off used to answer
    // "started" while nothing ran: the engine is only activated when the
    // setting is on, so the governor had no cycle to run. Say so instead.
    nonisolated static func manualCycleRefusal(foundryEnabled: Bool) -> String? {
        foundryEnabled ? nil : "not started: self-upgrade is off. Turn it on in Self-Upgrade (or Settings), then ask again."
    }

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

        // Sense: refresh the signal book, then synthesize proposals from it.
        let report = await SignalHarvester.standard().harvest()
        // Synthesize: this pass's signals become proposals on the pane.
        let filed = SignalProposalFiler.file(from: report.signals, into: .shared)
        for proposal in filed {
            FoundryViewBridge.mirror(action: .proposed, proposal: proposal,
                                     detail: proposal.evidence.first?.display ?? proposal.estCostLabel)
        }
        FoundryTimelineStore.shared.append(FoundryTimelineEntry(
            kind: .cycle,
            title: "\(pass.displayName) ran",
            detail: SignalProposalFiler.cycleDetail(signals: report.signals.count,
                                                    sourceErrors: report.sourceErrors.count,
                                                    filed: filed.count)
        ))
        WakeLog.shared.log("foundry: \(pass.rawValue) cycle harvested \(report.signals.count) signal(s), filed \(filed.count) proposal(s)")

        // Synthesize: the signals become proposals. Before 2026-10-30 this
        // stage did not exist and the harvest above went nowhere.
        // Not on an opportunistic pass: that one runs while the person is
        // away and must stand down when they return, and a synthesis run
        // cannot be interrupted part way. Nor after the governor yielded.
        if pass != .opportunistic, case .running = FoundryGovernor.shared.phase {
            _ = await ProposalSynthesizer.refresh(sourceRoot: ProposalSynthesizer.sourceRoot(), harvested: report)
        }

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
            // One build at a time: an escalated build is still running when
            // buildAndVerify returns, so the rest wait for the next pass.
            if let hold = currentBuildHold() {
                WakeLog.shared.log("foundry: cycle standing down (\(hold))")
                break
            }
            await buildAndVerify(proposal)
        }
        WakeLog.shared.log("foundry: \(pass.rawValue) cycle finished")
    }

    // A build that cannot start because the checkout is gone used to leave
    // one line in wake.log and nothing anywhere a person looks: the proposal
    // stayed accepted and the card kept offering Build it. The proposal still
    // stays accepted, because a checkout can come back (build.sh records it
    // again), but the timeline says what happened and what to do, and the
    // card re-measures the source on every click and flips to its own
    // "cannot build here" row.
    static func noteMissingSource(for proposal: UpgradeProposal, timeline: FoundryTimelineStore? = nil) {
        (timeline ?? .shared).append(FoundryTimelineEntry(
            kind: .rejected,
            title: "Build could not start: \(proposal.title)",
            detail: "No source checkout on this Mac. Rebuild with build.sh from the source folder so Grux records where it is, or copy the handoff for your agent.",
            lane: proposal.lane.displayName,
            domain: proposal.domain.displayName
        ))
    }

    // What the Self-Upgrade card reads to say "Building now" instead of
    // offering a second Build it: the rail's in-flight set and, for an M or L
    // proposal, the swarm job that owns it.
    func isBuilding(_ id: UUID) -> Bool { building.contains(id) }

    func escalatedJobId(for id: UUID) -> String? {
        escalatedJobs.first(where: { $0.value == id })?.key
    }

    // Accept-card kick: build a single just-accepted proposal.
    func buildAccepted(id: UUID) async {
        guard let proposal = ProposalStore.shared.proposal(id: id),
              proposal.status == .accepted else { return }
        await buildAndVerify(proposal)
    }

    // MARK: - Build it, without a click

    /// What ~/.grux/fire-foundry-build asks for: a build of one proposal, or a
    /// refusal that says why in a line wake.log can carry.
    enum BuildRequest: Equatable {
        case build(UUID)
        case refuse(String)
    }

    /// The shortest id start the trigger accepts, so a stray character never builds.
    nonisolated static let buildTokenMinimum = 4

    /// Decides from plain values, in the order a person would have to clear them:
    /// self-upgrade on, a usable name, exactly one proposal, one with a build still
    /// to run and not already on the rail. Never guesses between two proposals.
    nonisolated static func resolveBuildRequest(
        token: String, proposals: [UpgradeProposal], foundryEnabled: Bool, inFlight: Set<UUID>,
        baselineMeasuring: Bool = false, hold: String? = nil
    ) -> BuildRequest {
        guard foundryEnabled else {
            return .refuse("not building: self-upgrade is off. Turn it on in Self-Upgrade (or Settings), then ask again.")
        }
        guard !baselineMeasuring else {
            return .refuse("not building: the test baseline is being measured on this Mac. Ask again when it finishes.")
        }
        let name = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard name.count >= buildTokenMinimum else {
            return .refuse("not building: name a proposal by its id (the first 8 characters are enough).")
        }
        let matches = proposals.filter { $0.id.uuidString.hasPrefix(name) }
        guard let proposal = matches.first else {
            return .refuse("not building: no proposal id starts with \(name).")
        }
        guard matches.count == 1 else {
            return .refuse("not building: \(matches.count) proposals start with \(name); give more of the id.")
        }
        guard !inFlight.contains(proposal.id) else {
            return .refuse("not building: '\(proposal.title)' is already building.")
        }
        switch proposal.status {
        case .proposed, .accepted:
            // Refused before anything is accepted, so nothing waits for a pass.
            if let hold { return .refuse(hold + " Ask again later.") }
            return .build(proposal.id)
        case .building, .verifying, .landed, .rejected, .rolledBack:
            return .refuse("not building: '\(proposal.title)' is \(proposal.status.displayName.lowercased()), with no build left to run.")
        }
    }

    enum RejectRequest: Equatable {
        case reject(UUID, reason: String)
        case refuse(String)
    }

    /// The longest reason the reject door keeps, counted after whitespace is
    /// folded: a sentence for the timeline, not a pasted log.
    nonisolated static let rejectReasonLimit = 280

    /// ~/.grux/fire-foundry-reject: the card's Reject for a Mac nobody can
    /// click on (D83). The id start comes first, the reason after it; only a
    /// proposal still waiting for a yes or no, as on the card.
    nonisolated static func resolveRejectRequest(token: String, proposals: [UpgradeProposal]) -> RejectRequest {
        let text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(text.prefix { !$0.isWhitespace }).uppercased()
        // One line in wake.log and the timeline, however the reason was typed.
        let reason = String(text.dropFirst(name.count))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard name.count >= buildTokenMinimum else {
            return .refuse("not turning down: name a proposal by its id (the first 8 characters are enough), then the reason.")
        }
        let matches = proposals.filter { $0.id.uuidString.hasPrefix(name) }
        guard let proposal = matches.first else {
            return .refuse("not turning down: no proposal id starts with \(name).")
        }
        guard matches.count == 1 else {
            return .refuse("not turning down: \(matches.count) proposals start with \(name); give more of the id.")
        }
        guard proposal.status == .proposed else {
            return .refuse("not turning down: '\(proposal.title)' is \(proposal.status.displayName.lowercased()), not waiting for a yes or no.")
        }
        guard !reason.isEmpty else {
            return .refuse("not turning down: give the reason after the id, so the timeline says why.")
        }
        guard reason.count <= rejectReasonLimit else {
            return .refuse("not turning down: keep the reason to \(rejectReasonLimit) characters or fewer (this one is \(reason.count)), so the timeline reads it whole.")
        }
        return .reject(proposal.id, reason: reason)
    }

    /// Returns the line wake.log records.
    func rejectRequested(token: String) -> String {
        switch Self.resolveRejectRequest(token: token, proposals: ProposalStore.shared.proposals) {
        case .refuse(let why):
            return why
        case .reject(let id, let reason):
            FoundryDashboardModel.shared.reject(id: id.uuidString, reason: reason)
            let after = ProposalStore.shared.proposal(id: id)
            let title = after?.title ?? id.uuidString
            return after?.status == .rejected
                ? "turned down '\(title)': \(reason)"
                : "not turning down '\(title)': the Self-Upgrade pane has not loaded it yet. Ask again in a moment."
        }
    }

    /// ~/.grux/fire-foundry-build: Build it for a Mac nobody can click on.
    /// Returns the line wake.log records.
    func buildRequested(token: String) -> String {
        let request = Self.resolveBuildRequest(
            token: token,
            proposals: ProposalStore.shared.proposals,
            foundryEnabled: AppState.shared.config.foundryEnabled,
            inFlight: Self.inFlightProposals(building: building, escalated: Self.holdingEscalations(
                escalatedJobs, jobs: Self.agentJobStatuses(), routing: activated)),
            baselineMeasuring: RDBaselineStore.shared.measuring,
            hold: currentBuildHold()
        )
        switch request {
        case .refuse(let why):
            return why
        case .build(let id):
            let title = ProposalStore.shared.proposal(id: id)?.title ?? id.uuidString
            return startBuild(id: id)
                ? "building '\(title)'"
                : "not building '\(title)': no source checkout on this Mac."
        }
    }

    /// The one path Build it takes, from the Self-Upgrade card and from
    /// ~/.grux/fire-foundry-build. A proposed card is accepted, whose hook
    /// starts the RDWorker rail; one accepted earlier whose build never ran (no
    /// source at the time, a relaunch) is kicked directly. The engine is
    /// activated first because Settings says the loop takes effect on next
    /// launch, and a person who just turned it on should not wait. False when
    /// there is no source checkout; the timeline then says so.
    @discardableResult
    func startBuild(id: UUID) -> Bool {
        guard Self.resolveRepoRoot() != nil else {
            if let proposal = ProposalStore.shared.proposal(id: id) {
                Self.noteMissingSource(for: proposal)
            }
            return false
        }
        // The card shows the hold in place of Build it; a tap that raced it is
        // not accepted into a build that cannot run (wave 13 review).
        if let hold = currentBuildHold() {
            WakeLog.shared.log("foundry: Build it: \(hold)")
            return true
        }
        activate()
        switch ProposalStore.shared.proposal(id: id)?.status {
        case .proposed:
            FoundryDashboardModel.shared.accept(id: id.uuidString)
        case .accepted:
            Task { @MainActor [weak self] in await self?.buildAccepted(id: id) }
        default:
            break
        }
        return true
    }

    // MARK: - Test baseline (F4)

    /// Measures this Mac's test baseline on the source checkout itself: the bar every
    /// upgrade's full-suite gate is graded against. Self-Upgrade's Measure on this Mac
    /// and ~/.grux/fire-foundry-measure-baseline call it. Never while an upgrade is on
    /// the build rail, and no build starts while it runs: one suite at a time per Mac.
    func measureBaseline() async -> String {
        guard let repoRoot = Self.resolveRepoRoot() else {
            return RDBaselineStore.shared.refuse("Grux cannot find its source checkout on this Mac.")
        }
        return await RDBaselineStore.shared.measure(
            repoRoot: repoRoot,
            suite: AppState.shared.config.foundrySuiteCommand ?? .swiftTest,
            canMeasure: { [building, escalatedJobs] in
                Self.canMeasureBaseline(building: building,
                                        escalatedJobs: Self.liveEscalations(escalatedJobs, jobs: Self.agentJobStatuses()))
            }
        )
    }

    // MARK: - Build rail (RDWorker -> RDVerifier -> approval/install)

    func buildAndVerify(_ proposal: UpgradeProposal) async {
        guard !building.contains(proposal.id) else { return }
        if let hold = currentBuildHold() {
            WakeLog.shared.log("foundry: '\(proposal.title)' \(hold) It stays accepted for the next pass.")
            return
        }
        guard !RDBaselineStore.shared.measuring else {
            WakeLog.shared.log("foundry: not building '\(proposal.title)' while the test baseline is being measured; it stays accepted for the next pass")
            return
        }
        guard let repoRoot = Self.resolveRepoRoot() else {
            WakeLog.shared.log("foundry: no repo root found (set GRUX_REPO_ROOT); skipping build of '\(proposal.title)'")
            Self.noteMissingSource(for: proposal)
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
        let stranded = Self.strandedProposals(
            proposals: ProposalStore.shared.proposals,
            handles: handles,
            escalated: escalatedJobs,
            inFlight: building,
            worktreeExists: { fm.fileExists(atPath: $0) }
        )
        for (id, handle) in handles where !fm.fileExists(atPath: handle.worktreePath) {
            handles.removeValue(forKey: id)
        }
        persistEngineState()
        for (id, reason) in stranded {
            if let updated = ProposalStore.shared.transition(id: id, to: .rejected) {
                FoundryViewBridge.mirror(action: .rejected, proposal: updated, detail: reason)
            }
        }

        // A proposal can also sit in .building or .verifying with no handle,
        // no escalated job and no build in this process: nothing is running for
        // it and nothing ever will. Measured 2026-10-30: 13 proposals had sat in
        // .building since 2026-06-12, each card reading "building" for months.
        // (release/3.2: the pass above already rejects these with its own
        // reason, so this one finds nothing new; kept as the second net.)
        let untracked = Self.strandedProposalIDs(
            ProposalStore.shared.proposals,
            tracked: Set(handles.keys).union(escalatedJobs.values).union(building)
        )
        for id in untracked {
            if let updated = ProposalStore.shared.transition(id: id, to: .rejected) {
                FoundryViewBridge.mirror(
                    action: .rejected,
                    proposal: updated,
                    detail: "Build interrupted with no record of where it ran. Re-file to retry."
                )
            }
        }
    }

    /// The in-flight proposals nothing is tracking: .building or .verifying,
    /// and absent from every handle, escalated job and live build.
    nonisolated static func strandedProposalIDs(_ proposals: [UpgradeProposal], tracked: Set<UUID>) -> [UUID] {
        proposals
            .filter { ($0.status == .building || $0.status == .verifying) && !tracked.contains($0.id) }
            .map(\.id)
    }

    // A proposal mid build or verify that nothing can ever finish: its
    // worktree is gone, or no handle was ever recorded for it (a run cut off
    // before the build pass returned, or engine state from another Mac).
    // Without the second case such a proposal read Building forever.
    // A build on the rail now or owned by a swarm job is never stranded.
    nonisolated static func strandedProposals(
        proposals: [UpgradeProposal],
        handles: [UUID: RDRunHandle],
        escalated: [String: UUID],
        inFlight: Set<UUID>,
        worktreeExists: (String) -> Bool
    ) -> [(id: UUID, reason: String)] {
        let owned = Set(escalated.values)
        return proposals.compactMap { p in
            guard p.status == .building || p.status == .verifying,
                  !inFlight.contains(p.id), !owned.contains(p.id) else { return nil }
            guard let handle = handles[p.id] else {
                return (p.id, "Build was cut off before Grux recorded where it was working, so it can never finish. The next self-upgrade pass files it again if the problem is still there.")
            }
            guard !worktreeExists(handle.worktreePath) else { return nil }
            return (p.id, "Worktree no longer on disk (run interrupted or checkout removed). The next self-upgrade pass files it again if the problem is still there.")
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
    // Records protected paths (which pins the proposal, one way) and, when the
    // change may not go on, rejects it with the reason. True when refused.
    private func refuseBuiltChange(_ change: BuiltChange, proposalId: UUID, branch: String) -> Bool {
        if case .protected(let paths) = change {
            ProposalStore.shared.update(id: proposalId, touchedPaths: paths)
        }
        guard let refusal = Self.builtChangeRefusal(change, branch: branch) else { return false }
        let title = ProposalStore.shared.proposal(id: proposalId)?.title ?? proposalId.uuidString
        WakeLog.shared.log("foundry: '\(title)': \(refusal)")
        if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
            FoundryViewBridge.mirror(action: .rejected, proposal: updated, detail: refusal)
        }
        return true
    }

    private func verifyAndRoute(proposal: UpgradeProposal, handle: RDRunHandle) async {
        // One suite at a time: a swarm job that finished while the baseline is
        // being measured waits for the measure before running its full suite.
        while RDBaselineStore.shared.measuring {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let verifier = RDVerifier.standard(
            baseline: RDBaselineStore.shared.baseline,
            suite: AppState.shared.config.foundrySuiteCommand ?? .swiftTest,
            suiteProblem: AppState.shared.config.foundrySuiteCommandProblem,
            baseRef: handle.baseRef ?? "main"
        )
        let report = await verifier.verify(
            proposal: proposal,
            worktreeRoot: URL(fileURLWithPath: handle.worktreePath)
        )
        RDVerifier.attach(report, proposalStore: .shared, verificationStore: .shared)
        if report.passed {
            // Grade what the build changed before it can reach approval or
            // auto-land. Recording protected paths pins the proposal (one way),
            // so every later rail sees it as protected too.
            let change = await Self.readBuiltChange(
                worktree: URL(fileURLWithPath: handle.worktreePath),
                baseRef: handle.baseRef ?? "main",
                runner: RDLiveProcessRunner()
            )
            if refuseBuiltChange(change, proposalId: proposal.id, branch: handle.branch) { return }
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

    /// What Self-Upgrade's timeline says when an escalated build ends without a build to
    /// verify. An expired Claude sign-in says so and what to do; any other failure keeps
    /// the job's own words (D26: it used to say only "ended failed; nothing to verify").
    nonisolated static func escalationFailureReason(job: AgentJob?, jobId: String, statusRaw: String) -> String {
        if let job, job.failedOnSignIn {
            return "The build could not start: Claude's sign-in on this Mac has expired. Sign in again (Claude sign-in, at the top of Now), then build it again."
        }
        var words = (job?.errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while words.hasSuffix(".") { words.removeLast() }
        guard !words.isEmpty else { return "Escalated swarm job \(jobId) ended \(statusRaw); nothing to verify." }
        return "Escalated swarm job \(jobId) ended \(statusRaw): \(words). Nothing to verify."
    }

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
            // On the rail for the verify, so no baseline measure starts under it.
            building.insert(proposalId)
            defer { building.remove(proposalId) }
            await verifyAndRoute(proposal: proposal, handle: handle)
        case .failed, .cancelled:
            escalatedJobs.removeValue(forKey: jobId)
            persistEngineState()
            if let updated = ProposalStore.shared.transition(id: proposalId, to: .rejected) {
                FoundryViewBridge.mirror(
                    action: .rejected,
                    proposal: updated,
                    detail: Self.escalationFailureReason(
                        job: AgentService.shared.jobs.first(where: { $0.id == jobId }),
                        jobId: jobId, statusRaw: statusRaw)
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

    /// Tuning's "self-upgrade, at most". Only ever lowers the earned tier,
    /// and a ceiling that does not read as a tier fails closed at propose.
    nonisolated static func cappedTier(earned: TrustTier, ceiling: Int) -> TrustTier {
        min(earned, TrustTier(rawValue: ceiling) ?? .propose)
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
    static func agentJobStatuses() -> [String: AgentJob.Status] {
        Dictionary(AgentService.shared.jobs.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    /// F5: a build needs this much free space (a worktree, a release build and a
    /// full suite). Decimal GB, the unit Finder shows, so the line below never
    /// says "3.9 GB free" of a disk Finder calls 4.2 GB (wave 13 review).
    nonisolated static let minimumFreeBytesToBuild: Int64 = 4 * 1_000_000_000

    /// F5: why no new build may start now, or nil. One Foundry build at a time
    /// per Mac: none while one is on the rail (building or verifying) or an
    /// escalated swarm job is alive, and none on a nearly full disk. A free
    /// space that cannot be read holds too.
    nonisolated static func buildHold(building: Set<UUID>, liveEscalations: [String: UUID],
                                      freeBytes: Int64?) -> String? {
        if !building.isEmpty || !liveEscalations.isEmpty {
            return "not building: another upgrade is building, and one builds at a time on this Mac."
        }
        guard let freeBytes else {
            return "not building: Grux could not read how much disk space is free."
        }
        guard freeBytes >= minimumFreeBytesToBuild else {
            // Rounded down, so a Mac just under the floor never reads "4.0 GB free".
            let free = (Double(freeBytes) / 1_000_000_000 * 10).rounded(.down) / 10
            let need = minimumFreeBytesToBuild / 1_000_000_000
            return "not building: this Mac has \(String(format: "%.1f", free)) GB free and a build needs \(need) GB."
        }
        return nil
    }

    /// The hold for this Mac now, read from the rail, the swarm jobs and the
    /// volume the source checkout (and its sibling worktrees) live on.
    func currentBuildHold() -> String? {
        let volume = Self.resolveRepoRoot() ?? URL(fileURLWithPath: NSHomeDirectory())
        return Self.buildHold(building: building,
                              liveEscalations: Self.holdingEscalations(escalatedJobs, jobs: Self.agentJobStatuses(),
                                                                       routing: activated),
                              freeBytes: OllamaDiskCheck.availableCapacityBytes(at: volume))
    }

    /// One suite at a time per Mac: no measuring while a build is on the rail
    /// or an escalated swarm job may reach its verify (which runs the full suite).
    nonisolated static func canMeasureBaseline(building: Set<UUID>, escalatedJobs: [String: UUID]) -> Bool {
        building.isEmpty && escalatedJobs.isEmpty
    }

    /// The escalations whose swarm job is still alive (queued, running,
    /// waiting or paused). One that ended while Grux was not running, or whose
    /// job is gone, holds nothing.
    /// The escalations that hold the rail: every one whose job the store still
    /// has, ended or not. One that just ended is still being routed (its
    /// verify runs the full suite), and escalatedJobChanged drops the entry
    /// once it is. A job the store no longer has holds nothing, so a lost job
    /// never blocks builds for good (wave 13 review).
    nonisolated static func holdingEscalations(_ escalated: [String: UUID], jobs: [String: AgentJob.Status],
                                               routing: Bool) -> [String: UUID] {
        // An ended job holds only while an activated engine will route it;
        // with self-upgrade off nothing ever would (wave 13 round 2).
        escalated.filter { jobId, _ in
            guard let status = jobs[jobId] else { return false }
            return !status.isTerminal || routing
        }
    }

    /// Proposals with a build under way: on the rail, or owned by a swarm job.
    nonisolated static func inFlightProposals(building: Set<UUID>, escalated: [String: UUID]) -> Set<UUID> {
        building.union(escalated.values)
    }

    nonisolated static func liveEscalations(_ escalated: [String: UUID], jobs: [String: AgentJob.Status]) -> [String: UUID] {
        escalated.filter { jobId, _ in jobs[jobId].map { !$0.isTerminal } ?? false }
    }

    /// Escalations whose job is known to have ended, with its status, for the
    /// same routing a lifecycle notification gets. App restore marks an orphan
    /// failed without posting one, so without this its proposal never settles.
    nonisolated static func settledEscalations(_ escalated: [String: UUID], jobs: [String: AgentJob.Status]) -> [(jobId: String, status: String)] {
        escalated.keys.sorted().compactMap { jobId in
            guard let status = jobs[jobId], status.isTerminal else { return nil }
            return (jobId, status.rawValue)
        }
    }

    // MARK: - What the build changed (graded before any route)

    /// Every path a verified build changed, graded with the protected-zone rule.
    /// The proposal was graded before the build; this grades what the worker
    /// actually wrote, which is what lands.
    enum BuiltChange: Equatable {
        /// Clear of every protected zone; every changed path, sorted.
        case clear([String])
        /// The protected paths among the changes, sorted.
        case protected([String])
        /// The change could not be read, so it cannot be graded.
        case unreadable(String)
    }

    /// Every file that differs from the recorded base commit (the fork point,
    /// or "main" for a handle that predates it), read from the files
    /// themselves: each file on disk that git tracks, would add, or ignores
    /// under Sources (SwiftPM compiles those too) is hashed with no filters and
    /// compared to the base commit's blob, and a base file missing from disk is
    /// a deletion. Install builds the worktree as it stands, so this is what
    /// ships, and nothing the worker can set in git (index flags, a clean
    /// filter, an fsmonitor, a stat that did not move) hides an edit. Any git
    /// failure is unreadable, never clear.
    nonisolated static func readBuiltChange(worktree: URL, baseRef: String, runner: any RDProcessRunning) async -> BuiltChange {
        // The work tree is named here, not read from config: core.worktree (in a
        // linked worktree, config.worktree, both in the shared .git) would point
        // every listing at another folder and hide what the worker added.
        func git(_ args: [String], stdin: String? = nil) async -> RDProcessOutput {
            await runner.run(executable: "git",
                             arguments: ["--work-tree=\(worktree.path)",
                                         "-c", "core.quotePath=false", "-c", "core.fsmonitor=false"] + args,
                             currentDirectory: worktree, stdin: stdin, timeoutSeconds: 120)
        }
        func records(_ out: RDProcessOutput) -> [String] {
            out.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        }
        // The base commit's files: "<mode> <type> <sha>\t<path>" per record.
        let tree = await git(["ls-tree", "-r", "-z", "--full-tree", baseRef])
        guard tree.exitCode == 0 else {
            return .unreadable("git ls-tree \(baseRef) exited \(tree.exitCode): \(tree.stderr.prefix(300))")
        }
        var base: [String: (mode: String, sha: String)] = [:]
        for record in records(tree) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let meta = record[..<tab].split(separator: " ")
            guard meta.count == 3, meta[1] == "blob" else { continue }
            base[String(record[record.index(after: tab)...])] = (String(meta[0]), String(meta[2]))
        }
        let known = await git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        guard known.exitCode == 0 else {
            return .unreadable("git ls-files exited \(known.exitCode): \(known.stderr.prefix(300))")
        }
        // Every ignored file in the package but .build: an ignore rule anywhere
        // (a .gitignore, info/exclude, core.excludesFile) hides nothing build.sh
        // or SwiftPM reads. .build is not graded because none of it ships: the
        // install build deletes it first (verifyBuildsGreen), so the worker's
        // dependency checkouts and build products are never what is built.
        let ignored = await git(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--",
                                 "Grux-Mac", ":(exclude)Grux-Mac/.build"])
        guard ignored.exitCode == 0 else {
            return .unreadable("git ls-files --ignored exited \(ignored.exitCode): \(ignored.stderr.prefix(300))")
        }
        // git lists a nested repository (SwiftPM's .build/checkouts/<dep>/) even
        // under the excluded .build, so .build is dropped here too.
        let candidates = Set(base.keys)
            .union(records(known))
            .union(records(ignored).filter { !isFinderOrEditorLitter($0) && !$0.hasPrefix("Grux-Mac/.build/") })

        let fm = FileManager.default
        let root = worktree.resolvingSymlinksInPath().standardizedFileURL.path
        var changed: Set<String> = []
        var toHash: [String] = []
        for path in candidates {
            let onDisk = worktree.appendingPathComponent(path).path
            // A folder on the way that is a link moves what is under it out of
            // the graded tree, so nothing under it can be graded.
            let parent = worktree.appendingPathComponent(path).deletingLastPathComponent()
            let expected = (root as NSString).appendingPathComponent((path as NSString).deletingLastPathComponent)
            if fm.fileExists(atPath: parent.path),
               parent.resolvingSymlinksInPath().standardizedFileURL.path != (expected as NSString).standardizingPath {
                return .unreadable("a folder on the way to \(path) is a link, so what is under it is outside the graded tree")
            }
            let type = (try? fm.attributesOfItem(atPath: onDisk))?[.type] as? FileAttributeType
            guard let type else {
                if base[path] != nil { changed.insert(path) }   // deleted
                continue
            }
            guard let was = base[path] else {
                // A new link can point anywhere, so what it adds cannot be graded.
                if type == .typeSymbolicLink {
                    return .unreadable("\(path) is a new link")
                }
                changed.insert(path)   // added
                continue
            }
            if type == .typeSymbolicLink || was.mode == "120000" {
                // A link is its target text, not the file it points at.
                let target = try? fm.destinationOfSymbolicLink(atPath: onDisk)
                let wasTarget = await git(["cat-file", "blob", was.sha])
                if type != .typeSymbolicLink || was.mode != "120000" || wasTarget.exitCode != 0 || target != wasTarget.stdout {
                    changed.insert(path)
                }
                continue
            }
            guard type == .typeRegular else { changed.insert(path); continue }
            // The executable bit is part of what git records, and of what ships.
            let executable = fm.isExecutableFile(atPath: onDisk)
            if executable != (was.mode == "100755") { changed.insert(path); continue }
            toHash.append(path)
        }
        if toHash.contains(where: { $0.contains("\n") }) {
            return .unreadable("a file name holds a line break, so it cannot be hashed by path")
        }
        if !toHash.isEmpty {
            let hashed = await git(["hash-object", "--no-filters", "--stdin-paths"], stdin: toHash.joined(separator: "\n") + "\n")
            let shas = hashed.stdout.split(separator: "\n").map(String.init)
            guard hashed.exitCode == 0, shas.count == toHash.count else {
                return .unreadable("git hash-object exited \(hashed.exitCode) with \(shas.count) of \(toHash.count) hashes: \(hashed.stderr.prefix(300))")
            }
            for (path, sha) in zip(toHash, shas) where base[path]?.sha != sha {
                changed.insert(path)
            }
        }
        let paths = changed.sorted()
        let protected = paths.filter(TrustLedger.isProtectedChange)
        return protected.isEmpty ? .clear(paths) : .protected(protected)
    }

    /// Files Finder and editors leave beside source, which SwiftPM never builds.
    /// Python's compiled caches in a __pycache__ are litter too: the install
    /// script points Python at a cache outside the tree, so one left here is
    /// never read. Anything else in such a folder is graded.
    nonisolated static func isFinderOrEditorLitter(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let leaf = parts.last ?? path
        if parts.dropLast().contains("__pycache__") && leaf.hasSuffix(".pyc") { return true }
        return leaf == ".DS_Store" || leaf.hasPrefix("._") || leaf.hasSuffix(".swp") || leaf.hasSuffix(".swo") || leaf.hasSuffix("~")
    }

    /// The line the person reads when a verified build is not offered for
    /// install, or nil when it may go on to approval.
    nonisolated static func builtChangeRefusal(_ change: BuiltChange, branch: String) -> String? {
        switch change {
        case .clear:
            return nil
        case .protected(let paths):
            return "Not offered for install: it changes Grux's own safety checks or what builds and upgrades Grux (\(paths.joined(separator: ", "))), which Grux never installs by itself. The change is on branch \(branch) to review, and to build by hand if you want it."
        case .unreadable(let why):
            return "Not offered for install: Grux could not read what the build changed, so it could not check it against its safety rules (\(why))."
        }
    }

    nonisolated static func shouldAutoLand(earnedTier: TrustTier, proposal: UpgradeProposal) -> Bool {
        let effective = min(earnedTier, proposal.tierRequired)
        return effective >= .autoLand && proposal.riskClass != .protected
    }

    private func routePassedVerify(proposalId: UUID) {
        guard let stored = ProposalStore.shared.proposal(id: proposalId) else { return }
        // Defensive re-pin: protected zones never auto-land, even if a
        // record on disk predates the pinning rules or was hand-edited.
        let proposal = TrustLedger.applyProtectedPinning(to: stored)
        // Tuning's ceiling: never more than the person allows, whatever the
        // lane has earned.
        let earned = Self.cappedTier(earned: TrustLedger.shared.tier(lane: proposal.lane, domain: proposal.domain),
                                     ceiling: AppState.shared.config.selfUpgradeMaxTier)
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
        Task { @MainActor [weak self] in
            // Graded again here, not only after verify: an approval filed before
            // this rule existed, or a worktree that changed since its verify,
            // must not reach install ungraded.
            let change = await Self.readBuiltChange(worktree: worktreeURL, baseRef: handle.baseRef ?? "main",
                                                    runner: RDLiveProcessRunner())
            guard let self, !self.refuseBuiltChange(change, proposalId: proposalId, branch: handle.branch) else { return }
            let graded = TrustLedger.applyProtectedPinning(to: ProposalStore.shared.proposal(id: proposalId) ?? proposal)
            self.landGreen(proposal: graded, worktreeURL: worktreeURL)
        }
    }

    private func landGreen(proposal: UpgradeProposal, worktreeURL: URL) {
        let proposalId = proposal.id
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
