import XCTest
@testable import GruxAgentCore

final class SwarmAgentCoreTests: XCTestCase {

    // MARK: - StreamJSONParser

    func testParseSystemInit() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-sonnet-4-6"}"#
        let ev = StreamJSONParser.parse(line: line)
        guard case .systemInit(let sid, let model, _) = ev else {
            XCTFail("expected systemInit, got \(String(describing: ev))"); return
        }
        XCTAssertEqual(sid, "abc-123")
        XCTAssertEqual(model, "claude-sonnet-4-6")
    }

    func testParseAssistantText() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#
        let ev = StreamJSONParser.parse(line: line)
        guard case .assistantText(let text, _) = ev else {
            XCTFail("expected assistantText, got \(String(describing: ev))"); return
        }
        XCTAssertEqual(text, "hello world")
    }

    func testParseToolUse() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
        let ev = StreamJSONParser.parse(line: line)
        guard case .toolUse(let name, let inputJSON, _) = ev else {
            XCTFail("expected toolUse, got \(String(describing: ev))"); return
        }
        XCTAssertEqual(name, "Bash")
        XCTAssertTrue(inputJSON.contains("ls"))
    }

    func testParseToolResult() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file1\nfile2"}]}}"#
        let ev = StreamJSONParser.parse(line: line)
        guard case .toolResult(let text, _) = ev else {
            XCTFail("expected toolResult, got \(String(describing: ev))"); return
        }
        XCTAssertTrue(text.contains("file1"))
    }

    func testParseFinalResult() {
        let line = #"{"type":"result","subtype":"success","result":"done!","total_cost_usd":0.0123}"#
        let ev = StreamJSONParser.parse(line: line)
        guard case .finalResult(let text, let cost, let success, _) = ev else {
            XCTFail("expected finalResult, got \(String(describing: ev))"); return
        }
        XCTAssertEqual(text, "done!")
        XCTAssertEqual(cost ?? 0, 0.0123, accuracy: 1e-6)
        XCTAssertTrue(success)
    }

    func testParseChunkSplitsOnNewlines() {
        let chunk = """
        {"type":"system","subtype":"init","session_id":"s1"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        {"type":"result","subtype":"success","result":"end","total_cost_usd":0.01}
        """ + "\n" + #"{"type":"unknown_partial""# // partial line, should remain
        let (events, remainder) = StreamJSONParser.parseChunk(chunk)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(remainder.contains("unknown_partial"))
    }

    func testParseBlankIgnored() {
        XCTAssertNil(StreamJSONParser.parse(line: ""))
        XCTAssertNil(StreamJSONParser.parse(line: "   "))
        XCTAssertNil(StreamJSONParser.parse(line: "not json"))
    }

    // MARK: - MegapromptScaffold

    func testScaffoldContainsAllThreeMessages() {
        let block = MegapromptScaffold.block()
        XCTAssertTrue(block.contains("polished final product"))
        XCTAssertTrue(block.contains("parallel subagents"))
        XCTAssertTrue(block.contains("calm, lovely night") || block.contains("Please enjoy"))
    }

    func testScaffoldEmptyWhenAllStripped() {
        let block = MegapromptScaffold.block(polish: "", parallel: "", vibe: "", technicalGuardrails: "")
        XCTAssertTrue(block.isEmpty)
    }

    func testWrapIncludesGoal() {
        let wrapped = MegapromptScaffold.wrap(rolePrompt: "you are a builder", userGoal: "ship the thing")
        XCTAssertTrue(wrapped.contains("you are a builder"))
        XCTAssertTrue(wrapped.contains("ship the thing"))
        XCTAssertTrue(wrapped.contains("polished final product"))
    }

    // MARK: - SwarmPlanFactory

    func testSingleWorkerPlanHasOne() {
        let workers = SwarmPlanFactory.expand(template: .singleWorker, goal: "do X", rootDir: "/tmp")
        XCTAssertEqual(workers.count, 1)
        XCTAssertEqual(workers[0].role, .generic)
        XCTAssertTrue(workers[0].dependsOn.isEmpty)
    }

    func testArchitectImplementHasDependency() {
        let workers = SwarmPlanFactory.expand(template: .architectImplement, goal: "build it", rootDir: "/tmp")
        XCTAssertEqual(workers.count, 2)
        XCTAssertEqual(workers[0].role, .architect)
        XCTAssertEqual(workers[1].role, .implementor)
        XCTAssertEqual(workers[1].dependsOn, [workers[0].id])
    }

    func testParallelTrioAllIndependent() {
        let workers = SwarmPlanFactory.expand(template: .parallelTrio, goal: "g", rootDir: "/tmp")
        XCTAssertEqual(workers.count, 3)
        for w in workers { XCTAssertTrue(w.dependsOn.isEmpty) }
    }

    func testCritiqueLoopShape() {
        let workers = SwarmPlanFactory.expand(template: .critiqueLoop, goal: "write 15 tweets", rootDir: "/tmp")
        XCTAssertEqual(workers.count, 4)
        XCTAssertEqual(workers[0].role, .architect)   // brief
        XCTAssertEqual(workers[1].role, .implementor) // writer
        XCTAssertEqual(workers[2].role, .qa)          // critic
        XCTAssertEqual(workers[3].role, .integrator)  // reviser
        // Each stage depends on the previous one, strict chain.
        XCTAssertTrue(workers[0].dependsOn.isEmpty)
        XCTAssertEqual(workers[1].dependsOn, [workers[0].id])
        XCTAssertEqual(workers[2].dependsOn, [workers[1].id])
        XCTAssertEqual(workers[3].dependsOn, [workers[2].id])
    }

    func testIosAppFullDagShape() {
        let workers = SwarmPlanFactory.expand(template: .iosAppFull, goal: "Build a notes app", rootDir: "/tmp")
        // architect + 4 features + integrator + buildLoop + qa = 8
        XCTAssertEqual(workers.count, 8)
        let archId = workers.first(where: { $0.role == .architect })!.id
        let featureWorkers = workers.filter { $0.role == .implementor }
        XCTAssertEqual(featureWorkers.count, 4)
        for f in featureWorkers {
            XCTAssertEqual(f.dependsOn, [archId])
        }
        let integrator = workers.first(where: { $0.role == .integrator })!
        XCTAssertEqual(Set(integrator.dependsOn), Set(featureWorkers.map(\.id)))
    }

    // MARK: - AgentStore round-trip

    func testStoreRoundTrip() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AgentStore(rootDir: tmp)

        let workers = SwarmPlanFactory.expand(template: .singleWorker, goal: "g", rootDir: "/tmp")
        let job = AgentJob(
            title: "test",
            goal: "test goal",
            budgetUSD: 0.1,
            workers: workers,
            rootDir: "/tmp"
        )
        try await store.saveJob(job)

        let loaded = await store.loadJob(job.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.goal, "test goal")

        let step = AgentStep(
            workerId: workers[0].id,
            kind: .workerStart,
            text: "starting"
        )
        await store.appendStep(jobId: job.id, step: step)

        let steps = await store.loadSteps(jobId: job.id)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.text, "starting")

        let workerSteps = await store.loadWorkerSteps(jobId: job.id, workerId: workers[0].id)
        XCTAssertEqual(workerSteps.count, 1)

        let allJobs = await store.listJobs()
        XCTAssertTrue(allJobs.contains(where: { $0.id == job.id }))
    }

    // MARK: - SwarmWorker.resolveClaudeBinary

    func testResolveClaudeBinaryReturnsSomethingExecutableOrFallback() {
        let path = SwarmWorker.resolveClaudeBinary()
        XCTAssertFalse(path.isEmpty)
        // Either it's an executable file or it's the literal "claude" fallback.
        let fm = FileManager.default
        XCTAssertTrue(fm.isExecutableFile(atPath: path) || path == "claude")
    }
}
