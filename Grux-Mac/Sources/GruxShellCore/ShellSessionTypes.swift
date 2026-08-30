import Foundation

// MARK: - Public value types
//
// These are the types Grux's ShellTool exposes to Claude (via JSON round-trip)
// and to the rest of the app. Kept in one file so the tool surface is easy to
// read in a single pass.

// The safety dial:
//   .trust   - snapshots on, nothing else. The user is at the keyboard.
//   .guarded - snapshots on + network-call confirm gate. Default.
//   .strict  - snapshots on + confirm gate + command allowlist. Used when
//              Grux is driven by untrusted inputs (Omi transcripts, web
//              summaries) where prompt-injection risk is real.
public enum ShellMode: String, Codable, Sendable {
    case trust
    case guarded
    case strict
}

// Undo granularity. Default hybrid. Downgradable to per-turn from settings.
public enum ShellUndoMode: String, Codable, Sendable {
    case perTurn              // one snapshot per user request, before any command runs
    case hybrid               // per-turn + extra snapshot before each destructive-looking command
}

// What a command looks like on the way back to Claude (and onto the mirror UI).
public struct ShellRunResult: Codable, Sendable {
    public let sessionId: String
    public let command: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMs: Int
    public let cwdAfter: String
    public let snapshotId: String?           // populated when a snapshot was taken for this run
    public let gated: Bool                    // true when the command was network-gated and awaiting confirm
    public let blocked: Bool                  // true when containment / allowlist refused the command
    public let blockedReason: String?
}

public struct ShellSessionInfo: Codable, Sendable {
    public let sessionId: String
    public let rootDir: String
    public let cwd: String
    public let mode: ShellMode
    public let undoMode: ShellUndoMode
    public let commandsRun: Int
    public let snapshotsTaken: Int
    public let mirrorActive: Bool
    public let startedAt: Date
}

public struct ShellSnapshotRecord: Codable, Sendable, Equatable {
    public let snapshotId: String
    public let commitSha: String              // shadow-git commit sha
    public let trigger: String                // "turn-start", "destructive-detect", "manual"
    public let createdAt: Date
    public let commandIndex: Int              // which command in the session triggered it
    public let label: String
}

// MARK: - Errors

public enum ShellToolError: Error, CustomStringConvertible, Sendable {
    case sessionNotFound(String)
    case rootOutsideAllowlist(String)
    case rootDoesNotExist(String)
    case rootNotDirectory(String)
    case snapshotFailed(String)
    case restoreFailed(String)
    case runtime(String)

    public var description: String {
        switch self {
        case .sessionNotFound(let id):       return "session '\(id)' not found (maybe already ended)"
        case .rootOutsideAllowlist(let p):   return "rootDir '\(p)' is outside the folder Grux may work in; choose that folder in Settings"
        case .rootDoesNotExist(let p):       return "rootDir '\(p)' does not exist"
        case .rootNotDirectory(let p):       return "rootDir '\(p)' is not a directory"
        case .snapshotFailed(let reason):    return "snapshot failed: \(reason)"
        case .restoreFailed(let reason):     return "restore failed: \(reason)"
        case .runtime(let msg):              return "shell runtime: \(msg)"
        }
    }
}

// MARK: - Allowlist

// The folders Grux may operate in. EMPTY until the user names one: a fresh
// install ships no guess about where anybody keeps their code, so nothing on
// the machine is reachable until a folder is chosen. With none chosen every
// session refuses to start and says why, which is the honest failure.
//
// FilesystemTool reads this same list, so whatever Claude can READ with fs_read
// it can ALSO spawn a session inside, and there is exactly one place to change
// it.
public enum ShellAllowlist {
    // The `endpoint.sandbox_root` config key from the setup contract, which is
    // what the Settings "Watched folder" control writes. Spelled out here
    // because GruxShellCore is platform-free and cannot see the app's
    // capability resolver; the contract owns the string on both sides.
    public static let watchedRootDefaultsKey = "grux.sandbox.watched_root"

    // One path or a list of paths: both shapes are accepted so a person can
    // hand Grux several project trees without a schema migration.
    public static func allowedRoots() -> [String] {
        let defaults = UserDefaults.standard
        var configured: [String] = []
        if let list = defaults.array(forKey: watchedRootDefaultsKey) as? [String] {
            configured = list
        } else if let single = defaults.string(forKey: watchedRootDefaultsKey) {
            configured = [single]
        }
        return configured
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { standardize($0) }
    }

    public static func isInsideAllowedRoot(_ path: String) -> Bool {
        let p = standardize(path)
        for root in allowedRoots() {
            // Prefix check with trailing separator so "/foo/barbaz" doesn't match root "/foo/bar".
            let rootSep = root.hasSuffix("/") ? root : root + "/"
            if p == root || p.hasPrefix(rootSep) { return true }
        }
        return false
    }

    public static func standardize(_ p: String) -> String {
        let std = (p as NSString).standardizingPath
        return URL(fileURLWithPath: std).resolvingSymlinksInPath().path
    }
}
