import XCTest
@testable import Grux

/// REVIEW-2, P2: the phase notifier found the run again after an async hop.
/// A run gone from activeRuns and the 20-slot recentRuns by then read as live,
/// so a dry run posted a real banner and phone push. Every observer of the
/// engine's run notifications now reads what the run was when it was posted.
@MainActor
final class WorkflowNoteFactsTests: XCTestCase {

    private var engine: CommandV2Engine!

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        engine = CommandV2Engine()
        engine.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        engine = nil
        try await super.tearDown()
    }

    private func current(_ id: UUID) -> CommandV2Run? {
        engine.run(id: id) ?? engine.recentRuns.first { $0.id == id }
    }

    private func settle(_ id: UUID) async throws -> CommandV2Run {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let run = current(id), run.status.isTerminal || run.status == .waitingForApproval { return run }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(current(id))
    }

    private func notifier(_ effects: @escaping (CommandV2PhaseNotifier.Effect) -> Void) -> CommandV2PhaseNotifier {
        CommandV2PhaseNotifier(engine: { self.engine }, answers: AppStoreAnswerLog(url: nil), perform: effects)
    }

    private func isPosted(_ effect: CommandV2PhaseNotifier.Effect) -> Bool {
        switch effect {
        case .banner, .phonePush, .stage: return true
        case .orb: return false
        }
    }

    /// The note the engine posts as a dry ship run reaches its build step,
    /// read only after the run has left both lists: no banner, no push, no
    /// takeover.
    func test_aDryRunMilestoneReadAfterTheRunIsGonePostsNothing() async throws {
        var captured: Notification?
        let token = NotificationCenter.default.addObserver(forName: .gruxCommandV2PhaseTransitioned, object: nil, queue: nil) { note in
            if note.userInfo?["phaseName"] as? String == "Build it with a team of agents" { captured = note }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        guard case .success(let id) = await engine.start(definitionId: "ship-ios-app",
                                                         params: ["project": .string("NoteFacts")], dryRun: true)
        else { return XCTFail("start") }
        _ = try await settle(id)
        await engine.resume(id, userReply: "go")
        _ = try await settle(id)
        let note = try XCTUnwrap(captured, "control: the engine posted the build milestone")
        await engine.cancel(id)
        // More than the recent-runs cap of other runs finish after it.
        for _ in 0..<21 {
            guard case .success(let other) = await engine.start(definitionId: "smoke-hello-world", params: [:], dryRun: true)
            else { return XCTFail("start smoke") }
            _ = try await settle(other)
        }
        XCTAssertNil(current(id), "control: the dry run has left activeRuns and recentRuns")
        var effects: [CommandV2PhaseNotifier.Effect] = []
        notifier { effects.append($0) }.handle(note: note)
        XCTAssertFalse(effects.contains(where: isPosted), "a dry run posted a real notice: \(effects)")
    }

    /// A note that does not say whether it is a dry run, for a run nobody
    /// knows, may be a dry run: nothing is posted.
    func test_aNoteWithNoDryRunFlagForAnUnknownRunPostsNothing() {
        var effects: [CommandV2PhaseNotifier.Effect] = []
        let def = CommandV2Engine.builtinDefinitions.first { $0.id == "ship-ios-app" }!
        let index = def.phases.firstIndex { $0.id == "build" }! + 1
        notifier { effects.append($0) }.handle(note: Notification(name: .gruxCommandV2PhaseTransitioned, object: nil, userInfo: [
            "runId": UUID(), "fromPhase": index - 1, "toPhase": index,
            "phaseName": def.phases[index - 1].displayName, "commandId": "ship-ios-app"]))
        XCTAssertEqual(effects.count, 0, "a note with no flag for an unknown run posted: \(effects)")
        // Control: the same note for a live run that says so posts.
        notifier { effects.append($0) }.handle(note: Notification(name: .gruxCommandV2PhaseTransitioned, object: nil, userInfo: [
            "runId": UUID(), "fromPhase": index - 1, "toPhase": index, "isDryRun": false,
            "phaseName": def.phases[index - 1].displayName, "commandId": "ship-ios-app"]))
        XCTAssertTrue(effects.contains(where: isPosted), "control: a live milestone posts")
    }

    /// Webhooks reach outside Grux, so a dry run sends none, and a note that
    /// does not say sends none either.
    func test_aDryRunSendsNoWebhook() {
        XCTAssertFalse(WebhookManager.isLiveRun(["isDryRun": true], event: "test"), "a dry run sent a webhook")
        XCTAssertFalse(WebhookManager.isLiveRun([:], event: "test"), "a note that does not say sent a webhook")
        XCTAssertTrue(WebhookManager.isLiveRun(["isDryRun": false], event: "test"), "control: a live run sends")
    }

    /// Found in the same sweep: the shell looked a finished run up after it
    /// had left activeRuns, so every failure read "Workflow finished". The
    /// engine's own run-finished note says how it ended.
    func test_theShellReadsHowAWorkflowEndedFromTheNote() async throws {
        var ended: Notification?
        let token = NotificationCenter.default.addObserver(forName: .gruxCommandV2RunFinished, object: nil, queue: nil) { ended = $0 }
        defer { NotificationCenter.default.removeObserver(token) }
        guard case .success(let id) = await engine.start(definitionId: "smoke-hello-world", params: [:], dryRun: true)
        else { return XCTFail("start") }
        let run = try await settle(id)
        let note = try XCTUnwrap(ended, "control: the engine posted run finished")
        let end = ShellStateAdapters.workflowEnd(note.userInfo ?? [:])
        XCTAssertEqual(end.failed, run.status == .failed)
        XCTAssertEqual(end.name, run.displayName)
        XCTAssertTrue(ShellStateAdapters.workflowEnd(["status": "failed", "runName": "Ship"]).failed, "a failure read as finished")
    }

    // MARK: - Webhooks (REVIEW-2, P1)

    private actor Sends {
        var count = 0
        func add() { count += 1 }
    }

    /// A webhook manager of the test's own, whose deliveries are counted and
    /// never leave the process, subscribed to a stub endpoint for workflow events.
    private func stubWebhooks() async -> (WebhookManager, Sends, WebhookConfig) {
        let sends = Sends()
        // Counted where every delivery is recorded, sent or refused (the stub
        // endpoint has no signing secret, so none is actually sent).
        let manager = WebhookManager(sender: { _ in return (200, Data()) },
                                     sleeper: { _ in }, auditSink: { _ in await sends.add() })
        let config = WebhookConfig(name: "Stub", url: "https://example.com/grux-hook",
                                   events: [.commandPhaseTransitioned, .commandRunFinished])
        WebhookStore.shared.upsert(config)
        await manager.start()
        return (manager, sends, config)
    }

    private func drain() async throws { try await Task.sleep(nanoseconds: 500_000_000) }

    /// A person's Slack or server got "moved to <step>" from every dry run. A
    /// dry run delivers nothing, a note that does not say delivers nothing, and
    /// a live run still delivers.
    func test_aDryRunDeliversNoWebhookAndALiveRunStillDoes() async throws {
        let (manager, sends, config) = await stubWebhooks()
        defer { WebhookStore.shared.delete(id: config.id) }
        guard case .success(let dry) = await engine.start(definitionId: "smoke-hello-world", params: [:], dryRun: true)
        else { return XCTFail("start dry") }
        _ = try await settle(dry)
        try await drain()
        var sent = await sends.count
        XCTAssertEqual(sent, 0, "a dry run delivered webhooks")

        NotificationCenter.default.post(name: .gruxCommandV2PhaseTransitioned, object: nil, userInfo: [
            "runId": UUID(), "toPhase": 2, "phaseName": "Save a note for later", "commandId": "smoke-hello-world"])
        try await drain()
        sent = await sends.count
        XCTAssertEqual(sent, 0, "a note that does not say whether it is a dry run delivered a webhook")

        // smoke-hello-world touches nothing outside, so a live run is safe here.
        guard case .success(let live) = await engine.start(definitionId: "smoke-hello-world", params: [:], dryRun: false)
        else { return XCTFail("start live") }
        let run = try await settle(live)
        XCTAssertFalse(run.isDryRun, "control: the run is live")
        try await drain()
        sent = await sends.count
        XCTAssertGreaterThan(sent, 0, "control: a live run delivers its webhooks")
        await manager.stop()
    }
}
