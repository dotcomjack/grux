import Foundation

/// A breaker for account-level refusals that retrying cannot fix.
///
/// WHAT HAPPENED WITHOUT IT. Measured from the owner's logs on 2026-08-23,
/// after the Anthropic API credit balance reached zero:
///
///     253  reply FAILED: Anthropic HTTP 400
///     184  ambient extractor FAILED: Anthropic HTTP 400
///      64  jax briefing compose FAILED: Anthropic HTTP 400
///      62  stuck compose FAILED: Anthropic HTTP 400
///     190  spoken aloud through ElevenLabs, in wording that blamed the
///          conversation's length for an empty wallet
///      11  spoken aloud as raw JSON
///
/// Four autonomous loops kept firing at an account that had already told them,
/// in a plain English sentence, that it had no money. Each failure was then
/// announced through a paid voice API, so a dead balance on one vendor spent
/// credit on another to complain about it.
///
/// "Your credit balance is too low" is categorically different from a rate
/// limit or a 503. It does not clear on its own, no amount of backoff reaches
/// it, and only a person with a billing page can resolve it. Nothing in the app
/// modelled that difference, so nothing could stop.
///
/// DESIGN NOTES, each one load-bearing:
///
/// - ONLY non-transient signals latch. Latching on a 429 or a 503 would let one
///   bad minute silently disable every background feature, which is a worse
///   failure than the one this closes.
/// - A PERSON MAY ALWAYS STILL TRY. They may have topped up two seconds ago,
///   and their intent outranks our cached belief. Only background work stands
///   down, and background work is what burned the 563 calls.
/// - SUCCESS CLEARS IT. Otherwise adding credit leaves everything dead until
///   relaunch.
/// - ANNOUNCING IS RATE LIMITED SEPARATELY, because speech costs money too. The
///   first occurrence is information; the hundred and ninetieth is a bill.
final class ProviderHealth: @unchecked Sendable {

    static let shared = ProviderHealth()

    /// Marks a call as fired by a LOOP rather than pressed by a person.
    ///
    /// INVERTED after review. It was `userInitiated`, defaulting false, which
    /// made background the default so a new call site would be "safe by
    /// omission". That reasoning was wrong in the direction that matters:
    /// `withValue(true)` was set at exactly ONE of thirty seven call sites, so
    /// every user-pressed button routing through `complete()` was treated as a
    /// loop and refused locally while latched. Document rewrite, Compare,
    /// Research, Creative and the Design Studio editors all went dead on a
    /// latched breaker, and the class doc promised the opposite.
    ///
    /// Now the default is PERMISSIVE. A call site that says nothing is treated
    /// as a person, and the worst case is the pre-breaker status quo, one wasted
    /// request. Only the loops that burned 563 calls opt in, and each one is a
    /// deliberate line of code rather than an omission nobody notices.
    @TaskLocal static var backgroundWork = false


    private let lock = NSLock()
    private var creditExhausted = false
    /// The last failure we announced, so an identical unfixed one stays quiet
    /// while a genuinely NEW problem still gets through.
    private var lastAnnouncedSignature: String?
    /// Every failure kind already spoken since the last success. A set, not a
    /// single slot, because alternating kinds defeated the single slot.
    private var announced: Set<String> = []
    private var pendingSignature: String?

    private init() {}

    var isCreditExhausted: Bool {
        lock.lock(); defer { lock.unlock() }
        return creditExhausted
    }

    /// Background loops consult this before spending a call.
    var mayStartBackgroundWork: Bool { !isCreditExhausted }

    /// A person pressing a button is never blocked by a cached belief.
    var mayStartUserInitiatedWork: Bool { true }

    /// Classify a failure. Deliberately keyed off the provider's own sentence
    /// rather than the status code: an exhausted balance arrives as a 400
    /// `invalid_request_error`, the same shape as a genuinely malformed
    /// request, and only the message distinguishes them.
    func record(failureBody: String, statusCode: Int) {
        let lowered = failureBody.lowercased()
        let isCredit = lowered.contains("credit balance")
            || lowered.contains("plans & billing")
            || lowered.contains("purchase credits")

        lock.lock()
        let wasExhausted = creditExhausted
        if isCredit { creditExhausted = true }
        pendingSignature = isCredit ? "credit" : "http\(statusCode)"
        let latchedNow = !wasExhausted && creditExhausted
        lock.unlock()
        // LOG THE TRANSITION, NOT THE STATE. Reconstructing why the breaker was
        // or was not latched from failure logs alone proved impossible: the
        // gate demonstrably worked for three minutes and then stopped, and
        // nothing recorded what cleared it. A transition line makes the next
        // occurrence a one line grep instead of an inference.
        if latchedNow { WakeLog.shared.log("ProviderHealth: LATCHED on credit exhaustion") }
    }

    func recordSuccess() {
        lock.lock()
        let wasExhausted = creditExhausted
        creditExhausted = false
        lastAnnouncedSignature = nil
        announced.removeAll()
        pendingSignature = nil
        lock.unlock()
        if wasExhausted {
            // The interesting one. If this fires while the balance is still
            // empty, some call is succeeding that should not be clearing a
            // credit latch, and the caller is what needs finding.
            WakeLog.shared.log("ProviderHealth: CLEARED by a successful call")
        }
    }

    /// A different key has a different balance, so our belief was about the old
    /// one and must not outlive it.
    func credentialChanged() { recordSuccess() }

    /// The exact predicate the client gate uses.
    ///
    /// Extracted because the gate itself was UNTESTABLE: eight tests of this
    /// class passed with the gate in Claude.swift entirely disabled, since they
    /// only exercised the state machine and nothing proved the client consulted
    /// it. That is the same "a correct rule nothing calls" defect this codebase
    /// has hit before. Now the predicate is asserted directly and an
    /// integration test proves complete() routes through it.
    func shouldSkipCall(backgroundWork: Bool) -> Bool {
        backgroundWork && isCreditExhausted
    }

    /// The message the gate throws. Named so a test can assert the refusal came
    /// from HERE and not from the network.
    /// Deliberately avoids the phrases `record` latches on ("credit balance",
    /// "plans & billing", "purchase credits"). This string is thrown as a
    /// synthetic 400 and travels the same paths a real provider body does, so
    /// if it carried the trigger words any downstream classifier, including
    /// this one, could read our own refusal as a fresh account failure and
    /// re-latch on it. Self-reinforcing state is how a breaker becomes a bug.
    static let standDownMessage = "skipped locally: provider funds unavailable, background work stood down"

    /// True at most once per distinct unresolved failure. Consuming, so two
    /// callers cannot both announce the same thing.
    func shouldAnnounce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let sig = pendingSignature else { return false }
        // ALTERNATION DEFEATED THE OLD RULE. One slot plus an equality test
        // meant two loops failing with different statuses announced forever:
        // credit, 429, credit, 429. That is the incident's own shape, four
        // concurrent loops with interleaved statuses, and it reproduced the
        // paid-TTS storm this exists to stop. Announced kinds are now
        // remembered as a SET, so each distinct failure is heard once until
        // something actually changes.
        if announced.contains(sig) { return false }
        announced.insert(sig)
        lastAnnouncedSignature = sig
        return true
    }

    /// Tests only. The breaker is a process-wide singleton by design, so a test
    /// that trips it would otherwise leak into every test that follows.
    func resetForTesting() {
        lock.lock()
        creditExhausted = false
        lastAnnouncedSignature = nil
        announced.removeAll()
        pendingSignature = nil
        lock.unlock()
    }
}
