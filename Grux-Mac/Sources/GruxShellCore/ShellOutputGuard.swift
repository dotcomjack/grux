import Foundation
import GruxGuardrails
import Darwin

// MARK: - ShellOutputGuard
//
// THE SECOND DOOR HAD NO LOCK ON THE WAY BACK OUT.
//
// `SECURITY.md` used to claim that every byte Claude reads from disk passes
// through `FilesystemTool.swift` and that there is no other path. That sentence
// was false for months and was the most load-bearing one in the document,
// because an auditor who believes it stops reading. The text was corrected on
// 2026-08-26. This file narrows the gap the corrected text now describes
// honestly.
//
// The gap, measured on 2026-08-26 against this tree: `ShellSafety.evaluate`
// blocks `cd` escapes, writes to absolute paths outside `rootDir`, and
// network-reaching commands. It allows READS outside `rootDir` on purpose,
// because a build tool that cannot read `/opt/homebrew`, `/usr/include` or a
// global package cache is not a build tool. Nothing in `Sources/GruxShellCore`
// redacted anything. So `shell_run "cat ~/.ssh/id_rsa"`, `shell_run "env"` and
// `shell_run "cat ~/.aws/credentials"` all succeeded in EVERY mode, including
// strict, and their stdout went straight back into the model's prompt verbatim,
// while `fs_read` on the identical path was refused by the denylist and written
// to the audit log. Same file, same process, opposite answers, and only one of
// the two answers left a trace.
//
// A snapshot can undo a write. Nothing undoes a read, and nothing un-sends a
// prompt. So the only control available on the read side of the shell door is
// what happens to the bytes between the PTY and the model, which is this file.
//
// ## Why this no longer owns a copy of the secret patterns
//
// It used to, and two whole sections here argued for it: `GruxShellCore` is free of
// AppKit and SwiftUI and had no dependency on the `Grux` app target, where
// `SecretRedactor` lived, so it carried a hand-maintained superset and a test parsed both
// source files to hold the drift shut. A third section argued that importing the
// high-entropy sweep would be a mistake because it redacts the output of `pwd` in a deep
// tree.
//
// ALL THREE ARE NOW FALSE, and they are recorded rather than deleted because this file's
// own opening paragraph indicts SECURITY.md for exactly this failure: a stale security
// doc that an auditor believes and then stops reading.
//
//   - The table is gone. `SecretRedactor` moved to the `grux-guardrails` package, which
//     has zero dependencies and no UI, so this target depends on it directly. No cycle,
//     nothing to invert.
//   - The parity test is gone with it. There are no longer two lists to compare, so
//     "shell is a superset of the redactor" is true by construction.
//   - The entropy sweep IS imported now, because `redact` delegates with the full pass
//     set. The old objection was measured against the app's own entropy rule, not the
//     package's, and the package rejects path-shaped tokens structurally: the benign
//     corpus, 64 fixtures including deep source paths and `ls -l` output, comes back with
//     zero mangles.
//
// The copy was not merely redundant, it had fallen behind: fourteen patterns here against
// twenty six in the package, and the parity test read GREEN because it could no longer
// find the other table and a comparison against nothing is vacuously true.

public enum ShellOutputGuard {

    /// THE PATTERN TABLE THAT USED TO BE HERE IS GONE, and its absence is the fix.
    ///
    /// This file carried a hand-copied superset of `SecretRedactor`'s patterns because
    /// `GruxShellCore` is free of AppKit and SwiftUI and had no dependency on the `Grux`
    /// app target, where `SecretRedactor` lived. A test compared the two tables and
    /// failed if this one stopped being a superset, which is a real mechanism and it
    /// worked.
    ///
    /// That reason is void as of 2026-09-06. `SecretRedactor` moved to the
    /// `grux-guardrails` package, which has zero dependencies and no UI, so this target
    /// can depend on it directly. There is no cycle and nothing to invert.
    ///
    /// Deleting the copy rather than repointing the test matters, because the copy had
    /// already fallen behind: 14 patterns here against 26 in the package. The superset
    /// invariant was broken in substance the moment the app moved, and it read GREEN,
    /// because the parser could no longer find the other table and a comparison against
    /// nothing is vacuously true. The anti-vacuity test is what caught it.
    ///
    /// So shell output now gets exactly what every other untrusted surface gets: all 26
    /// branded patterns, the generic entropy rule, and the labelled-secret rule, none of
    /// which this file has to know about.

    /// Deliberately the same marker shape `SecretRedactor` emits so the two read
    /// identically to the model. A model that sees one marker for file contents
    /// and a different one for shell output learns two rules where there is one.
    public static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        // A PURE DELEGATION, and the local secret-assignment rule is gone with it.
        //
        // That rule preserved the variable NAME and replaced only the value, so an env
        // dump still told the model WHICH credential it held. It was kept here because
        // the app's old redactor had nothing like it. The package does, tagged
        // ASSIGNED_SECRET, and it is strictly better on the case that matters:
        //
        //   DB_PASS=hunter2secret        -> DB_PASS=[REDACTED:ASSIGNED_SECRET]
        //   ANTHROPIC_API_KEY=sk-ant-... -> ANTHROPIC_API_KEY=[REDACTED:ANTHROPIC_KEY]
        //   PATH=/usr/local/bin:/usr/bin -> untouched
        //
        // The local rule flattened the second line to SECRET_ASSIGNMENT and threw the
        // specific tag away. Keeping both was tried and is worse either way round:
        // package first destroyed nothing but made the local rule dead code, local rule
        // first stole branded keys from their own tags.
        return SecretRedactor.redact(input)
    }

    /// For a string GRUX WROTE, being re-checked as defence in depth.
    ///
    /// `ShellDispatcher.dispatch` runs every tool result through the redactor a second
    /// time, and that string is mostly Grux's own: session ids, snapshot ids, and error
    /// messages it composed. Running the inferring passes over it destroys those.
    /// Measured 2026-09-06, the `shell_start` reply came back as
    ///
    ///     session_id: [REDACTED:ASSIGNED_SECRET]
    ///
    /// because `session` is in the package's credential vocabulary, correctly: an HTTP
    /// session identifier IS a credential. A Grux shell handle is not, and every call
    /// after that one failed with `session '[REDACTED:ASSIGNED_SECRET]' not found`.
    ///
    /// So this runs the passes that need EVIDENCE, a known credential format or a
    /// `user:pass@` URL, and skips the two that INFER, from a neighbouring name or from
    /// shape alone. Untrusted subprocess output still gets everything: `redact` above is
    /// what `formatRun` calls on stdout and stderr, and it runs first, so a real key in
    /// the output is already gone before this ever sees the string.
    public static func redactControlPlane(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        return SecretRedactor.redact(input, passes: .evidenceOnly)
    }

    // MARK: - Internals

    private static func replaceAll(in input: String, regex: NSRegularExpression, with replacement: String) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input, options: [], range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}

// MARK: - ShellAuditLog
//
// ONE LOG THAT ANSWERS "WHAT DID THE MODEL READ".
//
// `FilesystemToolState.audit` in `Sources/Grux/FilesystemTool.swift` writes one
// JSON object per line to `~/Library/Application Support/Grux/fs-audit.log`, and
// until now it was the only writer. That made the log answer a narrower question
// than its name suggests: it recorded every `fs_read`, including the refusals,
// and recorded nothing at all about the door that was actually open. Somebody
// reading that log after an incident would have concluded that `~/.ssh` was
// never touched, because the tool that touched it did not write a line.
//
// This writes the SAME shape to the SAME file, from `GruxShellCore`, which
// cannot call the app-target writer for the module reasons given above.
//
// ## Two writers, one file
//
// The file is therefore APPEND ONLY, ONE LINE PER WRITE, and both writers have
// to keep it that way. Nothing may rewrite, compact or truncate it in place,
// because the other writer holds no lock and would append into the middle of the
// rewrite.
//
// The app-side writer opens a `FileHandle`, calls `seekToEnd()` and then
// `write(contentsOf:)`. Those are two separate syscalls, so two concurrent
// writers can both resolve the same end offset and the second silently
// overwrites the first: the losing line is not corrupted, it is GONE, which is
// the worst failure mode an audit log has. That was safe while the actor was the
// only writer. It stops being safe the moment this file exists.
//
// So this writer does not copy that approach. It opens with `O_APPEND` and
// issues ONE `write(2)` for the whole line. POSIX makes the offset seek and the
// write atomic with respect to other appenders on an `O_APPEND` descriptor, so
// this writer can never overwrite a line the app-side writer just placed, in
// either order, with no shared lock and no shared actor. It is also why this is
// a plain function rather than an actor: serialising this writer against itself
// would buy nothing, because the writer it actually races is in another module.
//
// The remaining hazard is one-sided and named rather than hidden: the app-side
// seek-then-write can still lose a line to a concurrent append from here. Fixing
// that is a one-line change to `FilesystemToolState.audit` (same `O_APPEND`
// open), and it belongs in that file, which this change does not own.
public enum ShellAuditLog {

    /// The exact path `FilesystemToolState` derives, spelled out the same way so
    /// the two cannot drift apart. If either side moves, the log silently splits
    /// in two and each half looks complete.
    public static let logURL: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Grux", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("fs-audit.log")
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One line per command, in the `fs_read` record shape.
    ///
    /// The field names are kept identical rather than invented fresh, because a
    /// log with two schemas in it needs a reader that knows both, and the
    /// question being asked of it ("what did the model read") is one question.
    /// The mapping, which is the only part a reader has to learn:
    ///
    ///   `tool`     `shell_run` or `shell_run_confirmed`
    ///   `path`     the COMMAND, redacted and truncated. For `fs_read` the thing
    ///              requested is a path; for the shell it is a command, and this
    ///              is the field a person scans.
    ///   `resolved` the working directory the command actually ran in, which is
    ///              what turns a relative path in the command into a real one.
    ///   `outcome`  `ok`, `blocked`, `gated` or `error`, matching the verdicts
    ///              `ShellSafety` can return.
    ///   `bytes`    stdout plus stderr, counted BEFORE truncation, so the log
    ///              says how much left the machine rather than how much the
    ///              model was shown.
    ///   `reason`   the block or gate reason, empty on success.
    ///
    /// The command is redacted before it is written. A log that records
    /// `export SOME_TOKEN=...` verbatim has turned an audit trail into a second
    /// copy of the secret, on disk, in a file nothing rotates.
    /// The record, built but not written.
    ///
    /// Split out from `record` so the shape can be asserted without appending to
    /// the real log in `~/Library/Application Support`. A test that had to write
    /// to the shared file to check its own output would either pollute the
    /// operator's machine on every `swift test` or be skipped, and skipped is
    /// how an audit writer ends up silently emitting nothing.
    public static func line(tool: String,
                            command: String,
                            cwd: String,
                            outcome: String,
                            bytes: Int,
                            reason: String) -> Data? {
        let safeCommand = String(ShellOutputGuard.redact(command).prefix(500))
        let record: [String: Any] = [
            "ts": isoFormatter.string(from: Date()),
            "tool": tool,
            "path": safeCommand,
            "resolved": cwd,
            "outcome": outcome,
            "bytes": bytes,
            "reason": ShellOutputGuard.redact(reason)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return nil }
        var out = data
        out.append(0x0A)
        return out
    }

    public static func record(tool: String,
                              command: String,
                              cwd: String,
                              outcome: String,
                              bytes: Int,
                              reason: String) {
        guard let url = logURL else { return }
        guard let line = line(tool: tool, command: command, cwd: cwd,
                              outcome: outcome, bytes: bytes, reason: reason) else { return }

        // 0o600 on creation. The log names every path the model was pointed at,
        // which is a map of the user's machine even with the values redacted,
        // and the default 0o644 publishes that map to every other account on a
        // shared Mac. The mode is ignored when the file already exists, so an
        // install that predates this line keeps whatever it had.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = write(fd, base, raw.count)
        }
    }
}
