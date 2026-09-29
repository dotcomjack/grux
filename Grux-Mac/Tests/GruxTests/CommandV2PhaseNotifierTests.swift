import XCTest
@testable import Grux

// Pure-logic coverage for CommandV2PhaseNotifier. The dispatcher's three
// fan-out side effects (UNUserNotification, encrypted phone push, Orb
// hint) all run through global singletons that we don't want to bring up
// in a unit test, so these tests target the pure decision functions:
//
//   • shouldFanOut(commandId:phaseId:), the milestone filter
//   • classifyPhase8(ascState:), the rejection/celebrate/pending router
//
// Together they cover the spec's "ONLY for ship-ios-app AND only when
// the phase is a milestone" guard, plus the phase 8 sub-classification
// that determines which orb action fires.
@MainActor
final class CommandV2PhaseNotifierTests: XCTestCase {

    // MARK: - Milestones, chosen by phase id

    /// Review finding, 2026-09-28, ruled by the lead: milestones were phase
    /// indices [2, 4, 5, 8] from an older definition, so they fired at the
    /// plan gate, the build, the audit and the screenshots, and Apple's answer
    /// was read at the screenshots. They are the phases the comments always
    /// described (lead's ruling): the build, the walkthrough pause, the
    /// publish step, and decide-next, where Apple's answer is read. Each must resolve in the
    /// current definition, so an edit to it cannot silently move them.
    func test_milestonesAreTheBuildWalkthroughPublishAndDecideNextPhases() throws {
        XCTAssertEqual(CommandV2PhaseNotifier.milestonePhaseIds, ["build", "walkthrough", "publish", "decide-next"])
        XCTAssertEqual(CommandV2PhaseNotifier.appleAnswerPhaseId, "decide-next")
        let ship = try XCTUnwrap(CommandV2Engine.builtinDefinitions.first { $0.id == CommandV2PhaseNotifier.shipIOSAppCommandId })
        func phase(_ id: String) throws -> CommandV2Definition.Phase {
            try XCTUnwrap(ship.phases.first { $0.id == id }, "milestone \(id) is no longer in ship-ios-app")
        }
        for id in CommandV2PhaseNotifier.milestonePhaseIds { _ = try phase(id) }
        if case .walkthrough = try phase("walkthrough").action {} else { XCTFail("walkthrough is not the walkthrough pause") }
        if case .iosTool(let name, _) = try phase("publish").action {
            XCTAssertEqual(name, "ios_publish_to_appstore")
        } else { XCTFail("publish is not the publish step") }
        if case .branch(let cond, _, _) = try phase("decide-next").action {
            XCTAssertTrue(String(describing: cond).contains("ascSubmissionState"), "decide-next does not read Apple's answer")
        } else { XCTFail("decide-next is not the branch on Apple's answer") }
    }

    func test_shouldFanOut_acceptsOnlyTheMilestonePhasesOfShipIOSApp() throws {
        let n = CommandV2PhaseNotifier.shared
        let ship = try XCTUnwrap(CommandV2Engine.builtinDefinitions.first { $0.id == "ship-ios-app" })
        for phase in ship.phases {
            XCTAssertEqual(n.shouldFanOut(commandId: "ship-ios-app", phaseId: phase.id),
                           CommandV2PhaseNotifier.milestonePhaseIds.contains(phase.id), phase.id)
        }
        for cmd in ["smoke-hello-world", "check-asc-status", "", "ship-mac-app"] {
            for id in CommandV2PhaseNotifier.milestonePhaseIds {
                XCTAssertFalse(n.shouldFanOut(commandId: cmd, phaseId: id), "\(cmd) \(id)")
            }
        }
    }

    /// Apple's answer is read at decide-next and nowhere else.
    func test_theOrbReadsApplesAnswerAtDecideNextOnly() {
        func hint(_ id: String, _ state: String?) -> (message: String, cinematic: Bool)? {
            CommandV2PhaseNotifier.orbHint(phaseId: id, phaseName: "Step", step: nil, ascState: state)
        }
        XCTAssertEqual(hint("decide-next", "READY_FOR_SALE")?.cinematic, true)
        XCTAssertEqual(hint("decide-next", "REJECTED")?.message, "Apple rejected the app. Open App Store Connect to see why.")
        XCTAssertNil(hint("decide-next", "WAITING_FOR_REVIEW"))
        XCTAssertEqual(hint("walkthrough", "REJECTED")?.message, "Step", "the walkthrough names its step")
        XCTAssertNil(hint("screenshots-design", "REJECTED"), "not a milestone")
        XCTAssertEqual(hint("build", nil)?.message, "Step", "the build names its step")
        XCTAssertNil(hint("brainstorm-approval-gate", nil), "not a milestone")
    }

    // MARK: - Apple's answer, said truly (review of 1ab78d2)

    /// "Live on the App Store!" showed for PENDING_DEVELOPER_RELEASE and
    /// PROCESSING_FOR_DISTRIBUTION, where the app is not on sale yet.
    func test_onlyAnAppOnSaleIsCelebratedAsLive() {
        func hint(_ state: String) -> (message: String, cinematic: Bool)? {
            CommandV2PhaseNotifier.orbHint(phaseId: "decide-next", phaseName: "See what Apple decided",
                                           step: nil, ascState: state)
        }
        XCTAssertEqual(hint("READY_FOR_SALE")?.cinematic, true)
        XCTAssertEqual(hint("PENDING_DEVELOPER_RELEASE")?.message, "Apple approved it. It goes live when you release it.")
        XCTAssertEqual(hint("PENDING_DEVELOPER_RELEASE")?.cinematic, false)
        XCTAssertEqual(hint("PROCESSING_FOR_DISTRIBUTION")?.message, "Apple approved it and is getting it ready for sale.")
        XCTAssertEqual(hint("PROCESSING_FOR_DISTRIBUTION")?.cinematic, false)
        XCTAssertEqual(hint("DEVELOPER_REJECTED")?.message,
                       "The app was taken out of review. Open App Store Connect to submit it again.")
    }

    /// DEVELOPER_REJECTED means the app was taken out of review: its title
    /// and spoken line said "Apple rejected".
    func test_aSubmissionTakenOutOfReviewIsNotCalledARejection() {
        let n = ASCStateMonitor.rejectionNotice(projectName: "Tracker", state: "DEVELOPER_REJECTED")
        for line in [n.spoken, n.title, n.body] {
            XCTAssertTrue(line.contains("taken out of review"), line)
            XCTAssertFalse(line.lowercased().contains("rejected"), line)
        }
    }

    // MARK: - A real run through the notifier (review of 1ab78d2)

    private func runEngine() -> CommandV2Engine {
        let engine = CommandV2Engine()
        engine.load()
        return engine
    }

    private func settle(_ engine: CommandV2Engine, _ id: UUID) async throws -> CommandV2Run {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let run = engine.run(id: id) ?? engine.recentRuns.first(where: { $0.id == id }),
               run.status.isTerminal || run.status == .waitingForApproval { return run }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("run did not settle"); throw CancellationError()
    }

    /// The observer hands each note to the actor in a Task; let them land.
    private func drain() async throws { try await Task.sleep(nanoseconds: 300_000_000) }

    private func describe(_ effects: [CommandV2PhaseNotifier.Effect]) -> [String] {
        effects.map {
            switch $0 {
            case .banner(let e): return "banner: \(e.body)"
            case .phonePush(_, _, let name, _, _): return "push: \(name)"
            case .orb(let m): return "orb: \(m)"
            case .stage(let m): return "stage: \(m)"
            }
        }
    }

    /// P2: a dry ship run posted "Ship the iOS app is now on this step:
    /// Publish to the App Store." and could show "Live on the App Store!".
    /// Ruling: a dry run posts no banner, no push and no takeover; the orb
    /// may say where it is, led by the dry-run note.
    func test_aDryShipRunPostsNoBannerPushOrTakeover() async throws {
        try Data().write(to: AudioOutput.sentinelURL)
        defer { try? FileManager.default.removeItem(at: AudioOutput.sentinelURL) }
        let engine = runEngine()
        var effects: [CommandV2PhaseNotifier.Effect] = []
        let notifier = CommandV2PhaseNotifier(engine: { engine }, answers: AppStoreAnswerLog(url: nil),
                                              perform: { effects.append($0) })
        notifier.start()
        defer { notifier.stop() }
        guard case .success(let id) = await engine.start(
            definitionId: "ship-ios-app",
            params: ["project": .string("DryShip\(UUID().uuidString.prefix(6))"),
                     "dryRun.asc_state": .string("READY_FOR_SALE")], dryRun: true)
        else { return XCTFail("start") }
        _ = try await settle(engine, id)
        await engine.resume(id, userReply: "go")
        _ = try await settle(engine, id)
        await engine.resume(id, userReply: "ship it")
        let run = try await settle(engine, id)
        XCTAssertEqual(run.status, .completed, run.lastError ?? "")
        try await drain()
        let said = describe(effects)
        XCTAssertFalse(said.isEmpty, "the dry run reached no milestone")
        for line in said {
            XCTAssertTrue(line.hasPrefix("orb: Dry run: "), "a dry run posted \(line)")
        }
    }

    /// Answers from "App Store Connect", one per check-status, handed to a
    /// live run through the engine's iOS tool stub: never from Apple.
    private final class AppleAnswers {
        var states: [String]
        let bundle: String
        var version: String
        init(_ states: [String], bundle: String, version: String) {
            self.states = states; self.bundle = bundle; self.version = version
        }
        func next() -> IOSDispatcherV2Result {
            let state = states.isEmpty ? "WAITING_FOR_REVIEW" : states.removeFirst()
            return IOSDispatcherV2Result(text: "stub", success: true, stateUpdates: [
                "asc_state": .string(state), "asc_bundle_id": .string(bundle),
                "asc_app_id": .string("1234567890"), "asc_version": .string(version)])
        }
    }

    /// A live ship run waiting on the clock before check-status, as it sits
    /// after publish. It starts dry, so no earlier step reaches anything,
    /// and is then made live at the point where the engine takes over.
    private func liveRunAwaitingCheck(_ engine: CommandV2Engine, app: String) async throws -> UUID {
        guard case .success(let id) = await engine.start(
            definitionId: "ship-ios-app", params: ["project": .string(app)], dryRun: true)
        else { XCTFail("start"); throw CancellationError() }
        _ = try await settle(engine, id)
        var run = try XCTUnwrap(engine.run(id: id))
        run.dryRun = false
        run.status = .waitingScheduled
        run.currentPhaseId = "wait-for-review"
        engine.upsert(run)
        return id
    }

    /// P2: every 24 hour recheck re-entered decide-next and posted "is now
    /// on this step: See what Apple decided" beside the spoken "still
    /// reviewing". Ruling: post at decide-next only for a final answer, at
    /// most once per run per answer. Review of 76341fb: through the engine's
    /// own transitions (scheduled wake, check-status, decide-next, the still
    /// pending loop), with App Store Connect's answers from the stub.
    /// Then 1.0.1 approved after 1.0 is celebrated again.
    func test_pendingRechecksThroughTheEnginePostNothingAndEachApprovalOnce() async throws {
        try Data().write(to: AudioOutput.sentinelURL)
        defer { try? FileManager.default.removeItem(at: AudioOutput.sentinelURL) }
        let engine = runEngine()
        var effects: [CommandV2PhaseNotifier.Effect] = []
        let notifier = CommandV2PhaseNotifier(engine: { engine }, answers: AppStoreAnswerLog(url: nil),
                                              perform: { effects.append($0) })
        notifier.start()
        defer { notifier.stop() }
        let apple = AppleAnswers(["WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_SALE"],
                                 bundle: "com.example.recheck\(UUID().uuidString.prefix(6))", version: "1.0")
        CommandV2Executor.iosToolStubForTests = { name, _, _ in
            name == "ios_check_asc_status" ? apple.next() : IOSDispatcherV2Result(text: "stub", success: true, stateUpdates: [:])
        }
        defer { CommandV2Executor.iosToolStubForTests = nil }

        let id = try await liveRunAwaitingCheck(engine, app: "Recheck\(UUID().uuidString.prefix(6))")
        for _ in 0..<2 {
            await engine.handleScheduledWake(runId: id, phase: "check-status")
            try await drain()
            // Still pending: the run waits on the clock again, back at check-status.
            let run = try XCTUnwrap(engine.run(id: id))
            XCTAssertEqual(run.status, .waitingScheduled, run.lastError ?? "")
            XCTAssertEqual(run.currentPhaseId, "check-status")
            XCTAssertEqual(run.phaseHistory.last?.phaseId, "still-pending", "the recheck did not loop")
        }
        XCTAssertEqual(describe(effects), [], "a pending recheck posted something")
        await engine.handleScheduledWake(runId: id, phase: "check-status")
        let done = try await settle(engine, id)
        XCTAssertEqual(done.status, .completed, done.lastError ?? "")
        try await drain()
        var said = describe(effects)
        XCTAssertEqual(said.filter { $0.hasPrefix("banner: ") }.count, 1, "\(said)")
        XCTAssertEqual(said.filter { $0.hasPrefix("push: ") }.count, 1, "\(said)")
        XCTAssertEqual(said.filter { $0 == "stage: 🎉 Live on the App Store!" }.count, 1, "\(said)")

        // A quick 1.0.1 after 1.0: a new answer, celebrated again.
        apple.states = ["READY_FOR_SALE"]
        apple.version = "1.0.1"
        let next = try await liveRunAwaitingCheck(engine, app: "Recheck\(UUID().uuidString.prefix(6))")
        await engine.handleScheduledWake(runId: next, phase: "check-status")
        _ = try await settle(engine, next)
        try await drain()
        said = describe(effects)
        XCTAssertEqual(said.filter { $0 == "stage: 🎉 Live on the App Store!" }.count, 2, "\(said)")
    }

    private func postDecideNext(_ engine: CommandV2Engine, _ id: UUID, state: String, bundle: String?) throws {
        var run = try XCTUnwrap(engine.run(id: id))
        run.dryRun = false
        run.currentPhaseId = "decide-next"
        run.state["asc_state"] = .string(state)
        if let bundle { run.state["asc_bundle_id"] = .string(bundle) }
        engine.upsert(run)
        let def = try XCTUnwrap(engine.definition(id: "ship-ios-app"))
        let index = try XCTUnwrap(def.phases.firstIndex { $0.id == "decide-next" }) + 1
        NotificationCenter.default.post(name: .gruxCommandV2PhaseTransitioned, object: id, userInfo: [
            "runId": id, "fromPhase": index - 1, "toPhase": index,
            "phaseName": def.phases[index - 1].displayName, "commandId": "ship-ios-app"])
    }

    /// Review of 76341fb, P1: a claim never released, so rejected Monday,
    /// resubmitted Tuesday and rejected again Thursday announced nothing the
    /// second time. A read that shows another state releases it. A live run
    /// cannot take the rejection branch in a test (rejection-recover starts
    /// a real agent), so the run's rechecks are posted as the engine posts them.
    func test_aResubmissionRejectedAgainIsAnnouncedAgain() async throws {
        let engine = runEngine()
        var effects: [CommandV2PhaseNotifier.Effect] = []
        let notifier = CommandV2PhaseNotifier(engine: { engine }, answers: AppStoreAnswerLog(url: nil),
                                              perform: { effects.append($0) })
        notifier.start()
        defer { notifier.stop() }
        let bundle = "com.example.resubmit\(UUID().uuidString.prefix(6))"
        guard case .success(let id) = await engine.start(
            definitionId: "ship-ios-app", params: ["project": .string("Resubmit\(UUID().uuidString.prefix(6))")], dryRun: true)
        else { return XCTFail("start") }
        _ = try await settle(engine, id)
        for state in ["REJECTED", "REJECTED", "WAITING_FOR_REVIEW", "REJECTED"] {
            try postDecideNext(engine, id, state: state, bundle: bundle)
            try await drain()
        }
        let said = describe(effects)
        XCTAssertEqual(said.filter { $0 == "orb: Apple rejected the app. Open App Store Connect to see why." }.count, 2,
                       "\(said)")
        XCTAssertEqual(said.filter { $0.hasPrefix("banner: ") }.count, 2, "\(said)")
        await engine.cancel(id)
    }

    /// Review of 76341fb, P3: the sweep keyed by the App Store Connect name
    /// and the run by its project folder, so both announced. Both now key by
    /// the bundle id: the run announces, the sweep of the same app stays
    /// quiet, whatever either calls it.
    func test_theSweepAndARunKeyAnAppTheSameWay() async throws {
        let engine = runEngine()
        let log = AppStoreAnswerLog(url: nil)
        var effects: [CommandV2PhaseNotifier.Effect] = []
        let notifier = CommandV2PhaseNotifier(engine: { engine }, answers: log, perform: { effects.append($0) })
        notifier.start()
        defer { notifier.stop() }
        let bundle = "com.example.same\(UUID().uuidString.prefix(6))"
        guard case .success(let id) = await engine.start(
            definitionId: "ship-ios-app", params: ["project": .string("/Users/someone/Projects/SameFolder\(UUID().uuidString.prefix(6))")], dryRun: true)
        else { return XCTFail("start") }
        _ = try await settle(engine, id)
        try postDecideNext(engine, id, state: "REJECTED", bundle: bundle)
        try await drain()
        XCTAssertEqual(describe(effects).filter { $0.hasPrefix("banner: ") }.count, 1)
        let swept = ASCAppRecord(projectName: "Same App - The Tagline", bundleId: bundle, ascAppId: "999",
                                 appStoreState: "REJECTED", versionString: "1.0", lastChecked: Date(), error: nil)
        XCTAssertFalse(ASCStateMonitor.shouldAnnounce(swept, log: log), "the sweep announced it again")
        await engine.cancel(id)
    }

    /// A run with no app identity (no project, no check yet) keys by its own
    /// run, never by "(unspecified)", so two such runs never silence each other.
    func test_runsWithoutAnAppNeverShareAKey() async throws {
        let engine = runEngine()
        var effects: [CommandV2PhaseNotifier.Effect] = []
        let notifier = CommandV2PhaseNotifier(engine: { engine }, answers: AppStoreAnswerLog(url: nil),
                                              perform: { effects.append($0) })
        notifier.start()
        defer { notifier.stop() }
        for _ in 0..<2 {
            guard case .success(let id) = await engine.start(
                definitionId: "ship-ios-app", params: ["project": .string(CommandV2Engine.unspecifiedParameter)],
                dryRun: true)
            else { return XCTFail("start") }
            _ = try await settle(engine, id)
            try postDecideNext(engine, id, state: "REJECTED", bundle: nil)
            try await drain()
            // Only one ship run per project runs at a time.
            await engine.cancel(id)
        }
        XCTAssertEqual(describe(effects).filter { $0.hasPrefix("banner: ") }.count, 2, "\(describe(effects))")
    }

    /// The other order: the sweep announced the rejection first, so the run
    /// reaching decide-next with it posts nothing.
    func test_aRejectionTheSweepAnnouncedStaysQuietInTheRun() async throws {
        let engine = runEngine()
        let log = AppStoreAnswerLog(url: nil)
        var effects: [CommandV2PhaseNotifier.Effect] = []
        let notifier = CommandV2PhaseNotifier(engine: { engine }, answers: log, perform: { effects.append($0) })
        let bundle = "com.example.swept\(UUID().uuidString.prefix(6))"
        let swept = ASCAppRecord(projectName: "Swept", bundleId: bundle, ascAppId: "42",
                                 appStoreState: "REJECTED", versionString: "1.0", lastChecked: Date(), error: nil)
        XCTAssertTrue(ASCStateMonitor.shouldAnnounce(swept, log: log))
        guard case .success(let id) = await engine.start(
            definitionId: "ship-ios-app", params: ["project": .string("SweptFolder\(UUID().uuidString.prefix(6))")], dryRun: true)
        else { return XCTFail("start") }
        _ = try await settle(engine, id)
        var run = try XCTUnwrap(engine.run(id: id))
        run.dryRun = false
        run.currentPhaseId = "decide-next"
        run.state["asc_state"] = .string("REJECTED")
        run.state["asc_bundle_id"] = .string(bundle)
        engine.upsert(run)
        let def = try XCTUnwrap(engine.definition(id: "ship-ios-app"))
        let index = try XCTUnwrap(def.phases.firstIndex { $0.id == "decide-next" }) + 1
        notifier.handle(note: Notification(name: .gruxCommandV2PhaseTransitioned, object: id, userInfo: [
            "runId": id, "toPhase": index, "phaseName": def.phases[index - 1].displayName, "commandId": "ship-ios-app"]))
        XCTAssertEqual(describe(effects), [], "the rejection was announced twice")
        await engine.cancel(id)
    }

    /// The log's own rule, with no time window: an answer is claimed once,
    /// released by a read that shows another state, and a new version is a
    /// new answer.
    func test_anAnswerIsClaimedOnceUntilTheAppMoves() {
        let log = AppStoreAnswerLog(url: nil)
        let app = "bundle:com.example.log"
        XCTAssertTrue(log.claim(app: app, state: "REJECTED", version: "1.0"))
        log.observe(app: app, state: "REJECTED")
        XCTAssertFalse(log.claim(app: app, state: "REJECTED", version: "1.0"),
                       "the same rejection, read again (a week later or not), is not new")
        log.observe(app: app, state: "WAITING_FOR_REVIEW")
        XCTAssertTrue(log.claim(app: app, state: "REJECTED", version: "1.0"), "rejected again after a resubmission")
        XCTAssertTrue(log.claim(app: app, state: "READY_FOR_SALE", version: "1.0"))
        XCTAssertTrue(log.claim(app: app, state: "READY_FOR_SALE", version: "1.0.1"), "1.0.1 is a new approval")
        XCTAssertFalse(log.claim(app: app, state: "READY_FOR_SALE", version: "1.0.1"))
        XCTAssertEqual(AppStoreAnswerLog.appKey(bundleId: "Com.Example.App", ascAppId: "1"), "bundle:com.example.app")
        XCTAssertEqual(AppStoreAnswerLog.appKey(bundleId: "", ascAppId: "1"), "asc:1")
        XCTAssertNil(AppStoreAnswerLog.appKey(bundleId: nil, ascAppId: ""))
    }

    // MARK: - classifyPhase8 router

    func test_classifyPhase8_celebrateOnLiveStates() {
        // The three "we're live" ASC states. Each triggers the cinematic
        // StageController takeover via .celebrate.
        let live = ["READY_FOR_SALE", "PROCESSING_FOR_DISTRIBUTION", "PENDING_DEVELOPER_RELEASE"]
        for s in live {
            XCTAssertEqual(
                CommandV2PhaseNotifier.classifyPhase8(ascState: s),
                .celebrate,
                "asc_state=\(s) should classify as celebrate"
            )
        }
    }

    func test_classifyPhase8_rejectionOnAppleBouncedStates() {
        // The four "Apple bounced" ASC states. Each triggers the orb alert.
        let rejected = ["REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "DEVELOPER_REJECTED"]
        for s in rejected {
            XCTAssertEqual(
                CommandV2PhaseNotifier.classifyPhase8(ascState: s),
                .rejection,
                "asc_state=\(s) should classify as rejection"
            )
        }
    }

    func test_classifyPhase8_stillPendingOnUnknownOrMissingState() {
        // Default to silent, the wait loop will fire its own notification
        // when the next status check comes back. This guards against false
        // celebrations when the ASC state is missing or in transition.
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: nil), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: ""), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: "WAITING_FOR_REVIEW"), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: "IN_REVIEW"), .stillPending)
        XCTAssertEqual(CommandV2PhaseNotifier.classifyPhase8(ascState: "UNKNOWN_STATE_FROM_FUTURE"), .stillPending)
    }

    func test_classifyPhase8_isCaseInsensitive() {
        // ASC payloads have historically inconsistent casing across Apple's
        // SDKs. Normalize on the way in so a lowercase response from a
        // stubbed test fixture still routes correctly.
        XCTAssertEqual(
            CommandV2PhaseNotifier.classifyPhase8(ascState: "ready_for_sale"),
            .celebrate
        )
        XCTAssertEqual(
            CommandV2PhaseNotifier.classifyPhase8(ascState: "Rejected"),
            .rejection
        )
    }

    // MARK: - handle() guard rails

    func test_handle_silentlyIgnoresMalformedUserInfo() {
        // The dispatcher must not crash on a notification with missing keys.
        // We post one with no userInfo at all and expect no exception.
        let n = CommandV2PhaseNotifier.shared
        let note = Notification(
            name: .gruxCommandV2PhaseTransitioned,
            object: nil,
            userInfo: nil
        )
        // No crash assertion, just call through. If this throws, XCTest fails.
        n.handle(note: note)
    }

    func test_handle_silentlyIgnoresMissingRunId() {
        // userInfo present but missing runId, must not fan out and must not crash.
        let n = CommandV2PhaseNotifier.shared
        let note = Notification(
            name: .gruxCommandV2PhaseTransitioned,
            object: nil,
            userInfo: [
                "commandId": "ship-ios-app",
                "toPhase": 2,
                "phaseName": "Build"
            ]
        )
        n.handle(note: note)
    }
}
