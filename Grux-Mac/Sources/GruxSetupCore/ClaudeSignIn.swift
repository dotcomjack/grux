import Foundation

/// Whether the last agent run found the Claude Code CLI's sign-in expired, as the app
/// stored it (`ClaudeSignInState`, `claude-sign-in.json`). The app leads Now with it;
/// `grux next` and `grux doctor` read the same file, so they work with Grux closed and
/// cannot tell a person something different (D103).
public enum ClaudeSignIn {
    /// The setup step every feature that runs the Claude Code CLI lists.
    public static let agentStep = "step.agent_cli_installed"

    /// The command the app's Sign in runs in Terminal when nothing else was recorded.
    public static let signInCommand = "claude auth login --claudeai"

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux/claude-sign-in.json")
    }

    /// What `grux next` says for an expired sign-in. The command leads to the app's Sign
    /// in, the one door that clears the verdict once a call goes through: signing in from
    /// Terminal leaves it until an agent run works (only `ClaudeSignInState.record`
    /// writes it), and `claude auth status` reads signed in while the dead refresh token
    /// that raised it is still there, so the CLI cannot clear it by asking (wave 28).
    public static func nextAnswer(blocking: [String], list: ([String]) -> String)
        -> (answer: String, command: String, why: String) {
        ("Sign in to Claude, in Grux.",
         "grux open agents",
         "The last agent run found Claude's sign-in expired, so " + blockedPhrase(blocking, list: list)
            + " until you sign in. Sign in, at the top of Now, runs Claude's login "
            + "and clears this once a call goes through. Signing in from Terminal with "
            + signInCommand + " works too, and Grux clears this after the next agent run "
            + "that works.")
    }

    /// What cannot run, in the words both commands print: the chosen features that use the
    /// CLI, or, with none to name, what the app's row means (wave 28 round 2).
    public static func blockedPhrase(_ blocking: [String], list: ([String]) -> String) -> String {
        blocking.isEmpty ? "agent runs cannot start" : list(blocking) + " cannot run"
    }

    private struct Stored: Decodable { var expired: Bool }

    /// True only when the app recorded an expired sign-in. No file, or one it cannot
    /// read, is no verdict: the next agent run writes one.
    public static func expired(at url: URL = defaultURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        return stored.expired
    }
}
