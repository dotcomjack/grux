import XCTest
@testable import Grux
@testable import GruxAgentCore

/// Wave 13 review (c0d8f32e...c705568b), each finding red first.
@MainActor
final class Wave13ReviewTests: XCTestCase {

    private func readiness(hold: String?, stage: FoundryProposalStage = .proposed) -> FoundryBuildReadiness {
        FoundryBuildReadiness(auth: .signedIn, subscriptionType: "max", cliInstalled: true, foundryEnabled: true,
                              sourceAvailable: true, stage: stage, buildInFlight: false, escalatedJobId: nil,
                              approvalPending: false, buildHold: hold)
    }

    // P2-1: while another upgrade builds (or the disk is short) the card says
    // so where Build it was, instead of a Build it that accepts and does nothing.
    func test_aHeldCardSaysWhyInsteadOfOfferingBuildIt() {
        let action = FoundryDirection.primaryAction(readiness(
            hold: "not building: another upgrade is building, and one builds at a time on this Mac."))
        XCTAssertEqual(action, .held(reason: "Another upgrade is building, and one builds at a time on this Mac."))
        XCTAssertFalse(action.isActionable)
        XCTAssertEqual(action.title, "Waiting to build")
        XCTAssertEqual(action.subtitle, "Another upgrade is building, and one builds at a time on this Mac.")
        XCTAssertEqual(FoundryDirection.primaryAction(readiness(hold: nil)), .build(power: "powered by your Claude Max subscription"))
    }

    func test_theCardAndStartBuildAskTheHold() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Foundry/SelfUpgradeView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("buildHold: hold"))
        let engine = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Foundry/FoundryEngine.swift"), encoding: .utf8)
        let start = try XCTUnwrap(engine.range(of: "func startBuild(id: UUID) -> Bool {"))
        let body = String(engine[start.upperBound...].prefix(900))
        let hold = try XCTUnwrap(body.range(of: "currentBuildHold()"))
        let accept = try XCTUnwrap(body.range(of: "FoundryDashboardModel.shared.accept"))
        XCTAssertLessThan(hold.lowerBound, accept.lowerBound, "Build it accepts before it asks the hold")
    }

    // P2-2: a card stored with D46's sentence is written back, so the CLI
    // stops printing it.
    func test_everyEarlierSentenceIsWrittenBack() throws {
        for old in DecisionGate.earlierAsksFirstReasons {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("w13-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let item = PendingApproval(action: ProposedAction(kind: .other, summary: "Run tool 'deep_research' (unclassified side effect).",
                                                              target: "deep_research"), reason: old)
            try enc.encode([item]).write(to: url)
            _ = ApprovalQueue(storeURL: url).pendingCount
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            XCTAssertEqual(raw.first?["reason"] as? String, DecisionGate.asksFirstReason, old)
        }
    }

    // P3-1: an escalation whose job just ended still holds until the engine
    // has routed it (its verify runs the full suite); a job the store no
    // longer has holds nothing, so a lost job cannot block builds forever.
    func test_anEscalationHoldsUntilRouted() {
        let p = UUID()
        XCTAssertEqual(FoundryEngine.holdingEscalations(["j": p], jobs: ["j": .done], routing: true), ["j": p])
        XCTAssertEqual(FoundryEngine.holdingEscalations(["j": p], jobs: ["j": .running], routing: true), ["j": p])
        XCTAssertEqual(FoundryEngine.holdingEscalations(["j": p], jobs: [:], routing: true), [:])
    }

    // P3-3: the diff reviewer names its model through the constant.
    func test_theDiffReviewerNamesItsModel() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/Foundry/RDVerifier.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(#"arguments: ["--model", FoundryModelIDs.standard, "--print", prompt]"#))
        XCTAssertFalse(src.contains(#"arguments: ["--print", prompt]"#))
    }

    // P3-6: a long last decision keeps its day in the menu bar.
    func test_theMenuBarKeepsTheDayWhenItTruncates() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/MenuBarView.swift"), encoding: .utf8)
        let at = try XCTUnwrap(src.range(of: "DecisionUsageSummary.datedLastLine(ledger.last)"))
        XCTAssertTrue(src[at.upperBound...].prefix(400).contains(".truncationMode(.middle)"))
    }

    // P3-7: a Self-Upgrade swarm job stored before `startedBy` existed still
    // stays out of chat.
    func test_anOlderSelfUpgradeJobStaysOutOfChat() {
        let job = AgentJob(title: "foundry: Thread 'x' repeated", goal: "g",
                           createdAt: AgentService.startedByIntroduced.addingTimeInterval(-3600), rootDir: "/tmp")
        XCTAssertNil(job.startedBy)
        XCTAssertFalse(AgentService.reportsEndToChat(job))
        XCTAssertTrue(AgentService.reportsEndToChat(AgentJob(title: "research brief", goal: "g", rootDir: "/tmp")))
    }
}
