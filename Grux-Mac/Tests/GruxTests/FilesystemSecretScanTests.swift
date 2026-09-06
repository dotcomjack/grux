import XCTest
@testable import Grux

/// `fs_read`'s secret detector, after it stopped carrying its own pattern table.
///
/// ## Why this file exists
///
/// `FilesystemTool` held a FOURTH hand-copied secret table, seven patterns against the
/// twenty six in `grux-guardrails`. It survived the 2026-09-06 consolidation because the
/// three copies everyone was looking at were the two redactors and the shell guard, and
/// nobody grepped for a fifth. An adversarial review found it.
///
/// It mattered more than the count suggests. This is a DETECTOR, not a redactor: a match
/// refuses the read and returns a blocked-error instead of bytes. So the app was refusing
/// seven shapes on the path the README calls "the only path from the model to your disk",
/// while the shell path redacted twenty six. A Google API key in a file was handed to the
/// model; the same bytes out of `shell_run` were not. That is the exact asymmetry
/// `ShellOutputGuard` was written to close, reappearing on the other side of the door.
///
/// ## Why `.evidenceOnly` and not the full pass set
///
/// A false positive here costs the user a file they are entitled to read, not a mangled
/// substring. So the two passes that INFER, from a name beside the value and from shape
/// alone, stay off. What runs is the two that work from evidence: a known credential
/// format, and a `user:pass@` URL. That is strictly better than the seven prefixes with
/// no new way to be wrong, and `testOrdinaryContentIsNotBlocked` is what holds that line.
@MainActor
final class FilesystemSecretScanTests: XCTestCase {

    /// Shapes the old seven-pattern table had no entry for at all.
    func testShapesTheOldLocalTableMissedAreNowBlocked() {
        let cases: [(String, String, String)] = [
            ("Google API key", "AIzaSy" + "A123456789012345678901" + "2345678901234", "GOOGLE_API_KEY"),
            ("Stripe live secret", "sk_live_" + "abcdefghijklm" + "nopqrstuvwx", "STRIPE_LIVE_SECRET"),
            ("HuggingFace token", "hf_" + "aBcDeFgHiJkLmNoPqRs" + "TuVwXyZ0123456789", "HUGGINGFACE_TOKEN"),
            ("Mongo URI credentials", "mongodb+srv://svc:P4ssw0rd" + "P4ssw0rd@c0.acme.mongodb.net", "URL_CREDENTIAL"),
        ]
        for (label, sample, expectedTag) in cases {
            let tag = FilesystemTool.probeContainsSecret("data: \(sample)\n")
            XCTAssertEqual(tag, expectedTag, """
                \(label) was not blocked by fs_read, or was blocked under the wrong tag.
                The audit log names the credential KIND, so the tag is part of the
                contract, not decoration.
                """)
        }
    }

    /// Everything the old table did catch must still be caught. A consolidation that
    /// trades old coverage for new coverage is not a consolidation.
    func testShapesTheOldLocalTableCaughtAreStillBlocked() {
        let cases: [(String, String, String)] = [
            ("Anthropic", "sk-ant-api0" + "3-ABCDEF0123456789abcdef", "ANTHROPIC_KEY"),
            ("AWS access key id", "AKIAIO" + "SFODNN7" + "EXAMPLE", "AWS_KEY"),
            ("GitHub PAT", "ghp_" + "abcdefghijklmnopqrst" + "uvwxyz012345", "GITHUB_TOKEN"),
            ("Slack token", "xoxb-" + "123456789012-abcd" + "efghijklmnop", "SLACK_TOKEN"),
        ]
        for (label, sample, expectedTag) in cases {
            XCTAssertEqual(FilesystemTool.probeContainsSecret("k = \(sample)"), expectedTag,
                           "\(label) stopped being blocked by fs_read")
        }
    }

    /// THE LINE THAT JUSTIFIES `.evidenceOnly`. A detector that refuses ordinary files is
    /// worse than no detector, because the user turns it off. The long base64 blob is the
    /// case that would fail if somebody widened this to the full pass set: the entropy
    /// rule takes it, and a file full of encoded data is a file people legitimately read.
    func testOrdinaryContentIsNotBlocked() {
        let cases: [(String, String)] = [
            ("swift source", "let x = 1\nfunc go() {}\n"),
            ("prose readme", "# Title\n\nSome prose about the project.\n"),
            ("long base64 blob", "data: " + String(repeating: "QUJDRA", count: 30)),
            ("a git sha", "commit " + "9f2b1ac0d4e6f8a1b" + "3c5d7e9f0a2b4c6d8e0f2a4"),
            ("a file path", "/Users/someone/Library/Application Support/Thing/cache.db"),
        ]
        for (label, sample) in cases {
            XCTAssertNil(FilesystemTool.probeContainsSecret(sample), """
                fs_read refused ordinary content (\(label)). A false positive here costs \
                somebody a file they are entitled to. If this fires because the pass set \
                was widened past .evidenceOnly, narrow it back rather than deleting this.
                """)
        }
    }

    /// The detector must not have its own table again. Structural, so reintroducing one
    /// is caught even if it happens to agree with the package on the cases above.
    func testTheDetectorHasNoLocalPatternTable() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Grux/FilesystemTool.swift"),
            encoding: .utf8)
        XCTAssertFalse(src.contains("secretPatterns"), """
            FilesystemTool has a local secret pattern table again. It had one until \
            2026-09-06, seven patterns against the package's twenty six, and the gap was \
            invisible because nothing compared them. Call the package instead.
            """)
        XCTAssertTrue(src.contains("SecretRedactor.redact"),
                      "FilesystemTool stopped calling the package's redactor")
    }
}
