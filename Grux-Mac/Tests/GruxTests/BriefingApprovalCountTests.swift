import XCTest
@testable import Grux

/// D125: the briefing's "N waiting for your OK" counts what the approval queue
/// says is waiting, and nothing else.
///
/// Measured live 2026-11-01 10:25 PM: ~/.grux/jax/approvals.json held 2
/// pending, 14 approved and 14 skipped items, and the briefing listed no
/// approvals at all. `JaxApprovalCount` read
/// `Application Support/Grux/jax/approvals.json`, a file the queue never
/// writes, so the count was always 0; had it found the file, it filtered on a
/// `status` key the queue never writes (the queue writes `state`), so every
/// approved and skipped item would have counted as waiting.
@MainActor
final class BriefingApprovalCountTests: XCTestCase {

    private func action(_ marker: String) -> ProposedAction {
        ProposedAction(kind: .other, summary: "D125 \(marker)", target: "d125-\(marker)", detail: [:])
    }

    func test_theBriefingCountsOnlyWhatTheQueueSaysIsWaiting() {
        let queue = ApprovalQueue.shared
        queue.judgeRisk = nil
        let marker = UUID().uuidString.prefix(8)
        let waiting = queue.enqueue(action("waiting \(marker)"))
        let approved = queue.enqueue(action("approved \(marker)"))
        let skipped = queue.enqueue(action("skipped \(marker)"))
        defer { queue.skip(waiting.id) }
        _ = queue.approve(approved.id)
        queue.skip(skipped.id)

        XCTAssertGreaterThanOrEqual(queue.pendingCount, 1)
        XCTAssertEqual(JaxApprovalCount.pending(), queue.pendingCount,
                       "the briefing and the approval queue disagree on what is waiting")
    }

    func test_aResolvedItemNeverCountsAsWaiting() {
        let queue = ApprovalQueue.shared
        queue.judgeRisk = nil
        let marker = UUID().uuidString.prefix(8)
        let before = JaxApprovalCount.pending()
        let item = queue.enqueue(action("resolved \(marker)"))
        XCTAssertEqual(JaxApprovalCount.pending(), before + 1, "a new item waits")
        queue.skip(item.id)
        XCTAssertEqual(JaxApprovalCount.pending(), before, "a skipped item still counts as waiting")
    }

    /// Live 2026-11-02 12:15 AM, the first briefing after the fix: rows
    /// "2 waiting for your OK" and "1 self-upgrade proposal", spoken as
    /// "2 things are waiting for your OK". The spoken count added rows. D179:
    /// each place is counted apart, so a proposal never joins the approvals count.
    func test_theSpokenCountAddsWhatEachRowStandsFor() {
        let items = [
            BriefingItem(kind: .approvalPending, title: "2 waiting for your OK", count: 2),
            BriefingItem(kind: .proposalPending, title: "1 self-upgrade proposal", count: 1),
        ]
        let text = BriefingEngine.fallbackSpoken(slot: .morning, items: items)
        XCTAssertTrue(text.contains("2 things are waiting for your OK in Approvals."), text)
        XCTAssertTrue(text.contains("1 self-upgrade proposal is waiting for your review in Self-Upgrade."), text)
        XCTAssertFalse(text.contains("3 things"), text)

        let one = [BriefingItem(kind: .approvalPending, title: "1 waiting for your OK", count: 1)]
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: one)
            .contains("1 thing is waiting for your OK in Approvals."))

        // A row saved before the count existed stands for one thing.
        let old = [BriefingItem(kind: .proposalPending, title: "1 self-upgrade proposal")]
        XCTAssertTrue(BriefingEngine.fallbackSpoken(slot: .morning, items: old)
            .contains("1 self-upgrade proposal is waiting for your review in Self-Upgrade."))
    }

    /// The class guard: inside the app, only the queue itself (and Foundry's
    /// own, separate approvals store) names the file, so no other surface can
    /// count waiting approvals by its own reading of it.
    func test_onlyTheQueuesOwnStoresNameTheFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let allowed: Set<String> = ["Jax/ApprovalQueue.swift", "Foundry/FoundryApprovals.swift"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            guard !allowed.contains(rel) else { continue }
            let src = try String(contentsOf: url, encoding: .utf8)
            for line in src.components(separatedBy: "\n") where line.contains("\"approvals.json\"") {
                offenders.append("\(rel): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "count waiting approvals through ApprovalQueue, not by reading its file")
    }

    // Wave 36: the spoken line adds proposals to "waiting for your OK", so it
    // may count only proposals that wait for the person's review; one already
    // accepted, building or verifying has their yes. Now and Self-Upgrade's
    // "pending" count the same ones.
    func test_onlyProposalsWaitingForReviewAreCountedAsWaiting() throws {
        func proposal(_ status: ProposalStatus) -> UpgradeProposal {
            var p = UpgradeProposal(title: "w36 \(status.rawValue)", lane: .performance, domain: .mac,
                                    evidence: [], expectedGain: 0.5, riskClass: .low,
                                    estCostLabel: "$1 estimated", tierRequired: .propose,
                                    readyPrompt: "x")
            p.status = status
            return p
        }
        for status in ProposalStatus.allCases {
            let waits = status == .proposed
            XCTAssertEqual(ProposalStore.awaitingReview([proposal(status)]), waits ? 1 : 0, status.rawValue)
            XCTAssertEqual(FoundryViewBridge.cardStatus(status) == .pending, waits,
                           "Now and Self-Upgrade count \(status.rawValue) the same way")
        }
        XCTAssertEqual(ProposalStore.awaitingReview(ProposalStatus.allCases.map(proposal)), 1)
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/BriefingApprovalCountTests.swift",
            with: "Sources/Grux/Jax/BriefingEngine.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("ProposalStore.waitingForReview("), "the briefing counts through the one rule")
    }

    /// W36-P3 item 7, the class guard: the morning brief said "2 proposals
    /// waiting on you" and Today listed "2 improvements to review" for
    /// proposals already accepted, building or verifying, because both counted
    /// `ranked()`, every open proposal. Any surface that reads the ranked book
    /// for a person filters it through the review rule Now and Self-Upgrade use.
    func test_everySurfaceThatCountsProposalsUsesTheReviewRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let src = try String(contentsOf: url, encoding: .utf8)
            for line in src.components(separatedBy: "\n")
            where line.contains("ProposalStore.shared.ranked(") && !line.contains("waitingForReview(") {
                offenders.append("\(rel): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "count proposals for a person through ProposalStore.waitingForReview")

        func proposal(_ status: ProposalStatus) -> UpgradeProposal {
            var p = UpgradeProposal(title: "w36p3 \(status.rawValue)", lane: .performance, domain: .mac,
                                    evidence: [], expectedGain: 0.5, riskClass: .low,
                                    estCostLabel: "$1 estimated", tierRequired: .propose,
                                    readyPrompt: "x")
            p.status = status
            return p
        }
        let all = ProposalStatus.allCases.map(proposal)
        XCTAssertEqual(ProposalStore.waitingForReview(all).map(\.status), [.proposed])
        XCTAssertEqual(ProposalStore.awaitingReview(all), ProposalStore.waitingForReview(all).count)
    }

    /// The brief is read aloud to a person who may never have opened
    /// Self-Upgrade: it names what the proposals are, as the briefing does.
    func test_theMorningBriefNamesSelfUpgradeProposals() throws {
        let one = MorningBriefScheduler.defaultNarrative(
            agenda: [], tasks: [], commitments: [], parked: [], proposalCount: 1)
        XCTAssertTrue(one.contains("1 self-upgrade proposal waiting for your review."), one)
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/BriefingApprovalCountTests.swift",
            with: "Sources/Grux/Reminders/MorningBrief.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("Foundry proposals waiting"), "the model is not told an internal name to read aloud")
    }
}
