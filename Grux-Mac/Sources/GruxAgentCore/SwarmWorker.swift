import Foundation

// MARK: - SwarmWorker
//
// A single autonomous worker. Wraps one `claude --print --output-format stream-json`
// subprocess. The worker's job:
//   1. Spawn the subprocess with a fully-formed prompt + scaffold + permissions
//   2. Stream stdout, parse stream-json events, emit AgentStep callbacks
//   3. Exit when the subprocess exits or we cancel/kill it
//   4. Return a SwarmWorkerResult (success/fail + final text + cost)
//
// Workers DO NOT depend on the Grux app - only on Foundation. They run
// completely off the @MainActor.

public struct SwarmWorkerResult: Sendable {
    public let workerId: String
    public let success: Bool
    public let finalText: String
    public let costUSD: Double
    public let durationSec: Double
    public let exitCode: Int32
    public let errorMessage: String?
    // Set when LimitSignal.detect matched any stream-json line during the
    // run. The orchestrator uses this to classify the worker as
    // `.pausedForAuth` instead of `.failed` even when exitCode != 0.
    public let interruption: WorkerInterruption?

    public init(
        workerId: String,
        success: Bool,
        finalText: String,
        costUSD: Double,
        durationSec: Double,
        exitCode: Int32,
        errorMessage: String? = nil,
        interruption: WorkerInterruption? = nil
    ) {
        self.workerId = workerId
        self.success = success
        self.finalText = finalText
        self.costUSD = costUSD
        self.durationSec = durationSec
        self.exitCode = exitCode
        self.errorMessage = errorMessage
        self.interruption = interruption
    }
}

// Step callback delivered for each interesting stream event. Implemented by
// the orchestrator to fan out into AgentStore + UI subscribers.
public protocol SwarmWorkerObserver: AnyObject, Sendable {
    func worker(_ workerId: String, didEmit step: AgentStep) async
}

public actor SwarmWorker {

    public let spec: SwarmWorkerSpec
    public weak var observer: (any SwarmWorkerObserver)?

    private var process: Process?
    private var cancelled = false
    private(set) public var isRunning: Bool = false

    // Set the moment LimitSignal.detect matches any stream-json line. Drives
    // the .pausedForAuth classification when the run wraps up. Also gates the
    // single .authLimitDetected step emit (we only want one per worker run).
    private var limitSignalDetected: Bool = false
    private var lastAssistantText: String?

    // Wall-clock of the most recent stream-json event we parsed. Updated in
    // the read loop; read by the idle-TTL watchdog from outside actor
    // isolation. Public-read so the detached watchdog Task can `await
    // self.lastEventAt`.
    private(set) public var lastEventAt: Date = Date()

    public init(spec: SwarmWorkerSpec, observer: (any SwarmWorkerObserver)?) {
        self.spec = spec
        self.observer = observer
    }

    // Resolve `claude` CLI absolute path. Honors $CLAUDE_BIN > PATH > common locations.
    public static func resolveClaudeBinary() -> String {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BIN"], !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Last resort - let env resolve it.
        return "claude"
    }

    // Outcome of building the confinement profile. The caller (run) inspects
    // this before spawning: a fatal misconfig refuses the worker outright; a
    // carveDenied (writable root not on the sanctioned allowlist, or overlaps a
    // protected root) still spawns but with NO write carve, so the worker is
    // confined to /tmp only and a loud step is emitted.
    struct SandboxDecision {
        let profile: String
        // True when the writable root was carved in. False when the root was
        // refused (not on the allowlist, or it sits inside a protected root):
        // the profile still allows /tmp writes but grants no project write.
        let carved: Bool
        // True when the job is structurally unsafe: the writable root is an
        // ANCESTOR of a protected live build tree (carving it would re-open the
        // live tree). The worker must NOT spawn in this case.
        let fatalMisconfig: Bool
        // Human-readable reason for a refused carve or a fatal misconfig.
        let reason: String?
    }

    // Sanctioned writable-root prefixes. A worker may only have its own root
    // carved back in when that root sits under one of these:
    //   - general swarm rootDir: ~/Documents/Grux/swarms or ~/Projects/GruxApps
    //   - a Foundry upgrade worktree: any sibling ".../.worktrees/<slug>"
    // Everything else (unrelated repos, the live build tree, broad areas like
    // the whole home dir) is refused a carve. The ".worktrees/" match is a
    // path-segment check, NOT a fixed prefix, because Foundry worktrees live
    // beside the canonical clone (e.g. ".../<your-clone-parent>/.worktrees/").
    static func isSanctionedWritableRoot(_ canonicalRoot: String) -> Bool {
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        let swarmsRoot = (home as NSString).appendingPathComponent("Documents/Grux/swarms")
        let gruxAppsRoot = (home as NSString).appendingPathComponent("Projects/GruxApps")
        // Design Studio workspace roots (T3 campaign). A subscription-CLI design
        // run writes under these; carving them in lets AgentBridgeRunner spawn a
        // design worker with real project write access without routing every run
        // through a .worktrees checkout.
        let designRoot = (home as NSString).appendingPathComponent("Documents/Grux/design")
        let studioRoot = (home as NSString).appendingPathComponent("Documents/Grux/studio")
        func under(_ prefix: String) -> Bool {
            canonicalRoot == prefix || canonicalRoot.hasPrefix(prefix + "/")
        }
        if under(swarmsRoot) || under(gruxAppsRoot) || under(designRoot) || under(studioRoot) { return true }
        // Foundry upgrade worktree: a ".worktrees" path segment somewhere in
        // the path. Split on "/" so "my.worktreesthing" never false-matches.
        let segments = canonicalRoot.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return segments.contains(".worktrees")
    }

    // The LIVE code tree the running app is built from, when the operator has
    // said where it is. `GRUX_REPO_ROOT` is the same environment variable the
    // Foundry engine resolves its checkout from, so one answer covers both, and
    // no layout is guessed at.
    //
    // Unset is the normal case for anyone running an installed Grux: there is
    // no source tree on the machine to protect, so no deny block is emitted and
    // the sanctioned allowlist above is the only thing deciding a carve.
    static func protectedBuildRoots() -> [String] {
        guard let root = ProcessInfo.processInfo.environment["GRUX_REPO_ROOT"],
              !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return [(root as NSString).resolvingSymlinksInPath]
    }

    // Build an allow-default sandbox-exec (SBPL) profile that DENIES writes to
    // the live Grux code tree the running app is built from, when one is known
    // (see protectedBuildRoots). The worker's OWN assigned root (spec.cwd) and
    // the system temp dir are carved back in ONLY when the root is sanctioned
    // (see isSanctionedWritableRoot) AND does not overlap a protected root.
    // CRITICAL ordering: the protected deny block is emitted LAST so it always
    // wins by SBPL last-match-wins, even if a (rejected) too-broad carve would
    // otherwise have re-opened a live tree. A general swarm worker's cwd is its
    // rootDir; a Foundry upgrade worker's cwd is its isolated upgrade worktree.
    // Everything else (/tmp, /var/folders, ~/.claude, ~/Library/Caches, npm and
    // node caches, the user's read access to the whole disk) stays allowed by
    // the (allow default) baseline, so real workers never break.
    //
    // `protectedRoots` is a parameter so the confinement rules can be exercised
    // against a scratch directory instead of whatever tree the machine running
    // the tests happens to hold.
    static func sandboxDecision(
        writableRoot: String,
        protectedRoots: [String] = protectedBuildRoots()
    ) -> SandboxDecision {
        // Resolve symlinks so a carve-out under a denied root still matches
        // by canonical path. Falls back to the raw path if resolution fails.
        let canonicalRoot = (writableRoot as NSString).resolvingSymlinksInPath
        // SBPL string literals use double quotes; backslash-escape any embedded
        // double quote or backslash so a path with odd characters can't break
        // out of the literal. (Project paths often contain spaces, which need no
        // escaping inside an SBPL quoted literal, but we escape defensively.)
        func sbplLiteral(_ p: String) -> String {
            let escaped = p
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        // The temp dir the worker (node) genuinely needs. Strip the trailing
        // slash so subpath matching is exact.
        let tmpDir: String = {
            let raw = NSTemporaryDirectory()
            if raw.count > 1 && raw.hasSuffix("/") { return String(raw.dropLast()) }
            return raw
        }()
        // Protected LIVE code trees: the running app is built from these, so a
        // worker must never write here. The deny block is emitted LAST so it is
        // authoritative regardless of any carve scope.
        let protected = protectedRoots.map { ($0 as NSString).resolvingSymlinksInPath }
        // With nothing to protect the block is omitted entirely, because a
        // filterless `(deny file-write*)` is not a no-op. Measured against
        // sandbox-exec: it denies every write EXCEPT the paths a filtered allow
        // rule above it names, so emitting an empty block would silently strip
        // workers of the ~/.claude, cache and npm writes the (allow default)
        // baseline exists to give them.
        let denyBlock = protected.isEmpty ? "" : """

        (deny file-write*
        \(protected.map { "    (subpath \(sbplLiteral($0)))" }.joined(separator: "\n")))
        """

        // Decide whether the writable root may be carved.
        //   (a) FATAL: canonicalRoot is an ANCESTOR of a protected root. Carving
        //       it would grant write to the live build tree. Refuse to spawn.
        //   (b) carveDenied: canonicalRoot IS a protected root, or sits INSIDE
        //       one (and is not an explicitly-sanctioned .worktrees sibling),
        //       or is simply not on the sanctioned allowlist. No carve; the
        //       worker gets /tmp only.
        //   (c) carve: sanctioned and non-overlapping.
        var fatal = false
        var fatalReason: String? = nil
        for pr in protected where pr.hasPrefix(canonicalRoot + "/") {
            fatal = true
            fatalReason = "writable root \(canonicalRoot) is an ancestor of protected live build tree \(pr); refusing to spawn (carving it would re-open the live tree)"
            break
        }

        let isProtectedItself = protected.contains(canonicalRoot)
        let insideProtected = protected.contains { canonicalRoot.hasPrefix($0 + "/") }
        let sanctioned = Self.isSanctionedWritableRoot(canonicalRoot)

        // Carve only when sanctioned, not a protected root, not inside one, and
        // not a fatal ancestor case.
        let mayCarve = sanctioned && !isProtectedItself && !insideProtected && !fatal

        var carveReason: String? = nil
        if !mayCarve && !fatal {
            if isProtectedItself {
                carveReason = "writable root \(canonicalRoot) IS a protected live build tree; no write carve granted (worker confined to temp)"
            } else if insideProtected {
                carveReason = "writable root \(canonicalRoot) is inside a protected live build tree; no write carve granted (worker confined to temp)"
            } else {
                carveReason = "writable root \(canonicalRoot) is not a sanctioned write target (expected under ~/Documents/Grux/swarms, ~/Projects/GruxApps, or a .worktrees/ upgrade worktree); no write carve granted (worker confined to temp)"
            }
        }

        // Allow block: always allow the temp dir. Add the project root only
        // when mayCarve. The deny block follows so protected roots always win.
        let carveLine = mayCarve ? "\n    (subpath \(sbplLiteral(canonicalRoot)))" : ""
        let profile = """
        (version 1)
        (allow default)
        (allow file-write*\(carveLine)
            (subpath \(sbplLiteral(tmpDir))))\(denyBlock)
        """
        return SandboxDecision(
            profile: profile,
            carved: mayCarve,
            fatalMisconfig: fatal,
            reason: fatal ? fatalReason : carveReason
        )
    }

    // Run the worker to completion. Returns when the subprocess exits or we cancel.
    public func run(
        scaffold: String = MegapromptScaffold.block(),
        ttlSeconds: Int = 1800
    ) async -> SwarmWorkerResult {
        let startedAt = Date()
        isRunning = true
        defer { isRunning = false }

        await emit(.workerStart, text: "spawning \(spec.label) (\(spec.role.rawValue), model=\(spec.model))")

        // Build the confinement decision up front. A FATAL misconfig (writable
        // root is an ancestor of a protected live build tree) refuses the
        // worker outright: spawning it would carve the live tree open, which is
        // exactly the 2026-06-16 incident. Better to fail the worker loudly
        // than to run it unconfined against the live source.
        let sandboxDecision = Self.sandboxDecision(writableRoot: spec.cwd)
        if sandboxDecision.fatalMisconfig {
            let why = sandboxDecision.reason ?? "writable root overlaps a protected live build tree"
            await emit(.error, text: "REFUSING to spawn worker: \(why)")
            return SwarmWorkerResult(
                workerId: spec.id,
                success: false,
                finalText: "",
                costUSD: 0,
                durationSec: Date().timeIntervalSince(startedAt),
                exitCode: -1,
                errorMessage: "refused: \(why)"
            )
        }
        if !sandboxDecision.carved, let why = sandboxDecision.reason {
            // Not fatal, but the worker gets NO project write carve (temp only).
            // Surface it loudly so a misrouted swarm is visible rather than
            // silently confined or silently granted broad write.
            await emit(.error, text: "WORKER WRITE CARVE DENIED: \(why)")
        }

        let claudePath = Self.resolveClaudeBinary()
        let proc = Process()
        // CONFINEMENT: never exec claude directly. Wrap it in sandbox-exec with
        // an allow-default profile that carves the worker's OWN assigned root
        // (spec.cwd) and the temp dir back in, and denies file writes to the
        // live Grux code tree when GRUX_REPO_ROOT names one. This is the only
        // OS-level guard on this rail: the subprocess runs --permission-mode
        // bypassPermissions, so claude's in-CLI gate is off and the sandbox is
        // what stops a worker from writing into the source tree it was built
        // from and breaking the build (the 2026-06-16 incident). Reads stay
        // fully open; only writes to the protected tree are blocked.
        let sandboxBin = "/usr/bin/sandbox-exec"
        let confine = FileManager.default.isExecutableFile(atPath: sandboxBin)
        if confine {
            proc.executableURL = URL(fileURLWithPath: sandboxBin)
        } else {
            // Fail-safe fallback: if sandbox-exec is missing (should never happen
            // on macOS), spawn claude directly rather than refusing all work.
            proc.executableURL = URL(fileURLWithPath: claudePath.contains("/") ? claudePath : "/usr/bin/env")
            await emit(.info, text: "sandbox-exec unavailable; worker running UNCONFINED")
        }

        // Arg vector. Under confinement the leading args are:
        //   sandbox-exec -p <profile> <claudePath-or-env> [claude] ...
        // Without confinement they match the prior direct-spawn shape.
        var args: [String] = []
        if confine {
            let profile = sandboxDecision.profile
            args.append(contentsOf: ["-p", profile])
            if claudePath.contains("/") {
                args.append(claudePath)
            } else {
                args.append(contentsOf: ["/usr/bin/env", "claude"])
            }
        } else {
            if !claudePath.contains("/") { args.append("claude") }
        }
        args.append(contentsOf: [
            "--print",
            "--output-format", "stream-json",
            "--verbose",                              // required for stream-json
            "--permission-mode", "bypassPermissions",
            "--model", spec.model,
            "--add-dir", spec.cwd,
            "--no-session-persistence"               // ephemeral; stream is our log
        ])
        // NOTE: deliberately NOT passing --max-budget-usd. Workers run through
        // the user's Claude.ai subscription, not metered API. The budgetUSD
        // field on SwarmWorkerSpec stays for reporting/UI only - the
        // subprocess has no cost cap. The TTL (`ttlSeconds` in run()) is the
        // only hard stop.
        if let n = spec.maxTurns {
            // claude CLI doesn't currently accept --max-turns directly in --print;
            // budget is the hard stop. Keep maxTurns in the spec for UI display.
            _ = n
        }
        if !scaffold.isEmpty {
            args.append("--append-system-prompt")
            args.append(scaffold)
        }
        if let allowed = spec.allowedTools, !allowed.isEmpty {
            args.append("--allowedTools")
            args.append(contentsOf: allowed)
        }
        // Final positional arg: the prompt. Use stdin instead so very long prompts
        // don't blow out arg-list limits.
        // We'll feed the goal via stdin.
        proc.arguments = args + ["--input-format", "text"]

        // Inherit env, then DELIBERATELY strip every key that would route the
        // spawned `claude` to API billing instead of the user's Claude.ai Max
        // (OAuth) subscription. Without this, `claude` finds an inherited
        // ANTHROPIC_API_KEY / Bedrock / Vertex var and hits api.anthropic.com
        // - the user's Anthropic Console dashboard shows REAL spend even
        // though they have a paid subscription. Also strip Claude-Code-loop
        // detection vars so the spawned CLI doesn't think it's nested inside
        // a parent Claude Code session and inherit that session's API auth.
        var env = ProcessInfo.processInfo.environment
        let stripKeys: Set<String> = [
            // Direct API key auth - top priority to remove.
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_API_TOKEN",
            "CLAUDE_API_KEY",
            "CLAUDE_AUTH_TOKEN",
            // Custom auth header / base URL overrides.
            "ANTHROPIC_AUTH_HEADER",
            "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_API_URL",
            // Cloud-provider auth alternatives that also bypass OAuth.
            "ANTHROPIC_BEDROCK_API_KEY",
            "ANTHROPIC_VERTEX_PROJECT_ID",
            "ANTHROPIC_VERTEX_REGION",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            // Claude Code parent-session detection. If these are set, the
            // spawned `claude` decides it's running inside Claude Code and
            // adopts that parent's auth/API mode. We want a fresh, OAuth-only
            // session.
            "CLAUDECODE",
            "CLAUDE_CODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_API_KEY",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
            "CLAUDE_CODE_SIMPLE",
            "CLAUDE_CODE_OAUTH_TOKEN"
        ]
        for k in stripKeys { env.removeValue(forKey: k) }
        env["NODE_NO_WARNINGS"] = "1"
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: spec.cwd)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        self.process = proc

        do {
            try proc.run()
        } catch {
            await emit(.error, text: "spawn failed: \(error.localizedDescription)")
            return SwarmWorkerResult(
                workerId: spec.id,
                success: false,
                finalText: "",
                costUSD: 0,
                durationSec: Date().timeIntervalSince(startedAt),
                exitCode: -1,
                errorMessage: "spawn failed: \(error.localizedDescription)"
            )
        }
        // Validate path. If `claude` is not on PATH and not at common locations,
        // we already fall back to "claude" via env; the exec error surfaces fast.

        // Write the prompt to stdin then close.
        let promptText = spec.goal + "\n"
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(promptText.utf8))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            // stdin write fail isn't fatal - claude with --print accepts prompts
            // a few ways. Continue and let the run unfold.
        }

        // Stream stdout incrementally. Set a TTL.
        // CRITICAL: `availableData` blocks until bytes arrive or EOF. If claude
        // hangs internally with no stream output, the read loop's TTL check
        // never fires. To enforce TTL even when stdout is silent, spin up a
        // separate watchdog task that calls proc.terminate() once the deadline
        // elapses - that closes the pipe, unblocks availableData, and lets the
        // read loop exit cleanly via the cancelled/terminated branch.
        let deadline = Date().addingTimeInterval(TimeInterval(ttlSeconds))
        // Idle TTL: kill the worker if claude emits zero stream-json events
        // for this many seconds, even when the wall TTL hasn't fired yet.
        // Catches the failure mode where claude is stuck (silent thinking
        // loop, internal retry deadlock, hung tool call with no progress)
        // but produces no stdout for the watchdog to react to. Default 600s
        // (10 min) - wide enough to absorb legitimately long single Bash
        // calls (xcodebuild test, large git fetch, brew install) without
        // false-positive killing real work, narrow enough to recover ~3x
        // faster than the 1800s wall TTL on actual hangs. Override via
        // GRUX_WORKER_IDLE_TTL_SECONDS for runs that legitimately do long
        // silent operations.
        let idleSeconds = (ProcessInfo.processInfo.environment["GRUX_WORKER_IDLE_TTL_SECONDS"]
                            .flatMap(Int.init)) ?? 600
        // Reset the idle clock at run start. The read loop bumps it after
        // every parsed stream-json event.
        self.lastEventAt = Date()
        let watchdog = Task<Void, Never> { [weak self, weak proc] in
            while !Task.isCancelled {
                let now = Date()
                if now > deadline {
                    if let p = proc, p.isRunning {
                        // Don't await emit here - emit hops to the actor; we're
                        // a detached Task. Just terminate; the post-exit branch
                        // emits the right TTL message based on which fired.
                        p.terminate()
                    }
                    return
                }
                if let self {
                    let last = await self.lastEventAt
                    if now.timeIntervalSince(last) > Double(idleSeconds) {
                        if let p = proc, p.isRunning {
                            p.terminate()
                        }
                        return
                    }
                }
                // Sleep in 1-second slices - short enough to react quickly,
                // long enough to not burn CPU. (Avoids tight-loop wakeups.)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { watchdog.cancel() }

        var residual = ""
        var costUSD: Double = 0
        var finalText: String = ""
        var success = false
        var ttlTerminated = false

        while proc.isRunning {
            if cancelled {
                proc.terminate()
                break
            }
            if Date() > deadline {
                ttlTerminated = true
                await emit(.error, text: "TTL exceeded (\(ttlSeconds)s) - terminating")
                proc.terminate()
                break
            }
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                // tiny sleep; avoid pegging the actor.
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            if let s = String(data: chunk, encoding: .utf8) {
                residual += s
                let (events, rem) = StreamJSONParser.parseChunk(residual)
                residual = rem
                for ev in events {
                    self.lastEventAt = Date()
                    await checkLimitSignal(in: ev)
                    let processed = await handleEvent(ev)
                    if let cost = processed.costUSD { costUSD = max(costUSD, cost) }
                    if let final = processed.finalText { finalText = final }
                    if processed.success != nil { success = processed.success ?? false }
                }
            } else {
                _ = String(data: chunk, encoding: .ascii) // best effort drop
            }
        }

        // Drain any remaining bytes.
        let tail = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil
        if let d = tail, let s = String(data: d, encoding: .utf8) {
            let combined = residual + s
            let (events, _) = StreamJSONParser.parseChunk(combined + "\n")
            for ev in events {
                self.lastEventAt = Date()
                await checkLimitSignal(in: ev)
                let processed = await handleEvent(ev)
                if let cost = processed.costUSD { costUSD = max(costUSD, cost) }
                if let final = processed.finalText { finalText = final }
                if processed.success != nil { success = processed.success ?? false }
            }
        }

        proc.waitUntilExit()
        let exitCode = proc.terminationStatus

        // Retroactively classify which TTL fired (if any). Three cases the
        // post-exit branch needs to handle:
        //   1. Read loop already noticed wall-TTL → ttlTerminated set, emit
        //      already happened from inside the loop. Emit nothing more.
        //   2. Watchdog killed silently because wall deadline elapsed during
        //      the read loop's 80ms sleep slice. ttlTerminated is false.
        //      Detect via `Date() > deadline && exitCode != 0` and emit.
        //   3. Watchdog killed because idle TTL fired. Detect via time-since-
        //      last-event and emit a different message so logs show it
        //      clearly.
        let endNow = Date()
        let wallSilentlyHit = !ttlTerminated && endNow > deadline && exitCode != 0
        let idleSilentlyHit = !ttlTerminated
            && !(endNow > deadline)
            && endNow.timeIntervalSince(lastEventAt) > Double(idleSeconds)
            && exitCode != 0
        if wallSilentlyHit {
            ttlTerminated = true
            await emit(.error, text: "wall TTL exceeded (\(ttlSeconds)s) - terminated by watchdog (claude produced no stdout for the entire ceiling)")
        }
        if idleSilentlyHit {
            ttlTerminated = true
            await emit(.error, text: "idle TTL exceeded (\(idleSeconds)s of stream-json silence) - claude went quiet mid-run")
        }

        // Append stderr content if present (helps diagnose spawn failures).
        let errBlob = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
        if let errData = errBlob,
           let s = String(data: errData, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await emit(.info, text: "stderr: \(s.prefix(500))")
        }

        let dur = Date().timeIntervalSince(startedAt)
        let okExit = exitCode == 0
        // A limit-hit run will sometimes ALSO carry result.subtype="success"
        // (the synthetic event mimics a normal completion shape) - but
        // is_error/api_error_status/error="rate_limit" reveal what really
        // happened. Override "success" downward when the detector fires so
        // workerCompleted classifies us as .pausedForAuth, not .done.
        var finalSuccess = (success || okExit) && !limitSignalDetected

        // TTL-during-finalization rescue: if the watchdog killed claude
        // (typically SIGTERM → exit 143) but the worker had already produced
        // its required deliverable, treat the run as a success. The marker
        // we look for is `build_summary.md` in spec.cwd containing the literal
        // "build_succeeded" - that's the convention v6/v7 workers emit when
        // they've finished their job, regardless of whether claude got to its
        // own clean exit. Without this rescue a 1800s-ceiling run that wrote
        // every artifact to disk in its final 30s gets scored `failed` purely
        // because the watchdog timer fired during the trailing write.
        var ttlRescued = false
        if !finalSuccess && ttlTerminated && !limitSignalDetected {
            let summaryPath = (spec.cwd as NSString).appendingPathComponent("build_summary.md")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: summaryPath)),
               let text = String(data: data, encoding: .utf8),
               text.contains("build_succeeded") {
                finalSuccess = true
                ttlRescued = true
                await emit(.info, text: "TTL hit during finalization - build_summary.md exists with build_succeeded marker; downgrading to success")
            }
        }

        let interruption: WorkerInterruption? = limitSignalDetected
            ? WorkerInterruption(
                kind: .authLimitHit,
                detectedAt: Date(),
                claudeAccountId: nil,
                resumePromptCheckpoint: lastAssistantText
            )
            : nil
        let errorMessage: String? = {
            if cancelled { return "cancelled" }
            if limitSignalDetected { return "paused: hit Anthropic monthly usage limit" }
            if ttlRescued { return nil }
            return finalSuccess ? nil : "exit \(exitCode)"
        }()
        let result = SwarmWorkerResult(
            workerId: spec.id,
            success: finalSuccess,
            finalText: finalText,
            costUSD: costUSD,
            durationSec: dur,
            exitCode: exitCode,
            errorMessage: errorMessage,
            interruption: interruption
        )
        let endSuffix: String = {
            if limitSignalDetected { return " (auth-paused)" }
            if ttlRescued { return " (TTL hit during finalization - rescued)" }
            return ""
        }()
        await emit(
            .workerEnd,
            text: "\(spec.label) ended exit=\(exitCode) cost=$\(String(format: "%.4f", costUSD)) dur=\(Int(dur))s\(endSuffix)",
            cost: costUSD
        )
        return result
    }

    // MARK: - Limit-signal detection
    //
    // Inspects every stream-json event's raw line for the synthetic
    // "monthly usage limit" markers the claude CLI emits when the active
    // account is over its quota. Sets `limitSignalDetected` exactly once per
    // run (so we don't spam the step log) and tracks the last assistant text
    // for resume-sheet copy.
    private func checkLimitSignal(in ev: StreamJSONEvent) async {
        let raw = Self.rawLine(of: ev)
        if case .assistantText(let text, _) = ev {
            lastAssistantText = text
        }
        guard !limitSignalDetected else { return }
        if LimitSignal.detect(rawLine: raw) {
            limitSignalDetected = true
            await emit(
                .authLimitDetected,
                text: "Anthropic monthly usage limit hit on the active claude account",
                payload: raw
            )
        }
    }

    private static func rawLine(of ev: StreamJSONEvent) -> String {
        switch ev {
        case .systemInit(_, _, let raw): return raw
        case .assistantText(_, let raw): return raw
        case .toolUse(_, _, let raw): return raw
        case .toolResult(_, let raw): return raw
        case .usage(_, _, _, let raw): return raw
        case .finalResult(_, _, _, let raw): return raw
        case .unknown(let raw): return raw
        }
    }

    public func cancel() async {
        cancelled = true
        if let p = process, p.isRunning {
            p.terminate()
        }
        await emit(.info, text: "cancel requested")
    }

    // MARK: - Event handling

    private struct ProcessedEvent {
        var costUSD: Double?
        var finalText: String?
        var success: Bool?
    }

    private func handleEvent(_ ev: StreamJSONEvent) async -> ProcessedEvent {
        switch ev {
        case .systemInit(let sid, _, let raw):
            await emit(.info, text: "session_id=\(sid ?? "?")", payload: raw)
            return ProcessedEvent()

        case .assistantText(let text, let raw):
            let preview = String(text.prefix(160))
            await emit(.assistantText, text: preview, payload: raw)
            return ProcessedEvent()

        case .toolUse(let name, let inputJSON, let raw):
            let prev = String(inputJSON.prefix(200))
            await emit(.toolUse, text: "\(name) \(prev)", toolName: name, payload: raw)
            return ProcessedEvent()

        case .toolResult(let text, let raw):
            let prev = String(text.prefix(200))
            await emit(.toolResult, text: prev, payload: raw)
            return ProcessedEvent()

        case .usage(let cost, _, _, let raw):
            if let c = cost {
                await emit(.usage, text: "cost=$\(String(format: "%.4f", c))", payload: raw, cost: c)
                return ProcessedEvent(costUSD: c)
            }
            return ProcessedEvent()

        case .finalResult(let text, let cost, let success, let raw):
            await emit(
                .info,
                text: "final: success=\(success) cost=$\(String(format: "%.4f", cost ?? 0)) text='\(String(text.prefix(120)))'",
                payload: raw,
                cost: cost
            )
            return ProcessedEvent(costUSD: cost, finalText: text, success: success)

        case .unknown:
            return ProcessedEvent()
        }
    }

    private func emit(
        _ kind: AgentStep.Kind,
        text: String,
        toolName: String? = nil,
        payload: String? = nil,
        cost: Double? = nil
    ) async {
        let step = AgentStep(
            workerId: spec.id,
            kind: kind,
            toolName: toolName,
            text: text,
            payloadJSON: payload,
            costUSD: cost
        )
        await observer?.worker(spec.id, didEmit: step)
    }
}
