import Foundation

// EmailKind: a deterministic, NO-LLM triage of who actually sent a message.
// The mail layer already parsed the sender address and the bulk / auto-submitted
// header flags; this turns those into one of three buckets. The bias is the whole
// point: dropping a real human into automated or marketing is the expensive error
// (a real reply gets missed), so on any ambiguity we fall through to .personal.
// Detection order is automated first, then marketing, else personal, because a
// no-reply newsletter is automated, not marketing.

enum EmailKind: String, Codable, CaseIterable, Identifiable {
    case automated   // no-reply / system / bounce / auto-submitted
    case marketing   // bulk / promotional / newsletter
    case personal    // a real human/business sender (default)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automated: return "No-reply / automated"
        case .marketing: return "Marketing / promotional"
        case .personal: return "Personal / business"
        }
    }

    // Unambiguous automated markers: safe to match ANYWHERE in the address
    // because no real human address contains them. "no-reply" and friends, the
    // bounce daemon, and the mpsend. relay host.
    private static let automatedAddressMarkers = [
        "no-reply", "noreply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
        "mailer-daemon", "postmaster", "mailer@", "mpsend.",
    ]

    // Automated tokens that are ONLY meaningful as a bounded local-part token,
    // never as arbitrary address text. Matching "bounce" or "notification" over
    // the whole address would drop a real human at bouncex.com or a handle like
    // jane.notification@gmail.com (the expensive error this file warns about), so
    // these are matched with separator boundaries against the local-part only.
    private static let automatedLocalTokens = [
        "bounce", "bounces", "notification", "notifications",
    ]

    // Transactional senders: the billing and receipt robots. Deliberately a
    // SHORT list of words no person uses as their base local-part. "billing",
    // "accounts" and "support" are NOT here on purpose, because at a small
    // company those are a real human whose reply we would be dropping, which is
    // the expensive error this file opens by warning about.
    //
    // Found from a live miss: a Stripe receipt from
    // invoice+statements+acct_<id>@stripe.com was classed .personal and staged
    // as a repliable support draft, so Jax spent a model call writing a courteous
    // reply to a billing robot about a purchase that was never made.
    private static let transactionalLocalTokens = [
        "invoice", "invoices", "receipt", "receipts", "statement", "statements",
    ]

    // Marketing local-part tokens. Compound tokens are unambiguous (a hasPrefix
    // match is safe). Short tokens are common enough in real handles ("newsguy",
    // "dealsdan") that they are bounded the same way as the automated tokens so
    // they do not swallow a real person.
    private static let marketingCompound = ["newsletter", "marketing", "promo", "promotions"]
    private static let marketingShort = ["news", "updates", "offers", "deals"]

    // Pure function. Decides the kind from sender address patterns plus the
    // bulk / auto-submitted header flags the mail layer already parsed.
    static func detect(fromEmail: String, fromName: String, subject: String,
                       isBulk: Bool, isAutoSubmitted: Bool) -> EmailKind {
        let address = fromEmail.lowercased()
        let localPart = address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? address
        // RFC 5233 sub-addressing: everything from the first "+" is a tag the
        // SENDER chose, and the part before it is who they actually are. Token
        // matching runs against that base, which is both more correct and safer
        // than adding "+" to the separator list in localPartHasToken.
        //
        // Safer in a specific way worth spelling out. Treating "+" as an
        // ordinary separator would also match it as a SUFFIX, so
        // jane+invoice@gmail.com would classify as automated. That is a real
        // person tagging her own mail, and dropping her reply is precisely the
        // expensive error this file warns about. Matching the base instead reads
        // invoice+statements+acct_<id>@stripe.com as "invoice" and
        // jane+invoice@gmail.com as "jane", which is the right answer for both.
        let baseLocal = localPart.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? localPart

        // 1. Automated wins (a no-reply newsletter is automated, not marketing).
        if isAutoSubmitted { return .automated }
        if automatedAddressMarkers.contains(where: { address.contains($0) }) { return .automated }
        if automatedLocalTokens.contains(where: { localPartHasToken(baseLocal, $0) }) { return .automated }
        if transactionalLocalTokens.contains(where: { localPartHasToken(baseLocal, $0) }) { return .automated }

        // 2. Marketing next.
        if isBulk { return .marketing }
        if marketingCompound.contains(where: { baseLocal == $0 || baseLocal.hasPrefix($0) }) { return .marketing }
        if marketingShort.contains(where: { localPartHasToken(baseLocal, $0) }) { return .marketing }

        // 3. Bias toward personal on anything ambiguous.
        return .personal
    }

    // True when `token` is a whole, separator-bounded segment of the local-part:
    // an exact match, a leading segment ("token." / "token-" / "token_"), or a
    // trailing segment (".token" / "-token" / "_token"). This deliberately does
    // NOT match "bouncer" from "bounce" or "newsguy" from "news".
    private static func localPartHasToken(_ localPart: String, _ token: String) -> Bool {
        if localPart == token { return true }
        for sep in [".", "-", "_"] {
            if localPart.hasPrefix(token + sep) || localPart.hasSuffix(sep + token) { return true }
        }
        return false
    }
}
