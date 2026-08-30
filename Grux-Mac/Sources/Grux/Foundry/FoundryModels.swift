import Foundation

// Core value types for the Foundry, Grux's self-upgrade engine
// (blueprint sections 01 and 04). Pure data: lanes, domains, trust
// tiers, risk classes, and the UpgradeProposal record that flows
// through Sense -> Synthesize -> Build -> Verify -> Land.
//
// All money figures in proposals are ESTIMATED API-equivalent spend
// (the engine runs on subscriptions, nothing here is billed dollars),
// so estCostLabel strings always carry the word "estimated".

// One of the six improvement lanes the engine works.
enum UpgradeLane: String, Codable, CaseIterable, Sendable {
    case performance
    case reliability
    case capability
    case cost
    case codeHealth
    case uxPolish

    var displayName: String {
        switch self {
        case .performance: return "Performance"
        case .reliability: return "Reliability"
        case .capability: return "Capability"
        case .cost: return "Cost"
        case .codeHealth: return "Code Health"
        case .uxPolish: return "UX Polish"
        }
    }
}

// Which part of the estate a proposal targets.
enum UpgradeDomain: String, Codable, CaseIterable, Sendable {
    case mac    // the Mac app
    case phone  // GruxPhone (simulator-verified)
    case site   // the project website
    case mini   // self-hosted helper services

    var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .phone: return "Phone"
        case .site: return "Site"
        case .mini: return "Small"
        }
    }
}

// The graduated trust ladder. Every (lane, domain) pair starts at
// propose and earns autonomy on its accepted-change streak.
enum TrustTier: Int, Codable, CaseIterable, Comparable, Sendable {
    case propose = 0    // files the proposal, the user approves the build
    case autoBuild = 1  // builds + verifies autonomously, the user approves install
    case autoLand = 2   // installs behind the rollback keeper, reports in recap

    static func < (lhs: TrustTier, rhs: TrustTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .propose: return "Propose"
        case .autoBuild: return "Auto-Build"
        case .autoLand: return "Auto-Land"
        }
    }

    // One rung up the ladder, clamped at the top.
    var promoted: TrustTier {
        TrustTier(rawValue: rawValue + 1) ?? .autoLand
    }

    // One rung down the ladder, clamped at the floor.
    var demoted: TrustTier {
        TrustTier(rawValue: rawValue - 1) ?? .propose
    }
}

// Blast-radius classification for a proposal. `protected` is forced
// onto anything touching the pinned zones (wire protocol, Keychain,
// Security) and never leaves propose tier.
enum RiskClass: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case protected

    // Sort rank for ranked() ordering: lower is safer.
    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .protected: return 3
        }
    }

    var displayName: String { rawValue.capitalized }
}

// Lifecycle of a proposal through the five-stage loop.
enum ProposalStatus: String, Codable, CaseIterable, Sendable {
    case proposed
    case accepted
    case building
    case verifying
    case landed
    case rejected
    case rolledBack

    var displayName: String {
        switch self {
        case .proposed: return "Proposed"
        case .accepted: return "Accepted"
        case .building: return "Building"
        case .verifying: return "Verifying"
        case .landed: return "Landed"
        case .rejected: return "Rejected"
        case .rolledBack: return "Rolled Back"
        }
    }

    // Terminal states never transition again (rolledBack is terminal;
    // a retry files a fresh proposal so the ledger sees the rollback).
    var isTerminal: Bool {
        self == .rejected || self == .rolledBack
    }
}

// A single piece of evidence backing a proposal, tagged with where it
// came from. Stored as "source: detail" strings, e.g.
// "flake: chat send retried 3x in 7 days" or
// "transcript: corrected calendar tool output 3x on 06-08".
struct UpgradeEvidence: Codable, Equatable, Hashable, Sendable {
    var source: String  // fs-audit, transcript, swarm, compare, crash, screenshot, manual
    var detail: String

    var display: String { "\(source): \(detail)" }
}

// One ranked upgrade proposal produced by the ProposalEngine and
// stored in ProposalStore. readyPrompt is the full context-packed
// Claude Code prompt, ready to fire on the execution rail.
struct UpgradeProposal: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var lane: UpgradeLane
    var domain: UpgradeDomain
    var evidence: [UpgradeEvidence] = []
    // Expected gain score, 0.0 to 1.0. Drives ranked() ordering.
    var expectedGain: Double
    var riskClass: RiskClass
    // Human-readable estimated cost, ALWAYS labeled estimated because
    // the engine is subscription powered, e.g. "$2 estimated".
    var estCostLabel: String
    var tierRequired: TrustTier
    var status: ProposalStatus = .proposed
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var readyPrompt: String

    // Every file path this proposal expects to touch (mined from the
    // prompt by the engine; used for protected-zone pinning).
    var touchedPaths: [String] = []
}
