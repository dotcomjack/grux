import Foundation
import GruxAgentCore

// Whether the last agent run found the Claude CLI's sign-in expired. The
// panel's Now list shows "Claude sign-in expired" from this, and its one
// button starts the same sign-in the Self-Upgrade card's "Sign in to build
// it" starts (`AccountSwitcher.signIn`). Never the monthly-limit pause: that
// state waits for an account switch and would lie about what happened.
//
// Stored, so the row outlives a relaunch: chat, Agents and Self-Upgrade send
// the person to "Claude sign-in, at the top of Now", and in memory only the
// row was gone after any relaunch while those lines still named it (D75).
@MainActor
final class ClaudeSignInState: ObservableObject {
    static var sharedStore: URL { Persistence.supportDir.appendingPathComponent("claude-sign-in.json") }
    static let shared = ClaudeSignInState(store: sharedStore)

    @Published private(set) var expired = false

    private struct Stored: Codable { var expired: Bool }

    /// Where the verdict is kept; nil keeps it in memory only.
    private let store: URL?

    init(store: URL? = nil) {
        self.store = store
        if let store {
            // Unreadable reads as no row: the next run's verdict rewrites it.
            expired = (try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: store)))?.expired ?? false
        }
    }

    /// `SignInExpiry.report` lands here: true on a run that failed on the
    /// sign-in, false on a run that succeeded.
    func record(expired: Bool) {
        guard self.expired != expired else { return }
        self.expired = expired
        if let store, let data = try? JSONEncoder().encode(Stored(expired: expired)) {
            try? data.write(to: store, options: .atomic)
        }
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
