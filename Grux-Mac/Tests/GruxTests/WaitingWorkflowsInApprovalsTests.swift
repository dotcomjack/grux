import XCTest
@testable import Grux
import GruxSetupCore

/// A workflow waiting at a gate shows up where somebody asks what is waiting.
///
/// Before this, `grux approvals` read only the Jax queue: with a TestFlight
/// triage run waiting for 'fix', 'ship' or 'hold' it answered "Waiting
/// nothing", and so did the grux_approvals tool an agent reads.
@MainActor
final class WaitingWorkflowsInApprovalsTests: XCTestCase {

    private var engine: CommandV2Engine!

    private var runsDir: URL { Persistence.supportDir.appendingPathComponent("v2-runs", isDirectory: true) }

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: CommandV2Engine.dryRunSentinelURL)
        engine = CommandV2Engine()
        engine.load()
        for run in engine.activeRuns { await engine.cancel(run.id) }
    }

    override func tearDown() async throws {
        for run in engine.activeRuns { await engine.cancel(run.id) }
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        engine = nil
        try await super.tearDown()
    }

    private func startTriage() async throws -> UUID {
        let project = "WaitApp\(UUID().uuidString.prefix(6))"
        guard case .success(let runId) = await engine.start(
            definitionId: "testflight-feedback", params: ["project": .string(project)], dryRun: true
        ) else { XCTFail("start"); throw CancellationError() }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if engine.run(id: runId)?.status == .waitingForApproval { return runId }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("run did not reach its gate")
        throw CancellationError()
    }

    // MARK: - The saved run carries its question

    func test_aWaitingRunIsSavedWithTheQuestionAndItsWords() async throws {
        let id = try await startTriage()
        let run = try XCTUnwrap(engine.run(id: id))
        XCTAssertEqual(run.gateQuestion, engine.gateQuestion(for: run))
        let question = try XCTUnwrap(run.gateQuestion, "no question saved")
        for word in [" fix ", " ship ", " hold "] { XCTAssertTrue(question.contains(word), question) }

        await engine.cancel(id)
        let after = engine.run(id: id) ?? engine.recentRuns.first { $0.id == id }
        XCTAssertNil(after?.gateQuestion, "a run that stopped waiting is not asking anything")
    }

    // MARK: - The CLI reads it off disk, with Grux closed

    func test_theDiskReaderFindsTheWaitingRun() async throws {
        let id = try await startTriage()
        let found = WaitingWorkflows.read(runsDir: runsDir).first { $0.id == id.uuidString }
        let row = try XCTUnwrap(found, "grux approvals would say nothing is waiting")
        XCTAssertEqual(row.workflow, "testflight-feedback")
        for word in [" fix ", " ship ", " hold "] { XCTAssertTrue(row.question.contains(word), row.question) }
        XCTAssertTrue(row.dryRun)

        await engine.cancel(id)
        XCTAssertFalse(WaitingWorkflows.read(runsDir: runsDir).contains { $0.id == id.uuidString },
                       "a canceled run is not waiting")
    }

    func test_theDiskReaderIsLenient() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waiting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Saved before runs carried their question: the reason still reads.
        try Data("""
        {"id":"A","definitionId":"localize-app","displayName":"Localize Demo","status":"waitingForApproval",
         "blockingReason":"Any final thoughts?","startedAt":"2026-09-27T08:00:00Z",
         "phaseHistory":[{"phaseId":"ask","startedAt":"2026-09-27T08:01:00Z"}]}
        """.utf8).write(to: dir.appendingPathComponent("A.json"))
        try Data(#"{"id":"B","status":"completed","displayName":"Done"}"#.utf8)
            .write(to: dir.appendingPathComponent("B.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("C.json"))

        let rows = WaitingWorkflows.read(runsDir: dir)
        XCTAssertEqual(rows.map(\.id), ["A"])
        XCTAssertEqual(rows.first?.question, "Localize Demo: Any final thoughts?")
        XCTAssertNotNil(rows.first?.since, "waiting since the gate phase began")
        XCTAssertEqual(WaitingWorkflows.read(runsDir: dir.appendingPathComponent("missing")), [])
    }

    // MARK: - The tool an agent reads says it too

    func test_theApprovalsToolListsWaitingWorkflows() async throws {
        let id = try await startTriage()
        let rows = GruxControlTools.waitingWorkflowRows(engine: engine)
        let row = try XCTUnwrap(rows.first { ($0["id"] as? String) == id.uuidString })
        XCTAssertEqual(row["workflow"] as? String, "testflight-feedback")
        XCTAssertEqual(row["replies"] as? [String], ["fix", "ship", "hold"])
        XCTAssertTrue((row["answer_in"] as? String)?.contains("Chat") ?? false)
    }
}
