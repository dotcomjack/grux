import XCTest
@testable import Grux

// D126, sense pass 13: with self-upgrade off, Approvals offered a live Approve on
// "Start a self-upgrade cycle." (queued two days earlier by a model's tool call,
// which the gate queued although the tool refuses while off), and approving it
// recorded the card as Approved while nothing started. The Self-Upgrade pane said
// "proposes nothing" above a listed proposal, and its card read "Checking your
// sign-in" while Now already said the sign-in had expired.
@MainActor
final class SelfUpgradeOffOffersNothingTests: XCTestCase {

    private var savedEnabled = false

    override func setUp() async throws {
        try await super.setUp()
        savedEnabled = AppState.shared.config.foundryEnabled
    }

    override func tearDown() async throws {
        AppState.shared.config.foundryEnabled = savedEnabled
        for item in ApprovalQueue.shared.items where item.state == .pending
            && item.action.detail["__replay_input"]?.contains("SelfUpgradeOffOffersNothingTests") == true {
            ApprovalQueue.shared.skip(item.id)
        }
        try await super.tearDown()
    }

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("d126-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("approvals.json")
    }

    /// The card sense pass 13 read, as the gate stores it.
    private func cycleCard(action: String = "start") -> PendingApproval {
        PendingApproval(action: ProposedAction(kind: .other, summary: "Start a self-upgrade cycle.",
                                               target: "foundry_upgrade_cycle",
                                               detail: ["tool": "foundry_upgrade_cycle",
                                                        "__replay_tool": "foundry_upgrade_cycle",
                                                        "__replay_input": "{\"action\":\"\(action)\"}"]),
                        urgent: false, reason: DecisionGate.asksFirstReason)
    }

    // MARK: - One rule: what would be turned down now

    func testTheCycleIsTurnedDownOnlyWhileOffAndOnlyForAStart() {
        XCTAssertNotNil(CannotRunNow.refusal(tool: "foundry_upgrade_cycle", input: ["action": "start"], foundryEnabled: false))
        XCTAssertNotNil(CannotRunNow.refusal(tool: "foundry_upgrade_cycle", input: [:], foundryEnabled: false),
                        "no action is a start, as dispatchTool reads it")
        XCTAssertNotNil(CannotRunNow.refusal(tool: "foundry_upgrade_cycle", input: ["action": "START"], foundryEnabled: false))
        XCTAssertNil(CannotRunNow.refusal(tool: "foundry_upgrade_cycle", input: ["action": "start"], foundryEnabled: true))
        XCTAssertNil(CannotRunNow.refusal(tool: "foundry_upgrade_cycle", input: ["action": "status"], foundryEnabled: false),
                     "a status read runs while off")
        XCTAssertNil(CannotRunNow.refusal(tool: "create_event", input: [:], foundryEnabled: false))
        // The words are the ones the chat tool and the fast path answer with.
        XCTAssertEqual(CannotRunNow.refusal(tool: "foundry_upgrade_cycle", input: [:], foundryEnabled: false),
                       "foundry: " + (FoundryEngine.manualCycleRefusal(foundryEnabled: false) ?? ""))
    }

    // MARK: - The gate files no card for a call that would be turned down

    func testWhileOffTheGateAnswersAtOnceAndQueuesNothing() async {
        AppState.shared.config.foundryEnabled = false
        let before = ApprovalQueue.shared.items.count
        let outcome = await JaxToolGate.evaluate(name: "foundry_upgrade_cycle",
                                                 input: ["action": "start", "note": "SelfUpgradeOffOffersNothingTests"])
        guard case .shortCircuit(let line) = outcome else { return XCTFail("a refused start must not run") }
        XCTAssertTrue(line.hasPrefix("foundry: not started: self-upgrade is off"), line)
        XCTAssertEqual(ApprovalQueue.shared.items.count, before, "no card waits in Approvals for a cycle that would refuse")
    }

    func testWhileOnTheCycleStillWaitsForAnOK() async {
        AppState.shared.config.foundryEnabled = true
        let outcome = await JaxToolGate.evaluate(name: "foundry_upgrade_cycle",
                                                 input: ["action": "start", "note": "SelfUpgradeOffOffersNothingTests"])
        guard case .shortCircuit(let line) = outcome else { return XCTFail("the cycle is gated while on") }
        XCTAssertTrue(line.hasPrefix("pending:"), line)
    }

    // MARK: - An older card says why, and its Approve does not record a false yes

    func testAnOlderCardSaysItWouldBeTurnedDown() {
        let line = CannotRunNow.cardLine(for: cycleCard(), foundryEnabled: false)
        XCTAssertEqual(line, "Self-upgrade is off, so this would be turned down. Turn it on in Self-Upgrade (or Settings), or Skip it.")
        XCTAssertNil(CannotRunNow.cardLine(for: cycleCard(), foundryEnabled: true))
        XCTAssertNil(CannotRunNow.cardLine(for: cycleCard(action: "status"), foundryEnabled: false))
        var bare = cycleCard()
        bare.action.detail["__replay_input"] = nil
        XCTAssertNotNil(CannotRunNow.cardLine(for: bare, foundryEnabled: false), "a card with no stored input is a start")
        bare.action.detail["__replay_tool"] = nil
        XCTAssertNil(CannotRunNow.cardLine(for: bare, foundryEnabled: false), "nothing to replay, nothing to refuse")
    }

    func testApprovingWhileOffKeepsTheCardWaitingAndRunsNothing() async throws {
        let queue = ApprovalQueue(storeURL: tempURL())
        queue.judgeRisk = nil
        queue.foundryEnabled = { false }
        let item = queue.enqueue(cycleCard())

        let result = await queue.approveAndExecute(item.id)
        XCTAssertTrue(result.hasPrefix("refused: "), result)
        let after = try XCTUnwrap(queue.items.first { $0.id == item.id })
        XCTAssertEqual(after.state, .pending, "a yes that would be turned down is not recorded as Approved")
        XCTAssertNil(after.resolvedAt)
        XCTAssertNil(after.lastFailure, "nothing was tried, so no 'Last try failed' line")
    }

    // Live, iteration 71: `grux approvals --approve` on the card printed "Approved ... Grux
    // has it and started foundry_upgrade_cycle" while the app held it. The door answers
    // before the approve runs, so it asks the same rule first.
    func testTheApproveDoorSaysItWouldBeTurnedDownAndStartsNothing() throws {
        AppState.shared.config.foundryEnabled = false
        var card = cycleCard()
        card.action.detail["__replay_input"] = "{\"action\":\"start\",\"note\":\"SelfUpgradeOffOffersNothingTests\"}"
        let item = ApprovalQueue.shared.enqueue(card)
        let reply = GruxControlTools.approvals(action: "approve", mode: nil, id: item.id.uuidString)
        XCTAssertEqual(reply["isError"] as? Bool, true, "a yes that would be turned down is not 'started'")
        let text = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("Self-upgrade is off, so this would be turned down."), text)
        XCTAssertTrue(text.hasSuffix("Nothing ran; it is still waiting."), text)
        XCTAssertEqual(ApprovalQueue.shared.items.first { $0.id == item.id }?.state, .pending)
    }

    func testTheApprovalsCardShowsTheLineAndHoldsApprove() throws {
        let card = try BackendSweepTests.source("Sources/Grux/Jax/JaxApprovalsSection.swift")
        XCTAssertTrue(card.contains("CannotRunNow.cardLine(for: approval, foundryEnabled: appState.config.foundryEnabled)"),
                      "the section asks the one rule, live")
        XCTAssertTrue(card.contains(".disabled(blocker != nil)"), "Approve is held while it would be turned down")
    }

    // MARK: - The pane's off line under a listed proposal

    func testTheOffLineNamesProposalsFromEarlierPasses() {
        let one = FoundrySchedule.line(enabled: false, schedule: FoundrySchedule(), waiting: 1)
        XCTAssertFalse(one.contains("proposes nothing"), one)
        XCTAssertEqual(one, "Self-upgrade is off, so Grux files no new proposals, spends nothing on its own, and turns down \"upgrade yourself\" until you switch it on here or in Settings. 1 proposal below, from an earlier pass, can still be built; building it switches self-upgrade on.")
        let two = FoundrySchedule.line(enabled: false, schedule: FoundrySchedule(), waiting: 2)
        XCTAssertTrue(two.hasSuffix("2 proposals below, from earlier passes, can still be built; building one switches self-upgrade on."), two)
        // D135 item 9 (sense pass 14): "The proposal below is from an earlier
        // pass" sat over two cards, one of them Not pursued. `waiting` counts
        // only cards with a build left, so the line counts those and never
        // reads as the number of cards listed.
        for n in 1...3 {
            let line = FoundrySchedule.line(enabled: false, schedule: FoundrySchedule(), waiting: n)
            XCTAssertFalse(line.contains("The proposal below") || line.contains("proposals below are"),
                           "\(n): the line reads as a count of every card listed: \(line)")
            XCTAssertTrue(line.contains("can still be built"), "\(n): \(line)")
        }
        XCTAssertEqual(FoundrySchedule.line(enabled: false, schedule: FoundrySchedule(), waiting: 0),
                       FoundrySchedule.line(enabled: false, schedule: FoundrySchedule()),
                       "with nothing listed the line is unchanged")
        XCTAssertEqual(FoundrySchedule.line(enabled: true, schedule: FoundrySchedule(), waiting: 3),
                       "Self-upgrade is on. It runs only when you ask.")
    }

    func testThePaneCountsOnlyProposalsStillToBuild() throws {
        let pane = try BackendSweepTests.source("Sources/Grux/Foundry/SelfUpgradeView.swift")
        XCTAssertTrue(pane.contains("waiting: model.buildableCount"), "the line reads the cards the pane lists")
    }

    // MARK: - A sign-in Now already knows expired is not "Checking"

    func testAKnownExpirySkipsChecking() {
        let live = AccountSwitcher.LiveStatus(loggedIn: true, authMethod: "claude.ai", email: nil, orgId: nil,
                                              orgName: nil, subscriptionType: "max", checkedAt: Date())
        XCTAssertEqual(FoundryDirection.authState(checked: false, liveStatus: nil, knownExpired: true), .signedOut)
        XCTAssertEqual(FoundryDirection.authState(checked: false, liveStatus: nil, knownExpired: false), .checking)
        XCTAssertEqual(FoundryDirection.authState(checked: false, liveStatus: live, knownExpired: true), .signedIn,
                       "a live answer wins over the stored verdict")
        let pane = try? BackendSweepTests.source("Sources/Grux/Foundry/SelfUpgradeView.swift")
        XCTAssertEqual(pane?.components(separatedBy: "knownExpired: signIn.expired").count, 3,
                       "both readiness reads in the pane use the stored verdict")
    }
}
