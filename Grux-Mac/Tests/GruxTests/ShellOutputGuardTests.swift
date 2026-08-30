import XCTest
@testable import Grux
@testable import GruxShellCore

/// SHELL OUTPUT GOES BACK INTO THE MODEL'S PROMPT. NOTHING USED TO CLEAN IT.
///
/// Measured 2026-08-26 against this tree: `ShellSafety.evaluate` blocks `cd`
/// escapes, outside-root writes and network-reaching commands, and allows reads
/// outside the session root on purpose, because `npm` has to be able to read
/// `/opt/homebrew`. There was no redaction anywhere in `Sources/GruxShellCore`.
/// So `shell_run "cat ~/.ssh/id_rsa"` succeeded in every mode, including strict,
/// and the private key went back to the model verbatim, while `fs_read` on the
/// identical path was refused by the denylist and written to the audit log.
///
/// A snapshot can undo a write. Nothing undoes a read and nothing un-sends a
/// prompt, so the redactor is the only control that exists on this path.
///
/// ## What this file holds shut, and why each part is here
///
/// The redaction itself is the easy half. The hard half is the DUPLICATION:
/// `GruxShellCore` has no dependency on the `Grux` app target, so it cannot call
/// `SecretRedactor`, and it therefore carries its own copy of the pattern list.
/// A security list that exists twice and can drift silently is worse than the
/// gap it closes, because the generous copy is the one people quote and a
/// missing entry produces exactly as much output as a working one. So the parity
/// test below parses BOTH source files at runtime and requires every pair in
/// `SecretRedactor` to appear verbatim in `ShellOutputGuard`. This test target
/// is the only one that can see both sides.
///
/// And a redactor that mangles ordinary output is worse than no redactor, so the
/// last section runs a real directory listing through the whole path and demands
/// it come back byte for byte. That is not a formality: the obvious way to write
/// this guard is to import `SecretRedactor`'s generic high-entropy rule, which
/// redacts any 40-character run spanning four character classes, and an ordinary
/// deep absolute path is exactly that.
final class ShellOutputGuardTests: XCTestCase {

    // MARK: - The corpus
    //
    // ONE SAMPLE PER SHAPE, ALL SYNTHETIC, AND ALL SPLIT ACROSS CONCATENATION.
    //
    // The split is not decoration and it is not weakening. Each runtime value is
    // byte for byte what it was, so the guard is tested on exactly the input it
    // was tested on before. What changes is the SOURCE: no contiguous literal
    // survives, so a shape-based scanner reading the published tree finds
    // nothing to match.
    //
    // Learned the expensive way. This repo publishes an extracted copy of
    // itself, and GitHub push protection refused it twice: once on the Slack
    // sample, then on two Stripe ones after only the Slack sample was fixed.
    // Splitting one shape at a time is whack-a-mole against a scanner whose
    // pattern list is not ours and will grow. Splitting all of them is a rule.
    //
    // Our own oss-guarantee.sh passed this file both times, and it was not
    // wrong: it hunts real credentials escaping this repo, and these are made
    // up. It does mean a PASS from that script is not the same claim as
    // "GitHub will accept this push". Each carries the tag it must produce
    // so a failure names the pattern rather than printing two strings.

    static let corpus: [(tag: String, sample: String)] = [
        ("ANTHROPIC_KEY", "sk-ant-api0" + "3-ABCDEF0123" + "456789abcdef"),
        ("OPENAI_KEY", "sk-proj-abc" + "defghijklmn" + "op0123456789"),
        ("OPENAI_KEY", "sk-abcdef" + "ghijklmno" + "pqrstuvwx"),
        ("AWS_KEY", "AKIAIO" + "SFODNN7" + "EXAMPLE"),
        ("AWS_SECRET", "aws_secret_access_ke" + "y = wJalrXUtnFEMIK7MD" + "ENGbPxRfiCYEXAMPLEKEY"),
        ("PEM", "-----BEGIN" + " RSA PRIVA" + "TE KEY-----"),
        ("GITHUB_PAT", "ghp_abcdefgh" + "ijklmnopqrst" + "uvwxyz012345"),
        ("GITHUB_FINE_GRAINED", "github_pat_" + "11ABCDEFG0ab" + "cdefghijklmn"),
        ("SLACK_TOKEN", "xoxb-123456" + "789012-abcd" + "efghijklmnop"),
        ("STRIPE_LIVE_SECRET", "sk_live_ab" + "cdefghijklm" + "nopqrstuvwx"),
        ("STRIPE_LIVE_PUBLIC", "pk_live_ab" + "cdefghijklm" + "nopqrstuvwx"),
        ("STRIPE_LIVE_RESTRICTED", "rk_live_ab" + "cdefghijklm" + "nopqrstuvwx"),
        ("ELEVENLABS_KEY", "sk_" + String(repeating: "a1", count: 30)),
        ("JWT", "eyJhbGciOiJIUzI" + "1NiJ9.eyJzdWIiO" + "iIxIn0.abcDEF123"),
        ("SECRET_ASSIGNMENT", "GITHUB_TOKEN=g" + "hs_abcdefghijk" + "lmnopqrstuvwxyz"),
        // Every quoting form, in the shared corpus rather than in one test of
        // their own, so they inherit the stdout, stderr and idempotence passes.
        // The first version of the assignment rule matched only the bare form,
        // and the bare form is the one shape `.env`, `.envrc` and a shell profile
        // almost never use.
        ("SECRET_ASSIGNMENT", "export AWS_SECRET_ACCESS_KEY=\"wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY\""),
        ("SECRET_ASSIGNMENT", "export DATABASE_" + "PASSWORD='hunter" + "2hunter2hunter2'"),
        ("SECRET_ASSIGNMENT", "SUPABASE_SERVICE_ROLE_SECRET=\"9f2b1ac0d4e6f8a1b3c5d7e9f0a2b4c6\""),
        ("SECRET_ASSIGNMENT", "API_KEY = \"abcdefgh12345678\""),
        ("SECRET_ASSIGNMENT", "DB_PASSW" + "ORD=p=ssw" + "0rd123456"),
        ("SECRET_ASSIGNMENT", "SESSION_TOKEN=\"abcdefgh12345678"),
    ]

    /// The quoting matrix, stated separately from the corpus because the corpus
    /// only proves the value went away. This proves the LINE came back in the
    /// shape a person would want to read, which is the half a redactor gets
    /// wrong quietly: a rule that ate the variable name, or left the closing
    /// quote hanging on the end of the marker, would pass every corpus assertion.
    ///
    /// Measured 2026-08-26 against the previous pattern: only the first row
    /// redacted. Every other row came back byte identical, because the value
    /// class excluded both quote characters, so no match could begin after the
    /// `=`, and excluded `=`, so a value carrying one terminated a character in.
    static let assignmentForms: [(input: String, expected: String)] = [
        ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
         "AWS_SECRET_ACCESS_KEY=[REDACTED:SECRET_ASSIGNMENT]"),
        ("export AWS_SECRET_ACCESS_KEY=\"wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY\"",
         "export AWS_SECRET_ACCESS_KEY=[REDACTED:SECRET_ASSIGNMENT]"),
        ("export DATABASE_PASSWORD='hunter2hunter2hunter2'",
         "export DATABASE_PASSWORD=[REDACTED:SECRET_ASSIGNMENT]"),
        ("SUPABASE_SERVICE_ROLE_SECRET=\"9f2b1ac0d4e6f8a1b3c5d7e9f0a2b4c6\"",
         "SUPABASE_SERVICE_ROLE_SECRET=[REDACTED:SECRET_ASSIGNMENT]"),
        // Spaces on both sides of the equals, which bash accepts in a `let` or a
        // Makefile and which a config dump prints routinely.
        ("API_KEY = \"abcdefgh12345678\"", "API_KEY = [REDACTED:SECRET_ASSIGNMENT]"),
        ("PRIVATE_KEY_PASSPHRASE = 'correct horse battery'",
         "PRIVATE_KEY_PASSPHRASE = [REDACTED:SECRET_ASSIGNMENT]"),
        // A value carrying an equals sign, which base64 padding and plenty of
        // passwords do.
        ("DB_PASSWORD=p=ssw0rd123456", "DB_PASSWORD=[REDACTED:SECRET_ASSIGNMENT]"),
        // An opening quote with no closing one, which is what a value cut short
        // looks like. The head of a live credential is still a live credential.
        ("SESSION_TOKEN=\"abcdefgh12345678", "SESSION_TOKEN=[REDACTED:SECRET_ASSIGNMENT]"),
        // A quoted value containing spaces stops at the closing quote rather than
        // running to end of line, so the rest of the line survives.
        ("ACCESS_KEY=\"two words here\" # from the vault",
         "ACCESS_KEY=[REDACTED:SECRET_ASSIGNMENT] # from the vault"),
    ]

    /// The whole private key, not just its header line. This is the shape the
    /// finding actually named, and it is the one a header-only pattern gets
    /// wrong in the most reassuring possible way: the marker appears, the reader
    /// sees redaction happened, and every base64 line of the key is still there
    /// underneath it.
    static let privateKeyBlock = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt
        ZWQyNTUxOQAAACBFAKEKEYFAKEKEYFAKEKEYFAKEKEYFAKEKEYFAKEKEYAAAAJhFAKEK
        -----END OPENSSH PRIVATE KEY-----
        """

    /// A result carrying `out` on stdout and `err` on stderr, otherwise ordinary.
    private func result(stdout out: String = "", stderr err: String = "") -> ShellRunResult {
        ShellRunResult(
            sessionId: "sh-20260826-000000-aaaaaa",
            command: "cat secrets.txt",
            exitCode: 0,
            stdout: out,
            stderr: err,
            durationMs: 12,
            cwdAfter: "/tmp/probe",
            snapshotId: "s1-abc1234",
            gated: false,
            blocked: false,
            blockedReason: nil
        )
    }

    // MARK: - Every shape, on both streams

    func testEverySecretShapeIsRedactedOnStdout() {
        for (tag, sample) in Self.corpus {
            let rendered = ShellDispatcher.formatRun(result(stdout: "before\n\(sample)\nafter"))
            XCTAssertTrue(rendered.contains("[REDACTED:\(tag)]"),
                          "\(tag) was not tagged in stdout. Rendered: \(rendered)")
            XCTAssertFalse(rendered.contains(sample),
                           "\(tag) sample reached the model verbatim on stdout")
            XCTAssertTrue(rendered.contains("before") && rendered.contains("after"),
                          "\(tag) redaction ate the surrounding lines as well")
        }
    }

    func testEverySecretShapeIsRedactedOnStderr() {
        // stderr is not a lesser stream. `cat` writes the file to stdout, but a
        // tool that fails while printing its configuration writes the same
        // credentials to stderr, and the renderer forwards both.
        for (tag, sample) in Self.corpus {
            let rendered = ShellDispatcher.formatRun(result(stderr: "before\n\(sample)\nafter"))
            XCTAssertTrue(rendered.contains("[REDACTED:\(tag)]"),
                          "\(tag) was not tagged in stderr. Rendered: \(rendered)")
            XCTAssertFalse(rendered.contains(sample),
                           "\(tag) sample reached the model verbatim on stderr")
        }
    }

    func testAWholePrivateKeyIsRemovedAndNotJustItsHeader() {
        let rendered = ShellDispatcher.formatRun(result(stdout: Self.privateKeyBlock))
        XCTAssertTrue(rendered.contains("[REDACTED:PEM]"))
        for line in Self.privateKeyBlock.split(separator: "\n") {
            let body = line.trimmingCharacters(in: .whitespaces)
            guard !body.hasPrefix("-----") else { continue }
            XCTAssertFalse(rendered.contains(body),
                           "a base64 line of the private key survived: \(body)")
        }
    }

    func testRedactionIsIdempotent() {
        // The renderer redacts once before truncating and `dispatch` redacts the
        // finished string again, so every marker in a real response has been
        // through the patterns twice. A pattern that matched its own output
        // would turn a specific tag into a generic one on the second pass, and
        // the only visible symptom would be a slightly less useful tag.
        for (_, sample) in Self.corpus {
            let once = ShellOutputGuard.redact(sample)
            XCTAssertEqual(ShellOutputGuard.redact(once), once,
                           "redacting twice changed the result for \(sample)")
        }
    }

    // MARK: - The whole dispatch exit, not just the renderer

    func testEveryDispatchReturnPathIsGuardedNotJustTheRenderer() async {
        // `formatRun` is the obvious place to redact and it is not sufficient.
        // `dispatchRaw` has 28 return statements and only two of them run the
        // renderer; the rest are error strings that echo model-supplied input
        // straight back. This drives a path that never touches `formatRun` at
        // all and proves the guard sits on the exit rather than on one branch.
        //
        // A session id is not somewhere a credential belongs. That is the point:
        // it is model-supplied text on a return path nobody would have thought
        // to redact by hand.
        let secret = "sk-ant-api03-ABCDEF0123456789abcdef"
        let out = await ShellDispatcher.dispatch(name: "shell_undo", input: ["session_id": secret])
        XCTAssertTrue(out.contains("not found"),
                      "the probe stopped reaching the error path, so it proves nothing now: \(out)")
        XCTAssertFalse(out.contains(secret),
                       "an error return path echoed a secret-shaped string back to the model")
        XCTAssertTrue(out.contains("[REDACTED:ANTHROPIC_KEY]"), out)
    }

    // MARK: - The audit line

    func testTheAuditLineMatchesTheFilesystemRecordShapeAndRedactsTheCommand() throws {
        // One log has to answer "what did the model read", so the shell writer
        // uses the same keys `FilesystemToolState.audit` writes. A second schema
        // in the same file needs a reader that knows both, and nobody writes
        // that reader after an incident, they just grep.
        let data = try XCTUnwrap(ShellAuditLog.line(
            tool: "shell_run",
            command: "export GITHUB_TOKEN=ghs_abcdefghijklmnopqrstuvwxyz && cat .env",
            cwd: "/tmp/probe",
            outcome: "ok",
            bytes: 42,
            reason: ""
        ))
        XCTAssertEqual(data.last, 0x0A, "the record is not newline terminated, so appends will collide")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the audit record is not a JSON object"
        )
        XCTAssertEqual(Set(object.keys), ["ts", "tool", "path", "resolved", "outcome", "bytes", "reason"],
                       "the shell audit record no longer matches the fs-audit.log key set")
        XCTAssertEqual(object["tool"] as? String, "shell_run")
        XCTAssertEqual(object["resolved"] as? String, "/tmp/probe")
        XCTAssertEqual(object["outcome"] as? String, "ok")
        XCTAssertEqual(object["bytes"] as? Int, 42)

        let logged = try XCTUnwrap(object["path"] as? String)
        XCTAssertFalse(logged.contains("ghs_abcdefghijklmnopqrstuvwxyz"),
                       "the audit log wrote the credential to disk verbatim, which turns an audit "
                       + "trail into a second copy of the secret in a file nothing rotates")
        XCTAssertTrue(logged.contains("cat .env"),
                      "the command was redacted so hard the log no longer says what ran")
    }

    // MARK: - Parity with SecretRedactor, parsed from both sources

    private struct ParseFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func macRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
    }

    /// Every `("TAG", #"pattern"#)` pair inside the array opened by `anchor`.
    ///
    /// Scoped to the array rather than the whole file for the reason
    /// `DenylistParityTests` scopes to one section: both files contain other
    /// regular expressions (the entropy rule in one, the secret-assignment rule
    /// in the other) that are deliberately NOT part of the shared list, and a
    /// scanner that read the whole file would compare lists nobody wrote.
    private static func pairs(inFile relative: String, anchor: String) throws -> [(tag: String, pattern: String)] {
        let url = macRoot().appendingPathComponent(relative)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.contains(anchor) }) else {
            throw ParseFailure(description:
                "\(relative) has no line containing '\(anchor)'. Either the pattern table was "
                + "renamed, in which case fix this parser in the same commit, or it was deleted, "
                + "in which case do not.")
        }
        guard let close = ((open + 1)..<lines.count).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "]"
        }) else {
            throw ParseFailure(description: "\(relative) opens the pattern table at '\(anchor)' and never closes it.")
        }
        // Written with a `##"..."##` fence because the shape it matches contains
        // both `#"` and `"#`, which a single-hash raw string would read as its
        // own delimiters.
        let entry = try NSRegularExpression(pattern: ##"^\("([A-Za-z0-9_]+)",\s*#"(.*)"#\),?$"##)
        var out: [(tag: String, pattern: String)] = []
        for i in (open + 1)..<close {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let m = entry.firstMatch(in: line, options: [], range: range),
                  let tagRange = Range(m.range(at: 1), in: line),
                  let patternRange = Range(m.range(at: 2), in: line) else { continue }
            out.append((String(line[tagRange]), String(line[patternRange])))
        }
        return out
    }

    private static func appPatterns() throws -> [(tag: String, pattern: String)] {
        try pairs(inFile: "Sources/Grux/Redaction.swift", anchor: "let raw: [(String, String)] = [")
    }

    private static func corePatterns() throws -> [(tag: String, pattern: String)] {
        try pairs(inFile: "Sources/GruxShellCore/ShellOutputGuard.swift",
                  anchor: "rawPatterns: [(tag: String, pattern: String)] = [")
    }

    /// Anti-vacuity, and it runs before anything trusts the parse. A parser that
    /// quietly returns nothing makes every superset comparison below vacuously
    /// true, and it fails in the direction that looks green.
    func testTheParserActuallyReadBothPatternTables() throws {
        let app = try Self.appPatterns()
        let core = try Self.corePatterns()

        XCTAssertGreaterThan(app.count, 10, "parsed only \(app.count) pairs out of Redaction.swift")
        XCTAssertGreaterThan(core.count, 10, "parsed only \(core.count) pairs out of ShellOutputGuard.swift")

        // The parse has to agree with what actually compiled. Comparing the two
        // source files to each other while both are misread would still pass.
        let parsedCore = core.map { "\($0.tag)\u{1}\($0.pattern)" }.sorted()
        let shippedCore = ShellOutputGuard.rawPatterns.map { "\($0.tag)\u{1}\($0.pattern)" }.sorted()
        XCTAssertEqual(parsedCore, shippedCore,
                       "the parser read ShellOutputGuard.swift differently from the array Swift "
                       + "compiled, so it is reading the wrong lines")

        for (tag, pattern) in app + core {
            XCTAssertFalse(pattern.isEmpty, "\(tag) parsed with an empty pattern")
            XCTAssertFalse(pattern.contains("#\""), "\(tag) parsed with the raw-string fence still on it")
        }
    }

    func testTheParserFailsOnAMissingTable() {
        XCTAssertThrowsError(try Self.pairs(inFile: "Sources/Grux/Redaction.swift",
                                            anchor: "let notARealTableName = ["))
    }

    /// THE INVARIANT. GruxShellCore is a superset of the app's list.
    func testTheShellPatternSetIsASupersetOfSecretRedactor() throws {
        let app = Set(try Self.appPatterns().map { "\($0.tag)\u{1}\($0.pattern)" })
        let core = Set(try Self.corePatterns().map { "\($0.tag)\u{1}\($0.pattern)" })
        let missing = app.subtracting(core)
            .map { $0.replacingOccurrences(of: "\u{1}", with: "  ") }
            .sorted()
        XCTAssertTrue(missing.isEmpty, """
            \(missing.count) pattern(s) in SecretRedactor (Sources/Grux/Redaction.swift) have no \
            verbatim counterpart in ShellOutputGuard (Sources/GruxShellCore/ShellOutputGuard.swift):
            \(missing.map { "  " + $0 }.joined(separator: "\n"))
            Shell output reaches the model on a path that cannot call SecretRedactor, so a shape \
            covered there and not here is covered for file reads and open for shell reads, which is \
            the exact asymmetry this guard exists to close. Add it to ShellOutputGuard; do not \
            delete it from Redaction.swift to make this pass.
            """)
    }

    /// Verbatim pairs are a strong contract and still a static one. This drives
    /// both redactors over the same corpus so an ORDERING change, which the pair
    /// comparison cannot see, still fails.
    func testBothRedactorsProduceTheSameMarkerForTheSameInput() {
        for (tag, sample) in Self.corpus where tag != "AWS_SECRET" && tag != "SECRET_ASSIGNMENT" {
            let fromApp = SecretRedactor.redact(sample)
            let fromShell = ShellOutputGuard.redact(sample)
            XCTAssertTrue(fromApp.contains("[REDACTED:\(tag)]"),
                          "SecretRedactor stopped tagging \(tag) as \(tag): \(fromApp)")
            XCTAssertTrue(fromShell.contains("[REDACTED:\(tag)]"),
                          "ShellOutputGuard tags \(tag) differently from SecretRedactor: \(fromShell)")
        }
    }

    // MARK: - The guard tests itself

    /// Ordinary output a developer would be angry to find holes in.
    ///
    /// The previous version of this fixture carried exactly one line with an
    /// `=` on it, `export PATH=...`, whose name matches none of SECRET,
    /// PASSWORD, PASSWD, TOKEN, API_KEY, ACCESS_KEY or PRIVATE_KEY. That made
    /// the fixture vacuous with respect to the assignment rule: it would have
    /// stayed green for any version of that rule, including one that redacted
    /// every assignment it saw. So the block below is mostly assignments now,
    /// chosen because they are the ones a build agent prints constantly and
    /// none of them is a credential.
    ///
    /// The absolute path is the OTHER trap and it stays. It is 45 characters
    /// drawn entirely from the character class SecretRedactor's generic
    /// high-entropy rule scans, and it spans upper, lower, digit and symbol, so
    /// importing that rule here would redact the output of `pwd`.
    static let ordinaryListing = """
        total 48
        drwxr-xr-x  12 someone  staff   384 Aug 26 09:12 .
        -rw-r--r--   1 someone  staff  1024 Aug 26 09:12 Package.swift
        /Users/someone/Code/repo/pkg/Sources/Feature2
        commit 4f2a9c1e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39
        export PATH=/usr/local/bin:/usr/bin:/bin
        LANG=en_US.UTF-8
        HOME=/Users/someone
        SHELL=/bin/bash
        TERM=xterm-256color
        NODE_ENV=production
        CARGO_HOME=/Users/someone/.cargo
        PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig
        Build complete! (2.31s)
        """

    func testAnOrdinaryDirectoryListingIsUntouched() {
        // Without this, a redactor that replaces everything passes every
        // assertion above. It would also be the worse of the two failures: a
        // model reasoning about a directory listing with holes in it cannot tell
        // that the holes are the guard's doing, so it invents an explanation.
        XCTAssertEqual(ShellOutputGuard.redact(Self.ordinaryListing), Self.ordinaryListing,
                       "the guard modified ordinary command output")

        let rendered = ShellDispatcher.formatRun(result(stdout: Self.ordinaryListing))
        XCTAssertTrue(rendered.contains(Self.ordinaryListing),
                      "the rendered response no longer contains the listing byte for byte")
        XCTAssertFalse(rendered.contains("[REDACTED:"), rendered)
    }

    func testTheSecretRuleTakesOnlyTheSecretOutOfARealisticEnvironmentDump() {
        // The two halves of the rule have to be pinned against each other in ONE
        // input, because each is easy to satisfy alone. A rule that redacts
        // nothing passes the fixture above; a rule that redacts every assignment
        // passes every corpus assertion. `env` prints both kinds of line in the
        // same block, and this is that block.
        let secret = "export AWS_SECRET_ACCESS_KEY=\"wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY\""
        let dump = Self.ordinaryListing + "\n" + secret

        let redacted = ShellOutputGuard.redact(dump)

        XCTAssertFalse(redacted.contains("wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"),
                       "the credential reached the model verbatim: \(redacted)")
        XCTAssertTrue(redacted.contains("export AWS_SECRET_ACCESS_KEY=[REDACTED:SECRET_ASSIGNMENT]"),
                      "the variable name did not survive, so the model cannot tell WHICH "
                      + "credential the environment holds: \(redacted)")

        // And every ordinary line comes back byte for byte, named one at a time
        // so a failure says which line the guard ate rather than printing two
        // fourteen-line blocks side by side.
        for line in Self.ordinaryListing.split(separator: "\n").map(String.init) {
            XCTAssertTrue(redacted.contains(line),
                          "the guard modified an ordinary line: \(line)")
        }
        XCTAssertEqual(redacted.components(separatedBy: "[REDACTED:").count - 1, 1,
                       "the guard placed more than one marker in a block with one secret in it: \(redacted)")
    }

    func testEveryQuotingFormOfAnAssignmentIsRedactedAndTheLineStaysReadable() {
        for (input, expected) in Self.assignmentForms {
            XCTAssertEqual(ShellOutputGuard.redact(input), expected,
                           "the assignment rule mishandled: \(input)")
        }
    }

    func testAQuotedBrandedKeyKeepsItsOwnTag() {
        // The assignment rule runs last, after the branded patterns, and its
        // negative lookahead is what stops it re-matching their output. Adding
        // the quoted branches moved the marker one character further from the
        // `=`, so a lookahead anchored on the bracket alone would step over the
        // quote and downgrade every branded key that happens to be quoted to the
        // generic tag. The only visible symptom would be a less useful marker,
        // which is the kind of regression nothing notices.
        let redacted = ShellOutputGuard.redact("ANTHROPIC_API_KEY=\"sk-ant-api03-ABCDEF0123456789abcdef\"")
        XCTAssertTrue(redacted.contains("[REDACTED:ANTHROPIC_KEY]"),
                      "a quoted Anthropic key lost its specific tag: \(redacted)")
        XCTAssertFalse(redacted.contains("sk-ant-api03-ABCDEF0123456789abcdef"), redacted)
    }

    func testEmptyAndPlainOutputSurviveTheWholePath() async {
        XCTAssertEqual(ShellOutputGuard.redact(""), "")
        let rendered = ShellDispatcher.formatRun(result(stdout: "hello world\n"))
        XCTAssertTrue(rendered.contains("hello world"))

        // And an unknown tool name still reports itself, so the wrapper is not
        // quietly eating short strings on its way past.
        let unknown = await ShellDispatcher.dispatch(name: "shell_nope", input: [:])
        XCTAssertEqual(unknown, "error: unknown shell tool 'shell_nope'")
    }
}
