import Foundation

// Jax outbound-comms persona + send-gate preparation.
//
// When Jax (or the user, through Jax) sends mail to another human, the message
// MUST carry the correct disclosure and MUST pass the decision gate before a
// single byte leaves the machine. This file owns two things:
//
//   1. Classification: is this outbound message BUSINESS or PERSONAL?
//      Disclosure split is a LOCKED behavior:
//        - business mail goes out under the assistant persona, which discloses
//          that it is writing on the user's behalf
//        - personal matters go out as the user themselves
//      When the classifier is unsure it defaults to BUSINESS, because the
//      assistant disclosure is the safer thing to say to a stranger than
//      impersonating the user directly.
//
//   2. Identity application: given a context, produce the From name, the
//      verified sender address for that brand, and the signature, then rewrite
//      the outgoing body so it is signed correctly.
//
// Every name, address, and brand comes from the roster the user configures
// (see CommsRoster). Grux ships with an EMPTY roster and knows nothing about
// who is using it until they say so.
//
// The actual send is NOT performed here. prepareSend() returns a PreparedSend
// value that wraps the chosen CommsIdentity and a ProposedAction
// (isExternalComms = true). The integrator hands that ProposedAction to
// DecisionGate.shared.evaluate(...) and only sends, via the existing
// ResendClient path, on a .proceed verdict.
//
// DecisionGate, ProposedAction, GateVerdict, and ApprovalQueue are defined by
// the sibling Jax module (Sources/Grux/Jax/DecisionGate.swift). This file
// references them; it does not redefine them.
//
// House style is enforced throughout: zero em dashes, zero en dashes, dollar
// amounts as $N. The body Jax produces still runs through DashSanitizer on the
// ResendClient send path as the final guard.

// MARK: - Context

// Which disclosure regime an outbound message falls under.
enum CommsContext: String, Codable, Equatable {
    case business   // brand work, goes out under the assistant persona
    case personal   // the user's own personal matters, goes out as the user
}

// MARK: - Roster

// Who this copy of Grux sends mail as, and which brands it can send on behalf
// of. EMPTY BY DEFAULT. Grux knows nothing about the person using it until
// they describe themselves here, and an unconfigured roster is a supported
// state: classification still runs, the brand lookup simply never matches, and
// the send falls back to whatever sender the user has set.
//
// Read from ~/.grux/comms-identity.json, shaped:
//
//   {
//     "personalName": "Alex Rivera",
//     "personalAddress": "alex@example.com",
//     "assistantName": "Robin",
//     "brands": [
//       {
//         "slug": "acme",
//         "address": "support@acme.example",
//         "aliases": ["acme co"],
//         "domains": ["acme.example"]
//       }
//     ]
//   }
//
// Every field is optional and every missing field means "not configured".
struct CommsRoster: Codable, Equatable {

    // One brand the user can send business mail on behalf of.
    struct Brand: Codable, Equatable {
        // Stable slug, stamped into ProposedAction.detail["brand"].
        var slug: String
        // Verified sender address for this brand. Empty falls back to the
        // personal address.
        var address: String
        // Extra spellings a brand hint might arrive as ("acme co", "acmeco").
        var aliases: [String]
        // Domains that mark a recipient as unambiguously business.
        var domains: [String]

        init(slug: String, address: String = "", aliases: [String] = [], domains: [String] = []) {
            self.slug = slug
            self.address = address
            self.aliases = aliases
            self.domains = domains
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slug = (try c.decodeIfPresent(String.self, forKey: .slug)) ?? ""
            address = (try c.decodeIfPresent(String.self, forKey: .address)) ?? ""
            aliases = (try c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
            domains = (try c.decodeIfPresent([String].self, forKey: .domains)) ?? []
        }
    }

    // Display name the user's own personal mail goes out under.
    var personalName: String
    // The user's personal verified sender address.
    var personalAddress: String
    // Display name the business / assistant persona goes out under.
    var assistantName: String
    var brands: [Brand]

    init(personalName: String = "",
         personalAddress: String = "",
         assistantName: String = "",
         brands: [Brand] = []) {
        self.personalName = personalName
        self.personalAddress = personalAddress
        self.assistantName = assistantName
        self.brands = brands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personalName = (try c.decodeIfPresent(String.self, forKey: .personalName)) ?? ""
        personalAddress = (try c.decodeIfPresent(String.self, forKey: .personalAddress)) ?? ""
        assistantName = (try c.decodeIfPresent(String.self, forKey: .assistantName)) ?? ""
        brands = (try c.decodeIfPresent([Brand].self, forKey: .brands)) ?? []
    }

    // The shipped default: nothing configured.
    static let empty = CommsRoster()
}

// Loads and caches the roster. A missing, unreadable, or malformed file is not
// an error: it means "not configured yet" and yields CommsRoster.empty. Cached
// after the first read, so a roster edit takes effect on the next launch or
// after an explicit reload().
enum CommsRosterStore {

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("comms-identity.json")
    }

    private static let lock = NSLock()
    private static var cached: CommsRoster?

    static var current: CommsRoster {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached { return c }
        let loaded = load()
        cached = loaded
        return loaded
    }

    // Drops the cache so the next read picks up an edited file.
    static func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private static func load() -> CommsRoster {
        guard let data = try? Data(contentsOf: fileURL),
              let roster = try? JSONDecoder().decode(CommsRoster.self, from: data) else {
            return .empty
        }
        return roster
    }
}

// MARK: - Identity

// The persona an outbound message is sent under: the human-facing From name,
// the verified Resend sender it goes out through, and the signature appended
// to the body.
struct CommsIdentity: Equatable {
    let context: CommsContext
    let displayName: String   // shown as the From name, e.g. the assistant persona
    let fromName: String      // same as displayName; kept distinct for clarity at call sites
    let fromAddress: String   // full verified Resend sender "Name <addr@domain>"
    let replyTo: String       // bare reply address
    let signature: String     // appended block, e.g. "Robin | Alex Rivera's assistant"

    // Business persona for a given brand. The assistant persona speaks for the
    // brand and always discloses that it is writing on the user's behalf. The
    // From address is the brand's own verified sender when the roster has one.
    static func business(brand: CommsBrand) -> CommsIdentity {
        let roster = CommsRosterStore.current
        let name = roster.assistantName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Assistant"
            : roster.assistantName.trimmingCharacters(in: .whitespaces)
        let owner = roster.personalName.trimmingCharacters(in: .whitespaces)
        return CommsIdentity(
            context: .business,
            displayName: name,
            fromName: name,
            fromAddress: sender(name: name, address: brand.fromBareAddress),
            replyTo: brand.fromBareAddress,
            signature: owner.isEmpty ? name : "\(name) | \(owner)'s assistant"
        )
    }

    // Personal persona. The user sends as themselves, from their own address,
    // with a plain name signature. No "assistant" disclosure, because personal
    // mail is genuinely from them. Empty until the roster says otherwise, which
    // renders as an unsigned message rather than somebody else's name.
    static func personal() -> CommsIdentity {
        let roster = CommsRosterStore.current
        let name = roster.personalName.trimmingCharacters(in: .whitespaces)
        let addr = roster.personalAddress.trimmingCharacters(in: .whitespaces)
        return CommsIdentity(
            context: .personal,
            displayName: name,
            fromName: name,
            fromAddress: sender(name: name, address: addr),
            replyTo: addr,
            signature: name
        )
    }

    // "Name <addr>" when both halves exist, otherwise whichever half does, and
    // an empty string when neither does. Never "Name <>": an unconfigured
    // roster produces a sender the mail provider rejects with a plain error,
    // which is the honest "not set up yet" signal, rather than a malformed
    // header that might get part-way sent.
    private static func sender(name: String, address: String) -> String {
        if name.isEmpty { return address }
        if address.isEmpty { return name }
        return "\(name) <\(address)>"
    }
}

// MARK: - Brand address mapping

// A brand Jax can send business mail on behalf of, paired with the verified
// sender address that brand's mail goes out through. Resolved from the roster
// the user configures, never from a compiled-in list: Grux ships with no
// brands at all and an unmatched hint collapses to the user's own sender.
struct CommsBrand: Codable, Equatable {
    // Stable slug, stamped into ProposedAction.detail["brand"].
    let rawValue: String
    // Bare verified-domain support/from address for this brand. Empty means
    // the roster has not configured one.
    let fromBareAddress: String

    // The brand used when the roster is empty or nothing matches: the user's
    // own sender, under the reserved "default" slug.
    static func fallback(_ roster: CommsRoster) -> CommsBrand {
        CommsBrand(
            rawValue: "default",
            fromBareAddress: roster.personalAddress.trimmingCharacters(in: .whitespaces)
        )
    }

    // Loose resolver from a free-form brand hint (slug, display name, alias,
    // or domain fragment) to a configured brand. Unknown / empty => fallback.
    static func resolve(_ hint: String?) -> CommsBrand {
        let roster = CommsRosterStore.current
        let q = (hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return fallback(roster) }
        for brand in roster.brands {
            let needles = ([brand.slug] + brand.aliases + brand.domains)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            guard needles.contains(where: { q.contains($0) }) else { continue }
            let slug = brand.slug.trimmingCharacters(in: .whitespaces)
            let addr = brand.address.trimmingCharacters(in: .whitespaces)
            return CommsBrand(
                rawValue: slug.isEmpty ? "default" : slug,
                fromBareAddress: addr.isEmpty
                    ? roster.personalAddress.trimmingCharacters(in: .whitespaces)
                    : addr
            )
        }
        return fallback(roster)
    }
}

// MARK: - Prepared send

// The output of prepareSend(): the chosen identity, the rewritten body, and a
// ProposedAction (isExternalComms = true) ready for DecisionGate.evaluate.
// Nothing here has been sent. The integrator must:
//   1. DecisionGate.shared.evaluate(prepared.proposed)
//   2. on .proceed: send via ResendClient using prepared.identity + body
//   3. on .queueForApproval: ApprovalQueue.shared.enqueue(prepared.proposed)
//   4. on .refuse: surface the reason, send nothing.
struct PreparedSend {
    let identity: CommsIdentity
    let context: CommsContext
    let recipients: [String]
    let subject: String
    let body: String            // already signed with the identity signature
    let brand: CommsBrand
    let proposed: ProposedAction
}

// MARK: - CommsPersona

// Stateless helper. Singleton for call-site symmetry with the rest of Grux
// (static let shared), but holds no mutable state, so it is safe to touch from
// any executor.
final class CommsPersona {
    static let shared = CommsPersona()
    private init() {}

    // Known business email domains, drawn from the brands the user configured.
    // A recipient on one of these is unambiguously business. Empty until the
    // roster names some, in which case this heuristic simply never fires and
    // the classifier falls through to the tone signals below.
    private static var businessDomains: Set<String> {
        Set(
            CommsRosterStore.current.brands
                .flatMap { $0.domains }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    // Free-mail / personal-contact domains. A recipient here, with no business
    // brand hint and no business-tone subject, leans personal. This list is
    // deliberately small: ambiguity defaults to business, not personal.
    private static let personalDomains: Set<String> = [
        "gmail.com",
        "icloud.com",
        "me.com",
        "yahoo.com",
        "hotmail.com",
        "outlook.com",
        "proton.me",
        "protonmail.com"
    ]

    // Tokens that read as commercial intent in a subject or body.
    private static let businessTokens: [String] = [
        "invoice", "order", "subscription", "support", "refund", "shipment",
        "tracking", "proposal", "sprint", "teardown", "client", "rfq",
        "vendor", "wholesale", "partnership", "press", "podcast", "feature",
        "app store", "testflight", "launch", "campaign", "ad ", "ads",
        "demo", "onboarding", "pricing", "founding", "case study", "brand"
    ]

    // Tokens that read as personal correspondence.
    private static let personalTokens: [String] = [
        "happy birthday", "thanks for", "thank you for", "see you",
        "dinner", "lunch", "coffee", "family", "weekend", "miss you",
        "love you", "congrats", "congratulations", "how are you",
        "good to see", "catch up"
    ]

    // Classifies an outbound message. Heuristics, in priority order:
    //   1. Any business brand hint => business.
    //   2. Any recipient on a known business domain => business.
    //   3. Strong personal signal (personal domain recipient AND personal
    //      tone, with no business tokens) => personal.
    //   4. Anything else => business (the safer disclosure).
    func classify(
        recipient: [String],
        subject: String,
        body: String,
        brandHint: String? = nil
    ) -> CommsContext {
        // 1. An explicit brand hint is a business signal.
        if let hint = brandHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            return .business
        }

        let domains = recipient.compactMap { Self.domain(of: $0) }

        // 2. Any recipient on a configured brand domain is business, full stop.
        if domains.contains(where: { Self.businessDomains.contains($0) }) {
            return .business
        }

        let haystack = "\(subject)\n\(body)".lowercased()
        let hasBusinessToken = Self.businessTokens.contains { haystack.contains($0) }
        let hasPersonalToken = Self.personalTokens.contains { haystack.contains($0) }
        let allPersonalDomains = !domains.isEmpty && domains.allSatisfy { Self.personalDomains.contains($0) }

        // 3. Personal only when the signal is clean: every recipient is a
        //    personal mailbox, the tone reads personal, and nothing commercial
        //    leaks through.
        if allPersonalDomains && hasPersonalToken && !hasBusinessToken {
            return .personal
        }

        // 4. Ambiguous => business + assistant disclosure (safer).
        return .business
    }

    // Picks the identity for a context. Business resolves the brand from the
    // hint (falling back to the user's own sender); personal is always the user.
    func identity(for context: CommsContext, brandHint: String? = nil) -> CommsIdentity {
        switch context {
        case .business:
            return .business(brand: CommsBrand.resolve(brandHint))
        case .personal:
            return .personal()
        }
    }

    // Appends the identity signature to a body if it is not already signed.
    // Idempotent: if the body already ends with the signature (case- and
    // whitespace-insensitive on the last line), it is returned unchanged so
    // re-runs do not stack signatures. An unconfigured roster has no signature
    // to append, so the body goes out unsigned rather than trailing two blank
    // lines.
    func sign(body: String, with identity: CommsIdentity) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.signature.trimmingCharacters(in: .whitespaces).isEmpty else {
            return trimmed
        }
        let lastLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        if lastLine.caseInsensitiveCompare(identity.signature) == .orderedSame {
            return trimmed
        }
        return "\(trimmed)\n\n\(identity.signature)"
    }

    // Builds the full PreparedSend: classifies, selects the identity, signs the
    // body, and assembles the ProposedAction (isExternalComms = true) for the
    // decision gate. NO send happens here.
    //
    // contextOverride lets a caller force business or personal when the user has
    // been explicit; nil = classify from heuristics.
    func prepareSend(
        recipients: [String],
        subject: String,
        body: String,
        brandHint: String? = nil,
        contextOverride: CommsContext? = nil
    ) -> PreparedSend {
        let context = contextOverride
            ?? classify(recipient: recipients, subject: subject, body: body, brandHint: brandHint)
        let brand = CommsBrand.resolve(brandHint)
        let identity = self.identity(for: context, brandHint: brandHint)
        let signedBody = sign(body: body, with: identity)

        let proposed = ProposedAction(
            kind: .externalComms,
            summary: "Email to \(recipients.joined(separator: ", ")) as \(identity.fromName) (\(context.rawValue)): \(subject)",
            isExternalComms: true,
            detail: [
                "channel": "email",
                "context": context.rawValue,
                "brand": brand.rawValue,
                "fromName": identity.fromName,
                "fromAddress": identity.fromAddress,
                "recipients": recipients.joined(separator: ", "),
                "subject": subject
            ]
        )

        return PreparedSend(
            identity: identity,
            context: context,
            recipients: recipients,
            subject: subject,
            body: signedBody,
            brand: brand,
            proposed: proposed
        )
    }

    // MARK: - Helpers

    static func domain(of address: String) -> String? {
        let a = address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a "Name <addr>" wrapper if present.
        let bare: String
        if let lt = a.lastIndex(of: "<"), let gt = a.lastIndex(of: ">"), lt < gt {
            bare = String(a[a.index(after: lt)..<gt])
        } else {
            bare = a
        }
        guard let at = bare.lastIndex(of: "@") else { return nil }
        let dom = String(bare[bare.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        return dom.isEmpty ? nil : dom
    }
}
