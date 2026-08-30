# Reply Policy System (Jax email triage)

Date: 2026-06-18
Status: Approved, pre-implementation
Lands before: email Phase 2 (corrections -> learning)

## Problem

Jax drafts a reply to every unread support email it reads, gated only by a
duplicate check. That means no-reply and marketing mail get drafts too: e.g. a
Walmart Marketplace webinar invite from `no-reply@mpsend.walmart.com` produced a
staged Acme reply. There is no way to (a) silence a sender, or (b) say which
TYPES of mail a given brand should auto-draft.

## Goal

Two controls, perfected before Phase 2:

1. Hide sender: a sender address or domain that never gets a draft again.
2. Per-brand reply rules: which email TYPES (kinds + support categories) a brand
   auto-drafts for.

Net effect: Jax stops drafting replies to no-reply / marketing mail by default,
and you can tune exactly what each mailbox replies to.

## Decisions (locked with the owner)

- Posture: opt-out. Personal/business mail drafts by default; no-reply/automated
  and marketing/promotional are OFF by default. You turn off what you do not
  want; you do not have to enable normal support mail.
- Hide sender granularity: both. The control offers "hide this address" and
  "hide @domain"; you pick per use.
- Skipped mail: silent skip + WakeLog entry. No separate "not drafted" queue in
  v1. The hide-sender affordance lives on draft cards and Mailbox rows (mail
  you can see), and the default-off kinds handle no-reply/marketing without you
  seeing them.
- Taxonomy v1: 3 kinds (No-reply/automated, Marketing/promotional,
  Personal/business) + the existing 4 support categories (Refund, Shipping,
  Product, Other). Richer taxonomy deferred (YAGNI).
- Gating strategy: cheap deterministic kind-gate BEFORE the LLM classify+draft
  (kills no-reply/marketing at zero model cost), plus a category filter applied
  to the category the existing classifier already returns. No second model in
  the path.

## Architecture

Each unit is small, single-purpose, testable in isolation.

### EmailKind (new, pure)
`Sources/Grux/EmailTriage/EmailKind.swift`

```
enum EmailKind: String, Codable, CaseIterable, Identifiable {
    case automated   // no-reply / system / bounce / auto-submitted
    case marketing   // bulk / promotional / newsletter
    case personal    // a real human/business sender (default)
    var id: String { rawValue }
    var label: String            // "No-reply / automated", "Marketing / promotional", "Personal / business"
    // Deterministic, no LLM. Sender-address patterns + bulk/auto header flags
    // the mail layer already parsed. Order: automated first, then marketing,
    // else personal.
    static func detect(fromEmail: String, fromName: String, subject: String,
                       isBulk: Bool, isAutoSubmitted: Bool) -> EmailKind
}
```
Automated address patterns (case-insensitive, on the local-part/address):
`no-reply`, `noreply`, `no_reply`, `donotreply`, `do-not-reply`, `do_not_reply`,
`mailer-daemon`, `postmaster`, `bounce`, `bounces`, `notification`,
`notifications`, `mailer@`, `mpsend.` (and `isAutoSubmitted`).
Marketing signals: `isBulk` (List-Unsubscribe / Precedence: bulk), or address
local-part `newsletter`, `marketing`, `promo`, `promotions`, `news`, `updates`,
`offers`, `deals`.

### BrandReplyPolicy + ReplyPolicyStore (new)
`Sources/Grux/EmailTriage/ReplyPolicy.swift`

```
struct BrandReplyPolicy: Codable, Equatable {
    var kinds: [String: Bool]       // EmailKind.rawValue -> enabled
    var categories: [String: Bool]  // SupportCategory.rawValue -> enabled
    static var defaults: BrandReplyPolicy  // personal:true, automated:false, marketing:false; all categories true
    func allows(kind: EmailKind) -> Bool       // missing key -> use defaults for that key
    func allows(category: SupportCategory) -> Bool
}

@MainActor final class ReplyPolicyStore: ObservableObject {
    static let shared: ReplyPolicyStore
    @Published private(set) var policies: [String: BrandReplyPolicy]  // brand voice -> policy
    func policy(for brand: String) -> BrandReplyPolicy   // defaults if absent
    func setKind(_ kind: EmailKind, enabled: Bool, for brand: String)
    func setCategory(_ category: SupportCategory, enabled: Bool, for brand: String)
}
```
Persists `~/.grux/support/reply-policy.json`. Lenient decode (new keys default
to `defaults`), so older files and unknown brands resolve to opt-out defaults.

### SenderSuppressionStore (new)
`Sources/Grux/EmailTriage/SenderSuppression.swift`

```
@MainActor final class SenderSuppressionStore: ObservableObject {
    static let shared: SenderSuppressionStore
    @Published private(set) var emails: Set<String>    // lowercased addresses
    @Published private(set) var domains: Set<String>   // lowercased bare domains, e.g. "walmart.com"
    func isSuppressed(email: String) -> Bool
    func muteEmail(_ email: String)
    func muteDomain(_ domain: String)     // accepts "walmart.com" or "@walmart.com"
    func unmuteEmail(_ email: String)
    func unmuteDomain(_ domain: String)
    static func domain(of email: String) -> String?   // lowercased domain part, nil if no "@"
}
```
Persists `~/.grux/support/muted-senders.json` `{ "emails": [...], "domains": [...] }`.
Matching (case-insensitive): suppressed if `emails` contains the address, OR the
address domain `d` equals a muted domain `m` or `d.hasSuffix("." + m)` (so muting
`walmart.com` also covers `mpsend.walmart.com`).

### ReplyPolicyGate (new)
`Sources/Grux/EmailTriage/ReplyPolicyGate.swift`

```
enum ReplyDecision: Equatable { case proceed(EmailKind); case skip(reason: String) }

@MainActor enum ReplyPolicyGate {
    static func decide(fromEmail: String, fromName: String, subject: String,
                       isBulk: Bool, isAutoSubmitted: Bool, brand: String) -> ReplyDecision
    static func allowsCategory(_ category: SupportCategory, brand: String) -> Bool
}
```
`decide`: muted sender -> `.skip("muted sender")`; `kind = EmailKind.detect(...)`;
policy disallows kind -> `.skip("\(kind.rawValue) disabled for \(brand)")`; else
`.proceed(kind)`.

## Integration (shared files)

- `MailGraphClient.fetchUnread`: add `internetMessageHeaders` to `$select`; parse
  `List-Unsubscribe` / `Precedence: bulk` -> `isBulk`, `Auto-Submitted` (non-`no`)
  -> `isAutoSubmitted`. Tab-scraping path leaves both false (degrades to
  address-pattern detection).
- `InboxMessage` (OutlookReader.swift): add `var isBulk: Bool = false` and
  `var isAutoSubmitted: Bool = false` (defaulted, so fixtures/old JSON decode).
- `EmailTriageEngine.runHourly`: after the dup check and before
  `classifyAndDraft`, call `ReplyPolicyGate.decide(...)`. On `.skip(reason)`,
  `WakeLog` it and `continue`. After classify, if
  `!ReplyPolicyGate.allowsCategory(result.category, brand:)`, log + skip staging.
- Hide-sender UI: a button on `JaxDraftCard` (Jax HQ) and the Mailbox detail
  header -> a small menu "Hide this address" / "Hide @domain". On choose: mute via
  `SenderSuppressionStore`, then dismiss every staged draft from that sender.
- Reply Rules sheet: `Sources/Grux/Jax/ReplyRulesSheet.swift`, opened from a gear
  in the Jax HQ Drafts section header, scoped to the current `BrandFilter`
  selection (falls back to Acme when scope is All). Shows kind toggles, category
  toggles, and the muted-senders list with remove buttons.

## Error handling

- Stores fail safe: unreadable/missing JSON -> defaults (opt-out policy, empty
  suppression). A corrupt policy never blocks the sweep.
- The gate is deterministic and never throws; a classification ambiguity resolves
  to `.personal` (most permissive) so a real human is never silently dropped by a
  detection miss. False negatives (a marketing mail slipping through) cost one
  draft you can dismiss + hide; false positives (dropping a human) are the
  expensive error, so detection biases toward `.personal`.

## Testing

Unit (new test files, parallelizable):
- `EmailKindTests`: automated/marketing/personal across address patterns, header
  flags, the Walmart `no-reply@mpsend.walmart.com` case, and a plain human sender.
- `SenderSuppressionTests`: email exact, domain exact, domain suffix
  (`mpsend.walmart.com` muted by `walmart.com`), case-insensitivity, `@domain`
  input normalization, unmute.
- `ReplyPolicyTests`: defaults (opt-out), `allows(kind:)` / `allows(category:)`,
  persistence round-trip, lenient decode of a partial file.
- `ReplyPolicyGateTests`: muted -> skip; automated kind under defaults -> skip;
  personal -> proceed; category disabled -> `allowsCategory` false.

End-to-end (driven via CLI fixtures + installed app):
- A no-reply fixture (Walmart) + a normal Acme support fixture run through the
  triage entry point: assert the no-reply stages NO draft and logs a skip; the
  support email stages a draft.
- Hide a sender, re-run: assert no new draft and existing drafts from that sender
  are dismissed.
- Screenshot the Reply Rules sheet rendering.

## Out of scope (v1)

Per-brand suppression lists (suppression is global); a visible "not drafted"
recovery queue; richer category taxonomy; learning from your edits (Phase 2).
