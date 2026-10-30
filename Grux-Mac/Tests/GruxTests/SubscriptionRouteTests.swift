import XCTest
import Foundation
@testable import Grux
@testable import GruxAgentCore

// The Claude subscription route, checked end to end on 2026-10-30. Four things
// were wrong with it, and each test below pins one of them shut:
//   - its default models had gone stale in four separate files
//   - the key-strip list lived in four copies, one of them with no test
//   - 13 Foundry proposals sat in "building" for months with nothing running
//   - Design Studio's "$0 metered" route reviewed every design on the API key
@MainActor
final class SubscriptionRouteTests: XCTestCase {

    /// Tests/GruxTests/<this file> -> up three -> Grux-Mac/Sources.
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    // MARK: - Default models

    func testEveryDefaultReadsTheOneSubscriptionModel() {
        XCTAssertEqual(ClaudeCodeAdapter().defaultModel, SubscriptionModels.code)
        let solo = SwarmPlanFactory.expand(template: .singleWorker, goal: "g", rootDir: "/tmp")
        XCTAssertEqual(solo.map(\.model), [SubscriptionModels.code])
        let spec = SwarmWorkerSpec(role: .generic, label: "l", goal: "g", cwd: "/tmp")
        XCTAssertEqual(spec.model, SubscriptionModels.code)
        XCTAssertEqual(RDWorker.Config(repoRoot: URL(fileURLWithPath: "/tmp")).model, SubscriptionModels.routine)
    }

    /// The subscription defaults are models the picker offers, so the next
    /// release bump that edits one list without the other fails here.
    func testSubscriptionModelsAreCurrentModels() {
        XCTAssertTrue(ClaudeModelCatalog.fallback.contains(SubscriptionModels.code))
        XCTAssertTrue(ClaudeModelCatalog.fallback.contains(SubscriptionModels.routine))
    }

    /// A file that starts a Claude Code run names no Claude model in a string:
    /// it takes one from SubscriptionModels. Measured on main before this fix:
    /// 9 such literals across SwarmPlan, RDWorker and Command V2, 2026-10-30.
    func testNoSubscriptionRunNamesAModelInline() throws {
        let spawns = try NSRegularExpression(pattern: #"SwarmWorkerSpec\(|\.buildInvocation\(|CommandV2AgentBridge\.run"#)
        let literal = try NSRegularExpression(pattern: #""claude-(opus|sonnet|haiku|fable)-[0-9]"#)
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        var spawningFiles = 0
        var found: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard spawns.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            spawningFiles += 1
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if literal.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThan(spawningFiles, 3, "the sweep found too few run-starting files to mean anything")
        XCTAssertEqual(found, [])
    }

    // MARK: - One key-strip list

    /// Every spawned `claude` strips the same billing variables, from the one
    /// list a test covers. A second copy of the list (its signature is the
    /// parent-session variable below) is a copy nothing tests.
    func testTheKeyStripListHasOneHome() throws {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        var holders: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("\"CLAUDE_CODE_ENTRYPOINT\"") { holders.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 100, "the walk found too few files to mean anything")
        XCTAssertEqual(holders, ["AgentCLIRegistry.swift"])
    }

    // MARK: - Stranded Foundry proposals

    private func proposal(_ status: ProposalStatus) -> UpgradeProposal {
        UpgradeProposal(title: "t", lane: .performance, domain: .mac, expectedGain: 0.5,
                        riskClass: .low, estCostLabel: "$2 estimated", tierRequired: .propose,
                        status: status, readyPrompt: "p")
    }

    func testOnlyUntrackedInFlightProposalsAreStranded() {
        let stuck = proposal(.building)
        let stuckVerifying = proposal(.verifying)
        let tracked = proposal(.building)
        let waiting = proposal(.accepted)
        let done = proposal(.landed)
        let ids = FoundryEngine.strandedProposalIDs(
            [stuck, stuckVerifying, tracked, waiting, done],
            tracked: [tracked.id]
        )
        XCTAssertEqual(Set(ids), [stuck.id, stuckVerifying.id])
    }

    // MARK: - Design Studio review on the plan

    func testPlanReviewersRunWithNoToolsAndNoConnectors() {
        let args = CritiqueGate.planReviewerArgs
        XCTAssertEqual(args, ["--tools", "", "--strict-mcp-config", "--setting-sources", ""])
        // `--tools` takes several values, so the prompt can never follow it on
        // the command line; the adapter sends it on stdin.
        let inv = ClaudeCodeAdapter().buildInvocation(prompt: "p", cwd: "/tmp", model: SubscriptionModels.routine,
                                                      extraArgs: args)
        XCTAssertEqual(inv.stdinPayload, "p\n")
        XCTAssertFalse(inv.args.contains("p"))
        let tools = try? XCTUnwrap(inv.args.firstIndex(of: "--tools"))
        XCTAssertEqual(tools.map { inv.args[$0 + 1] }, "")
        XCTAssertTrue(inv.args.contains("--strict-mcp-config"))
        XCTAssertNil(inv.env["ANTHROPIC_API_KEY"])
    }

    func testThePlanRouteCarriesNoReviewDollars() {
        let routes = CostMeter.routeComparison(inputTokens: 8000, maxOutputTokens: 2000,
                                               modelId: "claude-opus-5-5", critiqueUSD: 0.05)
        let sub = routes.first { $0.route == .subscriptionCLI }
        XCTAssertEqual(sub?.estimatedUSD, 0)
        XCTAssertEqual(sub?.label, "subscription, $0 metered (plan quota)")
    }

    /// Stop refuses the reviewers still waiting in the window, not just the
    /// ones running when it was pressed, until the next review begins.
    func testStopRefusesLaterReviewersUntilTheNextReview() async {
        let runners = PlanReviewerRunners()
        let inv = ClaudeCodeAdapter().buildInvocation(prompt: "p", cwd: "/tmp", model: SubscriptionModels.routine,
                                                      extraArgs: CritiqueGate.planReviewerArgs)
        func runner() -> AgentBridgeRunner {
            AgentBridgeRunner(adapter: ClaudeCodeAdapter(), invocation: inv, observer: nil)
        }
        await runners.begin()
        let first = await runners.add(runner())
        XCTAssertNotNil(first)
        await runners.cancelAll()
        let afterStop = await runners.add(runner())
        XCTAssertNil(afterStop)
        await runners.begin()
        let nextReview = await runners.add(runner())
        XCTAssertNotNil(nextReview)
    }

    /// A runner cancelled before it starts spawns nothing.
    func testACancelledRunnerNeverSpawns() async {
        let inv = AdapterInvocation(executablePath: "/bin/sleep", args: ["30"], env: [:], stdinPayload: nil, cwd: "/tmp")
        let runner = AgentBridgeRunner(adapter: ClaudeCodeAdapter(), invocation: inv, observer: nil)
        await runner.cancel()
        let started = Date()
        let result = await runner.run(ttlSeconds: 60)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.note, "cancelled before start")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Every run clears the previous run's Stop. Without the call, one Stop
    /// would leave every later plan review in the session "skipped".
    func testEveryRunClearsThePreviousStop() throws {
        let engine = sourcesRoot.appendingPathComponent("Grux/DesignStudio/DesignStudioEngine.swift")
        let text = try String(contentsOf: engine, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "func generate(projectId: UUID, brief: String, config: DesignRunConfig) async {"))
        let end = try XCTUnwrap(text.range(of: "defer {", range: start.upperBound..<text.endIndex))
        let opening = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(opening.contains("await CritiqueGate.beginPlanReview()"),
                      "generate() must clear the previous Stop before the run starts")
    }

    /// The stranded-card sweep runs at launch with self-upgrade off too, not
    /// only inside activate(), which an install with it off never calls.
    func testTheStrandedSweepRunsWithSelfUpgradeOff() throws {
        let app = sourcesRoot.appendingPathComponent("Grux/GruxApp.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        let gate = try XCTUnwrap(text.range(of: "if AppState.shared.config.foundryEnabled {"))
        let tail = text[gate.upperBound...].prefix(600)
        let elseBranch = try XCTUnwrap(tail.range(of: "} else {"))
        XCTAssertTrue(tail[elseBranch.upperBound...].contains("FoundryEngine.shared.reconcileStaleHandles()"))
    }
}
