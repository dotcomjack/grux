import XCTest
@testable import Grux

/// SWEEP-13, operator rule 0r.4: the Workflows run record could only be opened
/// with a click. fire-workflow-open-run opens a run's steps as Drill in does,
/// and workflows-status.json says what the view draws.
@MainActor
final class WorkflowTriggersTests: XCTestCase {

    private var engine: CommandV2Engine!
    private var saved: (() -> CommandV2Engine)!

    override func setUp() async throws {
        try await super.setUp()
        try Data().write(to: AudioOutput.sentinelURL)
        engine = CommandV2Engine()
        engine.load()
        saved = WorkflowTriggers.engine
        let engine = engine!
        WorkflowTriggers.engine = { engine }
        WorkflowsSelection.shared.open(nil)
    }

    override func tearDown() async throws {
        WorkflowTriggers.engine = saved
        WorkflowsSelection.shared.open(nil)
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        try await super.tearDown()
    }

    /// Drops `name` in a folder of the test's own, runs the app's
    /// registration on it, and returns the status file it writes.
    private func fire(_ name: String, _ contents: String = "") throws -> [String: Any] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-triggers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = TriggerWatcher(directory: dir)
        WorkflowTriggers.register(in: dir, on: watcher)
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        watcher.sweepNow()
        let url = dir.appendingPathComponent(WorkflowTriggers.statusFile)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "the trigger file was not taken")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func finishedSmokeRun() async throws -> CommandV2Run {
        guard case .success(let id) = await engine.start(definitionId: "smoke-hello-world", params: [:], dryRun: true)
        else { XCTFail("start"); throw CancellationError() }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let run = engine.run(id: id) ?? engine.recentRuns.first(where: { $0.id == id }), run.status.isTerminal { return run }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the run did not finish"); throw CancellationError()
    }

    func test_theStatusListsEveryCardAsTheViewDrawsIt() throws {
        let status = try fire(WorkflowTriggers.status)
        let cards = try XCTUnwrap(status["cards"] as? [[String: String]])
        XCTAssertEqual(cards.map { $0["title"] }, engine.definitions.map(PhaseLogCopy.cardTitle))
        // SWEEP-14: two cards read "localize {project}" and "TestFlight feedback
        // for {project}". A card never shows an unfilled placeholder.
        let raw = cards.compactMap { $0["title"] }.filter { $0.contains("{") || $0.contains("}") }
        XCTAssertEqual(raw, [], "a card title shows a raw placeholder")
        XCTAssertEqual(cards.map { $0["kind"] }, engine.definitions.map { PhaseLogCopy.category($0.category) })
        XCTAssertTrue(status["openRun"] is NSNull, "a run is open with none asked for")
    }

    func test_openRunOpensItsStepsAsDrillInDoes() async throws {
        let run = try await finishedSmokeRun()
        let status = try fire(WorkflowTriggers.openRun, run.id.uuidString)
        XCTAssertEqual(WorkflowsSelection.shared.openRunId, run.id, "the run was not opened")
        let open = try XCTUnwrap(status["openRun"] as? [String: Any], "the status does not show the open run")
        XCTAssertEqual(open["id"] as? String, run.id.uuidString)
        XCTAssertEqual(open["header"] as? String, "Steps")
        let steps = try XCTUnwrap(open["steps"] as? [[String: String]])
        let def = engine.definition(id: run.definitionId)
        XCTAssertEqual(steps.map { $0["title"] }, run.phaseHistory.map { PhaseLogCopy.stepTitle($0.phaseId, in: def) })
        XCTAssertEqual(steps.map { $0["status"] }, run.phaseHistory.map { PhaseLogCopy.status($0.outcome) })
        XCTAssertEqual(steps.first?["title"], "Greet", "the first step is not titled with its name")
        XCTAssertFalse(steps.contains { ($0["title"] ?? "").contains("-") }, "a step title is its id: \(steps)")

        // The button's own toggle closes it again; the same selection.
        WorkflowsSelection.shared.toggle(run.id)
        XCTAssertNil(WorkflowsSelection.shared.openRunId)
    }

    func test_anUnknownRunOpensNothing() throws {
        let status = try fire(WorkflowTriggers.openRun, UUID().uuidString)
        XCTAssertNil(WorkflowsSelection.shared.openRunId)
        XCTAssertTrue(status["openRun"] is NSNull)
    }

    func test_theAppRegistersTheWorkflowTriggers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let triggers = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Triggers/AppTriggers.swift"), encoding: .utf8)
        XCTAssertTrue(triggers.contains("WorkflowTriggers.register(in: dir)"), "the workflow triggers are never registered")
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Grux/CommandsV2/CommandsV2View.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("selection.toggle(run.id)"), "Drill in does not use the shared selection")
        XCTAssertFalse(view.contains("selectedRunId"), "the view keeps its own selection a trigger cannot reach")
    }
}
