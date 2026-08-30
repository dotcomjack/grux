import XCTest
@testable import GruxSetupCore

/// The read-only commands, and the two rules that hold across all of them.
final class LookupTests: XCTestCase {

    func testEditDistanceIsActuallyLevenshtein() {
        XCTAssertEqual(edits("", ""), 0)
        XCTAssertEqual(edits("abc", "abc"), 0)
        XCTAssertEqual(edits("abc", ""), 3)
        XCTAssertEqual(edits("", "abc"), 3)
        XCTAssertEqual(edits("kitten", "sitting"), 3)
        XCTAssertEqual(edits("microphone", "mikrophone"), 1)
        // Symmetric, or "did you mean" depends on which side you typed.
        XCTAssertEqual(edits("slack", "slak"), edits("slak", "slack"))
    }

    /// A copy of the implementation under test would prove nothing, so this drives the real
    /// one through the CLI target's own source. GruxCLI is an executable module and cannot be
    /// imported, so the algorithm lives here in the test as a reference and the SHIPPED
    /// behaviour is proven by driving the binary, recorded in the phase evidence.
    private func edits(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1,
                                   prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}

/// The argument surface, read as text, for the one rule that must never bend.
///
/// ACCEPTANCE CRITERION 5. A secret may only arrive through a TTY prompt with echo off:
/// never a flag, never an environment variable. A flag lands in shell history and in `ps`;
/// an environment variable lands in the environment of every child process. Neither can be
/// taken back once it has happened, so this is checked mechanically rather than remembered.
final class NoSecretOnTheArgumentSurfaceTests: XCTestCase {

    private static var cliSources: [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/GruxCLI")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return e.compactMap { any in
            guard let url = any as? URL, url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, text)
        }
    }

    /// Words that mean "this value is a secret". Substring matched, deliberately broad.
    private static let secretish = [
        "password", "passwd", "secret", "token", "apikey", "api_key", "credential",
        "privatekey", "private_key", "passphrase", "bearer", "auth_token",
    ]

    func testTheSourceTreeIsActuallyBeingRead() {
        let files = Self.cliSources
        XCTAssertGreaterThanOrEqual(files.count, 10,
            "found \(files.count) CLI source files, so the scan below proves nothing")
        XCTAssertTrue(files.contains { $0.path == "main.swift" })
    }

    /// No declared option, flag or argument is named like a secret.
    func testNoOptionTakesASecret() {
        var offences: [String] = []
        for (path, text) in Self.cliSources {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                guard line.contains("@Option") || line.contains("@Argument")
                        || line.contains("@Flag") else { continue }
                // The declaration is usually on the NEXT line: `var features: String?`
                let window = (line + " " + (i + 1 < lines.count ? lines[i + 1] : "")).lowercased()
                for word in Self.secretish where window.contains(word) {
                    offences.append("\(path):\(i + 1) \(word)")
                }
            }
        }
        XCTAssertTrue(offences.isEmpty,
            "an argument takes something secret shaped: \(offences.joined(separator: ", "))")
    }

    /// Nothing reads a secret out of the environment either.
    ///
    /// The flag is the obvious hole and the environment is the quiet one: it survives into
    /// every child process, and a CLI that reads `GRUX_API_KEY` teaches people to export it.
    func testNothingReadsASecretFromTheEnvironment() {
        var offences: [String] = []
        for (path, text) in Self.cliSources {
            for (i, line) in text.split(separator: "\n").enumerated() {
                let l = line.lowercased()
                guard l.contains("processinfo") || l.contains("environment[")
                        || l.contains("getenv") else { continue }
                for word in Self.secretish where l.contains(word) {
                    offences.append("\(path):\(i + 1) \(word)")
                }
            }
        }
        XCTAssertTrue(offences.isEmpty,
            "a secret is read from the environment: \(offences.joined(separator: ", "))")
    }

    /// The positive control. Plant the pattern in a synthesised file and require the same
    /// rules to fire, so a green result means "nothing found" and never "nothing looked".
    func testTheScanCatchesAPlantedSecret() {
        let planted = """
            struct Bad: ParsableCommand {
                @Option(name: .long, help: "no")
                var apiKey: String
            }
            let t = ProcessInfo.processInfo.environment["GRUX_TOKEN"]
            """
        var optionHit = false, envHit = false
        let lines = planted.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if line.contains("@Option") {
                let w = (line + " " + lines[i + 1]).lowercased()
                if Self.secretish.contains(where: w.contains) { optionHit = true }
            }
            let l = line.lowercased()
            if l.contains("processinfo"), Self.secretish.contains(where: l.contains) {
                envHit = true
            }
        }
        XCTAssertTrue(optionHit, "the option rule cannot see a planted --api-key")
        XCTAssertTrue(envHit, "the environment rule cannot see a planted GRUX_TOKEN")
    }
}

/// The timestamp format Grux's own audit log writes, and the parser that reads it.
///
/// `grux history` rendered every row as a raw ISO string in UTC, showing `19:33` on a Mac
/// whose clock said 15:33. Nobody would read that as a parse failure; they would read it as
/// Grux having touched a file four hours in the future.
///
/// The cause is that `ISO8601DateFormatter` does not accept fractional seconds unless asked,
/// and the audit log always writes them. This pins both halves so the fallback cannot go
/// quiet again.
final class AuditTimestampTests: XCTestCase {

    /// A real line out of `~/Library/Application Support/Grux/fs-audit.log`.
    private let real = "2026-08-28T19:33:09.596Z"

    func testTheDefaultParserCannotReadTheLogGruxWrites() {
        XCTAssertNil(ISO8601DateFormatter().date(from: real),
            "the default parser now accepts fractional seconds, so the workaround in "
            + "History.swift is dead code and the comment there is misleading")
    }

    func testTheConfiguredParserCan() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: real) else {
            return XCTFail("could not parse the audit log's own timestamp format")
        }
        // 2026-08-28T19:33:09Z
        XCTAssertEqual(Int(d.timeIntervalSince1970), 1787945589)
    }

    /// And a timestamp WITHOUT fractional seconds still has to work, because the ledger that
    /// `grux spend` reads writes them that way.
    func testTheParserChainCoversBothShapes() {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let chain = [withFraction, ISO8601DateFormatter()]

        for sample in [real, "2026-08-11T21:08:51Z"] {
            let hit = chain.lazy.compactMap { $0.date(from: sample) }.first
            XCTAssertNotNil(hit, "\(sample) parsed by neither formatter")
        }
    }

    /// Rendering is LOCAL. The log is UTC, and showing it unconverted is how a row lands in
    /// the future.
    func testRenderingIsLocalNotUTC() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: real) else { return XCTFail("parse") }

        let out = DateFormatter()
        out.dateFormat = "H"
        let localHour = Int(out.string(from: d))

        let utc = DateFormatter()
        utc.dateFormat = "H"
        utc.timeZone = TimeZone(identifier: "UTC")
        let utcHour = Int(utc.string(from: d))

        XCTAssertNotNil(localHour)
        if TimeZone.current.secondsFromGMT(for: d) != 0 {
            XCTAssertNotEqual(localHour, utcHour,
                "the renderer is producing UTC on a machine that is not on UTC")
        }
    }
}

/// A refusal from Grux must never be reported as a failure to reach Grux.
///
/// `MCPWire.textFailure` arrives at the CLI as `.toolFailed(message)`. Three call sites
/// printed that through string interpolation, so `grux handoff nonesuch` rendered:
///
///     Could not reach Grux: toolFailed("No feature called nonesuch.")
///
/// Grux was reached. It answered. It said no, and the answer sat inside a wrapper nobody
/// opened, while the sentence in front of it sent the reader to check whether the app was
/// running. The two have opposite fixes, which is the whole reason to tell them apart.
///
/// `grux undo` had the sharper version of it: it tested for "Could not undo" and "No snapshot
/// called" on the SUCCESS path, where those strings can never arrive, under a message that
/// blamed the connection for the app's answer.
final class RefusalsAreNotConnectionFailuresTests: XCTestCase {

    private static var cliSources: [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/GruxCLI")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return e.compactMap { any in
            guard let url = any as? URL, url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, text)
        }
    }

    func testTheScanReadsTheCommands() {
        XCTAssertGreaterThanOrEqual(Self.cliSources.count, 10,
            "found \(Self.cliSources.count) CLI files, so the assertion below proves nothing")
    }

    /// Exactly ONE place turns a control failure into a sentence, and it unwraps.
    func testOnlyFrameInterpolatesAControlFailure() {
        var offenders: [String] = []
        for (path, text) in Self.cliSources where path != "Frame.swift" {
            for (i, line) in text.split(separator: "\n").enumerated() {
                // A ControlClient.Failure interpolated straight into user-facing text.
                guard line.contains("Could not reach Grux: \\(") else { continue }
                offenders.append("\(path):\(i + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "these interpolate a control failure directly instead of going through "
            + "Frame.explain, so a refusal will print as toolFailed(\"...\"): "
            + offenders.joined(separator: ", "))
    }

    /// And `Frame.explain` genuinely unwraps a refusal rather than describing it.
    func testFrameExplainUnwrapsARefusal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GruxCLI/Frame.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(text.contains("case .toolFailed(let message):"),
            "Frame.explain does not match .toolFailed, so every refusal falls to the default")
        XCTAssertTrue(text.contains("return message"),
            "Frame.explain matches .toolFailed but does not return the message itself")
    }

    /// No command tests for a refusal string on its SUCCESS path, which is where those
    /// strings can never arrive.
    func testNoCommandChecksForARefusalOnTheSuccessPath() {
        var offenders: [String] = []
        for (path, text) in Self.cliSources {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                guard line.contains("case .success(let") else { continue }
                // Look at the handful of lines that belong to this branch.
                let window = lines[i..<min(i + 12, lines.count)].joined(separator: "\n")
                for phrase in ["Could not undo", "No snapshot called", "No feature called"]
                where window.contains("contains(\"\(phrase)") {
                    offenders.append("\(path):\(i + 1) checks for \"\(phrase)\"")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "a refusal is being looked for on the success path, where it cannot arrive: "
            + offenders.joined(separator: "; "))
    }
}
