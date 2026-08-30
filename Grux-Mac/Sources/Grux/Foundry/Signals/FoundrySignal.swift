import Foundation

// The Foundry's Stage 1 currency. Every signal source (telemetry, transcripts,
// swarm logs, test flakes, Compare history, UX screenshot audits) normalizes
// its findings into FoundrySignal values. The ProposalEngine (Stage 2) dedupes
// and ranks these into UpgradeProposals. A signal is evidence-first: summary is
// the one-line headline, evidence is the raw receipts (log lines, message
// excerpts, vote tallies) so a proposal can always cite its sources.
struct FoundrySignal: Codable, Identifiable, Equatable, Sendable {

    enum Severity: String, Codable, CaseIterable, Sendable, Comparable {
        case info
        case low
        case medium
        case high

        private var rank: Int {
            switch self {
            case .info: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    let id: UUID
    // Stable source key, e.g. "telemetry", "transcript", "swarm", "flake",
    // "compare", "ux-audit". Matches FoundrySignalSource.sourceName.
    var source: String
    var severity: Severity
    // One-line headline, human-readable, shown in the Self-Upgrade tab.
    var summary: String
    // Raw receipts: log excerpts, message quotes, counts. Multi-line OK.
    var evidence: String
    var suggestedLane: FoundryLane
    // Trust-ledger domain half of the (lane x domain) pair, e.g. "chat",
    // "swarm", "compare", "tests", "telemetry", "ui:settings".
    var suggestedDomain: String
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        source: String,
        severity: Severity,
        summary: String,
        evidence: String,
        suggestedLane: FoundryLane,
        suggestedDomain: String,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.severity = severity
        self.summary = summary
        self.evidence = evidence
        self.suggestedLane = suggestedLane
        self.suggestedDomain = suggestedDomain
        self.capturedAt = capturedAt
    }
}

// The six lanes from the blueprint (section 01): performance, reliability,
// capability, cost, code health, UX polish. Trust is tracked per
// (lane x domain) pair, so lanes are a closed enum while domains stay free
// strings.
enum FoundryLane: String, Codable, CaseIterable, Sendable {
    case performance
    case reliability
    case capability
    case cost
    case codeHealth = "code-health"
    case uxPolish = "ux-polish"

    var label: String {
        switch self {
        case .performance: return "Performance"
        case .reliability: return "Reliability"
        case .capability: return "Capability"
        case .cost: return "Cost"
        case .codeHealth: return "Code health"
        case .uxPolish: return "UX polish"
        }
    }
}

// One adapter per evidence stream. Implementations must be cheap to construct
// and side-effect free on harvest (read-only against logs/stores). They throw
// on hard failure; SignalHarvester isolates the failure per source so one
// broken stream never blanks the whole Sense pass.
protocol FoundrySignalSource: Sendable {
    var sourceName: String { get }
    func harvest() async throws -> [FoundrySignal]
}
