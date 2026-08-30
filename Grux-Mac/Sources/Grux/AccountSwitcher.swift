import Foundation
import AppKit
import Combine

// AccountSwitcher - manages the user's set of paired claude.ai OAuth accounts
// and which one is currently active.
//
// Why this exists: SwarmWorker spawns `claude --print` against whichever
// account is "active" in the macOS keychain. When a worker hits the monthly
// usage limit on that account (LimitSignalDetector fires), the orchestrator
// pauses the job. The Resume sheet lets the user pick a different account;
// AccountSwitcher then drives the actual swap and verifies it via
// `claude auth status --json` before the orchestrator re-spawns the paused
// worker.
//
// State on disk: ~/Library/Application Support/Grux/auth-state.json
//   { version, accounts[], activeAccountId, perAccount{} }
//
// Switching mechanism (v1): hard-switch via the supported claude CLI surface
// - `claude auth logout` then `claude auth login --email <addr>`. The login
// step requires browser interaction (Anthropic OAuth), so we spawn a Terminal
// window with the command pre-typed. Once the user finishes OAuth in their
// browser, we detect the swap by polling `claude auth status --json`.
//
// Why NOT env-based switching: setting CLAUDE_CODE_OAUTH_TOKEN per-spawn
// would mean the worker takes API auth path, and tools/verify-subscription-auth.sh
// guards against that exact regression. Hard-switch keeps the OAuth-only
// guarantee intact.

@MainActor
final class AccountSwitcher: ObservableObject {

    static let shared = AccountSwitcher()

    @Published private(set) var state: AuthState = AuthState()

    // Last observed `claude auth status --json` response. Refreshed on
    // refreshActiveStatus() and after a switch completes. Used to render the
    // "currently active" indicator in the Resume sheet.
    @Published private(set) var liveStatus: LiveStatus?

    // The `claude auth login` command from the most recent switch attempt, kept
    // so the Resume sheet can offer "Re-open login Terminal" on a timeout
    // WITHOUT re-running logout (the working account was already logged out at
    // the start of the switch). nil before any switch is attempted.
    @Published private(set) var lastLoginCommand: String?

    // True after a switch logged out the prior account but no new account is
    // signed in yet (the user closed the Terminal, the OAuth failed, or they
    // stepped away). Surfaces a "signed out of everything" warning in the
    // Resume sheet so a failed switch isn't a silent worse-than-before state.
    @Published private(set) var isSignedOutOfEverything: Bool = false

    private init() {
        load()
        Task { await refreshActiveStatus() }
    }

    // MARK: - Persistence

    private static var stateURL: URL {
        Persistence.supportDir.appendingPathComponent("auth-state.json")
    }

    func load() {
        let fallback = AuthState()
        let loaded = Persistence.load(AuthState.self, from: Self.stateURL, fallback: fallback)
        self.state = loaded
    }

    private func save() {
        Persistence.save(state, to: Self.stateURL)
    }

    // MARK: - Live status

    // Calls `claude auth status --json` and parses the result. Best-effort -
    // returns nil if the CLI is missing, the user is logged out, or the JSON
    // shape changed. Non-throwing because every caller should degrade
    // gracefully (the Resume sheet still works without it).
    func refreshActiveStatus() async {
        let out = await Self.runClaude(args: ["auth", "status", "--json"])
        guard out.exitCode == 0,
              let data = out.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            self.liveStatus = nil
            return
        }
        let status = LiveStatus(
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            authMethod: obj["authMethod"] as? String,
            email: obj["email"] as? String,
            orgId: obj["orgId"] as? String,
            orgName: obj["orgName"] as? String,
            subscriptionType: obj["subscriptionType"] as? String,
            checkedAt: Date()
        )
        self.liveStatus = status

        // A logged-in status means we're no longer stranded signed-out. This
        // catches a re-auth that completes outside the switch poll loop (e.g.
        // the user finished OAuth after the timeout, then the sheet's .task
        // refreshed status).
        if status.loggedIn {
            self.isSignedOutOfEverything = false
        }

        // Auto-import: if the live account isn't in our state yet, register
        // it under a derived id (the orgId, or a hash of email). Lets the
        // Resume sheet show real accounts on first run without forcing a
        // setup step.
        if let orgId = status.orgId, !orgId.isEmpty {
            let derivedId = orgId
            if !state.accounts.contains(where: { $0.id == derivedId }) {
                state.accounts.append(ClaudeAuthAccount(
                    id: derivedId,
                    label: status.email ?? status.orgName ?? "Account \(state.accounts.count + 1)",
                    email: status.email,
                    orgId: orgId,
                    addedAt: Date()
                ))
            }
            // Keep activeAccountId in sync with what the CLI says.
            if state.activeAccountId != derivedId {
                state.activeAccountId = derivedId
            }
            save()
        }
    }

    // Called by AgentService the moment a worker is classified as
    // .pausedForAuth. Stamps the limit-hit time on the currently-active
    // account so the Resume sheet can hint at "this account is rate-limited
    // until ~Mon" if the user opens it later.
    func recordLimitHitOnActiveAccount() {
        guard let activeId = state.activeAccountId else { return }
        var info = state.perAccount[activeId] ?? PerAccountInfo()
        info.lastLimitHitAt = Date()
        // Anthropic's monthly limit rolls on a calendar window - best-effort
        // estimate is +30 days. Used as a UI hint, never as the gating signal.
        info.estimatedResetAt = Calendar.current.date(byAdding: .day, value: 30, to: Date())
        state.perAccount[activeId] = info
        save()
    }

    // MARK: - Account label management

    func renameAccount(id: String, to label: String) {
        if let idx = state.accounts.firstIndex(where: { $0.id == id }) {
            state.accounts[idx].label = label
            save()
        }
    }

    // MARK: - The switch
    //
    // Returns when the active account, as reported by `claude auth status --json`,
    // matches the target's orgId (or the timeout elapses). The caller (Resume
    // sheet) is expected to keep its UI alive and let the user finish OAuth
    // in the browser the Terminal window pops open.
    func switchToAccount(id targetId: String, timeoutSec: TimeInterval = 300) async -> SwitchResult {
        guard let target = state.accounts.first(where: { $0.id == targetId }) else {
            return .failed("unknown account id: \(targetId)")
        }

        // Already the active one? Done.
        if let live = liveStatus, live.orgId == target.orgId {
            return .alreadyActive
        }

        // Step 1: log out the current account (non-interactive).
        let logoutResult = await Self.runClaude(args: ["auth", "logout"])
        if logoutResult.exitCode != 0 {
            return .failed("claude auth logout failed: \(logoutResult.stderr.prefix(200))")
        }

        // Step 2: open Terminal.app with the login command. Not silent - the
        // OAuth flow opens a browser tab. A label-friendly --email hint pre-
        // populates the Anthropic login form.
        let emailArg: String
        if let e = target.email, !e.isEmpty {
            emailArg = " --email \(Self.shellQuote(e))"
        } else {
            emailArg = ""
        }
        let cmd = "claude auth login --claudeai\(emailArg)"
        lastLoginCommand = cmd
        // We just logged out the working account; until a new login lands the
        // user is signed out of everything. The poll below clears this the
        // moment a logged-in status is observed.
        isSignedOutOfEverything = true
        Self.openTerminalRunning(command: cmd)

        // Step 3: poll status until the active orgId matches the target's
        // (or, if target.orgId is unknown, until any change from the current
        // active account is seen).
        let deadline = Date().addingTimeInterval(timeoutSec)
        let priorOrgId = liveStatus?.orgId
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshActiveStatus()
            guard let live = liveStatus, live.loggedIn else { continue }
            isSignedOutOfEverything = false
            if let want = target.orgId, !want.isEmpty {
                if live.orgId == want {
                    state.activeAccountId = targetId
                    save()
                    return .switched
                }
            } else {
                // No known orgId for the target - accept any change from the
                // prior active orgId as success and bind it now.
                if live.orgId != priorOrgId {
                    if let idx = state.accounts.firstIndex(where: { $0.id == targetId }) {
                        state.accounts[idx].orgId = live.orgId
                        state.accounts[idx].email = state.accounts[idx].email ?? live.email
                    }
                    state.activeAccountId = targetId
                    save()
                    return .switched
                }
            }
        }
        return .failed("timeout - finish `\(cmd)` in the Terminal window then retry")
    }

    // Re-open the login Terminal from the LAST switch attempt WITHOUT logging
    // out again. The timeout error leaves the prior account already logged out;
    // re-running logout here would be redundant and could fight an in-progress
    // browser OAuth. The Resume sheet calls this from a "Re-open login
    // Terminal" button so the user who closed the window can resume the flow.
    func reopenLoginTerminal() {
        let cmd = Self.reopenCommand(lastLoginCommand: lastLoginCommand)
        isSignedOutOfEverything = true
        Self.openTerminalRunning(command: cmd)
    }

    // Pure derivation of the command reopenLoginTerminal runs: the recorded
    // login command from the last switch, or the bare claudeai login as a
    // fallback when no switch has been attempted this session.
    nonisolated static func reopenCommand(lastLoginCommand: String?) -> String {
        lastLoginCommand ?? "claude auth login --claudeai"
    }

    // MARK: - Process helpers

    struct ClaudeRunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// The agent CLI on this Mac, or nil when there is not one.
    ///
    /// SPLIT OUT FROM `resolveClaudeBinary` BECAUSE THE FALLBACK WAS BEING READ AS AN
    /// ANSWER. That function ends `return "claude"`, a bare name for a shell to look up on
    /// PATH, which is right for spawning and wrong for asking. Two call sites asked:
    /// `TerminalSessionsSettingsView` rendered `resolvedBinary.isEmpty ? "not found" : ...`
    /// and gated its whole explanatory caption on the same test, so on a Mac with no agent
    /// CLI the pane printed `claude` in a monospaced field and the sentence saying it was
    /// missing could never render. The empty string it tested for is unreachable.
    ///
    /// Anything asking "is one installed" calls this. Anything about to spawn keeps calling
    /// `resolveClaudeBinary`, whose fallback is deliberate: PATH may still resolve it in a
    /// login shell even when none of the fixed locations match.
    static func locateClaudeBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BIN"], !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let home = NSHomeDirectory()
        for c in [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ] where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    static func resolveClaudeBinary() -> String {
        locateClaudeBinary() ?? "claude"
    }

    private static func runClaude(args: [String]) async -> ClaudeRunResult {
        // Resolve binary on the calling actor so the detached Task doesn't have
        // to cross actor isolation boundaries to reach the @MainActor-isolated
        // resolveClaudeBinary().
        let bin = await MainActor.run { AccountSwitcher.resolveClaudeBinary() }
        return await Task.detached(priority: .userInitiated) { () -> ClaudeRunResult in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin.contains("/") ? bin : "/usr/bin/env")
            proc.arguments = bin.contains("/") ? args : (["claude"] + args)
            // Match SwarmWorker's env-strip posture so this introspection
            // call can never accidentally route through API billing instead
            // of OAuth - `auth status` would happily report the API-key
            // identity if one is present in the env.
            var env = ProcessInfo.processInfo.environment
            for k in [
                "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_TOKEN",
                "CLAUDE_API_KEY", "CLAUDE_AUTH_TOKEN", "ANTHROPIC_AUTH_HEADER",
                "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_URL",
                "ANTHROPIC_BEDROCK_API_KEY", "ANTHROPIC_VERTEX_PROJECT_ID",
                "ANTHROPIC_VERTEX_REGION", "CLAUDE_CODE_USE_BEDROCK",
                "CLAUDE_CODE_USE_VERTEX", "CLAUDECODE", "CLAUDE_CODE",
                "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
                "CLAUDE_CODE_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"
            ] { env.removeValue(forKey: k) }
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                return ClaudeRunResult(exitCode: -1, stdout: "", stderr: "spawn: \(error.localizedDescription)")
            }
            proc.waitUntilExit()
            let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ClaudeRunResult(exitCode: proc.terminationStatus, stdout: outStr, stderr: errStr)
        }.value
    }

    private static func openTerminalRunning(command: String) {
        // AppleScript: open Terminal.app, run the command in a new window.
        // We don't capture the result; the user finishes interactively.
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        // Minimal POSIX-safe single-quote wrapping for shell args.
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    enum SwitchResult: Sendable, Equatable {
        case switched
        case alreadyActive
        case failed(String)
    }
}

// MARK: - Persistence types

struct ClaudeAuthAccount: Codable, Hashable, Identifiable {
    var id: String                  // canonical: orgId, falls back to UUID for unbound entries
    var label: String               // user-editable display name
    var email: String?
    var orgId: String?
    var addedAt: Date
}

struct PerAccountInfo: Codable, Hashable {
    var lastLimitHitAt: Date?
    var estimatedResetAt: Date?
}

struct AuthState: Codable {
    var version: Int = 1
    var accounts: [ClaudeAuthAccount] = []
    var activeAccountId: String?
    var perAccount: [String: PerAccountInfo] = [:]
}

extension AccountSwitcher {
    struct LiveStatus: Equatable {
        let loggedIn: Bool
        let authMethod: String?
        let email: String?
        let orgId: String?
        let orgName: String?
        let subscriptionType: String?
        let checkedAt: Date
    }
}
