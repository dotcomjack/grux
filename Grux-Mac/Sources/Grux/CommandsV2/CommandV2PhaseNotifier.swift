import Foundation

// Operator-visibility dispatcher for Commands V2 milestone phases. Listens
// for `gruxCommandV2PhaseTransitioned` and fans the event out across three
// surfaces: macOS notification banner, GruxPhone push (encrypted), and the
// in-app Orb status bus. Only the `ship-ios-app` workflow's milestone
// phases (build, walkthrough, publish, decide-next, by id) trigger a
// fan-out - every other phase is silently filtered so the dispatcher
// can safely observe ALL V2 phase transitions without spamming the user.
//
// The decide-next milestone sub-routes by examining the run's `asc_state`
// to determine which downstream branch will execute:
//   • READY_FOR_SALE / PROCESSING_FOR_DISTRIBUTION / PENDING_DEVELOPER_RELEASE
//     → 8b celebrate (cinematic StageController takeover)
//   • REJECTED / METADATA_REJECTED / INVALID_BINARY / DEVELOPER_REJECTED
//     → 8a rejection (orb alert)
//   • anything else (still in review)
//     → 8c still-pending (orb stays silent)
//
// Security: notification payloads carry only commandId/runId/phaseName/
// phaseIndex/totalPhases - never asc_feedback_text, build paths, or any
// other sensitive run state. Body copy is intentionally generic.

@MainActor
final class CommandV2PhaseNotifier {
    static let shared = CommandV2PhaseNotifier()

    // The single workflow that gets per-phase fan-out today.
    static let shipIOSAppCommandId = "ship-ios-app"
    // The ship-ios-app phases that warrant a notification, BY ID: the build,
    // the walkthrough pause, the publish step, and decide-next. They were
    // 1-based indices [2, 4, 5, 8] from an older definition, and once phases
    // were added they fired at the plan gate, the build, the audit and the
    // screenshots. CommandV2PhaseNotifierTests fails if an id leaves the
    // definition, so an edit cannot silently move them again.
    static let milestonePhaseIds: [String] = ["build", "walkthrough", "publish", "decide-next"]
    // The milestone where Apple's answer is read: celebrate, rejection or
    // silence. decide-next runs right after check-status sets `asc_state`.
    static let appleAnswerPhaseId = "decide-next"

    // ASC submission states where Apple approved the app (on sale, or on its
    // way). Mirrors the success branch in the
    // shipIOSApp definition's decide-next phase.
    static let liveASCStates: Set<String> = [
        "READY_FOR_SALE",
        "PROCESSING_FOR_DISTRIBUTION",
        "PENDING_DEVELOPER_RELEASE"
    ]

    // ASC states that mean Apple bounced the build. Drives the 8a alert.
    static let rejectedASCStates: Set<String> = [
        "REJECTED",
        "METADATA_REJECTED",
        "INVALID_BINARY",
        "DEVELOPER_REJECTED"
    ]

    // Sub-classification of the phase 8 ("decide-next") milestone. Surfaced
    // as a public type so unit tests can assert the classifier directly
    // without spinning up the engine.
    enum Phase8Branch: Equatable {
        case celebrate       // app went live
        case rejection       // Apple bounced - operator action needed
        case stillPending    // still in review - silent
    }

    /// What one milestone does, worked out before it is done: `effects(for:)`
    /// decides, `perform` does. A test passes its own `perform` and sees
    /// exactly what a run would post.
    enum Effect {
        case banner(TriageEnvelope)
        case phonePush(commandId: String, runId: String, phaseName: String, phaseIndex: Int, totalPhases: Int)
        case orb(String)
        case stage(String)
    }

    private var observerToken: NSObjectProtocol?
    private let engine: () -> CommandV2Engine
    private let answers: AppStoreAnswerLog
    private let perform: (Effect) -> Void
    /// The answer each run last announced, by run id, cleared when a recheck
    /// reads another state: at most once per run per answer.
    private var lastAnnounced: [String: String] = [:]

    init(engine: @escaping () -> CommandV2Engine = { .shared },
         answers: AppStoreAnswerLog = .shared,
         perform: ((Effect) -> Void)? = nil) {
        self.engine = engine
        self.answers = answers
        self.perform = perform ?? Self.deliver
    }

    static func deliver(_ effect: Effect) {
        switch effect {
        case .banner(let envelope):
            NotificationManager.shared.deliverPhaseTransition(envelope)
        case .phonePush(let commandId, let runId, let phaseName, let phaseIndex, let totalPhases):
            // Encrypted, fire-and-forget.
            PhoneReceiverService.shared.notifyPhaseTransitioned(
                commandId: commandId, runId: runId, phaseName: phaseName,
                phaseIndex: phaseIndex, totalPhases: totalPhases)
        case .orb(let message):
            OrbHintBus.shared.show(message: message, state: .thinking, duration: 8.0)
        case .stage(let message):
            // Cinematic full-screen takeover for the win.
            StageController.shared.show(message: message, state: .speaking, duration: 6.0)
        }
    }

    func start() {
        // Idempotent - re-calling start() is a no-op so AppDelegate can call
        // it from any boot path (smoke test, regular launch, --overlay-demo
        // future use) without double-registering.
        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: .gruxCommandV2PhaseTransitioned,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // The observer is registered with `queue: .main` so the closure
            // already runs on the main thread; jump back to the actor to
            // satisfy isolation.
            Task { @MainActor [weak self] in
                self?.handle(note: note)
            }
        }
    }

    func stop() {
        if let t = observerToken {
            NotificationCenter.default.removeObserver(t)
            observerToken = nil
        }
    }

    // Pulled out of the closure so unit tests can drive it without going
    // through NotificationCenter. Safe to call with malformed userInfo -
    // missing keys cause a silent return rather than a crash.
    func handle(note: Notification) {
        effects(for: note).forEach(perform)
    }

    /// What a phase transition posts. Records an announced answer, so the
    /// same answer for the same run is not posted twice.
    func effects(for note: Notification) -> [Effect] {
        let info = note.userInfo ?? [:]
        guard let commandId = info["commandId"] as? String,
              let phaseIndex = info["toPhase"] as? Int,
              let phaseName = info["phaseName"] as? String else {
            return []
        }
        // runId may be a UUID (engine post path) or a String (tests, future
        // payloads from disk-replayed events). Normalize to String so the
        // notification + envelope identifiers stay stable across both.
        let runIdString: String
        if let u = info["runId"] as? UUID {
            runIdString = u.uuidString
        } else if let s = info["runId"] as? String {
            runIdString = s
        } else {
            return []
        }
        let eng = engine()
        guard let def = eng.definition(id: commandId), def.phases.indices.contains(phaseIndex - 1) else { return [] }
        let phaseId = def.phases[phaseIndex - 1].id
        guard shouldFanOut(commandId: commandId, phaseId: phaseId) else { return [] }
        // What the run was when the engine posted this (CommandV2Engine.runFacts),
        // never re-found after the hop here: by then a finished run may have
        // left activeRuns and the 20-slot recentRuns, and a dry run read as
        // live posted a real banner and push (REVIEW-2). A note without the
        // facts (an older poster, a test) falls back to finding the run; with
        // neither, nothing is posted, since it may be a dry run.
        func found() -> RunFacts? {
            guard let id = UUID(uuidString: runIdString),
                  let run = eng.run(id: id) ?? eng.recentRuns.first(where: { $0.id == id }) else { return nil }
            return Self.runFacts(CommandV2Engine.runFacts(run))
        }
        guard let facts = Self.runFacts(info) ?? found() else {
            WakeLog.shared.log("phase-notifier: \(commandId) run \(runIdString.prefix(8)) at \(phaseId) has no dry-run flag and is no longer known, so nothing was posted")
            return []
        }
        // The definition's own numbering goes to the tap handler and the
        // phone. What a person reads counts only the steps they move through
        // (`mainPathStep`): branch and retry phases are not steps to them.
        let totalPhases = def.phases.count
        let step = def.mainPathStep(of: phaseId)
        let runName = facts.runName ?? CommandV2Engine.runName(def.displayName, params: [:])
        let ascState = phaseId == Self.appleAnswerPhaseId ? facts.ascState : nil

        // A dry run only records what it would do: no banner, no phone push
        // and no takeover. The orb may say where it is, as a dry run, but
        // never Apple's answer, which a dry run only seeded.
        if facts.isDryRun {
            guard phaseId != Self.appleAnswerPhaseId,
                  let hint = Self.orbHint(phaseId: phaseId, phaseName: phaseName, step: step, ascState: nil)
            else { return [] }
            return [.orb(Self.dryRunOrbNote + hint.message)]
        }
        // Every recheck re-enters decide-next. Only a final answer posts, at
        // most once per run per answer, and not when the App Store Connect
        // sweep already announced it (AppStoreAnswerLog).
        if phaseId == Self.appleAnswerPhaseId {
            // An unread answer ("UNKNOWN", nothing) says nothing about the app.
            guard let state = ascState?.uppercased(), !state.isEmpty, state != "UNKNOWN" else { return [] }
            // The app as the sweep keys it (bundle id from check-status); a
            // run that has none keys by itself, never by its project label.
            let app = AppStoreAnswerLog.appKey(bundleId: facts.ascBundleId, ascAppId: facts.ascAppId)
                ?? "run:" + runIdString
            answers.observe(app: app, state: state)
            guard Self.appleAnswer(state) != .pending else {
                lastAnnounced[runIdString] = nil
                return []
            }
            guard lastAnnounced[runIdString] != state else { return [] }
            lastAnnounced[runIdString] = state
            guard answers.claim(app: app, state: state, version: facts.ascVersion) else { return [] }
        }

        var out: [Effect] = [
            .banner(NotificationManager.phaseTransitionEnvelope(
                commandId: commandId, runId: runIdString, runName: runName, phaseName: phaseName,
                phaseIndex: phaseIndex, totalPhases: totalPhases, step: step)),
            .phonePush(commandId: commandId, runId: runIdString, phaseName: phaseName,
                       phaseIndex: phaseIndex, totalPhases: totalPhases)
        ]
        if let hint = Self.orbHint(phaseId: phaseId, phaseName: phaseName, step: step, ascState: ascState) {
            out.append(hint.cinematic ? .stage(hint.message) : .orb(hint.message))
        }
        return out
    }

    /// The run facts a note carries (CommandV2Engine.runFacts); nil when it
    /// carries no dry-run flag.
    struct RunFacts {
        let isDryRun: Bool
        let runName: String?
        let ascState, ascBundleId, ascAppId, ascVersion: String?
    }

    static func runFacts(_ info: [String: Any]) -> RunFacts? {
        runFacts(Dictionary(uniqueKeysWithValues: info.map { (AnyHashable($0.key), $0.value) }))
    }

    static func runFacts(_ info: [AnyHashable: Any]) -> RunFacts? {
        guard let dry = info["isDryRun"] as? Bool else { return nil }
        return RunFacts(isDryRun: dry, runName: info["runName"] as? String,
                        ascState: info["ascState"] as? String, ascBundleId: info["ascBundleId"] as? String,
                        ascAppId: info["ascAppId"] as? String, ascVersion: info["ascVersion"] as? String)
    }

    // MARK: - Filters (pure, unit-testable)

    /// Returns true iff this command + phase combination is a milestone
    /// that warrants operator visibility: one of `milestonePhaseIds` of
    /// ship-ios-app.
    func shouldFanOut(commandId: String, phaseId: String) -> Bool {
        guard commandId == Self.shipIOSAppCommandId else { return false }
        return Self.milestonePhaseIds.contains(phaseId)
    }

    /// Classify what the phase 8 branch is going to do, given the current
    /// `asc_state` value carried on the run. Pure function - no side effects,
    /// safe to unit test without an engine instance. Defaults to
    /// `.stillPending` when the state is missing or unrecognized so the
    /// caller stays silent rather than firing a false-positive celebration.
    static func classifyPhase8(ascState: String?) -> Phase8Branch {
        guard let raw = ascState?.uppercased(), !raw.isEmpty else {
            return .stillPending
        }
        if liveASCStates.contains(raw) { return .celebrate }
        if rejectedASCStates.contains(raw) { return .rejection }
        return .stillPending
    }

    /// What the orb says at a milestone, as the person reads it; nil when it
    /// stays silent (phase 8 while Apple is still reviewing). `cinematic` is
    /// the full-screen takeover for the app going live.
    static func orbHint(phaseId: String, phaseName: String, step: (n: Int, total: Int)?,
                        ascState: String?) -> (message: String, cinematic: Bool)? {
        guard milestonePhaseIds.contains(phaseId) else { return nil }
        guard phaseId == appleAnswerPhaseId else {
            // The step's own name, so the hint says what is happening.
            return (step.map { "Step \($0.n) of \($0.total): \(phaseName)" } ?? phaseName, false)
        }
        switch appleAnswer(ascState) {
        case .onSale: return ("🎉 Live on the App Store!", true)
        case .approvedAwaitingRelease: return ("Apple approved it. It goes live when you release it.", false)
        case .approvedProcessing: return ("Apple approved it and is getting it ready for sale.", false)
        case .rejected("DEVELOPER_REJECTED"):
            return ("The app was taken out of review. Open App Store Connect to submit it again.", false)
        case .rejected: return ("Apple rejected the app. Open App Store Connect to see why.", false)
        // Silent: the wait loop speaks when the next status check comes back.
        case .pending: return nil
        }
    }

    /// What leads an orb hint in a dry run.
    static let dryRunOrbNote = "Dry run: "

    /// Apple's answer at decide-next, as what is true for the person: only
    /// an app on sale is live; an approved app waiting for release, or being
    /// readied for sale, is not yet.
    enum AppleAnswer: Equatable {
        case onSale, approvedAwaitingRelease, approvedProcessing
        case rejected(String)
        case pending
    }

    static func appleAnswer(_ ascState: String?) -> AppleAnswer {
        let state = ascState?.uppercased() ?? ""
        switch state {
        case "READY_FOR_SALE": return .onSale
        case "PENDING_DEVELOPER_RELEASE": return .approvedAwaitingRelease
        case "PROCESSING_FOR_DISTRIBUTION": return .approvedProcessing
        default: return rejectedASCStates.contains(state) ? .rejected(state) : .pending
        }
    }
}
