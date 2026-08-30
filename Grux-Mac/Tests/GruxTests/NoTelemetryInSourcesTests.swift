import XCTest

/// Telemetry was removed from Grux. This proves it STAYS removed.
///
/// It replaces `testTelemetryIsOffByDefault`, which asserted that the enabled
/// flag on the config decoded to false. That test could only ever prove a
/// switch was in the off position, which is a weaker claim than the one that
/// was actually made: not a single connection point. A flag can be flipped, a
/// default can be edited, and a second code path can be added beside the one
/// the flag guards. A scan proves the capability is not in the tree at all.
///
/// Deliberately DIFFERENT from `NoTerminalInstructionsInUITests` in three ways,
/// and each difference is the point rather than an oversight:
///
///   1. It reads COMMENTS as well as code. That guard exempts developer
///      comments, correctly, because naming a shell command next to the code
///      that runs it is useful. Here there is nothing useful to say. A comment
///      naming the vendor is exactly the residue that tells a reader of a
///      public repo what used to be wired up, and one such sentence, which
///      said the strings in a test had been read off a real event in a shared
///      analytics project, is why a whole file had to be deleted rather than
///      scrubbed.
///   2. It reads EVERY file under `Sources/`, not only `.swift`. Two markdown
///      documents live under `Sources/` today, and a document is as readable
///      as code.
///   3. It reads `Package.swift`, which is not under `Sources/` at all. That
///      is the connection point that matters most and the one a source scan
///      would otherwise certify as clean: with the SDK still declared as a
///      package dependency, the vendor's code ships inside the binary no
///      matter how tidy `Sources/` reads.
///
/// `Package.resolved` is deliberately NOT scanned. It is a generated lockfile
/// that keeps a stale entry until the next resolve, so failing on it would
/// report a leak that no edit to this repo can fix.
///
/// The needles are assembled from fragments at runtime so this file does not
/// itself contain the strings it bans. Without that, a repo-wide grep for the
/// vendor name hits this guard and reports a leak that is not one, and every
/// future audit has to special-case the auditor.
final class NoTelemetryInSourcesTests: XCTestCase {

    /// The vendor name, assembled. Matched case-insensitively, which is what
    /// makes this one needle cover four of the five banned forms at once: the
    /// SDK type, the two ingest hosts, and the `grux.*` defaults keys all
    /// contain it. Those are not listed separately on purpose. A second
    /// spelling of a substring the first already matches cannot catch anything,
    /// and a longer list reads as broader coverage than it has.
    private static let vendor = "post" + "hog"

    /// The vendor's query language, assembled. This one IS genuinely separate:
    /// lowercased it does not contain the string above, so a grep for the
    /// vendor name never sees it. The protocol, its stub, and the function that
    /// ran the queries were all invisible for exactly that reason.
    private static let queryLanguage = "hog" + "ql"

    private static let banned = [vendor, queryLanguage]

    /// Tests/GruxTests/<this file> -> up three -> Grux-Mac.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func scannedFiles() throws -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let walker = fm.enumerator(at: repoRoot.appendingPathComponent("Sources"),
                                   includingPropertiesForKeys: [.isRegularFileKey])
        while let item = walker?.nextObject() as? URL {
            let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            if isFile == true { out.append(item) }
        }
        out.append(repoRoot.appendingPathComponent("Package.swift"))
        return out
    }

    /// Pure, so the scanner can be proven capable of failing without planting a
    /// file on disk.
    private func offences(in text: String, path: String) -> [String] {
        var found: [String] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lowered = rawLine.lowercased()
            for needle in Self.banned where lowered.contains(needle) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                found.append("\(path):\(index + 1) \(line)")
            }
        }
        return found
    }

    /// The scan must actually reach the tree. Without this the test passes by
    /// walking an empty directory, which is the same vacuous shape as a suite
    /// that collects zero tests and exits 0.
    func testScanReachesTheSourceTree() throws {
        let files = try scannedFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected the Grux source tree at \(repoRoot.path); found "
                             + "\(files.count) files, so the scan below proves nothing")
    }

    /// POSITIVE CONTROL, plus its negative twin.
    ///
    /// A guard that cannot fail is worse than no guard, because it reports a
    /// safety it never checked. This plants each banned form and requires the
    /// scanner to catch it, so a future reader can see the check has teeth
    /// without having to break the tree to find out.
    ///
    /// The negative half matters just as much: a scanner that flags everything
    /// is equally useless, and it is the shape a needle like "hog" on its own
    /// would produce.
    func testTheScannerCanActuallyFail() {
        let planted = [
            "import Post" + "Hog",
            "let t = Post" + "Hog" + "Telemetry.shared",
            "let url = \"https://us.i." + Self.vendor + ".com/capture\"",
            "defaults.string(forKey: \"grux." + Self.vendor + ".token\")",
            "protocol Foundry" + "Hog" + "QLQuerying: Sendable {}",
            "static func run" + "Hog" + "QL(_ query: String) {}",
        ]
        for line in planted {
            XCTAssertFalse(offences(in: line, path: "Planted.swift").isEmpty,
                           "the scanner missed a planted needle, so it cannot be "
                           + "trusted to catch a real one: \(line)")
        }

        let clean = [
            "WakeLog.shared.log(\"meta-ads: pull failed\")",
            "struct Telemetry { let sourceName = \"telemetry\" }",
            "let hog = 1  // a variable that is not the vendor",
            "evidence: [UpgradeEvidence(source: \"metrics\", detail: \"p95 4.2s\")]",
        ]
        for line in clean {
            XCTAssertTrue(offences(in: line, path: "Clean.swift").isEmpty,
                          "the scanner flagged ordinary source, which is how a guard "
                          + "gets deleted by the next person: \(line)")
        }
    }

    func testNoTelemetryReferenceSurvivesInSources() throws {
        let root = repoRoot.path
        var found: [String] = []

        for file in try scannedFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let shown = file.path.hasPrefix(root)
                ? String(file.path.dropFirst(root.count + 1))
                : file.path
            found += offences(in: text, path: shown)
        }

        XCTAssertTrue(found.isEmpty,
                      "telemetry was removed from Grux and must stay removed. A reference "
                      + "to the analytics vendor is back in the tree, in code, in a comment, "
                      + "in a document, or in the package manifest. Grux does not phone "
                      + "home, so there is no correct place for this.\n"
                      + found.joined(separator: "\n"))
    }
}
