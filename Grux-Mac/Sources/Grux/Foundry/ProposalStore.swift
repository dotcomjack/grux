import Foundation

// Disk layout for the Foundry. Lives beside Persistence's other
// subdirectories but defined here so the Foundry ships as new files
// only (no edits to Persistence.swift).
enum FoundryPaths {
    static var dir: URL {
        let dir = Persistence.supportDir.appendingPathComponent("foundry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var proposalsURL: URL { dir.appendingPathComponent("proposals.json") }
    static var trustLedgerURL: URL { dir.appendingPathComponent("trust-ledger.json") }
}

// JSON-on-disk store for UpgradeProposals. Mirrors NotesStore's shape:
// @MainActor singleton, @Published items, atomic writes via the
// Persistence helpers, debounced scheduleSave so proposal-engine bursts
// collapse into one disk write.
@MainActor
final class ProposalStore: ObservableObject {
    static let shared = ProposalStore()

    @Published private(set) var proposals: [UpgradeProposal] = []

    private let storageURL: URL
    private var saveTask: Task<Void, Never>?

    // Tests inject a temp URL; the app uses the shared singleton.
    init(storageURL: URL = FoundryPaths.proposalsURL) {
        self.storageURL = storageURL
        load()
    }

    func load() {
        proposals = Persistence.load([UpgradeProposal].self, from: storageURL, fallback: [])
    }

    // MARK: - CRUD

    // File a proposal. Protected-zone pinning is enforced here so no
    // caller can sneak a wire-protocol / Keychain / Security touch past
    // the rail: anything touching a pinned path is forced to
    // riskClass=protected and tierRequired=propose before it is stored.
    @discardableResult
    func file(_ proposal: UpgradeProposal) -> UpgradeProposal {
        let pinned = TrustLedger.applyProtectedPinning(to: proposal)
        proposals.insert(pinned, at: 0)
        scheduleSave()
        return pinned
    }

    @discardableResult
    func update(
        id: UUID,
        title: String? = nil,
        evidence: [UpgradeEvidence]? = nil,
        expectedGain: Double? = nil,
        estCostLabel: String? = nil,
        readyPrompt: String? = nil,
        touchedPaths: [String]? = nil
    ) -> UpgradeProposal? {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return nil }
        if let title { proposals[idx].title = title }
        if let evidence { proposals[idx].evidence = evidence }
        if let expectedGain { proposals[idx].expectedGain = expectedGain }
        if let estCostLabel { proposals[idx].estCostLabel = estCostLabel }
        if let readyPrompt { proposals[idx].readyPrompt = readyPrompt }
        if let touchedPaths { proposals[idx].touchedPaths = touchedPaths }
        proposals[idx].updatedAt = Date()
        // Re-pin after edits: a prompt rewrite can pull a protected path
        // into scope, and pinning is one-way.
        proposals[idx] = TrustLedger.applyProtectedPinning(to: proposals[idx])
        scheduleSave()
        return proposals[idx]
    }

    func delete(id: UUID) {
        proposals.removeAll { $0.id == id }
        scheduleSave()
    }

    func proposal(id: UUID) -> UpgradeProposal? {
        proposals.first { $0.id == id }
    }

    // MARK: - Status transitions

    // Legal moves through the five-stage loop. Anything not listed is
    // rejected so a bug can't teleport a proposal from proposed to
    // landed without passing verification.
    static func canTransition(from: ProposalStatus, to: ProposalStatus) -> Bool {
        switch (from, to) {
        case (.proposed, .accepted), (.proposed, .rejected):
            return true
        case (.accepted, .building), (.accepted, .rejected):
            return true
        case (.building, .verifying), (.building, .rejected):
            return true
        case (.verifying, .landed), (.verifying, .rejected):
            return true
        case (.landed, .rolledBack):
            return true
        default:
            return false
        }
    }

    // Apply a status transition. Returns nil (and changes nothing) when
    // the move is illegal or the proposal is unknown.
    @discardableResult
    func transition(id: UUID, to newStatus: ProposalStatus) -> UpgradeProposal? {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return nil }
        guard Self.canTransition(from: proposals[idx].status, to: newStatus) else { return nil }
        proposals[idx].status = newStatus
        proposals[idx].updatedAt = Date()
        scheduleSave()
        return proposals[idx]
    }

    // MARK: - Ranking

    // Ranked proposal book: expected gain descending, then risk
    // ascending (safer first on ties), then newest first as the final
    // tiebreak. Only open (non-terminal, not yet landed) proposals are
    // candidates for the ranked queue.
    func ranked(includeAll: Bool = false) -> [UpgradeProposal] {
        let pool = includeAll
            ? proposals
            : proposals.filter { !$0.status.isTerminal && $0.status != .landed }
        return pool.sorted { a, b in
            if a.expectedGain != b.expectedGain { return a.expectedGain > b.expectedGain }
            if a.riskClass.rank != b.riskClass.rank { return a.riskClass.rank < b.riskClass.rank }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: - Persistence

    // Debounced write: collapses bursts of mutations into one disk
    // write roughly 0.4s after the last change.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = proposals
        let url = storageURL
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            Persistence.save(snapshot, to: url)
        }
    }

    // Force a synchronous write (tests, app termination paths).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Persistence.save(proposals, to: storageURL)
    }
}
