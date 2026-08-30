import Foundation

/// Which brands this copy of Grux works for, loaded from disk.
///
/// Grux was written for one person and had his three companies compiled into
/// two enums: `BrandScope` (the app-wide filter across Drafts, Mailbox and the
/// Cognition Map) and `SupportInbox` (the mail triage roster). Every install
/// shipped a stranger's company names in its sidebar, in its mail triage, and
/// in the prompts the drafter sends to the model.
///
/// ## Why this is empty by default
///
/// The same shape ``ProductCatalogSeed`` and ``ProjectsServiceConfig`` already
/// use: the compiled-in default is EMPTY, and empty is a supported state that
/// renders needs-setup rather than an error. An empty roster is also the
/// SAFE default rather than a lossy one. Grux has no idea what anybody sells,
/// and a support drafter that invents a brand is worse than one that has none:
/// with no roster the filter shows only "All", the hourly sweep sweeps
/// nothing, and no reply can go out under a company that was never configured.
///
/// ## Shape, at `~/.grux/brands.json`
///
///     {"brands":        [{"id": "acme", "label": "Acme"}],
///      "supportInboxes":[{"id": "acme", "label": "Acme"}]}
///
/// `brands` is the filter vocabulary. `supportInboxes` is the subset that has
/// a real mailbox behind it, so it is what the hourly mail sweep walks; a
/// brand with no inbox still filters, it just never receives mail.
///
/// The subset is a contract the file cannot enforce, so an inbox listed with no
/// matching `brands` entry is FOLDED IN on load rather than ignored. An inbox is
/// a brand by definition: its mail is swept, its drafts stage, and its pills
/// render. Leaving it out of the filter vocabulary strands it, because every
/// per-brand control keys off `brands` and would never offer it, so the reply
/// rules and the muted-sender list for a brand that is actively drafting become
/// unreachable from the app.
///
/// ## id is DATA, label is display
///
/// `id` is the PERSISTED token. It is the string in `~/.grux/jax/
/// brand-filter.json`, the `inbox` and `brandVoice` on every draft in
/// `~/.grux/support/drafts.json`, and the key the reply policy, the autonomy
/// ledger and the correction lessons are all filed under. Renaming an id
/// orphans everything already tagged with the old one, silently: the drafts
/// still decode, they just stop matching any filter. Change a `label` freely,
/// treat an `id` as immutable.
///
/// Nothing here throws. A missing file, unreadable JSON, a type slip inside a
/// single entry, or empty arrays all yield an empty roster. That last one is
/// all-or-nothing on purpose rather than a per-entry salvage: a roster that
/// half-loads would show some brands and silently hide the rest, which is worse
/// than showing none, and salvaging an entry whose `bannedOffers` type slipped
/// would turn that brand's send guard off without saying so. Blank, duplicate
/// and reserved ids ARE dropped one at a time, because those are decided after
/// the whole file has already decoded (see `clean`).
enum BrandRoster {

    /// One brand. Read-only configuration, so this is only ever decoded.
    struct Entry: Codable, Sendable, Hashable, Identifiable {
        /// The persisted token. Lowercased and trimmed on load so a roster
        /// hand-written as `"Acme"` still matches the `"acme"` already sitting
        /// in `drafts.json`, which is the whole point of the migration being
        /// backfill-free.
        let id: String
        /// Display text. Defaults to the id so an entry carrying only an id
        /// still renders something a person can read.
        let label: String
        /// Offer-shaped phrases this brand does not do, scanned for in every
        /// outbound reply by `EmailTriageEngine.bannedTokensFound`. That scan
        /// used to hold one company's policy in a compiled-in `switch`, which
        /// is that company's business rather than Grux's. It is per-brand
        /// policy, so it lives on the brand's own entry. Optional: a brand
        /// with none still gets the universal floor (coupons, promo codes,
        /// free shipping) that no brand offers by accident.
        let bannedOffers: [String]

        init(id: String, label: String = "", bannedOffers: [String] = []) {
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.id = key
            let shown = label.trimmingCharacters(in: .whitespacesAndNewlines)
            self.label = shown.isEmpty ? key : shown
            self.bannedOffers = bannedOffers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }

        /// The input is a file a person writes by hand, so every key except
        /// `id` is optional. Swift's synthesized decoder would throw on the
        /// first missing key and take the whole roster with it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
                label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
                bannedOffers: try c.decodeIfPresent([String].self, forKey: .bannedOffers) ?? []
            )
        }
    }

    /// The on-disk shape. Both arrays absent means an empty roster, which is a
    /// supported state and never an error.
    struct Roster: Codable, Sendable {
        var brands: [Entry] = []
        var supportInboxes: [Entry] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let declared = try c.decodeIfPresent([Entry].self, forKey: .brands) ?? []
            supportInboxes = Roster.clean(try c.decodeIfPresent([Entry].self, forKey: .supportInboxes) ?? [])
            // An inbox with no matching `brands` entry is a brand too, so the
            // union happens ONCE here rather than as a guard at each consumer.
            // Reconciling per call site is how the two arrays drifted apart in
            // the first place: the drafts surface reads `BrandRoster.brands`
            // while the sweep reads `supportInboxes`, so an inbox-only entry
            // stages mail under a brand the filter bar never lists.
            // `clean` de-duplicates first-wins, so a brand declared in both
            // keeps its declared position and its label.
            brands = Roster.clean(declared + supportInboxes)
        }

        /// Drops blank ids and de-duplicates, first entry wins. Also drops the
        /// reserved `all` token: a brand literally named "all" would collide
        /// with the filter's match-everything sentinel and silently match every
        /// other brand's mail.
        private static func clean(_ entries: [Entry]) -> [Entry] {
            var seen = Set<String>()
            return entries.filter { entry in
                guard !entry.id.isEmpty, entry.id != BrandScope.allToken else { return false }
                return seen.insert(entry.id).inserted
            }
        }
    }

    /// `~/.grux/brands.json`, in Grux's own directory. Read once, because the
    /// roster is configuration rather than state: a mid-session change would
    /// otherwise re-key the filter under a running UI.
    static let roster: Roster = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux/brands.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Roster.self, from: data)
        else { return Roster() }
        return decoded
    }()

    static var brands: [Entry] { roster.brands }
    static var supportInboxes: [Entry] { roster.supportInboxes }

    /// True when nothing has been configured, so callers can say so plainly
    /// instead of rendering an empty roster as though it were a real one with
    /// no matches.
    static var isEmpty: Bool { roster.brands.isEmpty && roster.supportInboxes.isEmpty }

    static func brand(id: String) -> Entry? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return roster.brands.first { $0.id == key }
    }

    static func inbox(id: String) -> Entry? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return roster.supportInboxes.first { $0.id == key }
    }

    /// Display text for a token that may predate the current roster. A draft
    /// tagged with a brand the user has since removed still has to render, so
    /// the fallback is the token itself rather than a blank or a crash.
    static func label(forId id: String) -> String {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = brand(id: key) ?? inbox(id: key) { return hit.label }
        return key.uppercased()
    }

    /// The brand's own not-supported offer phrases, empty for an unconfigured
    /// brand.
    static func bannedOffers(forId id: String) -> [String] {
        (brand(id: id) ?? inbox(id: id))?.bannedOffers ?? []
    }
}
