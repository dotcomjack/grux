import Foundation
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
// ## Why this owns its own copy of the secret patterns
//
// `GruxShellCore` is deliberately free of AppKit and SwiftUI so the demo
// harness and the tests can exercise the whole shell surface without linking
// the UI stack, and `Package.swift` gives it NO dependency on the `Grux` app
// target. `SecretRedactor` lives in `Sources/Grux/Redaction.swift`, inside that
// app target. This file therefore cannot call it, and inverting the dependency
// would mean moving a redactor that OCR, ambient transcripts and file contents
// all depend on across a module boundary to serve one new caller.
//
// So the list is duplicated, and a duplicated security list that can drift
// silently is worse than the gap it closes: the generous copy is the one people
// quote, and a missing entry produces exactly as much output as a working one.
// `Tests/GruxTests/ShellOutputGuardTests.swift` holds the drift shut by parsing
// BOTH source files at runtime and asserting that every pair in
// `SecretRedactor` appears here verbatim. That test lives in the app test
// target because it is the only target that can see both sides.
//
// ## Why the high-entropy sweep from SecretRedactor is NOT here
//
// `SecretRedactor` finishes with a generic rule: any run of 40 or more
// characters from `[A-Za-z0-9+/=_-]` spanning four character classes is
// replaced. That rule is right for the text it was written for, which is OCR
// output and file contents. It is wrong here, and importing it would have been
// the easy mistake to make while calling this file finished.
//
// Shell output is mostly PATHS. `/Users/someone/Code/repo/pkg/Sources/Feature`
// is 46 characters, is drawn entirely from that character class, and spans
// upper, lower, digit and symbol the moment any segment carries a numeral. So
// the entropy rule redacts the output of `pwd` in a deep tree, and most of the
// output of `find`, `ls -R` and any build log that prints absolute paths. A
// redactor that mangles ordinary output is worse than none, because the model
// then reasons about a directory listing that has holes in it and the user
// cannot tell why. `testAnOrdinaryDirectoryListingIsUntouched` pins that.
//
// The two shapes the entropy rule was actually earning its keep on are covered
// by named patterns instead: the body of a PEM private key (the `PEM` entry
// below matches the whole block, not just the header line, which is the
// difference between redacting `cat ~/.ssh/id_rsa` and redacting one line of
// it) and an AWS secret access key. The residual gap is honest and worth
// stating: a high-entropy credential in a shape nobody has named, printed by a
// command nobody anticipated, still reaches the model. That is a smaller gap
// than the one this file closes and it is not a reason to accept the larger.
public enum ShellOutputGuard {

    /// The tagged patterns, in one place, ordered most-specific-first.
    ///
    /// The first fourteen entries are a superset of `SecretRedactor.patterns`
    /// in `Sources/Grux/Redaction.swift`. Twelve of them are BYTE IDENTICAL to
    /// their counterparts there, deliberately, so the parity test can compare
    /// pairs rather than compare behaviour through a sample corpus that would
    /// itself need maintaining. Do not "tidy" a pattern here without making the
    /// same edit there, and do not reorder these past each other: the more
    /// specific prefixes have to win so a Stripe live key keeps its own tag.
    ///
    /// `PEM` appears TWICE on purpose. The whole-block entry runs first and eats
    /// an entire private key; the header-only entry that follows is the exact
    /// pair `SecretRedactor` carries, kept verbatim so the parity check is a
    /// plain set comparison, and it still catches an orphan header with no
    /// matching END line. Both produce the same marker, so the two redactors
    /// read identically to the model for the input they both handle.
    public static let rawPatterns: [(tag: String, pattern: String)] = [
        ("PEM", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
        ("ANTHROPIC_KEY", #"sk-ant-[A-Za-z0-9_\-]{10,}"#),
        ("OPENAI_KEY", #"sk-(?:proj-)?[A-Za-z0-9_\-]{16,}"#),
        ("AWS_KEY", #"AKIA[0-9A-Z]{16}"#),
        ("AWS_SECRET", #"aws_secret_access_key[ \t]*=[ \t]*[A-Za-z0-9/+=]{20,}"#),
        ("PEM", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("GITHUB_PAT", #"ghp_[A-Za-z0-9]{30,}"#),
        ("GITHUB_FINE_GRAINED", #"github_pat_[A-Za-z0-9_]{20,}"#),
        ("SLACK_TOKEN", #"xox[baprs]-[A-Za-z0-9\-]{20,}"#),
        ("STRIPE_LIVE_SECRET", #"sk_live_[A-Za-z0-9]{20,}"#),
        ("STRIPE_LIVE_PUBLIC", #"pk_live_[A-Za-z0-9]{20,}"#),
        ("STRIPE_LIVE_RESTRICTED", #"rk_live_[A-Za-z0-9]{20,}"#),
        ("ELEVENLABS_KEY", #"sk_[a-f0-9]{48,}"#),
        ("JWT", #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
    ]

    /// Compiled once. A pattern that fails to compile is dropped rather than
    /// crashing the app, which is the same trade `SecretRedactor` makes, and it
    /// is the reason the parity test asserts on `rawPatterns` (the source of
    /// truth) rather than on whatever survived compilation.
    private static let compiled: [(tag: String, regex: NSRegularExpression)] = {
        rawPatterns.compactMap { pair in
            (try? NSRegularExpression(pattern: pair.pattern, options: [])).map { (pair.tag, $0) }
        }
    }()

    /// The one rule that is NOT in `SecretRedactor`, kept out of `rawPatterns`
    /// for the same structural reason the entropy rule is kept out of the
    /// pattern table there: it needs its own replacement template rather than
    /// the uniform one.
    ///
    /// It exists because `shell_run "env"` is one of the three commands named in
    /// the finding, and the branded prefixes above only catch the vendors
    /// somebody thought of. An environment variable whose NAME says it holds a
    /// secret is the strongest signal available without reading the value, and
    /// it is precise: `PATH=/usr/local/bin:/usr/bin` does not match, because
    /// `PATH` contains none of the words below.
    ///
    /// The variable NAME is preserved and only the value is replaced, via the
    /// capture group. Replacing the whole assignment would tell the model
    /// nothing about which credentials the environment holds, and "is
    /// GITHUB_TOKEN set at all" is a question a build agent legitimately needs
    /// to answer without ever seeing the value.
    ///
    /// The negative lookahead keeps this idempotent. Without it, a value another
    /// pattern had already turned into `[REDACTED:ANTHROPIC_KEY]` would be
    /// matched again on the next pass and lose its specific tag. It tolerates one
    /// optional quote in front of the marker, because the quoted branches below
    /// mean a branded key can now arrive as `KEY="[REDACTED:ANTHROPIC_KEY]"`, and
    /// a lookahead anchored on the bracket alone would step over the quote,
    /// re-match, and downgrade a specific tag to the generic one.
    ///
    /// ## Why the value has four branches instead of one character class
    ///
    /// The first version of this rule spelled the value `[^\s'"=]{8,}`, which
    /// excluded both quote characters from the run. Measured against a realistic
    /// `.envrc` on 2026-08-26, that meant no match could even BEGIN after the
    /// `=`, so `export AWS_SECRET_ACCESS_KEY="wJalr..."`,
    /// `export DATABASE_PASSWORD='hunter2...'` and
    /// `SUPABASE_SERVICE_ROLE_SECRET="9f2b..."` all came back byte identical
    /// while the unquoted spelling of the same variable redacted correctly. That
    /// is the wrong half to cover: `export NAME="value"` is what `.env`, `.envrc`
    /// and shell profiles actually contain, `env` and `cat .envrc` are ordinary
    /// things for the model to run, and this rule is the ONLY one that covers a
    /// credential carrying no branded prefix, which is exactly the class an AWS
    /// secret access key, a database password and a service role secret fall
    /// into. `fs_read` refuses those dotfiles by basename, so the shell was the
    /// only door to them and it was the door that leaked.
    ///
    /// Excluding `=` was the second half of the same mistake:
    /// `DB_PASSWORD=p=ssw0rd123456` terminated the run one character in, below
    /// the eight character floor, so it did not match either. The run now stops
    /// only on whitespace or a quote.
    ///
    /// The branches are ordered closed-quote first so a terminated value is
    /// consumed WITH its quotes and the marker reads the same as the bare form.
    /// `[^"\n]` rather than `[^"]` is the false-positive guard that matters: the
    /// newline exclusion means a stray quote cannot reach forward into later
    /// lines of a build log, and stopping at the closing quote rather than at end
    /// of line means an ordinary sentence like
    /// `error: TOKEN = "expected value" but got something` loses the quoted run
    /// and keeps the rest. That residual false positive is real, named, and the
    /// price of covering the dominant real-world shape; it fails safe, because
    /// the variable name survives and the marker says who did it.
    ///
    /// The third branch catches an opening quote with no closing one on the same
    /// line, which is what a value cut short looks like. Without it a truncated
    /// line would fall back to no match at all and emit the head of a live
    /// credential.
    private static let secretAssignmentRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?i)([A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|TOKEN|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY)[A-Z0-9_]*[ \t]*=[ \t]*)(?!['"]?\[REDACTED:)(?:"[^"\n]{8,}"|'[^'\n]{8,}'|['"][^\s'"]{8,}|[^\s'"]{8,})"#,
            options: []
        )
    }()

    /// Replace every secret-shaped token with `[REDACTED:TAG]`.
    ///
    /// Deliberately the same marker shape `SecretRedactor` emits so the two read
    /// identically to the model. A model that sees one marker for file contents
    /// and a different one for shell output learns two rules where there is one.
    public static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var out = input
        for (tag, regex) in compiled {
            out = replaceAll(in: out, regex: regex, with: "[REDACTED:\(tag)]")
        }
        if let regex = secretAssignmentRegex {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(
                in: out, options: [], range: range,
                withTemplate: "$1[REDACTED:SECRET_ASSIGNMENT]"
            )
        }
        return out
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
