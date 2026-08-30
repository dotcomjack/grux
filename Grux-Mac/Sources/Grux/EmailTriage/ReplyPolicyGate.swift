import Foundation

// ReplyPolicyGate: the deterministic, no-LLM gate that runs BEFORE the expensive
// classify+draft step in EmailTriageEngine.runHourly. It cheaply decides whether
// an inbound email is even worth drafting a reply to, so we never spend a model
// call on a muted sender or a kind/brand combo the user has opted out of. `decide`
// is the pre-draft gate; `allowsCategory` is the post-classify category filter
// applied once the classifier returns a SupportCategory. Both are @MainActor
// (the policy + suppression stores are), pure, and never throw.

enum ReplyDecision: Equatable {
    case proceed(EmailKind)
    // The detected kind rides along (nil when the skip was a muted sender, where
    // kind is irrelevant) so callers record the Filtered row from the gate's own
    // decision instead of re-deriving it.
    case skip(reason: String, kind: EmailKind?)
}

@MainActor
enum ReplyPolicyGate {
    // Pre-draft gate. Deterministic, no LLM, never throws. Runs BEFORE the
    // expensive classify+draft step in EmailTriageEngine.runHourly.
    static func decide(fromEmail: String, fromName: String, subject: String,
                       isBulk: Bool, isAutoSubmitted: Bool, brand: String) -> ReplyDecision {
        // 1. A sender the user explicitly muted never gets a reply, regardless of kind.
        if SenderSuppressionStore.shared.isSuppressed(email: fromEmail) {
            return .skip(reason: "muted sender", kind: nil)
        }
        // 2. Cheap heuristic classification (automated / marketing / personal).
        let kind = EmailKind.detect(fromEmail: fromEmail, fromName: fromName, subject: subject,
                                    isBulk: isBulk, isAutoSubmitted: isAutoSubmitted)
        // 3. Honor the per-brand opt-out for this kind.
        if !ReplyPolicyStore.shared.policy(for: brand).allows(kind: kind) {
            return .skip(reason: "\(kind.rawValue) disabled for \(brand)", kind: kind)
        }
        // 4. Clear to draft.
        return .proceed(kind)
    }

    // Post-classify category filter. Called after the classifier returns a
    // category, to decide whether to actually stage the drafted reply.
    static func allowsCategory(_ category: SupportCategory, brand: String) -> Bool {
        ReplyPolicyStore.shared.policy(for: brand).allows(category: category)
    }
}
