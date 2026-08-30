import Foundation
import Combine

// Which inbox a support thread came from. Each inbox carries its own brand
// voice and its own verified-domain From address, and both are webmail the
// user keeps open in Chrome (Microsoft 365).
//
// This was an enum with one person's two companies compiled in as cases. The
// roster now comes from the user's own ~/.grux/brands.json (see BrandRoster);
// with no roster there are no inboxes, the hourly sweep sweeps nothing, and
// that is the correct unconfigured state rather than an error.
//
// It is a struct wrapping a String rather than an enum for one reason: the
// token is PERSISTED, as `inbox` on every draft in ~/.grux/support/drafts.json
// and on every record in filtered-mail.json, and it is a key the mail config
// looks up. Coding as a bare string keeps those files byte-identical, so an
// already-persisted token decodes with no migration and no backfill. Decoding
// deliberately does NOT consult the roster: a draft tagged with an inbox the
// user has since removed still has to load, because one unreadable token would
// otherwise take the whole drafts file down and lose every staged reply.
//
// The concrete addresses live in the mail account config, never here.
struct SupportInbox: Codable, Hashable, Identifiable {

    let rawValue: String
    var id: String { rawValue }

    // Free-form, never fails, never reads the roster. Used by the decoder and
    // by tests, which must not depend on one person's config file existing.
    init(id: String) {
        rawValue = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Roster-checked. Turning an arbitrary string (a brand route in the account
    // config, a CLI trigger payload) into an inbox has to be able to say "that
    // names nothing this install has", which is what the callers' `if let`
    // already relies on. With no roster every token returns nil, so an
    // unconfigured install routes no account and triages nothing.
    init?(rawValue: String) {
        let inbox = SupportInbox(id: rawValue)
        guard BrandRoster.inbox(id: inbox.rawValue) != nil else { return nil }
        self = inbox
    }

    // Every configured inbox, in roster order. Replaces `allCases`: the set is
    // read from disk now, so it is not a compile-time constant and conforming
    // to CaseIterable would be a lie about that.
    static var roster: [SupportInbox] {
        BrandRoster.supportInboxes.map { SupportInbox(id: $0.id) }
    }

    // Short label for reports and the triage UI, from the user's own roster.
    // Deliberately does NOT carry a mailbox address: the address is
    // configuration, and a public build must not ship one baked into a string.
    var displayName: String { BrandRoster.label(forId: rawValue) }

    // Best-effort match against an open Chrome tab URL/title. Both inboxes are
    // M365 webmail (outlook.office.com), so we cannot tell them apart by host
    // alone; the login_hint / account name in the URL is the only signal, and
    // it is often absent. We match the host and let the per-run inbox choice
    // decide the brand. Documented limitation in the catalog.
    var webmailHostHints: [String] {
        ["outlook.office.com", "outlook.office365.com", "outlook.live.com"]
    }

    // Coded as a bare string, exactly as the enum's raw value was, so already
    // persisted drafts need no migration. An unreadable token degrades to a
    // blank inbox rather than throwing, which keeps the draft in the file where
    // it is visible and dismissible; a blank inbox matches no configured
    // account, so sendDraft refuses it instead of sending as somebody else.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(id: (try? container.decode(String.self)) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// Support categories the triage classifier assigns. Drives nothing
// automatically; shown in the UI so the queue can be scanned at a glance.
enum SupportCategory: String, Codable, CaseIterable {
    case refund
    case shipping
    case product
    case other

    var label: String {
        switch self {
        case .refund: return "Refund"
        case .shipping: return "Shipping"
        case .product: return "Product"
        case .other: return "Other"
        }
    }
}

// How loudly a thread needs the user's attention. Drives queue ordering (high
// first) so an angry refund surfaces above a routine product question.
enum SupportUrgency: String, Codable {
    case high
    case normal
    case low

    var label: String {
        switch self {
        case .high: return "Urgent"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
    // Sort weight, higher = nearer the top of the queue.
    var weight: Int {
        switch self {
        case .high: return 2
        case .normal: return 1
        case .low: return 0
        }
    }
}

// One staged reply awaiting the user's tap. The draft body is editable in the UI
// before send. `sourceMessageId` is usually empty (webmail scraping rarely
// exposes RFC message-ids); when present we thread the reply.
struct SupportDraft: Codable, Identifiable, Equatable {
    var id: String
    var createdAt: Date
    var inbox: SupportInbox
    var brandVoice: String          // a BrandRoster id (for display + From)
    var category: SupportCategory
    var fromName: String            // sender display name (best effort)
    var fromEmail: String           // sender address to reply to
    var subject: String             // original subject (reply gets "Re: "), editable
    var incomingPreview: String     // what we read from the inbox (list preview)
    var draftReply: String          // brand-voice reply text, editable
    var originalReply: String       // the first draft, never mutated (edit-capture baseline)
    var urgency: SupportUrgency     // queue ordering signal
    var needsReview: Bool           // refund / legal / angry => read carefully before send
    var reviewReason: String?       // why review was flagged (fabrication audit / banned offer)
    var sourceMessageId: String     // RFC message-id if known, else ""
    var status: Status

    enum Status: String, Codable {
        case staged       // waiting for the user
        case sent         // Resend accepted it
        case failed       // send attempt errored (see lastError)
        case dismissed    // the user discarded it
    }

    var lastError: String?
    var sentMessageId: String?
    // Jax cognition confidence for this draft (0...1), shown on the review card.
    // Optional so older persisted drafts decode cleanly.
    var confidence: Double? = nil
}

// JSON-backed store for staged drafts. Lives at ~/.grux/support/drafts.json so
// it survives relaunches and is greppable from the CLI for verification, the
// same convention the ambient watchers use. @MainActor ObservableObject so the
// SwiftUI list reacts to staging + send.
@MainActor
final class SupportDraftStore: ObservableObject {
    static let shared = SupportDraftStore()

    @Published private(set) var drafts: [SupportDraft] = []

    static var rootDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("support")
    }
    private static var fileURL: URL { rootDir.appendingPathComponent("drafts.json") }

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([SupportDraft].self, from: data) {
            drafts = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.rootDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(drafts) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // Upsert by id. New drafts land at the top; re-staging an existing id
    // (same inbox + sender + subject) updates it in place.
    func upsert(_ draft: SupportDraft) {
        if let idx = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[idx] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
        persist()
    }

    func update(_ id: String, _ mutate: (inout SupportDraft) -> Void) {
        guard let idx = drafts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&drafts[idx])
        persist()
    }

    func remove(_ id: String) {
        drafts.removeAll { $0.id == id }
        persist()
    }

    var stagedCount: Int { drafts.filter { $0.status == .staged }.count }

    // The live queue: only staged drafts, urgent first, then newest. This is
    // what the main list shows, so sent/dismissed cards drop out automatically.
    var activeDrafts: [SupportDraft] {
        drafts.filter { $0.status == .staged }.sorted {
            if $0.urgency.weight != $1.urgency.weight { return $0.urgency.weight > $1.urgency.weight }
            return $0.createdAt > $1.createdAt
        }
    }

    // Everything handled (sent or dismissed), newest first, for the collapsed
    // Done section.
    var doneDrafts: [SupportDraft] {
        drafts.filter { $0.status == .sent || $0.status == .dismissed }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
