import Foundation

// Tells a run that failed because the Claude CLI's sign-in expired apart from
// every other failure. Measured on the Mini 2026-09-27 (ledger A16): the CLI
// answers an expired OAuth with an `is_error` result reading
// `Failed to authenticate: OAuth session expired and could not be refreshed`.
// Nothing told the person to sign in again; the run just "had trouble".
//
// This is its own verdict and never the monthly usage limit (`LimitSignal`):
// a limit waits for an account switch, an expired sign-in needs a sign-in.
public enum SignInExpiry {

    /// True when a failed run's own words say the CLI is not signed in.
    /// Callers pass only the text of a run that already failed.
    public static func detect(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.hasPrefix("failed to authenticate")
            || t.contains("oauth session expired")
            || t.contains("oauth token has expired")
            || t.contains("please run /login")
    }

    /// Every agent runner reports here once per run: `true` when the run
    /// failed on an expired sign-in, `false` when a run succeeded (which proves
    /// the sign-in works again). The app points it at its sign-in state at
    /// launch; the default does nothing.
    nonisolated(unsafe) public static var report: @Sendable (_ expired: Bool) -> Void = { _ in }
}
