import Foundation
import Combine

// SenderSuppression: the persisted list of senders the user never wants surfaced in
// the email triage flow. Two tiers: exact addresses and whole domains. The
// domain tier uses a SUFFIX match so muting one bare domain ("walmart.com") also
// silences every subdomain mailer that hangs off it ("no-reply@mpsend.walmart.com",
// "alerts@email.walmart.com"). The suffix test is anchored on a leading "." so
// "walmart.com" never accidentally swallows a lookalike like "notwalmart.com".
// Persisted to ~/.grux/support so the choice survives relaunch.

@MainActor
final class SenderSuppressionStore: ObservableObject {
    static let shared = SenderSuppressionStore()

    @Published private(set) var emails: Set<String>    // lowercased full addresses
    @Published private(set) var domains: Set<String>   // lowercased BARE domains, e.g. "walmart.com"

    private let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/support", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("muted-senders.json")
    }()

    private init() {
        let stored = Persistence.load(Stored.self, from: url, fallback: Stored(emails: [], domains: []))
        emails = Set(stored.emails)
        domains = Set(stored.domains)
    }

    // Is this address silenced, either by an exact email match or by any muted
    // domain that equals or is a parent suffix of the address's own domain?
    func isSuppressed(email: String) -> Bool {
        let addr = Self.normalize(email)
        if emails.contains(addr) { return true }
        guard let d = Self.domain(of: addr) else { return false }
        if domains.contains(d) { return true }
        return domains.contains { m in d == m || d.hasSuffix("." + m) }
    }

    func muteEmail(_ email: String) {
        emails.insert(Self.normalize(email))
        save()
    }

    // Accepts "walmart.com", "@walmart.com", or "Walmart.com"; stores the bare
    // lowercased domain.
    func muteDomain(_ domain: String) {
        domains.insert(Self.normalizeDomain(domain))
        save()
    }

    func unmuteEmail(_ email: String) {
        emails.remove(Self.normalize(email))
        save()
    }

    func unmuteDomain(_ domain: String) {
        domains.remove(Self.normalizeDomain(domain))
        save()
    }

    // The lowercased text after the LAST "@", trimmed. nil if there is no "@" or
    // the resulting domain is empty. nonisolated + pure so value types (e.g.
    // FilteredMail.domain) can call it off the main actor.
    nonisolated static func domain(of email: String) -> String? {
        let lowered = normalize(email)
        guard let at = lowered.lastIndex(of: "@") else { return nil }
        let d = String(lowered[lowered.index(after: at)...])
        return d.isEmpty ? nil : d
    }

    // MARK: - Normalization

    nonisolated private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Collapse any input to a bare domain: a full address ("x@walmart.com") or an
    // "@walmart.com" form both reduce to "walmart.com", so muting a domain via a
    // pasted address does not store a dead, never-matching entry.
    private static func normalizeDomain(_ s: String) -> String {
        let d = normalize(s)
        if let at = d.lastIndex(of: "@") { return String(d[d.index(after: at)...]) }
        return d
    }

    // MARK: - Persistence

    // On-disk shape: sorted arrays for stable diffs. Converted to/from the live
    // Sets on load/save.
    private struct Stored: Codable {
        var emails: [String]
        var domains: [String]
    }

    private func save() {
        let stored = Stored(emails: emails.sorted(), domains: domains.sorted())
        Persistence.save(stored, to: url)
    }
}
