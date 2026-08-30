import Foundation

// Operator-visibility dispatcher for Commands V2 milestone phases. Listens
// for `gruxCommandV2PhaseTransitioned` and fans the event out across three
// surfaces: macOS notification banner, GruxPhone push (encrypted), and the
// in-app Orb status bus. Only the `ship-ios-app` workflow's milestone
// phases [2 build, 4 walkthrough, 5 publish, 8 decide-next] trigger a
// fan-out - every other phase index is silently filtered so the dispatcher
// can safely observe ALL V2 phase transitions without spamming the user.
//
// Phase 8 ("decide-next") sub-routes by examining the run's `asc_state`
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

    // The single workflow that gets per-phase fan-out today. New definitions
    // can opt in by extending `milestoneIndices(for:)`.
    static let shipIOSAppCommandId = "ship-ios-app"
    // 1-based phase indices that warrant a notification. Matches the spec
    // doc's "phase N/9" numbering. See CommandV2Definitions.shipIOSApp().
    static let milestonePhaseIndices: Set<Int> = [2, 4, 5, 8]

    // ASC submission states that mean "the app went live". Drives the 8b
    // celebrate cinematic. Mirrors the success branch in the
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

    private var observerToken: NSObjectProtocol?

    private init() {}

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
        let info = note.userInfo ?? [:]
        guard let commandId = info["commandId"] as? String,
              let phaseIndex = info["toPhase"] as? Int,
              let phaseName = info["phaseName"] as? String else {
            return
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
            return
        }

        guard shouldFanOut(commandId: commandId, phaseIndex: phaseIndex) else { return }

        // Total phases for ship-ios-app is fixed at 9 (matches the spec doc
        // and the shipIOSApp() definition). Pulling it from the engine would
        // require importing CommandV2Engine state into this dispatcher and
        // races with the engine's load() ordering; the static value is fine
        // because milestone fan-out is opt-in per commandId.
        let totalPhases = totalPhases(for: commandId)

        // 1. macOS banner.
        NotificationManager.shared.notifyAgentPhaseTransition(
            commandId: commandId,
            runId: runIdString,
            phaseName: phaseName,
            phaseIndex: phaseIndex,
            totalPhases: totalPhases
        )

        // 2. GruxPhone push (encrypted, fire-and-forget).
        PhoneReceiverService.shared.notifyPhaseTransitioned(
            commandId: commandId,
            runId: runIdString,
            phaseName: phaseName,
            phaseIndex: phaseIndex,
            totalPhases: totalPhases
        )

        // 3. Orb / Stage surface - varies per milestone.
        applyOrbState(
            commandId: commandId,
            phaseIndex: phaseIndex,
            phaseName: phaseName,
            totalPhases: totalPhases,
            runIdString: runIdString
        )
    }

    // MARK: - Filters (pure, unit-testable)

    /// Returns true iff this command + phase combination is a milestone
    /// that warrants operator visibility. Today only ship-ios-app phases
    /// 2/4/5/8 qualify.
    func shouldFanOut(commandId: String, phaseIndex: Int) -> Bool {
        guard commandId == Self.shipIOSAppCommandId else { return false }
        return Self.milestonePhaseIndices.contains(phaseIndex)
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

    // MARK: - Internals

    private func totalPhases(for commandId: String) -> Int {
        // ship-ios-app has 12 phases in the definition (the spec talks about
        // "9 phases" because branch/scheduled phases collapse into one
        // logical step). Pull the actual count from the engine if it's
        // loaded; fall back to the spec number to keep banner copy stable
        // when the engine isn't yet initialized (e.g. in tests).
        if let def = CommandV2Engine.shared.definition(id: commandId) {
            return def.phases.count
        }
        return 9
    }

    private func applyOrbState(
        commandId: String,
        phaseIndex: Int,
        phaseName: String,
        totalPhases: Int,
        runIdString: String
    ) {
        switch phaseIndex {
        case 2:
            // Phase 2 - build. Long-running swarm; thinking glow.
            OrbHintBus.shared.show(
                message: "Building app… phase 2/\(totalPhases)",
                state: .thinking,
                duration: 8.0
            )

        case 4:
            // Phase 4 - walkthrough. Operator approval required, so the orb
            // takes the alert pulse (rendered as `.thinking` until a
            // dedicated `.alert` state lands).
            OrbHintBus.shared.show(
                message: "Walkthrough required - tap to approve",
                state: .thinking,
                duration: 8.0
            )

        case 5:
            // Phase 5 - publish. Submitting to App Store Connect.
            OrbHintBus.shared.show(
                message: "Submitting to App Store…",
                state: .thinking,
                duration: 8.0
            )

        case 8:
            // Phase 8 - decide-next. Sub-route on ASC state.
            let ascState = ascStateForRun(runIdString: runIdString)
            switch Self.classifyPhase8(ascState: ascState) {
            case .celebrate:
                // Cinematic full-screen takeover for the win.
                StageController.shared.show(
                    message: "🎉 Live on the App Store!",
                    state: .speaking,
                    duration: 6.0
                )
            case .rejection:
                OrbHintBus.shared.show(
                    message: "App rejected by Apple - review the report",
                    state: .thinking,
                    duration: 8.0
                )
            case .stillPending:
                // Silent - the wait-loop will fire its own notification when
                // the next status check comes back.
                break
            }

        default:
            break
        }
    }

    /// Look up the asc_state on the live run. Returns nil if the run was
    /// already removed from `activeRuns` (e.g. canceled mid-fanout).
    private func ascStateForRun(runIdString: String) -> String? {
        guard let runId = UUID(uuidString: runIdString) else { return nil }
        guard let run = CommandV2Engine.shared.run(id: runId) else { return nil }
        return run.state["asc_state"]?.stringValue
    }
}
