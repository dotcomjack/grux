import Foundation
import GruxShellCore

// MARK: - Safety boundary
//
// Grux is NOT sandboxed (see `Grux.entitlements` - `com.apple.security.app-sandbox=false`)
// because it needs ScreenCaptureKit, AppleEvents, and microphone access. macOS therefore
// grants this process full user-level filesystem reach - no path allowlisting at the OS
// layer. The enforcement boundary is THIS file.
//
// `fs_read` and `fs_list` are ONE of the two routes Claude has to the user's disk, and the
// strict one. Everything here - the allowlist, the denylist, the secret-content scan, the
// rate limiter, the audit log - is a real perimeter: a denied path never reaches `open(2)`.
// If this file is wrong, the model can be talked into leaking secrets or reading arbitrary
// user data.
//
// The OTHER route is `shell_run`, and this comment used to deny it existed. `ShellSafety.swift`
// gates `cd` escapes, outside-root WRITES and network-reaching commands, and nothing else: it
// allows reads outside the session root on purpose, because a build that cannot read
// `/opt/homebrew` is not a build. So `shell_run "cat ~/.ssh/id_rsa"` succeeds while the
// identical `fs_read` is refused and audit-logged. Do not restore the stronger claim. It read
// as reassuring for months precisely because it was confident, and a reader who believes this
// file is the whole perimeter stops looking at the one that is weaker.
//
// See `SECURITY.md` (sibling doc) section 2 for the two-door invariant and section 5 for the
// denylist, which `Tests/GruxTests/DenylistParityTests.swift` holds equal to the lists below.

enum FilesystemTool {
    static func claudeTools() -> [ClaudeTool] {
        let desc = """
        This tool reads the user's local files, restricted to the folder they chose for Grux in Settings \
        (plus Grux's own exported documents). Paths must be absolute. Until they choose a folder, nothing \
        outside those documents is readable and every other path is refused. \
        Secrets, hidden dotfiles like .env/.ssh/.aws are blocked. Max 1MB per file, 10 reads per minute.
        """
        return [
            ClaudeTool(
                name: "fs_read",
                description: "Read a UTF-8 text file by absolute path. " + desc,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Absolute POSIX path to the file. Must resolve inside an allowed root."
                        ]
                    ],
                    "required": ["path"]
                ]
            ),
            ClaudeTool(
                name: "fs_list",
                description: "List the immediate children of a directory by absolute path. " + desc,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Absolute POSIX path to the directory. Must resolve inside an allowed root."
                        ]
                    ],
                    "required": ["path"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        let rawPath = (input["path"] as? String) ?? ""
        switch name {
        case "fs_read":
            return await performRead(requestedPath: rawPath)
        case "fs_list":
            return await performList(requestedPath: rawPath)
        default:
            return "error: unknown fs tool '\(name)'"
        }
    }

    // MARK: - Configuration

    private static let maxBytes = 1_048_576
    private static let rateLimitPerMinute = 10
    private static let binaryProbeBytes = 8192
    private static let maxListEntries = 200

    // Allowed roots. Any requested absolute path, after symlink + `..` resolution,
    // MUST still be prefixed by one of these. Re-checked post-resolution.
    //
    // The project side comes from ShellAllowlist, which reads the folder the
    // user chose in Settings and is empty until they choose one. Sharing that
    // one list is what keeps the read surface and the shell surface identical
    // instead of two copies drifting apart.
    private static func allowedRoots() -> [String] {
        // Document library (item 11/12): lets fs tools reach exported markdown
        // and filled PDF copies written by DocumentStore. Grux's own container,
        // so it needs no permission from the user and is always present.
        let documents = NSHomeDirectory() + "/Library/Application Support/Grux/documents"
        return (ShellAllowlist.allowedRoots() + [documents]).map { standardize($0) }
    }

    // Denylist segments. Reject if ANY path component (basename-level) matches.
    //
    // Entries are stored LOWERCASE and every comparison lowercases the candidate
    // first. That is load-bearing, not tidiness. Before it, this was an
    // exact-case `Set.contains` running against a filesystem that macOS formats
    // case-INSENSITIVE by default, so the entry `firefox` could never match the
    // directory the browser actually creates, `Library/Application Support/Firefox`.
    // That rule was dead from the day it was written and nothing said so: a
    // denylist entry that cannot fire looks exactly like one that never had to.
    // The same trap sat one keystroke away from `Safari`, `Chrome` and `Keychains`,
    // and a user who types `~/Documents/.SSH/id_rsa` walked through the front door.
    // `DenylistParityTests` fails if an entry is ever added with a capital in it.
    //
    // Single components only. Anything spanning a `/` belongs in the substring
    // list below, and the reason is in that comment.
    static let denylistSegments: Set<String> = [
        ".ssh", ".aws", ".claude", ".anthropic", ".cursor",
        ".gnupg", ".docker", ".kube",
        "keychains", "cookies", "messages", "mail",
        "safari", "chrome", "firefox", "arc", "bravesoftware"
    ]

    // Denylist path FRAGMENTS, matched case-insensitively against the whole
    // resolved path. Two kinds of entry live here, and both are here because a
    // single path component cannot express them.
    //
    // `node_modules/@anthropic-ai` lives as a nested segment inside deps trees.
    //
    // The rest span a directory boundary, and collapsing them into the segment
    // set above would be a usability regression dressed up as a security win.
    // `.config/gcloud` reduced to `.config` blocks every dotfile a developer
    // keeps under `~/.config`, editor config, shell config, git config, to
    // protect one credential directory. `Library/Containers` reduced to
    // `Library` blocks most of a Mac. A denylist people switch off protects
    // nothing, so the multi-segment entries stay multi-segment.
    static let denylistSubstrings: [String] = [
        "node_modules/@anthropic-ai",
        ".config/gcloud",
        "library/containers",
        "library/group containers"
    ]

    // Exact filenames, compared case-insensitively against the last path
    // component. Stored lowercase, same contract as the segment set.
    static let denylistBasenames: Set<String> = [
        ".env", ".envrc", ".netrc", ".pgpass",
        "credentials", "credentials.json",
        "id_rsa", "id_ed25519", "id_ecdsa",
        "known_hosts", "authorized_keys"
    ]

    // Key, cert and keystore extensions, compared case-insensitively against the
    // suffix of the last path component. Stored lowercase, leading dot included.
    //
    // `.keychain` does not cover `.keychain-db`: `"login.keychain-db"` does not
    // end in `".keychain"`, so both spellings are listed rather than assumed.
    static let denylistExtensions: [String] = [
        ".pem", ".p12", ".key", ".keystore", ".pfx", ".keychain", ".keychain-db"
    ]

    // Secret regex table - tagged for the audit log; content matching any of
    // these is suppressed (file read returns a blocked-error, never raw bytes).
    private static let secretPatterns: [(tag: String, regex: NSRegularExpression)] = {
        let raw: [(String, String)] = [
            ("ANTHROPIC_KEY", #"sk-ant-[A-Za-z0-9_\-]{10,}"#),
            ("ELEVENLABS_KEY", #"sk_[a-f0-9]{48,}"#),
            ("AWS_KEY", #"AKIA[0-9A-Z]{16}"#),
            ("PEM", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
            ("GITHUB_PAT", #"ghp_[A-Za-z0-9]{30,}"#),
            ("GITHUB_FINE_GRAINED", #"github_pat_[A-Za-z0-9_]{20,}"#),
            ("SLACK_TOKEN", #"xox[baprs]-[A-Za-z0-9\-]{20,}"#)
        ]
        return raw.compactMap { pair in
            (try? NSRegularExpression(pattern: pair.1, options: [])).map { (pair.0, $0) }
        }
    }()

    // MARK: - Read

    private static func performRead(requestedPath: String) async -> String {
        let requested = requestedPath
        guard !requested.isEmpty else {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: "", resolved: "", outcome: "denied_allowlist", bytes: 0, reason: "empty path")
            return "error: path required"
        }

        let resolved = resolve(requested)

        if let (allowed, reason) = await checkRate() {
            if !allowed {
                await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_rate", bytes: 0, reason: reason)
                return "error: rate_limit: \(rateLimitPerMinute) reads/min exceeded; retry in \(reason)s"
            }
        }

        if !isInsideAllowedRoot(resolved) {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_allowlist", bytes: 0, reason: "outside allowlist")
            return "error: path is outside the folder Grux may read; the user picks that folder in Settings"
        }
        if let hit = denyHit(resolved) {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_denylist", bytes: 0, reason: hit)
            return "error: path blocked by denylist (\(hit))"
        }
        if let hit = denyBasename(resolved) {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_denylist", bytes: 0, reason: hit)
            return "error: filename blocked (\(hit))"
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_missing", bytes: 0, reason: "not found")
            return "error: file not found"
        }
        if isDir.boolValue {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_missing", bytes: 0, reason: "is a directory")
            return "error: path is a directory; use fs_list"
        }

        // Size cap (pre-read; saves loading a giant file into RAM).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
           let size = attrs[.size] as? Int, size > maxBytes {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_size", bytes: size, reason: "over 1MB")
            return "error: file too large (\(size) bytes, max \(maxBytes))"
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_missing", bytes: 0, reason: "read failed")
            return "error: could not read file"
        }

        // Binary probe on first 8KB (NUL byte → treat as binary).
        let probe = data.prefix(binaryProbeBytes)
        if probe.contains(0) {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_binary", bytes: data.count, reason: "NUL byte in probe")
            return "error: binary file not supported"
        }

        guard let content = String(data: data, encoding: .utf8) else {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_binary", bytes: data.count, reason: "non-UTF-8")
            return "error: binary or non-UTF-8"
        }

        if let tag = containsSecret(content) {
            await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "denied_secret", bytes: data.count, reason: tag)
            return "error: file content blocked - potential secret detected"
        }

        await FilesystemToolState.shared.audit(tool: "fs_read", path: requested, resolved: resolved, outcome: "ok", bytes: data.count, reason: "")
        return content
    }

    // MARK: - List

    private static func performList(requestedPath: String) async -> String {
        let requested = requestedPath
        guard !requested.isEmpty else {
            await FilesystemToolState.shared.audit(tool: "fs_list", path: "", resolved: "", outcome: "denied_allowlist", bytes: 0, reason: "empty path")
            return "error: path required"
        }

        let resolved = resolve(requested)

        if let (allowed, reason) = await checkRate() {
            if !allowed {
                await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "denied_rate", bytes: 0, reason: reason)
                return "error: rate_limit: \(rateLimitPerMinute) reads/min exceeded; retry in \(reason)s"
            }
        }

        if !isInsideAllowedRoot(resolved) {
            await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "denied_allowlist", bytes: 0, reason: "outside allowlist")
            return "error: path is outside the folder Grux may read; the user picks that folder in Settings"
        }
        if let hit = denyHit(resolved) {
            await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "denied_denylist", bytes: 0, reason: hit)
            return "error: path blocked by denylist (\(hit))"
        }
        if let hit = denyBasename(resolved) {
            await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "denied_denylist", bytes: 0, reason: hit)
            return "error: filename blocked (\(hit))"
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "denied_missing", bytes: 0, reason: "not found")
            return "error: path not found"
        }
        if !isDir.boolValue {
            await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "denied_missing", bytes: 0, reason: "not a directory")
            return "error: path is not a directory"
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: resolved) else {
            await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "denied_missing", bytes: 0, reason: "list failed")
            return "error: could not list directory"
        }

        var lines: [String] = []
        lines.reserveCapacity(min(entries.count, maxListEntries))
        let sorted = entries.sorted()
        for name in sorted {
            if lines.count >= maxListEntries { break }
            // Skip entries whose basename matches the denylist - Claude shouldn't even
            // see them in a listing; less to prompt-inject against.
            if denylistSegments.contains(name.lowercased()) { continue }
            if matchesDeniedBasename(name) { continue }
            let full = (resolved as NSString).appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &childIsDir)
            let prefix = childIsDir.boolValue ? "DIR " : "FILE "
            lines.append(prefix + name)
        }

        await FilesystemToolState.shared.audit(tool: "fs_list", path: requested, resolved: resolved, outcome: "ok", bytes: lines.count, reason: "")
        if lines.isEmpty { return "(empty directory)" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rate limiting

    // Returns (allowed, retryInSeconds). `nil` means "no decision to log" (we're always
    // returning one here, but the Optional shape lets callers short-circuit).
    private static func checkRate() async -> (Bool, String)? {
        let (allowed, retryIn) = await FilesystemToolState.shared.admitCall()
        if allowed { return (true, "0") }
        return (false, "\(retryIn)")
    }

    // MARK: - Path handling

    private static func standardize(_ p: String) -> String {
        // `standardizingPath` collapses `..` + `.` components; `resolvingSymlinksInPath`
        // follows symlinks. Both are needed before we re-check the allowlist prefix,
        // or an attacker-controlled symlink inside an allowed root could point to
        // something outside it.
        let standardized = (p as NSString).standardizingPath
        let resolvedURL = URL(fileURLWithPath: standardized).resolvingSymlinksInPath()
        return resolvedURL.path
    }

    private static func resolve(_ requested: String) -> String {
        // Support `~` expansion even though we tell Claude absolute-only - cheap
        // defense, normalizes either form.
        let expanded = (requested as NSString).expandingTildeInPath
        return standardize(expanded)
    }

    private static func isInsideAllowedRoot(_ resolved: String) -> Bool {
        for root in allowedRoots() {
            if resolved == root { return true }
            if resolved.hasPrefix(root + "/") { return true }
        }
        return false
    }

    // Internal rather than private so `DenylistParityTests` can drive the real
    // check with `.SSH` and `Firefox` instead of re-implementing it. A parity
    // test that owns its own copy of the comparison is testing the copy.
    static func denyHit(_ resolved: String) -> String? {
        let lowerPath = resolved.lowercased()
        let comps = (resolved as NSString).pathComponents
        for c in comps where denylistSegments.contains(c.lowercased()) {
            return c
        }
        for sub in denylistSubstrings where lowerPath.contains(sub) {
            return sub
        }
        return nil
    }

    static func denyBasename(_ resolved: String) -> String? {
        let base = (resolved as NSString).lastPathComponent
        if matchesDeniedBasename(base) { return base }
        return nil
    }

    static func matchesDeniedBasename(_ base: String) -> Bool {
        let lower = base.lowercased()
        // Exact names: `.env`, `credentials`, `id_rsa`, `known_hosts` and friends.
        //
        // Lowercasing the candidate is the whole fix for `.ENV`. The old version
        // compared `base == ".env"` against the raw string and only lowercased
        // for the extension loop below, so a file literally named `.ENV` (or
        // `Credentials`, or `ID_RSA`, all of which open fine on a default macOS
        // volume) sailed past the name check and then past the extension check
        // too, because it has no extension to match.
        if denylistBasenames.contains(lower) { return true }
        // `.env.local`, `.env.production`, and every other suffixed variant.
        //
        // `.envrc` is NOT one of these and is listed as its own exact name
        // above, because it matches neither `.env` nor the `.env.` prefix. That
        // gap mattered more than the rest of this function: `.envrc` is direnv's
        // file, and direnv's normal use is a list of `export AWS_SECRET_...`
        // lines, so the one dotfile most likely to hold live cloud credentials
        // was the one this check walked straight past.
        if lower.hasPrefix(".env.") { return true }
        // Key, cert and keystore extensions.
        for ext in denylistExtensions where lower.hasSuffix(ext) { return true }
        return false
    }

    // MARK: - Secret content scan

    private static func containsSecret(_ s: String) -> String? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        for (tag, regex) in secretPatterns {
            if regex.firstMatch(in: s, options: [], range: range) != nil {
                return tag
            }
        }
        return nil
    }
}

// Actor that owns the rate-limit sliding window and serializes audit-log writes.
// Rate limit is a shared bucket across fs_read + fs_list (10/min combined).
actor FilesystemToolState {
    static let shared = FilesystemToolState()

    private var callTimestamps: [Date] = []
    private let windowSeconds: TimeInterval = 60
    private let limit: Int = 10

    private lazy var logURL: URL? = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base = appSupport else { return nil }
        let dir = base.appendingPathComponent("Grux", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("fs-audit.log")
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Admit (true, 0) or reject (false, retryInSeconds). Only counts admitted calls.
    func admitCall() -> (Bool, Int) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        callTimestamps.removeAll { $0 < cutoff }
        if callTimestamps.count >= limit {
            // Retry-in is time until the oldest kept timestamp ages out.
            let oldest = callTimestamps.first ?? now
            let retryIn = Int(ceil(windowSeconds - now.timeIntervalSince(oldest)))
            return (false, max(1, retryIn))
        }
        callTimestamps.append(now)
        return (true, 0)
    }

    func audit(tool: String, path: String, resolved: String, outcome: String, bytes: Int, reason: String) {
        guard let url = logURL else { return }
        let record: [String: Any] = [
            "ts": isoFormatter.string(from: Date()),
            "tool": tool,
            "path": path,
            "resolved": resolved,
            "outcome": outcome,
            "bytes": bytes,
            "reason": reason
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A) // newline

        // O_APPEND, one write(2), and no seek anywhere.
        //
        // This used to open a `FileHandle`, call `seekToEnd()` and then
        // `write(contentsOf:)`. Those are two separate syscalls, so two writers
        // can both resolve the same end offset and the second overwrites the
        // first: the losing line is not corrupted, it is GONE, which is the
        // worst failure mode an audit log has. That was safe while this actor
        // was the only writer, and it stopped being safe on 2026-08-26, when
        // `ShellAuditLog` in `Sources/GruxShellCore/ShellOutputGuard.swift`
        // began appending one line per shell command to this same file. It
        // writes from another module, so this actor serializes nothing about
        // it, and no lock is shared between them.
        //
        // `O_APPEND` moves the seek into the kernel and makes it atomic with
        // respect to other appenders on the descriptor, which is the single
        // property that makes two independent writers safe here. The shell-side
        // writer already opens exactly this way and named this gap in its own
        // comment so it would not be inherited silently.
        //
        // 0o600 on creation, matching that writer. The log names every path the
        // model was pointed at, which is a map of the user's machine, and the
        // default 0o644 publishes that map to every other account on a shared
        // Mac. The mode is ignored when the file already exists, so an install
        // that predates this line keeps whatever permissions it had.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = write(fd, base, raw.count)
        }
    }
}
