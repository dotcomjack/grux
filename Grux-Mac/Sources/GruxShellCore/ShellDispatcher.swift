import Foundation

// MARK: - ShellDispatcher
//
// Pure-Foundation dispatch entry point for the shell tool suite. Takes a tool
// name + dictionary of inputs (the shape Claude's tool_use blocks produce) and
// returns a flat string suitable as tool_result content.
//
// This lives in GruxShellCore so the demo harness can exercise the ENTIRE tool
// surface without linking AppKit / the Grux app. The Grux target's
// ShellToolBridge.swift wraps these dispatch calls into ClaudeTool schemas.

public enum ShellDispatcher {

    /// THE ONE EXIT. Everything this type returns to the model goes through the
    /// redactor here, and nothing returns any other way.
    ///
    /// The obvious version of this change was to redact `r.stdout` and
    /// `r.stderr` at the two places `formatRun` is called and stop. That version
    /// is wrong in a way that only shows up later: `dispatchRaw` has 28 `return`
    /// statements across six tool names, and the two carrying command output
    /// today are not a permanent fact about this file. A `shell_tail` or a
    /// `shell_read_log` added next year would come back through a return
    /// statement nobody thought to route through the guard, and the failure
    /// would be silent, because a redactor that is not called produces exactly
    /// the output of one that found nothing.
    ///
    /// Wrapping the whole switch makes coverage structural instead of
    /// remembered. The cost is that the redactor also runs over session ids,
    /// snapshot ids and error strings, which is cheap, and it is why the guard
    /// deliberately does NOT carry the generic high-entropy rule from
    /// `SecretRedactor` (see `ShellOutputGuard` for the measurement).
    ///
    /// `formatRun` redacts stdout and stderr a SECOND time, and that is not
    /// redundancy. It truncates at 4000 characters, and truncation happens
    /// before this wrapper sees the string, so a key sitting across the cut
    /// would have its head emitted as an unrecognisable fragment and its tail
    /// dropped. Redacting before the cut removes the whole key first.
    public static func dispatch(name: String, input: [String: Any]) async -> String {
        let raw = await dispatchRaw(name: name, input: input)
        return ShellOutputGuard.redact(raw)
    }

    private static func dispatchRaw(name: String, input: [String: Any]) async -> String {
        switch name {
        case "shell_start":
            let rootDir = (input["root_dir"] as? String) ?? ""
            let modeRaw = (input["mode"] as? String) ?? "guarded"
            let undoRaw = (input["undo_mode"] as? String) ?? "hybrid"
            let mirror = (input["mirror"] as? Bool) ?? true
            guard let mode = ShellMode(rawValue: modeRaw) else {
                return "error: unknown mode '\(modeRaw)' (use trust, guarded, or strict)"
            }
            guard let undoMode = ShellUndoMode(rawValue: undoRaw) else {
                return "error: unknown undo_mode '\(undoRaw)' (use perTurn or hybrid)"
            }
            do {
                let info = try await ShellSessionManager.shared.startSession(
                    rootDir: rootDir, mode: mode, undoMode: undoMode, openMirror: mirror
                )
                return formatStart(info: info)
            } catch let e as ShellToolError {
                return "error: \(e.description)"
            } catch {
                return "error: \(error.localizedDescription)"
            }

        case "shell_run":
            let sessionId = (input["session_id"] as? String) ?? ""
            let command = (input["command"] as? String) ?? ""
            let timeout = clampTimeout(input["timeout_sec"] as? Int)
            guard !sessionId.isEmpty else { return "error: session_id required" }
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return "error: command required" }
            do {
                let r = try await ShellSessionManager.shared.run(sessionId: sessionId, command: command, timeoutSec: timeout)
                audit(tool: "shell_run", command: command, result: r)
                return formatRun(r)
            } catch let e as ShellToolError {
                auditFailure(tool: "shell_run", command: command, reason: e.description)
                return "error: \(e.description)"
            } catch {
                auditFailure(tool: "shell_run", command: command, reason: error.localizedDescription)
                return "error: \(error.localizedDescription)"
            }

        case "shell_run_confirmed":
            let sessionId = (input["session_id"] as? String) ?? ""
            let command = (input["command"] as? String) ?? ""
            let timeout = clampTimeout(input["timeout_sec"] as? Int)
            guard !sessionId.isEmpty else { return "error: session_id required" }
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return "error: command required" }
            do {
                let info = try await ShellSessionManager.shared.status(sessionId: sessionId)
                if let reason = strictAllowlistRefusal(command: command, info: info) {
                    let refused = ShellRunResult(
                        sessionId: sessionId, command: command, exitCode: -1, stdout: "", stderr: "",
                        durationMs: 0, cwdAfter: info.cwd, snapshotId: nil, gated: false,
                        blocked: true, blockedReason: reason
                    )
                    // `bytes` lands on 0 because nothing ran and nothing left the
                    // machine. Putting the refusal text on stderr would inflate
                    // the field the audit log uses to say how much output escaped.
                    audit(tool: "shell_run_confirmed", command: command, result: refused)
                    return formatRun(refused, confirmed: true)
                }
                let r = try await ShellSessionManager.shared.runConfirmed(sessionId: sessionId, command: command, timeoutSec: timeout)
                audit(tool: "shell_run_confirmed", command: command, result: r)
                return formatRun(r, confirmed: true)
            } catch let e as ShellToolError {
                auditFailure(tool: "shell_run_confirmed", command: command, reason: e.description)
                return "error: \(e.description)"
            } catch {
                auditFailure(tool: "shell_run_confirmed", command: command, reason: error.localizedDescription)
                return "error: \(error.localizedDescription)"
            }

        case "shell_undo":
            let sessionId = (input["session_id"] as? String) ?? ""
            let snapshotId = input["snapshot_id"] as? String
            guard !sessionId.isEmpty else { return "error: session_id required" }
            do {
                let r = try await ShellSessionManager.shared.undo(sessionId: sessionId, to: snapshotId)
                let filesList = r.changed.isEmpty ? "(no files changed)" : r.changed.prefix(20).joined(separator: "\n  ")
                return """
                ok: undo → restored to snapshot \(r.restoredTo)
                files changed:
                  \(filesList)
                """
            } catch let e as ShellToolError {
                return "error: \(e.description)"
            } catch {
                return "error: \(error.localizedDescription)"
            }

        case "shell_status":
            let sessionId = (input["session_id"] as? String) ?? ""
            guard !sessionId.isEmpty else { return "error: session_id required" }
            do {
                let info = try await ShellSessionManager.shared.status(sessionId: sessionId)
                let snaps = (try? await ShellSessionManager.shared.listSnapshots(sessionId: sessionId)) ?? []
                return formatStatus(info: info, snaps: snaps)
            } catch let e as ShellToolError {
                return "error: \(e.description)"
            } catch {
                return "error: \(error.localizedDescription)"
            }

        case "shell_end":
            let sessionId = (input["session_id"] as? String) ?? ""
            guard !sessionId.isEmpty else { return "error: session_id required" }
            do {
                try await ShellSessionManager.shared.end(sessionId: sessionId)
                return "ok: session \(sessionId) ended"
            } catch let e as ShellToolError {
                return "error: \(e.description)"
            } catch {
                return "error: \(error.localizedDescription)"
            }

        default:
            return "error: unknown shell tool '\(name)'"
        }
    }

    // MARK: - The trust ceiling, on the path that actually reaches the shell
    //
    // THE CEILING HAS TO BIND HERE TOO, AND THIS IS THE ONLY PLACE IT CAN.
    //
    // `ShellTool.dispatch` clamps the `mode` ARGUMENT of `shell_start` against
    // the user's ceiling, and that is correct as far as it goes: the session
    // stores the clamped mode once and every later `shell_run` inherits it. It
    // is not far enough. `shell_run_confirmed` carries no `mode` argument, so
    // there is nothing at the app boundary left to rewrite, and
    // `ShellSession.runConfirmed` evaluates the command with a hardcoded
    // `mode: .trust` and then discards `.blockedStrictAllowlist` along with
    // `.requiresConfirm`. Measured 2026-08-26: a session the ceiling had pinned
    // to `strict` would run any binary at all through one `shell_run_confirmed`
    // call, and nothing anywhere checks that a prior `shell_run` was even gated,
    // so the walk-around does not need a refusal to launder. A ceiling a second
    // tool re-enters underneath is decoration, which is the whole defect the
    // ceiling exists to close, repeating one layer down.
    //
    // So the clamp on the argument stays where it is and the ENFORCEMENT lands
    // here, because the dispatcher is the only place that holds both halves: the
    // session's stored mode, which is where the ceiling actually came to rest,
    // and the command. Enforcing against `ShellTrustCeiling` itself instead
    // would be wrong even if this module could see it (it cannot, the type lives
    // in the app target). A model that asks for `strict` under a `guarded`
    // ceiling is honoured at `strict`, so the session's own mode is the binding
    // authority and the ceiling is only its upper bound. It also means
    // `ShellDemo`, which links `GruxShellCore` and calls this dispatcher
    // directly, gets the same refusal instead of a quieter surface.
    //
    // Only `.blockedStrictAllowlist` is refused. `.requiresConfirm` is passed
    // through deliberately, because that verdict IS what this tool exists to
    // answer: the user said "push it" in their own words and the network gate is
    // supposed to lift. The allowlist is a different kind of verdict. It has no
    // confirm affordance anywhere in the tool surface, `shell_run` returns it as
    // `blocked` rather than `gated`, and the response tells the model there is no
    // next step. Re-running the exact command the strict path refused, through a
    // door built for a verdict that offers one, converts a refusal into an
    // execution.
    //
    // `.blockedOutsideRoot` is left to `runConfirmed`, which already blocks it
    // and is the layer that knows the live cwd rather than the one snapshotted
    // into `info`.
    static func strictAllowlistRefusal(command: String, info: ShellSessionInfo) -> String? {
        let verdict = ShellSafety.evaluate(
            command: command, rootDir: info.rootDir, currentCwd: info.cwd, mode: info.mode
        )
        guard case .blockedStrictAllowlist(let reason) = verdict.decision else { return nil }
        return reason
    }

    // MARK: - Audit
    //
    // One line per command into the SAME log `FilesystemTool` writes, so the
    // question "what did the model read" has one answer instead of two halves.
    // Before this, the strict door recorded every refusal it issued and the
    // permissive door recorded nothing, which meant the log read as complete
    // while being silent about the only path that could actually reach
    // `~/.ssh`. See `ShellAuditLog` for the file, the record shape, and why
    // two writers sharing one file is safe here and what stays append only.
    //
    // Deliberately covers blocked and gated commands too. A command the safety
    // gate refused is still something the model tried to do, and a log of only
    // the successes cannot answer the question anybody actually asks it after
    // an incident, which is what was attempted.

    static func audit(tool: String, command: String, result r: ShellRunResult) {
        let outcome: String
        if r.blocked { outcome = "blocked" }
        else if r.gated { outcome = "gated" }
        else { outcome = "ok" }
        ShellAuditLog.record(
            tool: tool,
            command: command,
            cwd: r.cwdAfter,
            outcome: outcome,
            bytes: r.stdout.utf8.count + r.stderr.utf8.count,
            reason: r.blockedReason ?? ""
        )
    }

    /// The throwing paths. `cwd` is empty because a session that could not be
    /// resolved has none, and writing the requested one would invent a fact.
    static func auditFailure(tool: String, command: String, reason: String) {
        ShellAuditLog.record(
            tool: tool,
            command: command,
            cwd: "",
            outcome: "error",
            bytes: 0,
            reason: reason
        )
    }

    // MARK: - Formatters

    static func clampTimeout(_ raw: Int?) -> Int {
        let v = raw ?? 120
        if v < 1 { return 1 }
        if v > 900 { return 900 }
        return v
    }

    static func formatStart(info: ShellSessionInfo) -> String {
        """
        ok: session started
        session_id: \(info.sessionId)
        root_dir: \(info.rootDir)
        mode: \(info.mode.rawValue)   undo: \(info.undoMode.rawValue)   mirror: \(info.mirrorActive ? "open" : "off")
        """
    }

    static func formatRun(_ r: ShellRunResult, confirmed: Bool = false) -> String {
        if r.blocked {
            return """
            blocked: \(r.blockedReason ?? "containment")
            command: \(r.command)
            cwd: \(r.cwdAfter)
            (no changes applied - nothing to undo)
            """
        }
        if r.gated {
            return """
            gated: confirmation required before running this command
            reason: \(r.blockedReason ?? "external effect")
            command: \(r.command)
            next: ask the user to confirm, then call shell_run_confirmed with the same session_id + command
            """
        }
        let header = confirmed ? "ok (confirmed)" : "ok"
        let snap = r.snapshotId.map { " · snapshot=\($0)" } ?? ""
        // Redact BEFORE truncating. `dispatch` redacts the finished string as
        // well, but by then the cut has already happened, and a key that
        // straddles the 4000 character boundary would have its head emitted as
        // a fragment that matches no pattern and its tail dropped. Removing the
        // whole token first means the cut can only ever land on ordinary text.
        let safeStdout = ShellOutputGuard.redact(r.stdout)
        let safeStderr = ShellOutputGuard.redact(r.stderr)
        let stdoutTrimmed = safeStdout.count > 4000 ? String(safeStdout.prefix(4000)) + "\n…[truncated]" : safeStdout
        let stderrLine = safeStderr.isEmpty ? "" : "\n[stderr]\n\(safeStderr.prefix(2000))\n"
        return """
        \(header): exit=\(r.exitCode) · \(r.durationMs)ms · cwd=\(r.cwdAfter)\(snap)
        $ \(r.command)
        \(stdoutTrimmed)\(stderrLine)
        """
    }

    static func formatStatus(info: ShellSessionInfo, snaps: [ShellSnapshotRecord]) -> String {
        let snapList = snaps.isEmpty ? "(none)"
            : snaps.suffix(10).map { "  \($0.snapshotId) · \($0.trigger) · cmd#\($0.commandIndex) · \($0.label.prefix(60))" }.joined(separator: "\n")
        return """
        session_id: \(info.sessionId)
        root_dir: \(info.rootDir)
        cwd: \(info.cwd)
        mode: \(info.mode.rawValue)   undo: \(info.undoMode.rawValue)
        commands_run: \(info.commandsRun)   snapshots: \(info.snapshotsTaken)
        mirror: \(info.mirrorActive ? "open (Terminal.app)" : "off")
        started: \(info.startedAt)

        recent snapshots (newest last):
        \(snapList)
        """
    }
}
