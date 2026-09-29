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

        let destructive = looksDestructive(command: trimmed, cwd: currentCwd)
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

    /// `cwd` is where the command runs, when the caller knows it: `sort -o`
    /// destroys something only when the file it writes is already there.
    public static func looksDestructive(command: String, cwd: String? = nil) -> Bool {
        let lc = command.lowercased()
        let hits = ["rm ", "rm -", "rmdir ", "git reset --hard", "git checkout .",
                    "git clean -f", "truncate ", "dd if=", "> ", ">|", "mv ",
                    "drop table", "drop database", "npm uninstall", "yarn remove",
                    "cargo rm"]
        if hits.contains(where: { lc.contains($0) }) { return true }
        return pipelineSegments(command).contains { destroysByArgument(tokenize($0), cwd: cwd) }
    }

    /// Commands a listed read-only binary turns into a delete or an overwrite
    /// with one argument, which no text pattern above can see. Keyless there
    /// is no provider opinion to raise them, so they belong on the floor
    /// (ledger A23b). Writing a NEW file is not on it: nothing is lost.
    static func destroysByArgument(_ tokens: [String], cwd: String?) -> Bool {
        let tokens = unwrapped(tokens)
        guard let first = tokens.first else { return false }
        let args = Array(tokens.dropFirst())
        switch (first as NSString).lastPathComponent {
        case "find":
            return args.contains("-delete")
        case "sort":
            guard let (target, at) = sortOutputTarget(args) else { return false }
            // Sorting a file onto itself: the operand named again after the flag.
            let inputs = args.enumerated().filter { $0.offset != at && !$0.element.hasPrefix("-") }
            if inputs.contains(where: { $0.element == target }) { return true }
            guard let cwd else { return false }
            return FileManager.default.fileExists(atPath: resolveRelative(target: target, cwd: cwd))
        case "git":
            let sub = gitSubcommand(args)
            guard sub.first == "branch" else { return false }
            let deleting: Set<String> = ["-d", "-D", "--delete", "-M", "-C"]
            return sub.dropFirst().contains(where: deleting.contains)
        default:
            return false
        }
    }

    /// Wrappers that run the command after them, each with the flags of its
    /// own that take a separate value. `sudo find . -delete` is a find
    /// command, and a floor that read only the first word let it through
    /// (review RV5).
    static let wrapperValueFlags: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-T", "-D", "-R"],
        "env": ["-u", "-P", "-S", "-C"],
        "nice": ["-n"],
        "time": [], "command": [], "nohup": [], "exec": ["-a"],
        "xargs": ["-n", "-I", "-J", "-L", "-P", "-R", "-S", "-s", "-E", "-d", "-a"],
    ]

    /// `tokens` with leading `VAR=value` pairs and every wrapper (with its
    /// flags and their values) peeled off, so the program that actually runs
    /// is first.
    static func unwrapped(_ tokens: [String]) -> [String] {
        var rest = tokens[...]
        while let first = rest.first {
            if isAssignment(first) { rest = rest.dropFirst(); continue }
            guard let valued = wrapperValueFlags[(first as NSString).lastPathComponent] else { break }
            rest = rest.dropFirst()
            while let flag = rest.first, flag.hasPrefix("-") {
                rest = rest.dropFirst()
                if flag == "--" { break }
                if valued.contains(flag) { rest = rest.dropFirst() }
            }
        }
        return Array(rest)
    }

    static func isAssignment(_ token: String) -> Bool {
        token.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }

    /// git's arguments from the subcommand on: `git -C repo branch -D x` is
    /// `branch -D x`.
    static func gitSubcommand(_ args: [String]) -> [String] {
        let valued: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                                   "--super-prefix", "--config-env"]
        var rest = args[...]
        while let flag = rest.first, flag.hasPrefix("-") {
            rest = rest.dropFirst()
            if flag == "--" { break }
            if valued.contains(flag) { rest = rest.dropFirst() }
        }
        return Array(rest)
    }

    /// The file `sort` writes (`-o X`, `-oX`, `-uo X`, `--output X`, `--output=X`)
    /// and the index of the argument that names it.
    static func sortOutputTarget(_ args: [String]) -> (String, Int)? {
        for (i, arg) in args.enumerated() {
            let next = i + 1 < args.count ? (args[i + 1], i + 1) : nil
            if arg.hasPrefix("--output=") { return (String(arg.dropFirst("--output=".count)), i) }
            if arg == "--output" { return next }
            guard arg.hasPrefix("-"), !arg.hasPrefix("--"), let o = arg.firstIndex(of: "o") else { continue }
            let rest = arg[arg.index(after: o)...]
            return rest.isEmpty ? next : (String(rest), i)
        }
        return nil
    }

    /// Statements, and the commands piped together inside each, outside quotes.
    static func pipelineSegments(_ command: String) -> [String] {
        splitStatements(command).flatMap { statement -> [String] in
            var out: [String] = [], current = ""
            var inSingle = false, inDouble = false
            for c in statement {
                if c == "'" && !inDouble { inSingle.toggle() }
                if c == "\"" && !inSingle { inDouble.toggle() }
                if c == "|" && !inSingle && !inDouble { out.append(current); current = ""; continue }
                current.append(c)
            }
            out.append(current)
            return out
        }
    }

    // MARK: - Plainly read-only
    //
    // A command that cannot write cannot be destructive, so there is nothing
    // for a second opinion to raise and no reason to pay for one. This is the
    // cheap pre-filter in front of the engine, and it is deliberately narrow:
    // a binary is read-only here only if it is read-only with EVERY flag. `git`
    // is not on the list because `git reset --hard` is a git command; the three
    // read-only git subcommands are matched as whole phrases instead.

    static let plainlyReadOnlyBinaries: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "pwd", "echo", "stat", "file",
        "which", "whoami", "date", "uname", "df", "du", "env", "printenv",
        "grep", "rg", "find", "diff", "tree", "sort", "uniq", "basename", "dirname"
    ]

    static let plainlyReadOnlyPhrases: [String] = [
        "git status", "git log", "git diff", "git show", "git branch"
    ]

    /// True when the command reads and cannot write. A redirect, a pipe into
    /// anything, a chain or a subshell all disqualify it, because the second
    /// half of `ls > /etc/passwd` is the half that matters.
    public static func isPlainlyReadOnly(command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lc = trimmed.lowercased()
        // Anything that can chain, redirect or substitute is out of scope for
        // a one-token judgement.
        for marker in [">", "|", ";", "&", "`", "$(", "\n"] where lc.contains(marker) {
            return false
        }
        let tokens = tokenize(trimmed)
        if let phrase = plainlyReadOnlyPhrases.first(where: { lc == $0 || lc.hasPrefix($0 + " ") }) {
            return !writes(gitPhrase: phrase, args: Array(tokens.dropFirst(2)))
        }
        guard let first = tokens.first else { return true }
        let base = (first as NSString).lastPathComponent.lowercased()
        guard plainlyReadOnlyBinaries.contains(base) else { return false }
        return !writes(binary: base, args: Array(tokens.dropFirst()))
    }

    /// The arguments that make a listed binary write, delete or run another
    /// command. `find . -delete` is a find command, so the list above holds
    /// only while none of these is present.
    static func writes(binary: String, args: [String]) -> Bool {
        let operands = args.filter { !$0.hasPrefix("-") }
        switch binary {
        case "find":
            let acting: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir",
                                       "-fprint", "-fprint0", "-fprintf", "-fls"]
            return args.contains(where: acting.contains)
        case "sort":
            // `-o file`, also inside a cluster like `-uo`.
            return args.contains { $0.hasPrefix("--output") || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("o")) }
        case "tree":
            return args.contains { $0 == "-o" || $0 == "-R" }
        case "env":
            // Anything after `env` is a command it runs, or a setting for one.
            return !args.isEmpty
        case "rg":
            return args.contains { $0 == "--pre" || $0.hasPrefix("--pre=") }
        case "uniq":
            // `uniq in out` writes out.
            return operands.count > 1
        case "file":
            return args.contains("-C")
        default:
            return false
        }
    }

    static func writes(gitPhrase: String, args: [String]) -> Bool {
        if args.contains(where: { $0.hasPrefix("--output") }) { return true }
        guard gitPhrase == "git branch" else { return false }
        // Listing branches reads; naming one creates, deletes, moves or copies it.
        let listing: Set<String> = ["-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose",
                                    "--show-current", "--no-color", "--color"]
        return args.contains { !listing.contains($0) }
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


// MARK: - ShellSecondOpinion
//
// The text guards above are the FLOOR, not the ceiling. They are pattern
// matching on a string, so they miss anything phrased unusually: a destructive
// command written as `find . -delete`, or a script name that wipes a database.
//
// A decision provider gets to look at the same string and say "this destroys
// something", and that answer may only ever RAISE the verdict. It can never
// clear a command the text guard flagged, because the whole point of the text
// guard is that it does not depend on a model being right, being reachable, or
// being honest. A provider that is 0.99 sure `rm -rf ~` is harmless changes
// nothing.
//
// This type is pure and platform-free so it can live beside the guards it
// combines. The provider call itself belongs to the app-side adapter, which is
// where every other gate in the shell path already lives.

public enum ShellSecondOpinion {
    public static let instructions =
        "Would running this command destroy or overwrite something the person would want back? "
        + "Answer high for deleting files, dropping a database, force-overwriting, resetting work away, "
        + "or running a script whose name says it wipes, resets or cleans something. "
        + "Answer low for reading, listing, searching, building, installing, and for writing a new file."

    /// The one rule: the text guard wins whenever it says yes.
    public static func isDestructive(textGuardSaysYes: Bool,
                                     secondOpinion: Double?,
                                     threshold: Double) -> Bool {
        if textGuardSaysYes { return true }
        guard let secondOpinion else { return false }
        return secondOpinion >= threshold
    }

    /// Whether asking is worth a decision at all. Nothing to raise on a
    /// command the text guard already flagged, and nothing to raise on one
    /// that cannot write.
    public static func worthAsking(command: String, textGuardSaysYes: Bool) -> Bool {
        if textGuardSaysYes { return false }
        return !ShellSafety.isPlainlyReadOnly(command: command)
    }
}
