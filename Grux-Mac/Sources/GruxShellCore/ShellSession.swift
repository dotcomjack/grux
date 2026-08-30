import Foundation

// MARK: - ShellSession
//
// A persistent, stateful shell. One Session = one long-running `bash` child
// process. Commands sent into its stdin; output framed by unique markers so we
// can tell where one command's output ends and the next begins, and so we can
// capture exit code + new cwd without having to re-probe between calls.
//
// State preserved across commands (which is the whole point of the tool vs a
// one-shot exec):
//   - shell environment variables (export FOO=bar)
//   - cwd (changed by cd - we track it ourselves by parsing the marker)
//   - shell aliases (alias ll="ls -la")
//   - stdin-fed programs? No - commands are treated atomically per call.
//
// NOT a PTY. Interactive programs that NEED a TTY (vim, less, htop) won't work
// here. Build tools, CLIs, git, npm, cargo, xcodebuild etc. all work fine over
// pipes. If/when a customer demands interactive programs, upgrade to openpty.
//
// Thread safety: this class is an actor, so only one command runs at a time per
// session. If Claude queues two tool_use calls for the same session, they
// serialize - which matches the mental model (one shell, one command at a time).

public actor ShellSession {

    public let id: String
    public let rootDir: String
    public let mode: ShellMode
    public let undoMode: ShellUndoMode
    public let startedAt: Date

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    // Current working directory as we understand it. Updated after every command
    // via the __GRUX_CWD marker. Source of truth for the cd-escape gate.
    private(set) var currentCwd: String

    // Rolling command index - increments on each run. Useful for snapshot labels.
    private(set) var commandIndex: Int = 0

    // Human-readable audit log of everything that happened in this session.
    // Appended to mirrorLogPath so the Terminal.app mirror sees it too.
    public let mirrorLogPath: String

    // The snapshot store and mirror are injected by the manager - kept as weak
    // owning references rather than actors composed in so tests can stand up a
    // session without the full wiring.
    public let snapshots: ShellSnapshotStore
    public var mirror: ShellTerminalMirror?

    // Whether the per-turn baseline snapshot has been taken yet for the current
    // turn. The manager signals turn-starts via `beginTurn()`.
    private var turnSnapshotTaken: Bool = false

    public init(id: String, rootDir: String, mode: ShellMode, undoMode: ShellUndoMode, mirror: ShellTerminalMirror? = nil) {
        self.id = id
        self.rootDir = rootDir
        self.mode = mode
        self.undoMode = undoMode
        self.currentCwd = rootDir
        self.startedAt = Date()
        self.mirrorLogPath = "/tmp/grux-session-\(id).log"
        self.snapshots = ShellSnapshotStore(sessionId: id, rootDir: rootDir)
        self.mirror = mirror
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // Guard: rootDir validity.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootDir, isDirectory: &isDir) else {
            throw ShellToolError.rootDoesNotExist(rootDir)
        }
        guard isDir.boolValue else {
            throw ShellToolError.rootNotDirectory(rootDir)
        }
        guard ShellAllowlist.isInsideAllowedRoot(rootDir) else {
            throw ShellToolError.rootOutsideAllowlist(rootDir)
        }
        // Fresh mirror log - write a banner so the Terminal.app window has a
        // header explaining what it is.
        let banner = """
        ============================================================
         GRUX SHELL SESSION - READ-ONLY MIRROR
         session: \(id)
         root:    \(rootDir)
         mode:    \(mode.rawValue)   undo: \(undoMode.rawValue)
         ⚠️  Do NOT type into this window. It's a live tail of what
             Grux is doing. Your keystrokes will not reach Grux.
             To take over manually, ask Grux to end the session.
        ============================================================

        """
        try banner.write(toFile: mirrorLogPath, atomically: true, encoding: .utf8)

        try await snapshots.ensureInitialized()
        _ = try await snapshots.snapshot(label: "session start", trigger: "session-start", commandIndex: 0)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        // --noprofile/--norc keeps startup fast and, crucially, deterministic:
        // The user's local ~/.bashrc or ~/.bash_profile won't inject tooling that
        // competes with our markers (e.g. powerline prompts, `cd` overrides).
        proc.arguments = ["--noprofile", "--norc"]
        proc.currentDirectoryURL = URL(fileURLWithPath: rootDir)

        // Clean environment - start from a minimal PATH that covers homebrew +
        // system binaries, plus pass through HOME/USER/SHELL/TERM. Don't leak
        // the whole Grux process env (may contain API keys).
        //
        // We also prepend any $HOME-rooted entries from the parent PATH -
        // that's how we pick up nvm (~/.nvm/versions/node/.../bin), pyenv,
        // cargo, ~/.local/bin, etc. without dragging in the full parent env.
        let parentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let userToolPaths: [String] = parentPath
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix(home) && !$0.contains("/.claude/plugins/") }
        let basePath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let fullPath = (userToolPaths + [basePath]).joined(separator: ":")
        var env: [String: String] = [
            "HOME":  home,
            "USER":  NSUserName(),
            "SHELL": "/bin/bash",
            "TERM":  "dumb",            // discourage ANSI cursor gymnastics
            "LANG":  "en_US.UTF-8",
            "LC_ALL":"en_US.UTF-8",
            "PATH":  fullPath,
            "PS1":   "" // suppress prompt
        ]
        // Pass through NVM_DIR, RUSTUP_HOME, CARGO_HOME if present - otherwise
        // Node/Rust toolchain managers silently fail.
        for k in ["NVM_DIR", "RUSTUP_HOME", "CARGO_HOME", "GEM_HOME", "PYENV_ROOT"] {
            if let v = ProcessInfo.processInfo.environment[k] { env[k] = v }
        }
        proc.environment = env

        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        try proc.run()

        // Verify process alive; any immediate exit is fatal for a session.
        if !proc.isRunning {
            throw ShellToolError.runtime("shell died immediately at launch (exit \(proc.terminationStatus))")
        }

        appendMirror("▶ session started at \(isoNow())\n\n")
    }

    public func end() async {
        // Tell the shell to exit cleanly; if it doesn't, terminate.
        if let stdin = stdinPipe?.fileHandleForWriting {
            try? stdin.write(contentsOf: Data("exit\n".utf8))
            try? stdin.close()
        }
        if let proc = process, proc.isRunning {
            // Give bash a moment to exit on its own.
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning { proc.terminate() }
        }
        appendMirror("\n■ session ended at \(isoNow())\n")
        await mirror?.close()
        await snapshots.tearDown()
    }

    // MARK: - Turn boundary
    //
    // Called by the tool dispatch BEFORE any commands from a new user turn run.
    // Ensures we have a clean per-turn snapshot we can revert to.
    public func beginTurn(label: String) async throws {
        _ = try await snapshots.snapshot(label: "turn: \(label)", trigger: "turn-start", commandIndex: commandIndex)
        turnSnapshotTaken = true
    }

    // MARK: - Run a command

    public func run(command: String, timeoutSec: Int = 120) async throws -> ShellRunResult {
        commandIndex += 1

        // Safety gate first - containment + allowlist + confirm signaling.
        let verdict = ShellSafety.evaluate(command: command, rootDir: rootDir, currentCwd: currentCwd, mode: mode)
        switch verdict.decision {
        case .blockedOutsideRoot(let reason), .blockedStrictAllowlist(let reason):
            appendMirror("⛔ blocked: \(reason)\n   command: \(command)\n\n")
            return ShellRunResult(
                sessionId: id, command: command, exitCode: -1, stdout: "", stderr: reason,
                durationMs: 0, cwdAfter: currentCwd, snapshotId: nil, gated: false, blocked: true,
                blockedReason: reason
            )
        case .requiresConfirm(let reason):
            // At the tool level, we return gated=true so the dispatcher can ask
            // the user for confirmation and re-call run(confirmed: true, …). The
            // confirm UI/voice is the caller's problem - here we just flag.
            appendMirror("⏸ confirm required: \(reason)\n   command: \(command)\n\n")
            return ShellRunResult(
                sessionId: id, command: command, exitCode: -2, stdout: "", stderr: reason,
                durationMs: 0, cwdAfter: currentCwd, snapshotId: nil, gated: true, blocked: false,
                blockedReason: reason
            )
        case .allow:
            break
        }

        // Hybrid undo: take a pre-command snapshot if the command looks destructive.
        var snapshotId: String? = nil
        if undoMode == .hybrid && verdict.looksDestructive {
            let snap = try await snapshots.snapshot(
                label: "before destructive cmd #\(commandIndex): \(command.prefix(80))",
                trigger: "destructive-detect",
                commandIndex: commandIndex
            )
            snapshotId = snap.snapshotId
            appendMirror("📸 hybrid snapshot (\(snap.snapshotId)) before destructive command\n")
        }

        // If no turn baseline exists yet (caller didn't call beginTurn, which is
        // fine for direct use), take an implicit one on first run.
        if !turnSnapshotTaken {
            let snap = try await snapshots.snapshot(
                label: "implicit turn baseline before cmd #\(commandIndex)",
                trigger: "implicit-turn-start",
                commandIndex: commandIndex
            )
            if snapshotId == nil { snapshotId = snap.snapshotId }
            turnSnapshotTaken = true
        }

        // Execute.
        let t0 = Date()
        let (stdout, stderr, exitCode, newCwd) = try await executeFramed(command: command, timeoutSec: timeoutSec)
        let durationMs = Int(Date().timeIntervalSince(t0) * 1000)
        if let cwd = newCwd { currentCwd = cwd }

        // Log to mirror.
        appendMirror("""
        $ \(command)
        \(stdout)\(stderr.isEmpty ? "" : "\n[stderr]\n\(stderr)")
        [exit \(exitCode) · \(durationMs)ms · cwd \(currentCwd)]

        """)

        return ShellRunResult(
            sessionId: id, command: command, exitCode: exitCode, stdout: stdout, stderr: stderr,
            durationMs: durationMs, cwdAfter: currentCwd, snapshotId: snapshotId, gated: false,
            blocked: false, blockedReason: nil
        )
    }

    // MARK: - Run with explicit confirm (bypasses the network gate)

    public func runConfirmed(command: String, timeoutSec: Int = 120) async throws -> ShellRunResult {
        // Bypass network-gate by forcing trust-mode evaluation for containment only.
        commandIndex += 1
        let verdict = ShellSafety.evaluate(command: command, rootDir: rootDir, currentCwd: currentCwd, mode: .trust)
        switch verdict.decision {
        case .blockedOutsideRoot(let reason):
            return ShellRunResult(
                sessionId: id, command: command, exitCode: -1, stdout: "", stderr: reason,
                durationMs: 0, cwdAfter: currentCwd, snapshotId: nil, gated: false, blocked: true,
                blockedReason: reason
            )
        case .blockedStrictAllowlist, .requiresConfirm, .allow:
            break
        }
        if !turnSnapshotTaken {
            _ = try await snapshots.snapshot(
                label: "implicit turn baseline (confirmed cmd)",
                trigger: "implicit-turn-start",
                commandIndex: commandIndex
            )
            turnSnapshotTaken = true
        }
        let t0 = Date()
        let (stdout, stderr, exitCode, newCwd) = try await executeFramed(command: command, timeoutSec: timeoutSec)
        let durationMs = Int(Date().timeIntervalSince(t0) * 1000)
        if let cwd = newCwd { currentCwd = cwd }
        appendMirror("""
        ✅ confirmed
        $ \(command)
        \(stdout)\(stderr.isEmpty ? "" : "\n[stderr]\n\(stderr)")
        [exit \(exitCode) · \(durationMs)ms · cwd \(currentCwd)]

        """)
        return ShellRunResult(
            sessionId: id, command: command, exitCode: exitCode, stdout: stdout, stderr: stderr,
            durationMs: durationMs, cwdAfter: currentCwd, snapshotId: nil, gated: false,
            blocked: false, blockedReason: nil
        )
    }

    // MARK: - Undo

    public func undo(to snapshotId: String? = nil) async throws -> (restoredTo: String, changed: [String]) {
        let changed = try await snapshots.restore(to: snapshotId)
        let allRecords = await snapshots.list()
        let record: ShellSnapshotRecord? = {
            if let id = snapshotId { return allRecords.first(where: { $0.snapshotId == id }) }
            return allRecords.last
        }()
        let target = record?.snapshotId ?? "latest"
        appendMirror("↩ undo: restored to snapshot \(target) - \(changed.count) files changed\n")
        return (target, changed)
    }

    public func info() async -> ShellSessionInfo {
        let snapCount = await snapshots.list().count
        var mirrorActive = false
        if let mirror = mirror {
            mirrorActive = await mirror.isOpen
        }
        return ShellSessionInfo(
            sessionId: id,
            rootDir: rootDir,
            cwd: currentCwd,
            mode: mode,
            undoMode: undoMode,
            commandsRun: commandIndex,
            snapshotsTaken: snapCount,
            mirrorActive: mirrorActive,
            startedAt: startedAt
        )
    }

    // MARK: - Framed execution
    //
    // Sends the command with a unique trailer that prints the exit code and
    // post-command cwd. We read from stdout until we see the trailer marker,
    // then slice out the command's actual output. stderr is drained in parallel
    // until we see its matching marker.
    //
    // Bash injection risk: the command itself is user/model-controlled. The
    // trailer uses a single-quoted HEREDOC-ish construct to keep our markers
    // from being caught in quote games the model's command might use. We run
    // the trailer as a SEPARATE line after a newline, so anything the command
    // did (even a missing newline) is immune.

    private func executeFramed(command: String, timeoutSec: Int) async throws -> (String, String, Int32, String?) {
        guard let stdin = stdinPipe?.fileHandleForWriting,
              let stdoutReader = stdoutPipe?.fileHandleForReading,
              let stderrReader = stderrPipe?.fileHandleForReading else {
            throw ShellToolError.runtime("pipes not available")
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let outMarker = "__GRUX_STDOUT_END_\(token)__"
        let errMarker = "__GRUX_STDERR_END_\(token)__"

        // Wrap the user command in a subshell `( ... )` so our trailer runs even
        // if the user's command exits with `set -e` or changes `$?` semantics
        // via a pipeline. After the subshell we emit:
        //   printf '\n<OUTMARKER> exit=%d cwd=%s\n' $? "$(pwd)"  → stdout
        //   printf '\n<ERRMARKER>\n' >&2                          → stderr
        // The `exit=` + `cwd=` are parsed back on the Swift side.
        let framed = """
        ( \(command) )
        __grux_rc=$?
        printf '\\n%s exit=%d cwd=%s\\n' '\(outMarker)' $__grux_rc "$(pwd)"
        printf '\\n%s\\n' '\(errMarker)' 1>&2

        """
        try stdin.write(contentsOf: Data(framed.utf8))

        // Spin up concurrent readers for stdout + stderr. Each reads until it
        // sees its marker line.
        async let stdoutTask: String = Self.readUntilMarker(reader: stdoutReader, marker: outMarker, timeoutSec: timeoutSec)
        async let stderrTask: String = Self.readUntilMarker(reader: stderrReader, marker: errMarker, timeoutSec: timeoutSec)

        let stdoutRaw = try await stdoutTask
        let stderrRaw = try await stderrTask

        let (bodyOut, exitCode, newCwd) = Self.splitStdout(stdoutRaw, marker: outMarker)
        let bodyErr = Self.splitStderr(stderrRaw, marker: errMarker)

        return (bodyOut, bodyErr, exitCode, newCwd)
    }

    // Read the FileHandle in small chunks, accumulating, until we see a line
    // starting with `marker`. Honors timeoutSec. Does NOT require non-blocking
    // IO - uses `availableData` reads on a background thread, signaled via
    // continuation.
    private static func readUntilMarker(reader: FileHandle, marker: String, timeoutSec: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(Double(timeoutSec))
        var accumulated = Data()
        while Date() < deadline {
            // `availableData` blocks until at least one byte is available or EOF.
            // To avoid blocking the actor, jump to a detached Task.
            let chunk: Data = await Task.detached(priority: .userInitiated) {
                return reader.availableData
            }.value
            if chunk.isEmpty {
                // EOF - child died. Return whatever we've got.
                return String(data: accumulated, encoding: .utf8) ?? ""
            }
            accumulated.append(chunk)
            // Look for marker as a complete line.
            if let s = String(data: accumulated, encoding: .utf8), s.contains(marker) {
                return s
            }
        }
        throw ShellToolError.runtime("command timed out after \(timeoutSec)s waiting for marker")
    }

    // Given the raw stdout read that contains the marker line, split out the
    // command's actual output and parse exit= + cwd= from the trailer.
    private static func splitStdout(_ raw: String, marker: String) -> (String, Int32, String?) {
        // Find the last line that starts with the marker (defensive vs. a
        // command that echoed the marker as data, which is extremely unlikely
        // given UUID).
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var trailerIdx: Int? = nil
        for i in (0..<lines.count).reversed() {
            if lines[i].hasPrefix(marker) { trailerIdx = i; break }
        }
        guard let idx = trailerIdx else {
            return (raw, -3, nil)
        }
        let body = lines[..<idx].joined(separator: "\n").trimmingCharacters(in: CharacterSet.newlines)
        let trailer = lines[idx]
        // Parse "MARKER exit=<n> cwd=<path>"
        var exitCode: Int32 = -3
        var cwd: String? = nil
        let afterMarker = trailer.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        for part in afterMarker.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true) {
            if part.hasPrefix("exit=") {
                exitCode = Int32(part.dropFirst("exit=".count)) ?? -3
            } else if part.hasPrefix("cwd=") {
                cwd = String(part.dropFirst("cwd=".count))
            }
        }
        // Second pass - the original split is space-delimited but cwd may have
        // spaces. Reparse defensively.
        let flatParts = afterMarker.components(separatedBy: " ")
        for p in flatParts where p.hasPrefix("exit=") {
            if let n = Int32(p.dropFirst("exit=".count)) { exitCode = n }
        }
        if let cwdStart = afterMarker.range(of: "cwd=") {
            cwd = String(afterMarker[cwdStart.upperBound...])
        }
        return (body, exitCode, cwd)
    }

    private static func splitStderr(_ raw: String, marker: String) -> String {
        if let range = raw.range(of: "\n" + marker) {
            return String(raw[..<range.lowerBound]).trimmingCharacters(in: CharacterSet.newlines)
        }
        if let range = raw.range(of: marker) {
            return String(raw[..<range.lowerBound]).trimmingCharacters(in: CharacterSet.newlines)
        }
        return raw
    }

    // MARK: - Mirror log append (also written when no Terminal.app mirror is open).

    private func appendMirror(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: mirrorLogPath)) {
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}
