import XCTest
@testable import Grux

/// No em dash (U+2014) or en dash (U+2013) anywhere in the shipping trees.
///
/// The rule covers comments, not just user-facing copy, and until this test
/// existed nothing enforced it. `Grux-Mac/Sources` was clean because somebody
/// swept it by hand, which is not the same thing: `GruxPhone/` was never swept
/// and carried THIRTY, including two inside the iOS permission dialog strings a
/// user actually reads before granting camera and local network access. A tree
/// that is clean by habit goes dirty the moment a tree nobody remembers is added.
///
/// Scans by literal CHARACTER. `DashSanitizer` and its own tests have to talk
/// about these code points and do it with `\u{2014}` escapes, so they pass
/// without needing an exemption, and an exemption list is exactly what would rot.
///
/// This is deliberately a different guard from `DashSanitizerTests`, which is a
/// runtime filter on outbound email. That one cleans text the app generates. This
/// one cleans text the repository ships, and neither substitutes for the other.
final class NoTypographicDashesTests: XCTestCase {

    private static let extensions: Set<String> = [
        "swift", "md", "plist", "yml", "yaml", "json", "entitlements", "sh", "txt",
    ]

    struct Hit: CustomStringConvertible {
        let file: String, line: Int, text: String
        var description: String { "\(file):\(line)  \(text)" }
    }

    /// The repository root, which is the parent of the Swift package.
    static func repoRoot() throws -> URL {
        let mac = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
        return mac.deletingLastPathComponent()
    }

    /// Path prefixes that do not ship, read from the same file the extractor reads.
    static func manifestURL(repo: URL) -> URL {
        repo.appendingPathComponent("Grux-Mac/scripts/oss-exclude.txt")
    }

    static func manifestPresent(repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(repo: repo).path)
    }

    static func excludedPrefixes(repo: URL) throws -> [String] {
        let url = manifestURL(repo: repo)
        var out: [String] = []
        if manifestPresent(repo: repo) {
        let text = try String(contentsOf: url, encoding: .utf8)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { out.append(line) }
        }
        } else {
        // The published tree does not carry this manifest, because the publishing
        // toolchain does not ship. There, every file present IS a file that
        // shipped, so an empty exclusion set is the CORRECT answer rather than a
        // degraded one: it can only ever widen this scan, never narrow it. The
        // dangerous direction is a manifest that excludes too much, and that
        // cannot happen when there is no manifest at all.
        }
        // The two guards that must contain these characters to detect them, and
        // the identity scanner whose banned-word list is its whole point.
        out += [
            "Grux-Mac/scripts/extract-oss.py",
            "Grux-Mac/scripts/check-contract.py",
            "Grux-Mac/Tests/GruxTests/NoPersonalIdentityTests.swift",
            "Grux-Mac/Tests/GruxTests/NoTypographicDashesTests.swift",
        ]
        return out
    }

    static func isSkipped(_ rel: String, _ excluded: [String]) -> Bool {
        if rel.hasPrefix(".git/") || rel.contains("/.git/") { return true }
        if rel.contains(".build/") || rel.contains("DerivedData/") { return true }
        if rel.contains(".swiftpm/") || rel.contains("__pycache__/") { return true }
        return excluded.contains { rel == $0 || rel.hasPrefix($0 + "/") }
    }

    static func scan(root: URL, skipping excluded: [String] = []) throws -> [Hit] {
        var hits: [Hit] = []
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return hits }
        for case let rel as String in walker {
            guard extensions.contains((rel as NSString).pathExtension.lowercased()) else { continue }
            if isSkipped(rel, excluded) { continue }
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard text.contains("\u{2014}") || text.contains("\u{2013}") else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("\u{2014}") || line.contains("\u{2013}") {
                hits.append(Hit(file: rel,
                                line: i + 1,
                                text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return hits
    }

    /// Scans EVERYTHING THAT SHIPS, which is the repository minus
    /// `scripts/oss-exclude.txt`, and not merely the three roots the identity
    /// guard walks.
    ///
    /// The distinction is not academic. This test first shipped scanning
    /// `NoPersonalIdentityTests.shippingRoots()`, which is Sources, Tests and
    /// GruxPhone, and reported clean while SIXTY-SEVEN dashes sat just outside it
    /// in SECURITY.md, build.sh, Package.swift, LATER.md, Grux.entitlements and
    /// tools/MakeIcon.swift. That is the same gap that had left GruxPhone dirty,
    /// repeated one directory level up, and it was found by the extractor scanning
    /// its own OUTPUT rather than by anything scanning the source.
    ///
    /// Reading the exclude file means this guard and the thing that actually
    /// produces the published tree cannot disagree about what "ships" means.
    func testNoDashesAnywhereThatShips() throws {
        let repo = try Self.repoRoot()
        let excluded = try Self.excludedPrefixes(repo: repo)
        if Self.manifestPresent(repo: repo) {
        XCTAssertGreaterThan(excluded.count, 5,
            "parsed \(excluded.count) exclusions from scripts/oss-exclude.txt, which is too few. "
            + "If the file moved or its format changed this guard is scanning the wrong set.")
        }

        let hits = try Self.scan(root: repo, skipping: excluded)
        XCTAssertTrue(hits.isEmpty, """
            \(hits.count) typographic dash(es) in files that SHIP. Use a comma, a period,
            a colon, parentheses or a pipe. In a string the app shows a user, prefer a
            full stop and a second sentence over a comma splice.
            \(hits.prefix(30).map(\.description).joined(separator: "\n"))
            """)
    }

    /// Guards the guard. If the walk stops finding files this reports clean over a
    /// dirty tree, which is exactly how the first version of this test passed.
    func testTheScanActuallyReachesTheFilesItClaimsTo() throws {
        let repo = try Self.repoRoot()
        let excluded = try Self.excludedPrefixes(repo: repo)
        var seen = 0
        guard let walker = FileManager.default.enumerator(atPath: repo.path) else {
            return XCTFail("cannot enumerate the repository root")
        }
        for case let rel as String in walker {
            if Self.isSkipped(rel, excluded) { continue }
            if Self.extensions.contains((rel as NSString).pathExtension.lowercased()) { seen += 1 }
        }
        XCTAssertGreaterThan(seen, 400,
            "the shipping scan reached only \(seen) files. The repository ships several "
            + "hundred, so the walk is being cut short and the clean result above means nothing.")
    }

    /// Proves the scanner can fail. Without this the assertion above is
    /// indistinguishable from a scanner that reads nothing and reports nothing,
    /// which is how a guard ships green over a dirty tree.
    func testTheScannerActuallyDetectsAPlantedDash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-dash-plant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "// an em dash \u{2014} right here\nlet ok = \"a-hyphen is fine\"\n"
            .write(to: dir.appendingPathComponent("Plant.swift"), atomically: true, encoding: .utf8)
        try "copy with an en dash \u{2013} in prose\n"
            .write(to: dir.appendingPathComponent("Plant.md"), atomically: true, encoding: .utf8)
        try "<string>plist copy \u{2014} here</string>\n"
            .write(to: dir.appendingPathComponent("Plant.plist"), atomically: true, encoding: .utf8)

        let hits = try Self.scan(root: dir)
        XCTAssertEqual(hits.count, 3, "expected one hit per planted file, got:\n"
                       + hits.map(\.description).joined(separator: "\n"))
    }

    /// An ASCII hyphen is not a dash and must never be reported. Product copy is
    /// full of them ("2-pack", "auto-send", "playAndRecord"), and a guard that
    /// flagged those would be turned off within a day.
    func testTheScannerDoesNotFlagAsciiHyphens() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-dash-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "// auto-send, a 2-pack, well-formed, playAndRecord\nlet x = \"e-mail\"\n"
            .write(to: dir.appendingPathComponent("Clean.swift"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try Self.scan(root: dir).isEmpty)
    }

    /// The two strings iOS puts in a system dialog. Named explicitly because they
    /// are the highest-visibility copy either app ships and they are generated
    /// from `project.yml`, so a fix applied only to the plist would be silently
    /// undone the next time anybody runs xcodegen.
    func testThePhonePermissionCopyIsCleanInBothTheSourceAndTheGeneratedPlist() throws {
        let root = NoPersonalIdentityTests.phoneRoot()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path),
                          "GruxPhone is absent, so there is nothing to check")

        for rel in ["project.yml", "GruxPhone/Info.plist"] {
            let url = root.appendingPathComponent(rel)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"),
                           "\(rel) carries a typographic dash in permission copy")
            XCTAssertTrue(text.contains("NSCameraUsageDescription"),
                          "\(rel) no longer holds the usage descriptions, so this test moved "
                          + "off the thing it was written to protect")
        }
    }
}
