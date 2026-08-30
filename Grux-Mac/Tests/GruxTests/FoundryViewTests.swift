import XCTest
@testable import Grux

// Pure-logic tests for the Self-Upgrade tab: evidence truncation, the
// estimated-cost label (always $N, always labeled estimated and subscription
// powered), ranking order, dashboard accept/reject transitions, and the
// FoundryTimelineStore persistence round-trip. Every store test uses its own
// temp URL so nothing touches the real Application Support files.
@MainActor
final class FoundryViewTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-foundry-timeline-test-\(UUID().uuidString).json")
    }

    // MARK: - Evidence truncation

    func testEvidenceTruncation() {
        let items = ["a", "b", "c", "d", "e"]

        let t = FoundryFormat.truncateEvidence(items, limit: 2)
        XCTAssertEqual(t.visible, ["a", "b"])
        XCTAssertEqual(t.hiddenCount, 3)

        let all = FoundryFormat.truncateEvidence(["a", "b"], limit: 2)
        XCTAssertEqual(all.visible, ["a", "b"])
        XCTAssertEqual(all.hiddenCount, 0, "no hidden count when under the cap")

        let empty = FoundryFormat.truncateEvidence([], limit: 2)
        XCTAssertTrue(empty.visible.isEmpty)
        XCTAssertEqual(empty.hiddenCount, 0)

        let negative = FoundryFormat.truncateEvidence(items, limit: -1)
        XCTAssertTrue(negative.visible.isEmpty, "negative limit clamps to zero visible")
        XCTAssertEqual(negative.hiddenCount, 5)
    }

    // MARK: - Estimated cost label

    func testEstimatedCostLabelAlwaysLabeledEstimated() {
        XCTAssertEqual(FoundryFormat.estimatedCostLabel(usd: 3), "$3 estimated (subscription powered)")
        XCTAssertEqual(FoundryFormat.estimatedCostLabel(usd: 0.45), "$0.45 estimated (subscription powered)")
        XCTAssertEqual(FoundryFormat.estimatedCostLabel(usd: 12.6), "$13 estimated (subscription powered)")
        XCTAssertEqual(FoundryFormat.estimatedCostLabel(usd: 0), "$0 estimated (subscription powered)")
        XCTAssertEqual(FoundryFormat.estimatedCostLabel(usd: -2), "$0 estimated (subscription powered)", "negative clamps to $0")
        // Every label carries both markers, no exceptions.
        for usd in [0.0, 0.07, 1.5, 4.0, 25.0] {
            let label = FoundryFormat.estimatedCostLabel(usd: usd)
            XCTAssertTrue(label.hasPrefix("$"))
            XCTAssertTrue(label.contains("estimated"))
            XCTAssertTrue(label.contains("subscription powered"))
        }
    }

    // MARK: - Ranking

    func testRankedOrderPendingFirstByScore() {
        let old = Date(timeIntervalSinceNow: -3600)
        let new = Date()
        let cards = [
            FoundryProposalCardModel(id: "rejected-high", title: "r", lane: "cost", domain: "chat", score: 99, createdAt: old, status: .rejected),
            FoundryProposalCardModel(id: "pending-low", title: "p1", lane: "ux polish", domain: "notes", score: 1, createdAt: old, status: .pending),
            FoundryProposalCardModel(id: "accepted-mid", title: "a", lane: "reliability", domain: "shell", score: 50, createdAt: old, status: .accepted),
            FoundryProposalCardModel(id: "pending-high", title: "p2", lane: "performance", domain: "orb", score: 10, createdAt: old, status: .pending),
            FoundryProposalCardModel(id: "pending-tie-new", title: "p3", lane: "capability", domain: "voice", score: 10, createdAt: new, status: .pending),
        ]
        let ranked = FoundryFormat.ranked(cards).map(\.id)
        XCTAssertEqual(ranked, ["pending-tie-new", "pending-high", "pending-low", "accepted-mid", "rejected-high"],
                       "pending first by score desc (newest wins ties), then accepted, then rejected")
    }

    // MARK: - Tier names

    func testTierNames() {
        XCTAssertEqual(FoundryFormat.tierName(0), "TIER 0 / PROPOSE")
        XCTAssertEqual(FoundryFormat.tierName(1), "TIER 1 / AUTO-BUILD")
        XCTAssertEqual(FoundryFormat.tierName(2), "TIER 2 / AUTO-LAND")
    }

    // MARK: - Relative stamp

    func testRelativeStamp() {
        let now = Date()
        XCTAssertEqual(FoundryFormat.relativeStamp(now.addingTimeInterval(-10), relativeTo: now), "now")
        XCTAssertEqual(FoundryFormat.relativeStamp(now.addingTimeInterval(-120), relativeTo: now), "2m ago")
        XCTAssertEqual(FoundryFormat.relativeStamp(now.addingTimeInterval(-7200), relativeTo: now), "2h ago")
        XCTAssertEqual(FoundryFormat.relativeStamp(now.addingTimeInterval(-172_800), relativeTo: now), "2d ago")
    }

    // MARK: - Dashboard accept / reject flow

    func testAcceptMarksStatusReturnsPromptAndLogsTimeline() {
        let timeline = FoundryTimelineStore(storageURL: tempURL())
        let model = FoundryDashboardModel(timeline: timeline)
        var hookFired: FoundryProposalCardModel?
        model.onAccept = { hookFired = $0 }
        model.proposals = [
            FoundryProposalCardModel(id: "p1", title: "Cache theme palette", lane: "performance", domain: "design system", readyPrompt: "Do the thing.")
        ]

        let prompt = model.accept(id: "p1")
        XCTAssertEqual(prompt, "Do the thing.")
        XCTAssertEqual(model.proposals[0].status, .accepted)
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(hookFired?.id, "p1", "engine hook receives the accepted card")
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries[0].kind, .accepted)
        XCTAssertTrue(timeline.entries[0].detail.contains("estimated"), "timeline detail keeps the estimated cost label")

        // Re-accepting a decided card is a no-op.
        XCTAssertNil(model.accept(id: "p1"))
        XCTAssertEqual(timeline.entries.count, 1)
    }

    func testRejectMarksStatusAndLogsTimeline() {
        let timeline = FoundryTimelineStore(storageURL: tempURL())
        let model = FoundryDashboardModel(timeline: timeline)
        var hookFired: FoundryProposalCardModel?
        model.onReject = { hookFired = $0 }
        model.proposals = [
            FoundryProposalCardModel(id: "p2", title: "Rewrite wire protocol", lane: "capability", domain: "security")
        ]

        model.reject(id: "p2")
        XCTAssertEqual(model.proposals[0].status, .rejected)
        XCTAssertEqual(hookFired?.id, "p2")
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries[0].kind, .rejected)

        // Rejecting again is a no-op.
        model.reject(id: "p2")
        XCTAssertEqual(timeline.entries.count, 1)
    }

    // MARK: - Timeline store

    func testTimelineStorePersistsAndOrdersReverseChron() {
        let url = tempURL()
        let store = FoundryTimelineStore(storageURL: url)
        XCTAssertTrue(store.entries.isEmpty)

        let older = FoundryTimelineEntry(date: Date(timeIntervalSinceNow: -100), kind: .cycle, title: "Cycle 1 ran")
        let newer = FoundryTimelineEntry(date: Date(), kind: .landed, title: "Landed sidebar groups")
        store.append(older)
        store.append(newer)
        XCTAssertEqual(store.ordered.map(\.title), ["Landed sidebar groups", "Cycle 1 ran"], "newest first")

        store.flush()
        let reloaded = FoundryTimelineStore(storageURL: url)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.ordered.first?.kind, .landed)
    }

    func testTimelineStoreCapsEntries() {
        let store = FoundryTimelineStore(storageURL: tempURL())
        for i in 0..<(FoundryTimelineStore.maxEntries + 25) {
            store.append(FoundryTimelineEntry(kind: .proposed, title: "p\(i)"))
        }
        XCTAssertEqual(store.entries.count, FoundryTimelineStore.maxEntries)
        XCTAssertEqual(store.entries.first?.title, "p25", "oldest entries fall off the front")
    }

    // MARK: - Bridge mapping (engine types -> display models)

    func testParseDollars() {
        XCTAssertEqual(FoundryFormat.parseDollars("$2 estimated"), 2)
        XCTAssertEqual(FoundryFormat.parseDollars("$0.45 estimated (subscription powered)"), 0.45)
        XCTAssertEqual(FoundryFormat.parseDollars("est $15 to $30 equivalent"), 15, "first figure wins")
        XCTAssertEqual(FoundryFormat.parseDollars("no figure here"), 0)
    }

    func testBridgeCardMapping() {
        let proposal = UpgradeProposal(
            title: "Debounce orb glow repaints",
            lane: .performance,
            domain: .mac,
            evidence: [UpgradeEvidence(source: "metrics", detail: "p95 repaint 41ms over 7d")],
            expectedGain: 0.72,
            riskClass: .low,
            estCostLabel: "$2 estimated",
            tierRequired: .propose,
            readyPrompt: "Do it."
        )
        let card = FoundryViewBridge.card(from: proposal)
        XCTAssertEqual(card.id, proposal.id.uuidString)
        XCTAssertEqual(card.lane, "Performance")
        XCTAssertEqual(card.domain, "Mac")
        XCTAssertEqual(card.evidence, ["metrics: p95 repaint 41ms over 7d"])
        XCTAssertEqual(card.estimatedCostUSD, 2)
        XCTAssertEqual(card.tierRequired, 0)
        XCTAssertEqual(card.score, 0.72)
        XCTAssertEqual(card.status, .pending)
        XCTAssertEqual(FoundryViewBridge.cardStatus(.building), .accepted, "in-flight statuses display as accepted")
        XCTAssertEqual(FoundryViewBridge.cardStatus(.rolledBack), .rejected)
    }

    func testBridgeTierChangeReplay() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var history: [TrustLedger.LedgerEvent] = []
        // Five accepted-and-kept in a row promotes 0 -> 1.
        for i in 0..<5 {
            history.append(TrustLedger.LedgerEvent(outcome: .acceptedAndKept, proposalId: nil, at: base.addingTimeInterval(Double(i))))
        }
        // One rejection keeps the tier; the second demotes 1 -> 0.
        history.append(TrustLedger.LedgerEvent(outcome: .rejected, proposalId: nil, at: base.addingTimeInterval(10)))
        history.append(TrustLedger.LedgerEvent(outcome: .rejected, proposalId: nil, at: base.addingTimeInterval(11)))
        // A rollback at tier 0 stays clamped at the floor: no event emitted.
        history.append(TrustLedger.LedgerEvent(outcome: .rolledBack, proposalId: nil, at: base.addingTimeInterval(12)))

        let changes = FoundryViewBridge.tierChanges(from: history)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].fromTier, 0)
        XCTAssertEqual(changes[0].toTier, 1)
        XCTAssertTrue(changes[0].isPromotion)
        XCTAssertEqual(changes[1].fromTier, 1)
        XCTAssertEqual(changes[1].toTier, 0)
        XCTAssertFalse(changes[1].isPromotion)
    }
}
