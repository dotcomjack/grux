import XCTest
@testable import Grux

/// Wave 26 round 1, P2: a Jax plan queued to Approvals (Observe, or Live when
/// the worth judgment held it) carried no replay coordinates, so saying yes
/// recorded the answer and started nothing, while the card said it runs if you
/// say yes. The item now carries the `agent_swarm_start` call the Live path
/// would have made, so `ApprovalQueue.approveAndExecute` replays it.
@MainActor
final class GoalPursuitApprovalReplayTests: XCTestCase {
    private func item(template: String = "architectImplement", budget: Double = 2.5) -> PendingApproval {
        GoalPursuitEngine.approvalItem(
            PlannedSwarmAction(title: "Fix the build", goal: "Make the build green", template: template, budgetUSD: budget),
            domain: "product/code", rationale: "It is red.")
    }

    func test_aQueuedPlanCarriesTheSwarmStartItWouldHaveRun() throws {
        let detail = item().action.detail
        XCTAssertEqual(detail["__replay_tool"], "agent_swarm_start")
        XCTAssertTrue(AgentTools.toolNames.contains("agent_swarm_start"))
        let input = try XCTUnwrap(detail["__replay_input"].flatMap(ApprovalQueue.decodeInput))
        XCTAssertEqual(input["goal"] as? String, "Make the build green")
        XCTAssertEqual(input["title"] as? String, "Fix the build")
        XCTAssertEqual(input["template"] as? String, "architectImplement")
        XCTAssertEqual(input["budget_usd"] as? Double, 2.5)
        XCTAssertEqual(input["max_parallel"] as? Int, 3)
    }

    /// The Live path falls back to one worker on a template it does not know;
    /// `agent_swarm_start` would refuse it, so the replay carries the fallback.
    func test_anUnknownTemplateReplaysAsTheLivePathWouldRunIt() throws {
        let input = try XCTUnwrap(item(template: "noSuchTemplate").action.detail["__replay_input"]
            .flatMap(ApprovalQueue.decodeInput))
        XCTAssertEqual(input["template"] as? String, "singleWorker")
    }

    func test_aWholeDollarBudgetStillReadsAsTheBudget() throws {
        let input = try XCTUnwrap(item(budget: 5).action.detail["__replay_input"].flatMap(ApprovalQueue.decodeInput))
        // agent_swarm_start reads `as? Double`, then `as? Int`; either way 5.
        let read = (input["budget_usd"] as? Double) ?? Double((input["budget_usd"] as? Int) ?? -1)
        XCTAssertEqual(read, 5)
    }

    // W26-P3 item 1: the card showed the model's raw template while the yes
    // ran one worker; it now names the template the yes runs.
    func test_theCardNamesTheTemplateTheYesRuns() {
        XCTAssertEqual(item(template: "noSuchTemplate").action.detail["template"], "singleWorker")
        XCTAssertEqual(item(template: "architectImplement").action.detail["template"], "architectImplement")
    }

    // W26-P3 item 2: a yes starts a session on the person's paid Claude
    // sign-in, so the card says so and is flagged as a spend, which `grux
    // approvals` and the MCP row read. Wave 27 round 2 (P2): it said "It may
    // spend up to $5.00", but nothing caps a session (`SwarmWorker` passes no
    // `--max-budget-usd`; the job's budget is a figure for display), so the
    // card says there is no cap, names the planned figure as usage, and puts
    // no amount in the header.
    func test_theCardSaysTheSessionHasNoCapAndIsASpend() {
        let a = item(budget: 2.5)
        XCTAssertEqual(a.action.summary, "Run a Claude Code session: Fix the build. It runs on your Claude sign-in with no spending cap; Grux planned about $2.50 of usage.")
        XCTAssertTrue(a.action.isSpend)
        XCTAssertNil(a.amountCents, "the header showed the planned figure as if it were charged or capped")
        let row = GruxControlTools.approvalsRow(a, stamp: ISO8601DateFormatter())
        XCTAssertEqual(row["not_routine_because"] as? [String], ["spends money"])
        XCTAssertEqual(item(budget: 5).action.summary, "Run a Claude Code session: Fix the build. It runs on your Claude sign-in with no spending cap; Grux planned about $5.00 of usage.")
        for budget in [0.004, 0.005, 0.015, 2.5, 5, 25, 1e17] {
            let line = item(budget: budget).action.summary
            XCTAssertFalse(line.contains("up to") || line.contains("may spend"), line)
            XCTAssertNil(item(budget: budget).amountCents, "\(budget)")
        }
    }

    func test_aFigureUnderACentReadsAsUsage() {
        XCTAssertEqual(item(budget: 0.004).action.summary, "Run a Claude Code session: Fix the build. It runs on your Claude sign-in with no spending cap; Grux planned under $0.01 of usage.")
    }

    /// The card says there is no cap because the worker sets none. If a cap
    /// is ever passed, this turns red so the card can say so.
    func test_theWorkerStillSetsNoCap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/GruxAgentCore/SwarmWorker.swift"), encoding: .utf8)
        let code = src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertFalse(code.joined(separator: "\n").contains("max-budget-usd"), "a session now has a cap: say it on the card")
    }

    /// Two builds of the same plan read the same, so the risk question about a
    /// held plan is the item's own state word for word (the input's keys came
    /// out in hash order, which differed between two encodes in one process).
    func test_theSamePlanEncodesTheSameInputEveryTime() {
        let first = item().action.detail["__replay_input"]
        for _ in 0..<50 { XCTAssertEqual(item().action.detail["__replay_input"], first) }
        XCTAssertEqual(first, #"{"budget_usd":2.5,"goal":"Make the build green","max_parallel":3,"template":"architectImplement","title":"Fix the build"}"#)
    }

    // Wave 27 round 1, P0: a model's budget of 1e17 or more passed the floor in
    // `parsePlan`, and the card's cents (`Int(budget * 100)`) trapped, so the
    // nightly cycle crashed Grux. A plan's budget is now kept between the floor
    // and the ceiling wherever it is read.
    private func parsedBudget(_ raw: String) -> Double? {
        let reply = #"{"domain":"ops","chosenGoal":"G","rationale":"r","action":{"title":"T","goal":"G","template":"singleWorker","budgetUSD":"# + raw + "}}"
        return GoalPursuitEngine.parsePlan(reply)?.action?.budgetUSD
    }

    func test_aPlansBudgetIsKeptUnderTheCeiling() {
        let ceiling = GoalPursuitEngine.maxBudgetUSD
        XCTAssertEqual(ceiling, 25)
        for (raw, want) in [("1e17", ceiling), ("100000000000000000", ceiling), ("1e300", ceiling),
                            ("26", ceiling), ("25.01", ceiling), ("25", 25), ("24.99", 24.99),
                            ("5", 5), ("0.5", 0.5), ("0", 5), ("-3", 5)] as [(String, Double)] {
            XCTAssertEqual(parsedBudget(raw), want, "budgetUSD \(raw)")
        }
    }

    /// Built directly, as the deterministic worker and any later caller do: no
    /// budget a caller passes can trap, and the line, the cents and the replay
    /// agree on the one limit.
    func test_anyBudgetBuildsACardThatAgreesWithItsReplay() throws {
        for budget in [1e17, 1e300, Double.infinity, -Double.infinity, Double.nan, -1, 0,
                       25, 25.01, 9.2e16, Double.greatestFiniteMagnitude] {
            let a = item(budget: budget)
            let input = try XCTUnwrap(a.action.detail["__replay_input"].flatMap(ApprovalQueue.decodeInput), "\(budget)")
            let replayed = try XCTUnwrap((input["budget_usd"] as? Double) ?? (input["budget_usd"] as? Int).map(Double.init))
            XCTAssertTrue(replayed > 0 && replayed <= GoalPursuitEngine.maxBudgetUSD, "\(budget) replays \(replayed)")
            XCTAssertTrue(a.action.summary.hasSuffix("Grux planned about \(AgentsView.money(replayed)) of usage."),
                          "\(budget): \(a.action.summary)")
        }
    }

    /// A title that ends a sentence is not given a second stop.
    func test_aTitleEndingASentenceReadsOnce() {
        func line(_ title: String) -> String {
            GoalPursuitEngine.approvalItem(
                PlannedSwarmAction(title: title, goal: "g", template: "singleWorker", budgetUSD: 5),
                domain: "ops", rationale: "r").action.summary
        }
        let rest = " It runs on your Claude sign-in with no spending cap; Grux planned about $5.00 of usage."
        XCTAssertEqual(line("Fix the build."), "Run a Claude Code session: Fix the build." + rest)
        XCTAssertEqual(line("Ship it!"), "Run a Claude Code session: Ship it!" + rest)
        XCTAssertEqual(line("Ready?"), "Run a Claude Code session: Ready?" + rest)
        XCTAssertEqual(line("Fix the build "), "Run a Claude Code session: Fix the build." + rest)
    }

    // W27-P3 item 1: the chat tool told the model `budget_usd` is a "Hard cost
    // ceiling", so chat could call a swarm capped at $5 while Approvals says
    // nothing caps it. The tool, its result line and the plan model's word
    // agree with the worker, which sets no cap.
    func test_theSwarmToolNeverCallsItsBudgetACap() throws {
        let tool = try XCTUnwrap(AgentTools.claudeTools().first { $0.name == "agent_swarm_start" })
        let props = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let budget = try XCTUnwrap((props["budget_usd"] as? [String: Any])?["description"] as? String)
        let lower = budget.lowercased()
        for promise in ["ceiling", "hard", "limit", "stops at", "capped"] {
            XCTAssertFalse(lower.contains(promise), "the budget is described as \(promise): \(budget)")
        }
        XCTAssertTrue(lower.contains("not a cap"), budget)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = try String(contentsOf: root.appendingPathComponent("Sources/Grux/AgentTools.swift"), encoding: .utf8)
        XCTAssertTrue(tools.contains("planned_usage=\\(AgentsView.money(budget)) (no cap)"),
                      "the start result reads the figure as a budget")
        let plan = try String(contentsOf: root.appendingPathComponent("Sources/GruxAgentCore/SwarmPlan.swift"), encoding: .utf8)
        XCTAssertFalse(plan.contains("hard stop on cost"))
    }
}
