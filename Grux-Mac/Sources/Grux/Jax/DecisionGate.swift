import Foundation

// Jax's universal decision gate. EVERY action Jax wants to take, autonomously or
// on the user's behalf, must pass through DecisionGate.shared.evaluate(_:) first.
// The gate is the single, auditable choke point that enforces the five hard
// guardrails. It is intentionally boring and explicit: each guardrail is a
// separate, named check, in priority order, so a reviewer can read exactly why
// any given action proceeded, queued, or was refused.
//
// FAIL SAFE is the whole point. The default for anything that is not provably
// routine-and-reversible is queueForApproval, never a silent proceed. A bug in
// classification therefore costs the user a tap, not a wire transfer.
//
// The gate NEVER performs the action. It returns a verdict. The caller (the
// CommsPersona send path, a spend path, a SwarmOrchestrator step) is responsible
// for honoring that verdict: proceed runs it, queueForApproval hands it to
// ApprovalQueue and waits, refuse drops it.
//
// House style: @MainActor final class : ObservableObject + static let shared,
// Codable models, zero em/en dashes, dollars as $N.
//
// Shared-type note: CommsPersona (the empire/personal disclosure helper) is
// owned by the sibling CommsPersona.swift. This module references CommsContext
// from there for the resolved persona on an outbound comm and defines its own
// queue-facing GatePersona for ApprovalQueue.

// MARK: - ActionRisk

// The gate's classification of an action's blast radius. guardrailHit carries
// the specific guardrail it tripped so the verdict and any log line can name it.
enum ActionRisk: Equatable {
    case routineReversible              // safe to do now (read, draft locally, plan)
    case bigIrreversible                // real-world effect, hard to undo : needs a tap
    case guardrailHit(reason: String)   // one of the five hard rules : refuse autonomous
}

// MARK: - ProposedAction

// A self-describing request to do something. Callers fill in the flags honestly;
// the gate trusts the flags AND independently sniffs the kind/target/detail so a
// caller that forgets to set isSpend still cannot slip a spend through.
struct ProposedAction: Codable, Equatable, Identifiable {

    // Coarse bucket the UI and gate switch on. .other covers everything that is
    // not money or an outbound comm (drafting a note, filing a task, queueing a
    // swarm step, etc.).
    enum Kind: String, Codable, Equatable {
        case spend           // moving / committing money in any form
        case externalComms   // a message to another person (email, DM, reply)
        case other
    }

    let id: UUID
    var kind: Kind
    // One line a human reads on the approval card. Plain language, no jargon.
    var summary: String
    // Machine target: an email address, a vendor, a brand surface, a file path.
    // Used both for the human card and for the gate's secret/leak heuristics.
    var target: String
    // Which brand this is for, if any. Drives the assistant-vs-user disclosure
    // split for outbound comms.
    var brand: String?
    // Opaque structured detail the caller needs to actually perform the work if
    // approved (recipient, amount_cents, draft body, file id, ...). The gate
    // peeks at a few well-known keys but treats the rest as opaque.
    var detail: [String: String]

    // Honest self-declared flags. The gate uses these AND its own sniff; a true
    // here is taken at face value, a false is re-checked, never blindly trusted.
    var isExternalComms: Bool
    var isSpend: Bool
    var isPublicPost: Bool
    var touchesSecrets: Bool

    init(
        id: UUID = UUID(),
        kind: Kind = .other,
        summary: String = "",
        target: String = "",
        brand: String? = nil,
        isExternalComms: Bool = false,
        isSpend: Bool = false,
        isPublicPost: Bool = false,
        touchesSecrets: Bool = false,
        detail: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.target = target
        self.brand = brand
        self.detail = detail
        self.isExternalComms = isExternalComms
        self.isSpend = isSpend
        self.isPublicPost = isPublicPost
        self.touchesSecrets = touchesSecrets
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, summary, target, brand, detail
        case isExternalComms, isSpend, isPublicPost, touchesSecrets
    }

    // Lenient decode so a persisted PendingApproval written by an older build
    // still loads (defaults rather than a throw that wipes the queue).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .other
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        target = (try? c.decode(String.self, forKey: .target)) ?? ""
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        detail = (try? c.decode([String: String].self, forKey: .detail)) ?? [:]
        isExternalComms = (try? c.decode(Bool.self, forKey: .isExternalComms)) ?? false
        isSpend = (try? c.decode(Bool.self, forKey: .isSpend)) ?? false
        isPublicPost = (try? c.decode(Bool.self, forKey: .isPublicPost)) ?? false
        touchesSecrets = (try? c.decode(Bool.self, forKey: .touchesSecrets)) ?? false
    }

    // The amount being committed, in cents, if this is a spend with a declared
    // amount_cents detail. nil for non-spends or an unpriced spend.
    var amountCents: Int? {
        guard let raw = detail["amount_cents"], let cents = Int(raw), cents > 0 else { return nil }
        return cents
    }
}

// MARK: - GatePersona

// The disclosure face a queued action would go out under, recorded on the
// PendingApproval so the approval card can show the user who it would send as
// before they tap. Mirrors the split: business => Sarah, personal => the user.
// Distinct from the sibling CommsPersona class (the full identity builder); this
// is just the tiny Codable token the queue persists.
enum GatePersona: String, Codable, Equatable {
    case sarah   // the assistant persona : business mail
    case owner   // the user themselves : personal matters
    case none    // not an outbound comm, no persona applies

    /// `owner` was called `jack` and its raw value is PERSISTED on every queued
    /// approval, so a plain rename would decode every already-queued item as
    /// `none` and show "n/a" where the card should say "you". Reading both
    /// spellings and writing only the new one migrates the queue as it drains,
    /// with no backfill and no migration step to forget.
    ///
    /// Unknown values decode to `.none` rather than throwing: a queue item that
    /// fails to decode takes the whole queue file with it, and losing a user's
    /// pending approvals to an unrecognized token is a far worse outcome than
    /// showing one card with no persona.
    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "sarah":          self = .sarah
        case "owner", "jack":  self = .owner
        default:               self = .none
        }
    }

    var displayName: String {
        switch self {
        case .sarah: return "Sarah (assistant)"
        case .owner: return "you"
        case .none: return "n/a"
        }
    }

    // The signature line an outbound message would carry. The user's own mail
    // signs with their own name (CommsPersona builds that from the configured
    // identity), so this case is the card-facing label for it, not a name.
    var signature: String {
        switch self {
        case .sarah: return "Sarah, assistant"
        case .owner: return "you"
        case .none: return ""
        }
    }

    // Map the sibling CommsContext (business/personal) onto a queue persona.
    init(context: CommsContext) {
        switch context {
        case .business: self = .sarah
        case .personal: self = .owner
        }
    }
}

// MARK: - GateVerdict

// The gate's answer. proceed = do it now. queueForApproval carries the fully
// built PendingApproval the caller should hand to ApprovalQueue. refuse blocks
// it outright with a reason (a hard guardrail Jax must never cross autonomously).
enum GateVerdict: Equatable {
    case proceed
    case queueForApproval(PendingApproval)
    case refuse(reason: String)
}

// MARK: - DecisionGate

@MainActor
final class DecisionGate: ObservableObject {
    static let shared = DecisionGate()

    // Last verdict, for an at-a-glance UI / activity readout. Not persisted:
    // the durable record is the ApprovalQueue (for queued items) and the
    // notification timeline (for urgent pings).
    @Published private(set) var lastVerdict: GateVerdict?
    @Published private(set) var lastAction: ProposedAction?

    private init() {}

    // MARK: The gate

    // Evaluate ONE action against all five hard guardrails, in priority order.
    // Pure decision: it never performs the action and never mutates the queue
    // (the caller enqueues the returned PendingApproval). Records lastVerdict so
    // the UI can show what just happened.
    func evaluate(_ action: ProposedAction) -> GateVerdict {
        let verdict = decide(action)
        lastAction = action
        lastVerdict = verdict
        return verdict
    }

    // The decision tree. Order matters: a public post that also spends should
    // refuse on the post rule first; money is the next-hardest line; leaks
    // refuse; outbound comms queue with the right persona; everything else falls
    // through the routine-vs-not classifier where the FAIL SAFE default lives.
    private func decide(_ action: ProposedAction) -> GateVerdict {

        // GUARDRAIL 3: never post publicly as the user. No Threads / social
        // publish, autonomously or queued. This is a hard refuse, not a tap: there
        // is deliberately no one-tap path to publish-as-them at all.
        if sniffsPublicPost(action) {
            return .refuse(reason: "Public posting as you is never allowed. \(UserIdentity.assistantName) does not publish to social.")
        }

        // GUARDRAIL 2: never send / share important documents, files, insights,
        // or trade secrets externally. A leak is irreversible and a hard refuse.
        if sniffsSecretLeak(action) {
            return .refuse(reason: "Sharing documents, files, or trade secrets externally is never allowed.")
        }

        // GUARDRAIL 1: never move money. Spend is REFUSED as an autonomous act,
        // but Jax may QUEUE it for the user's one-tap approval. So: do not proceed,
        // do not silently spend, build an approval item instead. Spend approvals
        // are urgent (the user should see them now).
        if sniffsSpend(action) {
            let item = PendingApproval(
                action: action,
                urgent: true,
                persona: .none,
                reason: "Spend may only be approved by you. \(UserIdentity.assistantName) never moves money on its own."
            )
            return .queueForApproval(item)
        }

        // GUARDRAIL 4: outbound comms must carry the correct disclosure and may
        // ONLY go out through the gate. Every external message queues for a tap
        // with the resolved persona attached (business => Sarah, personal => you)
        // so the user sees who it would send as before approving.
        if sniffsExternalComms(action) {
            let persona = resolvedPersona(for: action)
            let item = PendingApproval(
                action: action,
                urgent: true,
                persona: persona,
                reason: "Outbound message. Sends as \(persona.displayName) only after your approval."
            )
            return .queueForApproval(item)
        }

        // Everything else: classify routine-and-reversible vs not. This is where
        // GUARDRAIL 5 (default to PAUSE-and-ask) lives. Only a provably routine,
        // reversible, internal action proceeds; anything else queues.
        switch classifyResidual(action) {
        case .routineReversible:
            return .proceed
        case .bigIrreversible:
            let item = PendingApproval(
                action: action,
                urgent: false,
                persona: .none,
                reason: "Not clearly routine and reversible. Pausing for your call."
            )
            return .queueForApproval(item)
        case .guardrailHit(let reason):
            return .refuse(reason: reason)
        }
    }

    // MARK: Guardrail sniffers
    //
    // Each sniffer combines the caller's honest flag with an independent content
    // heuristic, so a caller that under-declares (forgets to set a flag) still
    // gets caught. Over-declaring (sets a flag it did not need) only ever makes
    // the gate MORE cautious, which is the safe direction.

    private func sniffsPublicPost(_ a: ProposedAction) -> Bool {
        if a.isPublicPost { return true }
        let hay = (a.target + " " + a.summary + " " + a.detailBlob).lowercased()
        let publicSurfaces = ["threads", "twitter", " x ", "instagram", "tiktok",
                              "facebook", "linkedin", "youtube", "reddit",
                              "publish", "post publicly", "go public", "social post"]
        return publicSurfaces.contains { hay.contains($0) }
    }

    private func sniffsSecretLeak(_ a: ProposedAction) -> Bool {
        if a.touchesSecrets { return true }
        // A leak needs BOTH "leaving the building" (an external recipient or an
        // upload) AND sensitive material. An internal note that mentions an API
        // key is fine; emailing that note out is not.
        let leaving = a.isExternalComms || isExternalTarget(a.target) || a.kind == .externalComms
        guard leaving else { return false }
        let hay = (a.summary + " " + a.detailBlob).lowercased()
        let sensitive = ["api key", "api_key", "secret", "token", "password",
                         "credential", "private key", ".p8", ".env",
                         "trade secret", "attach", "attachment", "this document",
                         "source code", "the file", "internal doc"]
        return sensitive.contains { hay.contains($0) }
    }

    private func sniffsSpend(_ a: ProposedAction) -> Bool {
        if a.isSpend || a.kind == .spend { return true }
        // amount_cents in the detail is the canonical money signal across Grux.
        if a.amountCents != nil { return true }
        let hay = (a.summary + " " + a.detailBlob).lowercased()
        let moneyVerbs = ["send money", "transfer", "wire", "swap", "purchase",
                          "buy ", "pay ", "checkout", "charge", "subscribe",
                          "top up", "fund "]
        return moneyVerbs.contains { hay.contains($0) }
    }

    private func sniffsExternalComms(_ a: ProposedAction) -> Bool {
        if a.isExternalComms || a.kind == .externalComms { return true }
        return isExternalTarget(a.target)
    }

    // MARK: Residual classifier (FAIL SAFE)

    // Reached only after the four hard sniffers cleared. Anything that smells
    // like a real-world, hard-to-undo effect on an external system queues; only
    // clearly internal, reversible work proceeds. When in genuine doubt, this
    // returns .bigIrreversible (queue), never .routineReversible.
    private func classifyResidual(_ a: ProposedAction) -> ActionRisk {
        let hay = (a.target + " " + a.summary + " " + a.detailBlob).lowercased()

        // Irreversible / external-effect verbs that are not money, comms, posts,
        // or leaks but still should not happen unattended.
        let heavyVerbs = ["delete", "destroy", "drop table", "deploy", "merge to main",
                          "force push", "rotate", "revoke", "disable", "uninstall",
                          "cancel subscription", "shut down", "terminate",
                          "publish app", "submit to app store", "release"]
        if heavyVerbs.contains(where: { hay.contains($0) }) {
            return .bigIrreversible
        }

        // FAIL SAFE: anything reaching the residual classifier is a tool that was
        // NOT on JaxToolGate.safeReadOnlyTools (the authoritative allowlist of
        // internal, reversible tools, which short-circuit to .proceed BEFORE a
        // ProposedAction is ever built), so by construction it is potentially
        // side-effecting. We do NOT let free-text verb sniffing (a safe-sounding
        // word like "read" / "log" / "note" appearing anywhere in the summary)
        // upgrade it to .proceed: that failed OPEN for any side-effecting tool
        // whose text happened to mention such a word. Unclassified always queues
        // for one-tap approval. To let a genuinely-safe new tool run unattended,
        // add it to JaxToolGate.safeReadOnlyTools, not here.
        return .bigIrreversible
    }

    // MARK: Helpers

    // The disclosure split for a queued comm. Reuses the sibling CommsPersona
    // classifier so the gate and the actual send path can never disagree on who
    // a message goes out as. Falls back to a local heuristic if no recipient is
    // present. Default for an unclassified outbound is Sarah (business), the
    // safer face for an automated send.
    func resolvedPersona(for a: ProposedAction) -> GatePersona {
        // Pull recipients out of the detail if the comms path stamped them.
        let recipients = (a.detail["recipients"] ?? a.target)
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let subject = a.detail["subject"] ?? a.summary
        let context = CommsPersona.shared.classify(
            recipient: recipients,
            subject: subject,
            body: a.detail["body"] ?? a.summary,
            brandHint: a.brand
        )
        return GatePersona(context: context)
    }

    // A target that points outside the user's own machine/state. An email address,
    // an http(s) URL, or an @handle all count as external.
    private func isExternalTarget(_ target: String) -> Bool {
        let t = target.lowercased()
        if t.contains("@") { return true }          // email or @handle
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return true }
        if t.contains("://") { return true }
        return false
    }
}

private extension ProposedAction {
    // Flatten the opaque detail into one searchable string for the heuristics.
    // Sorted so the blob is stable across runs (handy for any logging).
    var detailBlob: String {
        detail
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " ")
    }
}
