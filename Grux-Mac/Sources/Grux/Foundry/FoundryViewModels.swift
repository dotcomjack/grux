import Foundation
import SwiftUI

// Display-layer models for the Self-Upgrade tab. Deliberately decoupled from
// the Foundry engine's own types (ProposalStore / TrustLedger / FoundryAudit):
// everything here is plain Strings + Ints so the view compiles and renders
// independently of the engine's enums. The integrator maps engine types into
// these models (see SelfUpgradeView integration notes); until then the tab
// renders honest empty states.

// MARK: - Proposal card model

enum FoundryProposalCardStatus: String, Codable {
    case pending, accepted, rejected
}

struct FoundryProposalCardModel: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var lane: String            // performance, reliability, capability, cost, code health, UX polish
    var domain: String          // module/surface the change touches
    var evidence: [String]      // one line per signal
    var expectedGain: String    // human sentence
    var estimatedCostUSD: Double
    var risk: String            // "low" / "medium" / "high"
    var tierRequired: Int       // 0 propose, 1 auto-build, 2 auto-land
    var score: Double           // ProposalEngine rank score, higher first
    var readyPrompt: String     // context-packed prompt, copied on Accept
    var createdAt: Date
    var status: FoundryProposalCardStatus

    init(
        id: String = UUID().uuidString,
        title: String,
        lane: String,
        domain: String,
        evidence: [String] = [],
        expectedGain: String = "",
        estimatedCostUSD: Double = 0,
        risk: String = "low",
        tierRequired: Int = 0,
        score: Double = 0,
        readyPrompt: String = "",
        createdAt: Date = Date(),
        status: FoundryProposalCardStatus = .pending
    ) {
        self.id = id
        self.title = title
        self.lane = lane
        self.domain = domain
        self.evidence = evidence
        self.expectedGain = expectedGain
        self.estimatedCostUSD = estimatedCostUSD
        self.risk = risk
        self.tierRequired = tierRequired
        self.score = score
        self.readyPrompt = readyPrompt
        self.createdAt = createdAt
        self.status = status
    }
}

// MARK: - Trust ladder tile model

struct FoundryTrustHistoryEvent: Identifiable, Codable, Equatable {
    var id: String
    var date: Date
    var fromTier: Int
    var toTier: Int
    var reason: String

    init(id: String = UUID().uuidString, date: Date = Date(), fromTier: Int, toTier: Int, reason: String) {
        self.id = id
        self.date = date
        self.fromTier = fromTier
        self.toTier = toTier
        self.reason = reason
    }

    var isPromotion: Bool { toTier > fromTier }
}

struct FoundryTrustTileModel: Identifiable, Codable, Equatable {
    var lane: String
    var domain: String
    var tier: Int               // 0 propose, 1 auto-build, 2 auto-land
    var streak: Int             // consecutive accepted changes, promotes at 5
    var pinnedTierZero: Bool    // wire protocol / Keychain / Security, forever Tier 0
    var history: [FoundryTrustHistoryEvent]

    var id: String { "\(lane)|\(domain)" }

    init(lane: String, domain: String, tier: Int = 0, streak: Int = 0, pinnedTierZero: Bool = false, history: [FoundryTrustHistoryEvent] = []) {
        self.lane = lane
        self.domain = domain
        self.tier = tier
        self.streak = streak
        self.pinnedTierZero = pinnedTierZero
        self.history = history
    }
}

// MARK: - Pure formatting + ranking helpers (unit tested)

enum FoundryFormat {

    // Costs always display as $N and always carry the estimated label,
    // because the engine runs on subscriptions, never billed dollars.
    static func estimatedCostLabel(usd: Double) -> String {
        let clamped = max(0, usd)
        let amount: String
        if clamped >= 10 {
            amount = "$\(Int(clamped.rounded()))"
        } else if clamped == clamped.rounded() {
            amount = "$\(Int(clamped))"
        } else {
            amount = String(format: "$%.2f", clamped)
        }
        return "\(amount) estimated (subscription powered)"
    }

    // Pull the first $N figure out of an engine cost label like
    // "$2 estimated" so display math (and the canonical label) can rebuild
    // from a number. Returns 0 when no dollar figure is present.
    static func parseDollars(_ label: String) -> Double {
        guard let range = label.range(of: #"\$[0-9]+(\.[0-9]+)?"#, options: .regularExpression) else { return 0 }
        return Double(label[range].dropFirst()) ?? 0
    }

    // Evidence lists collapse to a few lines with a "+N more" affordance.
    static func truncateEvidence(_ items: [String], limit: Int = 2) -> (visible: [String], hiddenCount: Int) {
        let cap = max(0, limit)
        guard items.count > cap else { return (items, 0) }
        return (Array(items.prefix(cap)), items.count - cap)
    }

    // Ranked order for the proposals pane: pending first (by score, then
    // newest), then accepted, then rejected, so live work floats and the
    // decided pile sinks without disappearing.
    static func ranked(_ proposals: [FoundryProposalCardModel]) -> [FoundryProposalCardModel] {
        proposals.sorted { a, b in
            if statusOrder(a.status) != statusOrder(b.status) {
                return statusOrder(a.status) < statusOrder(b.status)
            }
            if a.score != b.score { return a.score > b.score }
            return a.createdAt > b.createdAt
        }
    }

    static func statusOrder(_ status: FoundryProposalCardStatus) -> Int {
        switch status {
        case .pending: return 0
        case .accepted: return 1
        case .rejected: return 2
        }
    }

    static func tierName(_ tier: Int) -> String {
        switch tier {
        case 0: return "TIER 0 / PROPOSE"
        case 1: return "TIER 1 / AUTO-BUILD"
        default: return "TIER 2 / AUTO-LAND"
        }
    }

    static func relativeStamp(_ date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

// MARK: - Dashboard model

// The Self-Upgrade tab's single observable surface. The Foundry engine (or
// the integrator's glue) pushes proposal cards + trust tiles in, and installs
// the onAccept / onReject hooks so decisions flow back into ProposalStore and
// TrustLedger. The view itself only mutates display status and the local
// timeline; everything engine-side goes through the hooks.
@MainActor
final class FoundryDashboardModel: ObservableObject {
    static let shared = FoundryDashboardModel()

    @Published var proposals: [FoundryProposalCardModel] = []
    @Published var trustTiles: [FoundryTrustTileModel] = []

    // Integration hooks: wired by the integrator to ProposalStore.accept /
    // ProposalStore.reject + TrustLedger.record* (see SelfUpgradeView notes).
    var onAccept: ((FoundryProposalCardModel) -> Void)?
    var onReject: ((FoundryProposalCardModel) -> Void)?

    private let timeline: FoundryTimelineStore

    init(timeline: FoundryTimelineStore? = nil) {
        self.timeline = timeline ?? FoundryTimelineStore.shared
    }

    var pendingCount: Int { proposals.filter { $0.status == .pending }.count }
    var ranked: [FoundryProposalCardModel] { FoundryFormat.ranked(proposals) }

    // Marks the card accepted, records the decision in the local timeline,
    // and fires the engine hook. Returns the readyPrompt so the view can put
    // it on the clipboard (AppKit stays out of the model for testability).
    @discardableResult
    func accept(id: String) -> String? {
        guard let idx = proposals.firstIndex(where: { $0.id == id }), proposals[idx].status == .pending else { return nil }
        proposals[idx].status = .accepted
        let card = proposals[idx]
        timeline.append(FoundryTimelineEntry(
            kind: .accepted,
            title: "Accepted: \(card.title)",
            detail: "Ready prompt copied. \(FoundryFormat.estimatedCostLabel(usd: card.estimatedCostUSD))",
            lane: card.lane,
            domain: card.domain
        ))
        onAccept?(card)
        return card.readyPrompt
    }

    func reject(id: String) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }), proposals[idx].status == .pending else { return }
        proposals[idx].status = .rejected
        let card = proposals[idx]
        timeline.append(FoundryTimelineEntry(
            kind: .rejected,
            title: "Rejected: \(card.title)",
            detail: "Two rejections on a (lane x domain) pair demote its tier.",
            lane: card.lane,
            domain: card.domain
        ))
        onReject?(card)
    }
}
