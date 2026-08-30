import Foundation
import GruxMCPCore
import GruxShellCore

// MARK: - grux_shell

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// The session every `grux shell` command runs in, remembered between calls.
    ///
    /// ONE session reused, rather than one per command, and the reason is `grux undo`.
    /// `ShellSessionManager.end` calls `ShellSnapshotStore.tearDown`, which DELETES the
    /// shadow repository, so a session per command would have to either leak a bash process
    /// and a whole shadow repository every time or throw away the undo history it had just
    /// created. Reusing one keeps a single repository whose commits accumulate, which is
    /// exactly the shape `grux undo` already lists and restores.
    ///
    /// Kept out of `ShellSessionManager` deliberately. The manager holds every session,
    /// including the ones the model opened through `shell_start`, and this is a pointer at
    /// one of them rather than a second registry.
    private static var cliSessionId: String?

    /// Run a shell command through the trust ceiling, snapshotted first.
    ///
    /// ## The snapshot is NOT taken in this file, and that is the point
    ///
    /// `ShellSession.run` takes it: a baseline before the first command in a session, plus
    /// one in front of anything `ShellSafety` reads as destructive while `undoMode` is
    /// `.hybrid`. Taking a second one here would put two commits in front of one command,
    /// so `grux undo <id>` would restore a folder the person had already been shown a
    /// different id for. The whole job of this handler is to enter the app's existing path
    /// and report what it recorded.
    ///
    /// ## An empty command is a QUESTION, not a mistake
    ///
    /// `grux shell` has to tell somebody the folder, the root and the cost BEFORE it asks
    /// them to confirm, and the CLI cannot work any of that out for itself: `ShellAllowlist`
    /// reads `UserDefaults.standard`, which is the app's domain and not reliably the
    /// binary's. So a call with no command answers "here is where this would run and what it
    /// would cost", starts nothing and runs nothing. It is `textResult` rather than
    /// `textFailure` because it is a complete, true answer to that question, and a model that
    /// omitted the argument reads `needs_command` and the folder in the same reply.
    static func shell(command: String, timeoutSec: Double?) async -> [String: Any] {
        let wanted = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = shellClampTimeout(timeoutSec)
        let roots = ShellAllowlist.allowedRoots()
        let live = await shellLiveSession()
        let root = live?.rootDir ?? roots.first(where: { shellIsFolder($0) })

        if wanted.isEmpty {
            return MCPWire.textResult(jsonText(shellPlan(
                root: root, live: live, roots: roots, seconds: seconds)))
        }

        guard let root else {
            shellAudit(command: wanted, cwd: "", outcome: "blocked",
                       reason: "no allowed root", bytes: 0)
            return MCPWire.textFailure(shellNoFolderRefusal(roots: roots))
        }

        // The session, started on first use. `openMirror: false` because the person is
        // already watching the only window that matters, the terminal they typed into, and
        // a second read-only Terminal.app window opening behind it is a surprise nobody
        // asked for.
        let info: ShellSessionInfo
        if let live {
            info = live
        } else {
            do {
                // ASKED FOR AS A CLAMP OF `.trust`, NOT AS A READ OF THE CEILING, and the
                // difference is what the call site is claiming. `trust` means "the user is
                // at the keyboard", which is precisely true here: they typed the command and
                // then typed a word to confirm it. The ceiling is what lowers that, so
                // expressing it this way keeps this line correct if the clamp's rule ever
                // changes, and it reads as the request it is.
                let started = try await ShellSessionManager.shared.startSession(
                    rootDir: root,
                    mode: ShellTrustCeiling.clamp(GruxShellCore.ShellMode.trust),
                    undoMode: .hybrid,
                    openMirror: false)
                cliSessionId = started.sessionId
                info = started
            } catch let error as ShellToolError {
                shellAudit(command: wanted, cwd: root, outcome: "error",
                           reason: error.description, bytes: 0)
                return MCPWire.textFailure("Grux could not open a shell in \(root): "
                    + "\(error.description).")
            } catch {
                shellAudit(command: wanted, cwd: root, outcome: "error",
                           reason: error.localizedDescription, bytes: 0)
                return MCPWire.textFailure("Grux could not open a shell in \(root): "
                    + "\(error.localizedDescription).")
            }
        }

        // THE ALLOWLIST DECIDES, AND THIS IS THE CHECK THAT IS NOT A TAUTOLOGY. A root taken
        // from `allowedRoots()` is inside the allowlist by construction; a live session's
        // WORKING DIRECTORY is not. It moves whenever a command cds inside the folder, and
        // the list itself moves whenever somebody runs `grux remove project`, so a session
        // opened an hour ago can be sitting somewhere the person has since taken off the
        // list. Containment inside `ShellSafety` bounds a cd against the root the session
        // started with, which is the older answer, not the current one.
        guard ShellAllowlist.isInsideAllowedRoot(info.cwd) else {
            shellAudit(command: wanted, cwd: info.cwd, outcome: "blocked",
                       reason: "cwd outside every allowed root", bytes: 0)
            cliSessionId = nil
            return MCPWire.textFailure(shellOutsideRefusal(cwd: info.cwd, roots: roots))
        }

        // The Touch ID gate, on the same command class `ShellTool.dispatch` gates for the
        // model. It only bites when the ceiling is `trust`, because every lower ceiling
        // refuses these outright a few lines further down rather than running them, and
        // asking for a fingerprint in front of a refusal would be theatre.
        if info.mode == .trust,
           let effect = ShellSafety.detectNetworkOrExternalEffect(command: wanted) {
            let allowed = await SensitiveActionGate.shared.authorize(
                .shellDangerous, reason: "grux shell: \(wanted.prefix(80))")
            guard allowed else {
                shellAudit(command: wanted, cwd: info.cwd, outcome: "blocked",
                           reason: "touch id refused", bytes: 0)
                return MCPWire.textFailure("Grux asked for Touch ID before running that, "
                    + "because it reaches off this Mac (\(effect)), and the request was "
                    + "refused. Nothing ran. Run it again to be asked again, or turn the "
                    + "gate off under Security in Grux Settings.")
            }
        }

        do {
            let result = try await ShellSessionManager.shared.run(
                sessionId: info.sessionId, command: wanted, timeoutSec: seconds)
            shellAudit(command: wanted, cwd: result.cwdAfter,
                       outcome: result.blocked ? "blocked" : (result.gated ? "gated" : "ok"),
                       reason: result.blockedReason ?? "",
                       bytes: result.stdout.utf8.count + result.stderr.utf8.count)

            if result.blocked || result.gated {
                // NOT `textFailure`. The tool did exactly what it was asked: it put the
                // command in front of the gate the person's own ceiling built, and the
                // answer is the refusal. The CLI needs the reason and the kind to say which
                // of the two it was, and a refusal flattened into a sentence cannot tell a
                // strict-mode allowlist (change the ceiling) from containment (write inside
                // the folder instead), which want opposite things from the reader.
                let reason = result.blockedReason ?? "Grux would not run that."
                var extra: [String: Any] = ["ran": false, "reason": reason]
                if result.blocked {
                    // `ShellSafety` produces exactly two shapes of refusal and this is the
                    // only thing that tells them apart: `strictAllowlistBlock` writes
                    // "strict mode: '<binary>' not on allowlist", and containment writes
                    // "cd would leave rootDir" or "command writes to '<path>' which is
                    // outside rootDir". Only set on a refusal, because the gate reason is a
                    // third kind of sentence and labelling it as either would be a guess.
                    extra["blocked_kind"] = reason.hasPrefix("strict mode:")
                        ? "allowlist" : "containment"
                }
                return MCPWire.textResult(jsonText(shellOutcome(
                    info: info, result: result, roots: roots, seconds: seconds,
                    snapshot: nil, extra: extra)))
            }

            let snapshot = await shellSnapshotFor(session: info.sessionId,
                                                  taken: result.snapshotId)
            if result.exitCode < 0 {
                // THE FRAMING BROKE, which is a different fact from the command failing.
                // `splitStdout` returns -3 when the trailer that carries `exit=` never
                // arrived, so the exit status below is not the command's, and passing it
                // through as one would be a lie a script would act on. The stream is out of
                // step with the reader by then, so the session is dropped for the same
                // reason a timed out one is.
                cliSessionId = nil
                return MCPWire.textResult(jsonText(shellOutcome(
                    info: info, result: result, roots: roots, seconds: seconds,
                    snapshot: snapshot, extra: ["ran": true, "status_unreadable": true])))
            }
            return MCPWire.textResult(jsonText(shellOutcome(
                info: info, result: result, roots: roots, seconds: seconds,
                snapshot: snapshot, extra: ["ran": true])))

        } catch let error as ShellToolError {
            // A TIMEOUT IS NOT AN ERROR TO REPORT AND FORGET. `ShellSession.executeFramed`
            // throws `.runtime("command timed out after Ns waiting for marker")`, which is
            // the only signal there is: no case of `ShellToolError` distinguishes it, so the
            // message is matched rather than the case alone. What matters to the reader is
            // that the snapshot was taken BEFORE the command started and is still there, so
            // it travels with the timeout instead of being something they have to go and
            // look for.
            let timedOut = error.isShellTimeout
            let snapshot = await shellSnapshotFor(session: info.sessionId, taken: nil)
            shellAudit(command: wanted, cwd: info.cwd, outcome: "error",
                       reason: error.description, bytes: 0)
            if timedOut {
                // The shell is still chewing on the command and its output has nowhere to
                // go, so the next read on this session would collect the leftovers of this
                // one. Dropping the pointer, and NOT calling `end`, gives the next command a
                // clean session while leaving this one registered with the manager, which is
                // what keeps its snapshots restorable by `grux undo`.
                cliSessionId = nil
            }
            var payload = shellBase(info: info, roots: roots, seconds: seconds,
                                    command: wanted, snapshot: snapshot)
            payload["ran"] = true
            payload["timed_out"] = timedOut
            payload["reason"] = error.description
            return MCPWire.textResult(jsonText(payload))
        } catch {
            shellAudit(command: wanted, cwd: info.cwd, outcome: "error",
                       reason: error.localizedDescription, bytes: 0)
            return MCPWire.textFailure("That command did not finish: "
                + "\(error.localizedDescription).")
        }
    }

    // MARK: - The session

    /// The remembered session, only when it is still real, still allowed, and still the
    /// ceiling the person has set.
    ///
    /// Four things can have happened since the last command: the app never had one, the
    /// session was ended from somewhere else, the folder came off the allowlist, or the
    /// trust ceiling moved under it. All four land on the same answer, which is to start
    /// again from the list rather than to reuse a pointer that no longer means anything.
    private static func shellLiveSession() async -> ShellSessionInfo? {
        guard let id = cliSessionId else { return nil }
        guard let info = try? await ShellSessionManager.shared.status(sessionId: id) else {
            cliSessionId = nil
            return nil
        }
        guard ShellAllowlist.isInsideAllowedRoot(info.rootDir) else {
            cliSessionId = nil
            return nil
        }
        // THE CEILING IS A LIVE SETTING AND THIS SESSION FROZE ONE. `ShellSession.mode` is a
        // `let` fixed at `startSession`, and every later `run` evaluates `ShellSafety`
        // against that frozen value, so a Settings change reached nothing while this pointer
        // survived. Traced at HEAD: with the ceiling at trust, one `grux shell "echo hi"`
        // pinned a trusting session, and lowering the ceiling to strict or guarded afterwards
        // left `curl ... | sh` running on nothing but the typed confirmation, straight past
        // the gate the person had just switched back on. It read wrong the other way too:
        // raising the ceiling left the CLI printing "Ceiling: strict" over a setting that
        // said trust, and refusing work that setting now allowed. Compared against the clamp
        // rather than against `ceiling` for the reason `startSession` gives above, so this
        // asks the same question that call site asks.
        guard info.mode == ShellTrustCeiling.clamp(GruxShellCore.ShellMode.trust) else {
            // The pointer goes, `end` is not called. Same as the timeout path: the old
            // session stays registered with the manager, so its snapshots are still there
            // for `grux undo`, and the next command opens a fresh one at the ceiling that is
            // set now.
            cliSessionId = nil
            return nil
        }
        return info
    }

    /// The snapshot that puts this folder back, and whether it is this command's own.
    ///
    /// `ShellSession.run` returns an id only when it took one for THIS command: a baseline
    /// on the session's first command, and one in front of anything that looks destructive.
    /// An ordinary command in an established session takes none, and reporting nothing there
    /// would read as "there is no way back" when the session's earlier snapshots are sitting
    /// right there. So the newest one is reported instead, flagged as not this command's, and
    /// the CLI says out loud that undoing it reaches back past this command.
    private static func shellSnapshotFor(
        session id: String, taken: String?
    ) async -> (record: ShellSnapshotRecord, own: Bool)? {
        let records = (try? await ShellSessionManager.shared.listSnapshots(sessionId: id)) ?? []
        if let taken, let hit = records.first(where: { $0.snapshotId == taken }) {
            return (record: hit, own: true)
        }
        guard let newest = records.last else { return nil }
        return (record: newest, own: false)
    }

    // MARK: - Payloads

    /// What this tool would do, with nothing started and nothing run.
    private static func shellPlan(root: String?, live: ShellSessionInfo?,
                                  roots: [String], seconds: Int) -> [String: Any] {
        [
            "needs_command": true,
            "ran": false,
            "roots": roots,
            "root": root ?? "",
            "cwd": live?.cwd ?? root ?? "",
            "mode": (live?.mode ?? ShellTrustCeiling.clamp(GruxShellCore.ShellMode.trust))
                .rawValue,
            "session_live": live != nil,
            "timeout_sec": seconds,
            // Named here because it is a COST the person is owed before they confirm, and
            // only the app can see the policy that decides it.
            "asks_touch_id": SecurityPolicyStore.shared.policy
                .policy(for: .shellDangerous) == .require,
        ]
    }

    /// The fields every answer about a real command carries.
    private static func shellBase(
        info: ShellSessionInfo, roots: [String], seconds: Int, command: String,
        snapshot: (record: ShellSnapshotRecord, own: Bool)?
    ) -> [String: Any] {
        var out: [String: Any] = [
            "command": command,
            "root": info.rootDir,
            "cwd": info.cwd,
            "roots": roots,
            "mode": info.mode.rawValue,
            "session_id": info.sessionId,
            "session_live": true,
            "timeout_sec": seconds,
            "snapshot_id": "",
            "snapshot_label": "",
            "snapshot_is_for_this_command": false,
        ]
        if let snapshot {
            out["snapshot_id"] = snapshot.record.snapshotId
            out["snapshot_label"] = snapshot.record.label
            out["snapshot_is_for_this_command"] = snapshot.own
        }
        return out
    }

    private static func shellOutcome(
        info: ShellSessionInfo, result: ShellRunResult, roots: [String], seconds: Int,
        snapshot: (record: ShellSnapshotRecord, own: Bool)?, extra: [String: Any]
    ) -> [String: Any] {
        var out = shellBase(info: info, roots: roots, seconds: seconds,
                            command: result.command, snapshot: snapshot)
        out["cwd"] = result.cwdAfter
        out["exit_code"] = Int(result.exitCode)
        out["duration_ms"] = result.durationMs
        out["gated"] = result.gated
        out["blocked"] = result.blocked

        // REDACT BEFORE CLIPPING, for the reason `ShellDispatcher.formatRun` gives: a key
        // lying across the cut would have its head emitted as an unrecognisable fragment and
        // its tail dropped, so removing the whole token first means the cut can only land on
        // ordinary text. The limit is far above the 4000 characters the model's door uses,
        // because this output is going to a person who asked for it by name and a build log
        // cut at 4000 characters is useless to them, but it is still a limit: one socket
        // frame is one line, and an unbounded `cat` of a large file would be one very long
        // one.
        let (out1, clipped1) = shellClip(ShellOutputGuard.redact(result.stdout))
        let (err1, clipped2) = shellClip(ShellOutputGuard.redact(result.stderr))
        out["stdout"] = out1
        out["stderr"] = err1
        out["stdout_clipped"] = clipped1
        out["stderr_clipped"] = clipped2
        out["timed_out"] = false
        for (key, value) in extra { out[key] = value }
        return out
    }

    // MARK: - Refusals
    //
    // Both of these are `textFailure`, and both name the command that widens the allowlist
    // rather than offering to widen it. Grux never adds a folder to its own allowlist on the
    // strength of a command it was asked to run in that folder: that is the one move that
    // would turn the list into a formality.

    private static func shellNoFolderRefusal(roots: [String]) -> String {
        guard !roots.isEmpty else {
            return "Grux has no folder it is allowed to work in, so there is nowhere to run "
                + "that. Add one with grux add project <path> and it will run there."
        }
        let list = roots.map { shellShorten($0) }.joined(separator: ", ")
        return "Grux is allowed to work in \(list), and none of those folders is on this Mac "
            + "any more. Add one that is with grux add project <path>."
    }

    private static func shellOutsideRefusal(cwd: String, roots: [String]) -> String {
        let list = roots.isEmpty ? "nothing"
            : roots.map { shellShorten($0) }.joined(separator: ", ")
        return "That shell is sitting in \(shellShorten(cwd)), which is outside every folder "
            + "Grux may work in. Those are \(list). Add the one you meant with "
            + "grux add project <path>, or run the command again and Grux will start over in "
            + "a folder it is allowed to touch."
    }

    // MARK: - Small helpers

    /// The same 1 to 900 second window `ShellDispatcher.clampTimeout` holds the model to.
    /// Written again rather than shared because that function is internal to GruxShellCore,
    /// and a socket call that could pin a bash process open for a day is the thing both
    /// copies exist to refuse.
    private static func shellClampTimeout(_ raw: Double?) -> Int {
        guard let raw, raw.isFinite else { return 60 }
        return min(900, max(1, Int(raw.rounded())))
    }

    private static func shellClip(_ text: String) -> (String, Bool) {
        let limit = 200_000
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    private static func shellIsFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private static func shellShorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// One line into the SAME log `shell_run` writes, under this tool's own name.
    ///
    /// The name is what makes the log answerable afterwards: `shell_run` is the model's
    /// door and `grux_shell` is the person's, and a log that recorded them under one name
    /// could not tell "the model did this" from "somebody typed it", which is the first
    /// question anybody asks it.
    private static func shellAudit(command: String, cwd: String, outcome: String,
                                   reason: String, bytes: Int) {
        ShellAuditLog.record(tool: "grux_shell", command: command, cwd: cwd,
                             outcome: outcome, bytes: bytes, reason: reason)
    }
}

private extension ShellToolError {
    /// `executeFramed` has no timeout case to throw, so it throws `.runtime` with a sentence.
    /// Matching the sentence is not something to be pleased about, but the alternative is
    /// reporting every runtime fault as a timeout or none of them as one, and the timeout is
    /// the one a person is most likely to hit and most needs told about the snapshot.
    var isShellTimeout: Bool {
        guard case .runtime(let message) = self else { return false }
        return message.contains("timed out")
    }
}
