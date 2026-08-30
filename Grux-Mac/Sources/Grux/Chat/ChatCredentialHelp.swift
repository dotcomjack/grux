import Foundation

/// The sentences Grux uses when a credential is the problem, in one place.
///
/// WHY THIS EXISTS. Grux keeps two credentials whose names both end in Claude,
/// and the app repeatedly told users to fix the wrong one:
///
///   1. An Anthropic API key in the Keychain. This is what CHAT spends.
///   2. A claude.ai OAuth session on the agent CLI, managed by AccountSwitcher.
///      This is what headless TERMINAL SESSIONS spend.
///
/// They are funded separately, and that is the part nobody guesses. A claude.ai
/// Pro or Max subscription does NOT pay for API calls. You can be signed in,
/// well inside your plan limits, with a perfectly healthy account, and still
/// have an API balance of zero, because they are two different balances.
///
/// Reported by the owner 2026-08-23 with an active plan, plenty of usage left,
/// and Grux telling them to switch accounts. They were right and the app was
/// wrong: switching accounts runs `claude auth logout`, cannot change the API
/// key chat is about to reuse, and destroys a working terminal session on the
/// way past.
enum ChatCredentialHelp {

    /// The distinction itself. Kept short enough to sit in a banner, because a
    /// banner nobody finishes reading explains nothing.
    static let apiCreditVersusSubscription =
        "A Claude subscription and API credit are billed separately, so an active plan does not "
      + "pay for API calls. Chat spends the API key in Settings."

    /// For the credit-exhausted case. Names the free way out first: a local
    /// model needs no key and no balance, and next to a billing link that path
    /// would otherwise be invisible.
    static let creditExhausted =
        "Chat's API key is out of credit. "
      + apiCreditVersusSubscription
      + " Add credit to that key, use a different key, or run a local model, which costs nothing."

    /// For a genuine per-minute API rate limit. Waiting really is the fix here.
    static let rateLimited =
        "Chat's API key hit a rate limit. Wait a moment and retry, or run a local model to keep "
      + "working while it clears."

    /// For an account or organisation USAGE limit, which is a different thing
    /// and must not be described as something a moment's wait clears. The two
    /// used to share one sentence, so a monthly cap was reported as if retrying
    /// shortly would help.
    static let usageLimitReached =
        "Chat's API key has hit its usage limit, which does not clear by waiting a moment. "
      + apiCreditVersusSubscription
      + " Raise the limit on that key, use a different key, or run a local model."

    /// Shown wherever the two credentials could be mistaken for each other.
    static let notTheSameAsSigningInTheCli =
        "This is separate from signing the agent CLI in to Claude. That powers terminal sessions, "
      + "not chat."
}
