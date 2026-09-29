import Foundation
import GruxAgentCore

// Whether the last agent run found the Claude CLI's sign-in expired. The
// panel's Now list shows "Claude sign-in expired" from this, and its one
// button starts the same sign-in the Self-Upgrade card's "Sign in to build
// it" starts (`AccountSwitcher.signIn`). Never the monthly-limit pause: that
// state waits for an account switch and would lie about what happened.
@MainActor
final class ClaudeSignInState: ObservableObject {
    static let shared = ClaudeSignInState()

    @Published private(set) var expired = false

    /// `SignInExpiry.report` lands here: true on a run that failed on the
    /// sign-in, false on a run that succeeded.
    func record(expired: Bool) {
        if self.expired != expired { self.expired = expired }
    }

    /// Points every agent runner's verdict at this state. Runs once, at launch.
    static let wireAgentRunners: Void = {
        SignInExpiry.report = { expired in
            Task { @MainActor in ClaudeSignInState.shared.record(expired: expired) }
        }
    }()

    /// The one button: the existing sign-in flow, cleared once it lands.
    func startSignIn(using signIn: @escaping @MainActor () async -> Bool = { await AccountSwitcher.shared.signIn() }) {
        Task { @MainActor in
            if await signIn() { self.record(expired: false) }
        }
    }
}
