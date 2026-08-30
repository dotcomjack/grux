import Foundation
import Combine

// Glue between the Foundry engine stores (ProposalStore, TrustLedger) and
// the Self-Upgrade tab's display layer (FoundryDashboardModel +
// FoundryTimelineStore). One activate() call at startup keeps the tab live:
//   • ProposalStore.$proposals  -> FoundryProposalCardModel cards
//   • TrustLedger.$entries      -> FoundryTrustTileModel tiles
//   • dashboard Accept/Reject   -> ProposalStore.transition + TrustLedger
//                                  records
// The engine should also call mirror(action:proposal:) at every
// build/land/rollback stage, so the timeline carries the whole audit trail
// (hard rail five).
@MainActor
enum FoundryViewBridge {

    private static var cancellables: Set<AnyCancellable> = []
    private static var activated = false

    static func activate(
        proposalStore: ProposalStore? = nil,
        trustLedger: TrustLedger? = nil,
        dashboard: FoundryDashboardModel? = nil
    ) {
        guard !activated else { return }
        activated = true
        let proposalStore = proposalStore ?? .shared
        let trustLedger = trustLedger ?? .shared
        let dashboard = dashboard ?? .shared

        dashboard.proposals = proposalStore.proposals.map(card(from:))
        dashboard.trustTiles = trustLedger.entries.map(tile(from:))

        proposalStore.$proposals
            .sink { [weak dashboard] proposals in
                dashboard?.proposals = proposals.map(card(from:))
            }
            .store(in: &cancellables)

        trustLedger.$entries
            .sink { [weak dashboard] entries in
                dashboard?.trustTiles = entries.map(tile(from:))
            }
            .store(in: &cancellables)

        // Accept: legal transition proposed -> accepted.
        // (TrustLedger's acceptedAndKept is recorded later, after the change
        // lands and survives the 24h watch window; not at accept time.)
        dashboard.onAccept = { card in
            guard let id = UUID(uuidString: card.id) else { return }
            proposalStore.transition(id: id, to: .accepted)
        }

        // Reject: legal transition -> rejected, ledger rejection (two in a
        // row demotes the pair). The ledger write rides the
        // FoundryTrustTransitions choke point so a demotion triggered by
        // this rejection lands the demotion timeline entry (hard rail five),
        // exactly like the install-approval reject path.
        dashboard.onReject = { card in
            guard let id = UUID(uuidString: card.id) else { return }
            if let updated = proposalStore.transition(id: id, to: .rejected) {
                FoundryTrustTransitions.recordRejected(proposal: updated, ledger: trustLedger)
            }
        }
    }

    // Convenience for the engine: append the audit timeline entry that
    // matches an action in one call.
    static func mirror(
        action: FoundryAudit.Action,
        proposal: UpgradeProposal,
        detail: String = "",
        timeline: FoundryTimelineStore? = nil
    ) {
        (timeline ?? .shared).append(FoundryTimelineEntry(
            kind: timelineKind(for: action),
            title: "\(titlePrefix(for: action)): \(proposal.title)",
            detail: detail.isEmpty ? proposal.estCostLabel : detail,
            lane: proposal.lane.displayName,
            domain: proposal.domain.displayName
        ))
    }

    // MARK: - Mapping (pure, unit tested)

    static func card(from p: UpgradeProposal) -> FoundryProposalCardModel {
        FoundryProposalCardModel(
            id: p.id.uuidString,
            title: p.title,
            lane: p.lane.displayName,
            domain: p.domain.displayName,
            evidence: p.evidence.map(\.display),
            expectedGain: "Expected gain score \(Int((p.expectedGain * 100).rounded())) of 100",
            estimatedCostUSD: FoundryFormat.parseDollars(p.estCostLabel),
            risk: p.riskClass.displayName,
            tierRequired: p.tierRequired.rawValue,
            score: p.expectedGain,
            readyPrompt: p.readyPrompt,
            createdAt: p.createdAt,
            status: cardStatus(p.status)
        )
    }

    static func cardStatus(_ status: ProposalStatus) -> FoundryProposalCardStatus {
        switch status {
        case .proposed: return .pending
        case .rejected, .rolledBack: return .rejected
        case .accepted, .building, .verifying, .landed: return .accepted
        }
    }

    static func tile(from entry: TrustLedger.LedgerEntry) -> FoundryTrustTileModel {
        FoundryTrustTileModel(
            lane: entry.lane.displayName,
            domain: entry.domain.displayName,
            tier: entry.tier.rawValue,
            streak: entry.streak,
            pinnedTierZero: false,
            history: tierChanges(from: entry.history)
        )
    }

    // The ledger's history records outcomes, not tier moves. Replay the
    // outcomes with the ledger's own rules (promote at a 5 streak, demote on
    // rollback or two consecutive rejections) to reconstruct the
    // promote/demote history the tile popover shows.
    static func tierChanges(from history: [TrustLedger.LedgerEvent]) -> [FoundryTrustHistoryEvent] {
        var tier = 0
        var streak = 0
        var consecutiveRejections = 0
        var changes: [FoundryTrustHistoryEvent] = []
        for event in history.sorted(by: { $0.at < $1.at }) {
            switch event.outcome {
            case .acceptedAndKept:
                consecutiveRejections = 0
                streak += 1
                if streak >= 5 {
                    let from = tier
                    tier = min(tier + 1, 2)
                    streak = 0
                    if tier != from {
                        changes.append(FoundryTrustHistoryEvent(
                            date: event.at, fromTier: from, toTier: tier,
                            reason: "Streak of 5 accepted-and-kept changes"
                        ))
                    }
                }
            case .rolledBack:
                streak = 0
                consecutiveRejections = 0
                let from = tier
                tier = max(tier - 1, 0)
                if tier != from {
                    changes.append(FoundryTrustHistoryEvent(
                        date: event.at, fromTier: from, toTier: tier,
                        reason: "Rollback"
                    ))
                }
            case .rejected:
                streak = 0
                consecutiveRejections += 1
                if consecutiveRejections >= 2 {
                    consecutiveRejections = 0
                    let from = tier
                    tier = max(tier - 1, 0)
                    if tier != from {
                        changes.append(FoundryTrustHistoryEvent(
                            date: event.at, fromTier: from, toTier: tier,
                            reason: "Two consecutive rejections"
                        ))
                    }
                }
            }
        }
        return changes
    }

    static func timelineKind(for action: FoundryAudit.Action) -> FoundryTimelineKind {
        switch action {
        case .proposed: return .proposed
        case .accepted: return .accepted
        case .rejected: return .rejected
        case .buildStarted, .verifyStarted: return .built
        case .landed: return .landed
        case .rolledBack: return .rollback
        case .tierPromoted: return .promotion
        case .tierDemoted: return .demotion
        }
    }

    static func titlePrefix(for action: FoundryAudit.Action) -> String {
        switch action {
        case .proposed: return "Proposed"
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .buildStarted: return "Build started"
        case .verifyStarted: return "Verify started"
        case .landed: return "Landed"
        case .rolledBack: return "Rolled back"
        case .tierPromoted: return "Tier promoted"
        case .tierDemoted: return "Tier demoted"
        }
    }

    // Test seam: tears down subscriptions and hooks.
    static func deactivateForTesting(dashboard: FoundryDashboardModel? = nil) {
        cancellables.removeAll()
        let dashboard = dashboard ?? .shared
        dashboard.onAccept = nil
        dashboard.onReject = nil
        activated = false
    }
}
