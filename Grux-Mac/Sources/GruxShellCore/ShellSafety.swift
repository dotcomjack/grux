import Foundation

// MARK: - ShellSafety
//
// The safety gate that sits in front of every command. Its job is to decide
// BEFORE a command runs:
//
//   1. Will this escape the session's rootDir? (containment - every mode)
//   2. Does it hit the outside world in a way we can't undo? (network gate -
//      guarded + strict)
//   3. Is it on the allowlist? (strict mode only)
//   4. Does it look destructive enough to warrant an extra mid-turn snapshot?
//      (hybrid undo mode)
//
// The guards are deliberately TEXT-LEVEL - we inspect the command string the
// model intends to send to the shell, before we pipe it into the PTY. Once the
// PTY has it, too late to intervene cleanly. Text-level guards can be defeated
// by sufficiently adversarial shell tricks (eval / printf escapes / subshell
// chaining). That's why trust mode is paired with shadow-git snapshots - the
// kernel boundary of "you can undo it" is the real defense, the text guards
// are convenience + clear error messages.

public enum ShellGateDecision: Equatable {
    case allow
    case blockedOutsideRoot(reason: String)
    case blockedStrictAllowlist(reason: String)
    case requiresConfirm(reason: String)  // network-reaching; guarded/strict pause for user
}

public struct ShellSafetyVerdict {
    public let decision: ShellGateDecision
    public let looksDestructive: Bool     // used by hybrid undo to insert an extra snapshot
    public let detectedCdTarget: String?  // if the command is a `cd <target>`, normalized target
}

public enum ShellSafety {

    // MARK: - Containment
    //
    // cwd lock: every command runs with the PTY's current cwd. We pre-scan for
    // two escape patterns:
    //   (a) `cd <dir>` / `cd` / `pushd <dir>` - if the resolved target lands
    //       outside rootDir, reject. (Plain `cd` with no arg goes to $HOME - also
    //       rejected unless $HOME is inside rootDir, which it won't be.)
    //   (b) absolute path references that would write outside rootDir.
    //       We only flag WRITE patterns (> >> | tee, rm, mv dst, cp dst, etc.)
    //       since reads outside rootDir are fine (npm needs to read /opt/homebrew).
    //
    // Absolute-path scanning is intentionally conservative: we whitelist reads
    // and only catch the common write-outside-root footguns. A sophisticated
    // prompt-injection can still construct an outside-root write that slips
    // past - the snapshot is the backstop.

    static func evaluate(command raw: String, rootDir: String, currentCwd: String, mode: ShellMode) -> ShellSafetyVerdict {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ShellSafetyVerdict(decision: .allow, looksDestructive: false, detectedCdTarget: nil)
        }

        // Strict mode: command allowlist first. Only accept binaries from the
        // curated list. The check is deliberately naive - first token compared
        // against the list. Pipes / && chains with disallowed binaries are
        // refused because the FIRST binary in the chain rules.
        if mode == .strict {
            if let reason = strictAllowlistBlock(command: trimmed) {
                return ShellSafetyVerdict(
                    decision: .blockedStrictAllowlist(reason: reason),
                    looksDestructive: false,
                    detectedCdTarget: nil
                )
            }
        }

        // Containment: cd / pushd escape detection.
        if let cdTarget = detectCdTarget(command: trimmed) {
            let resolved = resolveRelative(target: cdTarget, cwd: currentCwd)
            if !pathIsInside(resolved, root: rootDir) {
                return ShellSafetyVerdict(
                    decision: .blockedOutsideRoot(reason: "cd would leave rootDir (target: \(resolved))"),
                    looksDestructive: false,
                    detectedCdTarget: resolved
                )
            }
            return ShellSafetyVerdict(decision: .allow, looksDestructive: false, detectedCdTarget: resolved)
        }

        // Containment: absolute-path write outside rootDir.
        if let absPath = detectOutsideRootWrite(command: trimmed, rootDir: rootDir) {
            return ShellSafetyVerdict(
                decision: .blockedOutsideRoot(reason: "command writes to '\(absPath)' which is outside rootDir"),
                looksDestructive: true,
                detectedCdTarget: nil
            )
        }

        // Network / external-effect gate for guarded + strict.
        if mode != .trust, let reason = detectNetworkOrExternalEffect(command: trimmed) {
            return ShellSafetyVerdict(
                decision: .requiresConfirm(reason: reason),
                looksDestructive: false,
                detectedCdTarget: nil
            )
        }

        let destructive = looksDestructive(command: trimmed)
        return ShellSafetyVerdict(decision: .allow, looksDestructive: destructive, detectedCdTarget: nil)
    }

    // MARK: - CD detection

    static func detectCdTarget(command: String) -> String? {
        // Match `cd`, `cd <target>`, `pushd <target>`, `cd ~` etc., but only as the
        // leading statement or immediately after `;` / `&&` / `||`. Piping into cd
        // doesn't make sense; chaining does.
        let segments = splitStatements(command)
        for seg in segments {
            let s = seg.trimmingCharacters(in: .whitespaces)
            if s == "cd" { return NSHomeDirectory() }
            if s.hasPrefix("cd ") {
                let target = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                return stripQuotes(target)
            }
            if s.hasPrefix("pushd ") {
                let target = String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                return stripQuotes(target)
            }
        }
        return nil
    }

    // MARK: - Outside-root write detection

    // Conservative heuristic: look for absolute paths that the command tries to
    // WRITE. Catches `rm -rf /etc/*`, `> /tmp/foo`, `tee /some/path`, `mv x /usr/…`.
    // Misses: $(printf '/tmp/x'), heredocs, shell expansion - those are on the snapshot.
    static func detectOutsideRootWrite(command: String, rootDir: String) -> String? {
        let writePrefixes = [
            "rm ", "rm -", "rmdir ",
            "mv ", "cp ",       // destination argument - best-effort: flag any abs path
            "tee ", "> /", ">> /",
        ]
        let tokens = tokenize(command)
        let rootStd = ShellAllowlist.standardize(rootDir)
        for tok in tokens {
            // Only consider absolute paths. Relative paths are fine (PTY cwd is inside rootDir).
            guard tok.hasPrefix("/") else { continue }
            let std = ShellAllowlist.standardize(tok)
            if !std.hasPrefix(rootStd + "/") && std != rootStd {
                // Absolute path outside rootDir. If the command looks like a write, block.
                for pref in writePrefixes where command.contains(pref) {
                    return std
                }
            }
        }
        return nil
    }

    // MARK: - Network / external-effect gate

    // Catches the "command reaches outside the filesystem" footguns that snapshots
    // cannot undo. User confirmation required in guarded + strict. Public so the
    // app-side Touch ID gate (ShellTool) can classify trust-mode commands too.
    public static func detectNetworkOrExternalEffect(command: String) -> String? {
        let lc = command.lowercased()
        // git push - any form
        if lc.contains("git push") { return "git push reaches the remote; snapshots can't undo a push" }
        // force push extra flag
        if lc.contains("--force") || lc.contains(" -f ") {
            if lc.contains("git") { return "git --force operation is destructive on the remote" }
        }
        // destructive remote ops
        if lc.contains("git branch -d") || lc.contains("git branch -d") { return "branch deletion" }
        // curl with destructive verbs or pipe-to-shell
        if lc.range(of: #"curl[^|]*-x\s+(post|put|delete|patch)"#, options: .regularExpression) != nil {
            return "curl with destructive HTTP verb"
        }
        if lc.range(of: #"curl[^|]*\|\s*(ba)?sh"#, options: .regularExpression) != nil {
            return "curl pipe to shell (remote code execution)"
        }
        // wget similar
        if lc.range(of: #"wget[^|]*\|\s*(ba)?sh"#, options: .regularExpression) != nil {
            return "wget pipe to shell"
        }
        // deploy CLIs that hit prod
        let deployCLIs = ["render deploy", "render api", "gh pr merge", "gh release create",
                          "stripe ", "vercel deploy", "vercel --prod", "flyctl deploy",
                          "netlify deploy --prod", "firebase deploy", "supabase db push",
                          "wrangler deploy", "eas submit", "fastlane deliver", "pod trunk push"]
        for kw in deployCLIs where lc.contains(kw) {
            return "deploy / external effect: '\(kw.trimmingCharacters(in: .whitespaces))'"
        }
        // npm publish, cargo publish
        if lc.contains("npm publish") { return "npm publish - snapshots can't un-publish" }
        if lc.contains("cargo publish") { return "cargo publish - snapshots can't un-publish" }
        // sudo
        if lc.hasPrefix("sudo ") || lc.contains(" sudo ") {
            return "sudo - operates outside rootDir and the snapshot scope"
        }
        return nil
    }

    // MARK: - Destructive heuristic (triggers hybrid snapshot)

    static func looksDestructive(command: String) -> Bool {
        let lc = command.lowercased()
        let hits = ["rm ", "rm -", "rmdir ", "git reset --hard", "git checkout .",
                    "git clean -f", "truncate ", "dd if=", "> ", ">|", "mv ",
                    "drop table", "drop database", "npm uninstall", "yarn remove",
                    "cargo rm"]
        return hits.contains(where: { lc.contains($0) })
    }

    // MARK: - Strict-mode allowlist

    // Only these binaries can run in strict mode. Deliberately short; add on demand.
    private static let strictAllowed: Set<String> = [
        "ls", "cat", "echo", "pwd", "head", "tail", "grep", "rg", "find", "file",
        "wc", "sort", "uniq", "diff", "tree", "stat",
        "node", "npm", "npx", "yarn", "pnpm", "deno", "bun",
        "python", "python3", "pip", "pip3", "poetry", "uv",
        "cargo", "rustc", "go", "swift", "xcodebuild",
        "git", "make", "cmake",
        "true", "false"
    ]

    static func strictAllowlistBlock(command: String) -> String? {
        let tokens = tokenize(command)
        guard let first = tokens.first else { return nil }
        // strip leading env assignments: VAR=val tool
        var idx = 0
        while idx < tokens.count, tokens[idx].contains("=") && !tokens[idx].hasPrefix("/") {
            idx += 1
        }
        let bin = idx < tokens.count ? tokens[idx] : first
        let base = (bin as NSString).lastPathComponent
        if !strictAllowed.contains(base) {
            return "strict mode: '\(base)' not on allowlist"
        }
        return nil
    }

    // MARK: - Parsing helpers (tiny subset - good enough for the gate)

    // Split on ; && || but ignore inside single/double quotes.
    static func splitStatements(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var chars = Array(s)
        var i = 0
        var inSingle = false
        var inDouble = false
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle(); current.append(c); i += 1; continue }
            if c == "\"" && !inSingle { inDouble.toggle(); current.append(c); i += 1; continue }
            if !inSingle && !inDouble {
                if c == ";" {
                    out.append(current); current = ""; i += 1; continue
                }
                if c == "&" && i + 1 < chars.count && chars[i+1] == "&" {
                    out.append(current); current = ""; i += 2; continue
                }
                if c == "|" && i + 1 < chars.count && chars[i+1] == "|" {
                    out.append(current); current = ""; i += 2; continue
                }
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // Whitespace-split with quote awareness. Good enough for the containment
    // checks; not a full POSIX shell tokenizer.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inSingle = false
        var inDouble = false
        for c in s {
            if c == "'" && !inDouble { inSingle.toggle(); continue }
            if c == "\"" && !inSingle { inDouble.toggle(); continue }
            if c.isWhitespace && !inSingle && !inDouble {
                if !cur.isEmpty { out.append(cur); cur = "" }
                continue
            }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func stripQuotes(_ s: String) -> String {
        var out = s
        if (out.hasPrefix("\"") && out.hasSuffix("\"")) || (out.hasPrefix("'") && out.hasSuffix("'")) {
            out.removeFirst()
            if !out.isEmpty { out.removeLast() }
        }
        return out
    }

    static func resolveRelative(target: String, cwd: String) -> String {
        if target.hasPrefix("/") { return ShellAllowlist.standardize(target) }
        if target == "~" { return ShellAllowlist.standardize(NSHomeDirectory()) }
        if target.hasPrefix("~/") {
            return ShellAllowlist.standardize(NSHomeDirectory() + "/" + String(target.dropFirst(2)))
        }
        return ShellAllowlist.standardize((cwd as NSString).appendingPathComponent(target))
    }

    static func pathIsInside(_ path: String, root: String) -> Bool {
        let p = ShellAllowlist.standardize(path)
        let r = ShellAllowlist.standardize(root)
        let rSep = r.hasSuffix("/") ? r : r + "/"
        return p == r || p.hasPrefix(rSep)
    }
}
