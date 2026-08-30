import Foundation
import Combine

// FilteredMail: a record of one email the reply-policy gate chose NOT to draft,
// kept so the skip is visible and tunable instead of vanishing into the log.
// Each record carries enough of the original message to re-draft it on demand
// ("Draft anyway"), plus why it was filtered so the UI can offer the right
// one-tap action (mute the domain, enable the kind, override once). Persisted to
// ~/.grux/support so it survives relaunch and is greppable from the CLI.
struct FilteredMail: Codable, Identifiable, Equatable {
    var id: String              // stable dedup key (inbox + sender + subject), matches draftId
    var filteredAt: Date
    var inbox: SupportInbox
    var brand: String           // brand voice, matches SupportDraft.brandVoice
    var fromName: String
    var fromEmail: String
    var subject: String
    var preview: String
    var body: String?           // full thread when known, so "Draft anyway" stays thread-aware
    var reason: String          // human-readable why ("No-reply / automated", "Muted sender", ...)
    var kind: String?           // EmailKind.rawValue when a kind drove the skip (enables "Enable this kind")
    var category: String?       // SupportCategory.rawValue when a category drove the skip

    // The sender domain, for the one-tap "Mute domain" action.
    var domain: String? { SenderSuppressionStore.domain(of: fromEmail) }
}

// JSON-backed store at ~/.grux/support/filtered-mail.json. @MainActor
// ObservableObject so the Jax HQ Filtered section reacts as the sweep records
// skips and as they are cleared. Newest first, capped so the file stays small.
@MainActor
final class FilteredMailStore: ObservableObject {
    static let shared = FilteredMailStore()

    @Published private(set) var items: [FilteredMail] = []

    private let maxItems = 100

    static var rootDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("support")
    }
    private static var fileURL: URL { rootDir.appendingPathComponent("filtered-mail.json") }

    private init() { load() }

    func load() {
        items = Persistence.load([FilteredMail].self, from: Self.fileURL, fallback: [])
            .sorted { $0.filteredAt > $1.filteredAt }
    }

    // Upsert by id (re-filtering the same thread refreshes it in place, newest
    // first), then cap.
    func record(_ item: FilteredMail) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        persist()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    // Drop every record from a domain (used after muting it, so the list does
    // not keep showing mail already silenced). Uses the SAME suffix semantics
    // as the mute it pairs with, so muting "walmart.com" also clears rows from
    // "mpsend.walmart.com".
    func removeDomain(_ domain: String) {
        let d = (domain.hasPrefix("@") ? String(domain.dropFirst()) : domain).lowercased()
        items.removeAll { item in
            guard let rowDom = item.domain else { return false }
            return rowDom == d || rowDom.hasSuffix("." + d)
        }
        persist()
    }

    func removeSender(_ email: String) {
        let e = email.lowercased()
        items.removeAll { $0.fromEmail.lowercased() == e }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        // Ensure ~/.grux/support exists before writing: on a fresh machine no
        // sibling store may have created it yet, and Persistence.save swallows
        // the write error, which would silently drop every filtered record.
        try? FileManager.default.createDirectory(at: Self.rootDir, withIntermediateDirectories: true)
        Persistence.save(items, to: Self.fileURL)
    }
}
