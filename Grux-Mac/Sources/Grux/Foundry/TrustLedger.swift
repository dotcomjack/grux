import Foundation

// The graduated trust ladder, persisted per (lane, domain) pair.
//
// Rules (blueprint section 01, "The trust ladder"):
//   • Every pair starts at .propose.
//   • Five consecutive accepted-and-kept changes with zero rollbacks
//     in the streak promote the pair one tier (capped at .autoLand).
//   • Any rollback demotes one tier immediately.
//   • Two consecutive rejections demote one tier.
//   • Protected zones (wire protocol, Keychain, Security) are pinned:
//     proposals touching them are forced riskClass=protected and
//     tierRequired stays .propose forever, regardless of ledger state.
@MainActor
final class TrustLedger: ObservableObject {
    static let shared = TrustLedger()

    // MARK: - Records

    enum Outcome: String, Codable, Sendable {
        case acceptedAndKept  // landed and survived the 24h watch window
        case rejected         // the user declined the proposal or the diff
        case rolledBack       // landed then auto-reverted or manually reverted
    }

    struct LedgerEvent: Codable, Equatable, Sendable {
        var outcome: Outcome
        var proposalId: UUID?
        var at: Date = Date()
    }

    struct LedgerEntry: Codable, Equatable, Sendable {
        var lane: UpgradeLane
        var domain: UpgradeDomain
        var tier: TrustTier = .propose
        // Consecutive accepted-and-kept count since the last reset.
        var streak: Int = 0
        // Consecutive rejections; two in a row demotes.
        var consecutiveRejections: Int = 0
        var history: [LedgerEvent] = []
    }

    @Published private(set) var entries: [LedgerEntry] = []

    private let storageURL: URL
    private var saveTask: Task<Void, Never>?

    private static let promotionStreak = 5
    private static let demotionRejections = 2

    // Tests inject a temp URL; the app uses the shared singleton.
    init(storageURL: URL = FoundryPaths.trustLedgerURL) {
        self.storageURL = storageURL
        load()
    }

    func load() {
        entries = Persistence.load([LedgerEntry].self, from: storageURL, fallback: [])
    }

    // MARK: - Reads

    func entry(lane: UpgradeLane, domain: UpgradeDomain) -> LedgerEntry {
        entries.first { $0.lane == lane && $0.domain == domain }
            ?? LedgerEntry(lane: lane, domain: domain)
    }

    // The tier a (lane, domain) pair has earned. Callers gating an
    // actual proposal must take min(this, proposal.tierRequired) and
    // remember protected proposals are pinned to .propose at the
    // proposal level by applyProtectedPinning.
    func tier(lane: UpgradeLane, domain: UpgradeDomain) -> TrustTier {
        entry(lane: lane, domain: domain).tier
    }

    // MARK: - Writes

    // Record an accepted-and-kept change. Five in a row with zero
    // rollbacks promotes one tier and resets the streak so the next
    // rung is earned from scratch.
    @discardableResult
    func recordAcceptedAndKept(lane: UpgradeLane, domain: UpgradeDomain, proposalId: UUID? = nil) -> LedgerEntry {
        mutate(lane: lane, domain: domain) { e in
            e.history.append(LedgerEvent(outcome: .acceptedAndKept, proposalId: proposalId))
            e.consecutiveRejections = 0
            e.streak += 1
            if e.streak >= Self.promotionStreak {
                e.tier = e.tier.promoted
                e.streak = 0
            }
        }
    }

    // Any rollback demotes one tier immediately and resets the streak.
    @discardableResult
    func recordRollback(lane: UpgradeLane, domain: UpgradeDomain, proposalId: UUID? = nil) -> LedgerEntry {
        mutate(lane: lane, domain: domain) { e in
            e.history.append(LedgerEvent(outcome: .rolledBack, proposalId: proposalId))
            e.streak = 0
            e.consecutiveRejections = 0
            e.tier = e.tier.demoted
        }
    }

    // Rejections demote one tier after two in a row. A single
    // rejection resets the promotion streak but keeps the tier.
    @discardableResult
    func recordRejection(lane: UpgradeLane, domain: UpgradeDomain, proposalId: UUID? = nil) -> LedgerEntry {
        mutate(lane: lane, domain: domain) { e in
            e.history.append(LedgerEvent(outcome: .rejected, proposalId: proposalId))
            e.streak = 0
            e.consecutiveRejections += 1
            if e.consecutiveRejections >= Self.demotionRejections {
                e.tier = e.tier.demoted
                e.consecutiveRejections = 0
            }
        }
    }

    private func mutate(
        lane: UpgradeLane,
        domain: UpgradeDomain,
        _ body: (inout LedgerEntry) -> Void
    ) -> LedgerEntry {
        if let idx = entries.firstIndex(where: { $0.lane == lane && $0.domain == domain }) {
            body(&entries[idx])
            scheduleSave()
            return entries[idx]
        }
        var fresh = LedgerEntry(lane: lane, domain: domain)
        body(&fresh)
        entries.append(fresh)
        scheduleSave()
        return fresh
    }

    // MARK: - Protected zones (pinned to Tier 0 forever)

    // Path fragments that mark the no-autonomy zones: the phone wire
    // protocol and its crypto/pairing/envelope peers, the Keychain
    // store, and the whole Security module. Matched case-insensitively
    // as substrings so both absolute and repo-relative paths hit.
    static let protectedPathMarkers: [String] = [
        "sources/grux/iphone/phoneprotocol",
        "phoneprotocol.swift",
        "phonecrypto.swift",
        "phonechatenvelope.swift",
        "phonepairing.swift",
        "keychainstore.swift",
        // Canonical Security-module marker (also surfaced verbatim in the RD
        // worker prompt). Kept alongside the broader "/security/" segment
        // marker below so detection no longer depends on the Sources/ prefix:
        // the previous lone marker missed package-root-relative paths
        // ("Security/SecurityPolicy.swift") and bare-segment references that
        // Claude Code prompts and git diffs routinely use without it.
        "sources/grux/security/",
        "/security/"
    ]

    // Known Security-module filenames with no individual marker. A touched
    // path ending in one of these is protected even when it carries no
    // directory context at all (a bare "URLGuard.swift" reference).
    static let protectedSecurityFilenames: [String] = [
        "securitypolicy.swift",
        "urlguard.swift",
        "promptsecurity.swift",
        "sensitiveactiongate.swift",
        "securityauditlog.swift"
    ]

    nonisolated static func isProtectedPath(_ path: String) -> Bool {
        // Normalize: lowercase, strip a leading ./, collapse repeated slashes.
        var p = path.lowercased().trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        if protectedPathMarkers.contains(where: { p.contains($0) }) { return true }
        // A path that starts with "security/" (no leading slash) is the
        // package-root-relative case the substring markers miss.
        if p.hasPrefix("security/") { return true }
        // Bare filename of a known Security file, regardless of directory.
        let leaf = p.split(separator: "/").last.map(String.init) ?? p
        return protectedSecurityFilenames.contains(leaf)
    }

    // True when any of the proposal's touched paths, evidence lines,
    // or prompt text reference a protected zone.
    nonisolated static func touchesProtectedZone(_ proposal: UpgradeProposal) -> Bool {
        if proposal.touchedPaths.contains(where: isProtectedPath) { return true }
        if proposal.evidence.contains(where: { isProtectedPath($0.detail) || isProtectedPath($0.source) }) { return true }
        let prompt = proposal.readyPrompt.lowercased()
        if protectedPathMarkers.contains(where: { prompt.contains($0) }) { return true }
        // The prompt routinely names a Security file by package-root-relative
        // path ("edit security/securitypolicy.swift ...") or by bare filename,
        // neither of which the directory markers catch. Match those too.
        if prompt.contains("security/") { return true }
        return protectedSecurityFilenames.contains(where: { prompt.contains($0) })
    }

    // Force protected pinning: riskClass=protected, tierRequired stays
    // .propose forever. No-op for proposals that stay clear of the
    // protected zones.
    nonisolated static func applyProtectedPinning(to proposal: UpgradeProposal) -> UpgradeProposal {
        guard touchesProtectedZone(proposal) else { return proposal }
        var pinned = proposal
        pinned.riskClass = .protected
        pinned.tierRequired = .propose
        return pinned
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
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
        Persistence.save(entries, to: storageURL)
    }
}
