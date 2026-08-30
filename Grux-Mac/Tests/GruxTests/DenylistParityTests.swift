import XCTest
@testable import Grux

/// The denylist in `FilesystemTool.swift` and the denylist in `SECURITY.md`
/// section 5 have to be the same list. Until this test existed they were not.
///
/// Measured 2026-08-26, before the repair: the document promised seven path
/// segments, nine file names and three extensions that the code had never
/// implemented, and the code carried five entries the document never mentioned.
/// Somebody auditing the app read section 5, saw `.gnupg`, `.kube` and
/// `credentials.json` listed as refused, and had no way to find out that nothing
/// refused them. That is the worst direction for the drift to run, because the
/// generous side is the one people quote.
///
/// A missing denylist entry produces silence, and so does a working one. There
/// is no output to notice, which is why this went four months without anybody
/// spotting it and why the fix has to be a test rather than a careful reviewer.
///
/// ## Why this parses the document instead of restating it
///
/// The obvious version of this test is a hardcoded array compared against the
/// code. That version is a THIRD copy of the same list, it drifts from the other
/// two exactly the way they drifted from each other, and it is worse than no
/// test because a green suite then certifies the drift. So the document is
/// parsed at runtime and the parse IS the contract: the fenced blocks in section
/// 5 are the single source, and either side that stops matching them fails.
///
/// ## Why the parser is asserted on before its output is trusted
///
/// A parser that quietly returns nothing makes every "code equals doc"
/// comparison meaningless, and it fails in the safe-looking direction: green.
/// `testTheParserActuallyReadSomething` pins the shape of what was read, and
/// `testTheParserFailsOnAMissingHeading` proves the parser can still say no.
/// A check that returns nothing is a broken check until it has found a known
/// case, and a known-absent one.
final class DenylistParityTests: XCTestCase {

    // MARK: - Reading SECURITY.md section 5

    private struct ParseFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func securityDoc() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
            .appendingPathComponent("SECURITY.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every line between the `## 5.` heading and the next top level heading.
    ///
    /// Scoped to the section rather than the whole file on purpose: section 4
    /// and section 7 both contain fenced blocks, and a parser that scanned the
    /// document would happily read the audit-log JSON sample as a denylist.
    private static func sectionFiveLines() throws -> [String] {
        let lines = try securityDoc().components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## 5. Denylist") }) else {
            throw ParseFailure(description:
                "SECURITY.md has no '## 5. Denylist' heading. Either the section was renamed "
                + "or renumbered, in which case fix this parser in the same commit, or the "
                + "denylist is no longer documented at all, in which case do not.")
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    /// One entry per line, out of the first fenced block following `heading`.
    private static func documentedList(_ heading: String) throws -> [String] {
        let lines = try sectionFiveLines()
        guard let head = lines.firstIndex(where: { $0.hasPrefix(heading) }) else {
            throw ParseFailure(description:
                "SECURITY.md section 5 has no heading starting '\(heading)'.")
        }
        func trimmed(_ i: Int) -> String {
            lines[i].trimmingCharacters(in: .whitespaces)
        }
        guard let open = (head..<lines.count).first(where: { trimmed($0) == "```text" }) else {
            throw ParseFailure(description:
                "SECURITY.md heading '\(heading)' is not followed by a ```text fence. The "
                + "fenced block is the machine-readable half of that section; prose alone "
                + "cannot be compared to the code.")
        }
        guard let close = ((open + 1)..<lines.count).first(where: { trimmed($0) == "```" }) else {
            throw ParseFailure(description:
                "SECURITY.md heading '\(heading)' opens a fence that is never closed.")
        }
        let entries = ((open + 1)..<close).map(trimmed).filter { !$0.isEmpty }
        let unique = Set(entries)
        guard unique.count == entries.count else {
            throw ParseFailure(description:
                "SECURITY.md heading '\(heading)' lists an entry twice. A duplicate reads as "
                + "harmless and hides a real mismatch, because the code side is compared as a "
                + "set and a set swallows it.")
        }
        return entries
    }

    /// Both sides are compared lowercased. The document shows the casing macOS
    /// writes on disk because that is the useful thing for a human to read; the
    /// code stores the lowercase form because that is what it compares against.
    private static func lowered(_ xs: [String]) -> Set<String> {
        Set(xs.map { $0.lowercased() })
    }

    /// The real check, run in the same order `performRead` and `performList`
    /// run it. Deliberately not a reimplementation: a parity test that carries
    /// its own copy of the comparison is testing the copy.
    private static func isDenied(_ path: String) -> Bool {
        FilesystemTool.denyHit(path) != nil || FilesystemTool.denyBasename(path) != nil
    }

    // MARK: - The parser has to work before its results mean anything

    func testTheParserActuallyReadSomething() throws {
        let segments = try Self.documentedList("### 5a.")
        let fragments = try Self.documentedList("### 5b.")
        let names = try Self.documentedList("### 5c.")
        let extensions = try Self.documentedList("### 5d.")

        // Loose floors, not the lists themselves. A floor proves the fence was
        // found and had content in it; restating the entries here would rebuild
        // the third copy this test exists to avoid.
        XCTAssertGreaterThan(segments.count, 8, "5a parsed as \(segments)")
        XCTAssertGreaterThan(fragments.count, 1, "5b parsed as \(fragments)")
        XCTAssertGreaterThan(names.count, 5, "5c parsed as \(names)")
        XCTAssertGreaterThan(extensions.count, 3, "5d parsed as \(extensions)")

        // Nothing parsed should carry markdown. A backtick or a bullet means the
        // fence boundaries slipped and prose was read as data.
        for entry in segments + fragments + names + extensions {
            XCTAssertFalse(entry.contains("`"), "parsed '\(entry)' still carries markdown")
            XCTAssertFalse(entry.hasPrefix("- "), "parsed '\(entry)' is a bullet, not an entry")
        }
    }

    func testTheParserFailsOnAMissingHeading() {
        // The counterpart to the test above. A parser that cannot report absence
        // reports success for everything, and a parity test built on it passes
        // the day section 5 is deleted.
        XCTAssertThrowsError(try Self.documentedList("### 5z. Not A Real Heading"))
    }

    // MARK: - Code equals document, in both directions

    func testSegmentsMatchTheDocument() throws {
        let documented = Self.lowered(try Self.documentedList("### 5a."))
        let shipped = FilesystemTool.denylistSegments
        XCTAssertEqual(shipped, documented, Self.explain("path segments (5a)", shipped, documented))
    }

    func testFragmentsMatchTheDocument() throws {
        let documented = Self.lowered(try Self.documentedList("### 5b."))
        let shipped = Set(FilesystemTool.denylistSubstrings)
        XCTAssertEqual(shipped.count, FilesystemTool.denylistSubstrings.count,
                       "FilesystemTool.denylistSubstrings lists an entry twice")
        XCTAssertEqual(shipped, documented, Self.explain("path fragments (5b)", shipped, documented))
    }

    func testFileNamesMatchTheDocument() throws {
        let documented = Self.lowered(try Self.documentedList("### 5c."))
        let shipped = FilesystemTool.denylistBasenames
        XCTAssertEqual(shipped, documented, Self.explain("file names (5c)", shipped, documented))
    }

    func testExtensionsMatchTheDocument() throws {
        let documented = Self.lowered(try Self.documentedList("### 5d."))
        let shipped = Set(FilesystemTool.denylistExtensions)
        XCTAssertEqual(shipped.count, FilesystemTool.denylistExtensions.count,
                       "FilesystemTool.denylistExtensions lists an entry twice")
        XCTAssertEqual(shipped, documented, Self.explain("extensions (5d)", shipped, documented))
    }

    /// Names the entries on each side rather than printing two sets and leaving
    /// the reader to diff them. A parity failure is usually one word.
    private static func explain(_ label: String, _ shipped: Set<String>, _ documented: Set<String>) -> String {
        let notEnforced = documented.subtracting(shipped).sorted()
        let notDocumented = shipped.subtracting(documented).sorted()
        var out = "denylist \(label) disagree between FilesystemTool.swift and SECURITY.md."
        if !notEnforced.isEmpty {
            out += "\n  documented but NOT enforced (a promise the code does not keep): "
                + notEnforced.joined(separator: ", ")
        }
        if !notDocumented.isEmpty {
            out += "\n  enforced but NOT documented (add it to SECURITY.md, do not delete it "
                + "from the code to make this pass): " + notDocumented.joined(separator: ", ")
        }
        return out
    }

    // MARK: - Case-insensitivity, driven through the real check

    func testEveryShippedEntryIsStoredLowercase() {
        // The comparison lowercases the candidate, so an entry with a capital in
        // it can never match anything. That is not a style rule. `firefox` was
        // spelled lowercase and compared exact-case, which made it unmatchable
        // against the directory the browser creates; the inverse mistake, adding
        // `Firefox` to a set that is compared lowercased, is just as silent.
        for entry in FilesystemTool.denylistSegments {
            XCTAssertEqual(entry, entry.lowercased(), "denylistSegments entry '\(entry)' can never match")
        }
        for entry in FilesystemTool.denylistSubstrings {
            XCTAssertEqual(entry, entry.lowercased(), "denylistSubstrings entry '\(entry)' can never match")
        }
        for entry in FilesystemTool.denylistBasenames {
            XCTAssertEqual(entry, entry.lowercased(), "denylistBasenames entry '\(entry)' can never match")
        }
        for entry in FilesystemTool.denylistExtensions {
            XCTAssertEqual(entry, entry.lowercased(), "denylistExtensions entry '\(entry)' can never match")
        }
    }

    func testDenyIsCaseInsensitive() {
        // macOS formats the boot volume case-insensitive by default, so every
        // one of these paths opens on a real machine. Each was reachable before
        // the fix.
        let cases: [(String, String)] = [
            ("/tmp/probe/.SSH/config", "a shifted .ssh directory"),
            ("/tmp/probe/Library/Application Support/Firefox/profiles.ini", "the real Firefox directory name"),
            ("/tmp/probe/Library/Group Containers/group.example/data", "a multi-segment fragment"),
            ("/tmp/probe/.CONFIG/GCLOUD/credentials.db", "a shifted two-segment fragment"),
            ("/tmp/probe/.ENV", "a shifted .env"),
            ("/tmp/probe/keys/ID_RSA", "a shifted private key name"),
            ("/tmp/probe/certs/SERVER.PEM", "a shifted key extension"),
        ]
        for (path, why) in cases {
            XCTAssertTrue(Self.isDenied(path), "fs tools would read \(path) (\(why))")
        }
    }

    func testEnvrcIsDenied() {
        // `.envrc` matches neither `.env` nor the `.env.` prefix rule, so it
        // needed its own entry. It is direnv's file, and direnv's ordinary use
        // is a list of `export`ed cloud credentials, which made it the dotfile
        // most likely to hold a live secret and the one nothing checked.
        XCTAssertTrue(Self.isDenied("/tmp/probe/project/.envrc"))
        XCTAssertTrue(Self.isDenied("/tmp/probe/project/.ENVRC"))
        // The prefix rule still has to cover the suffixed variants.
        XCTAssertTrue(Self.isDenied("/tmp/probe/project/.env.production"))
    }

    // MARK: - The guard tests itself

    func testAnOrdinaryFileIsNotDenied() throws {
        // Without this, a denylist that refuses literally everything passes every
        // assertion above. `fs_read` refusing all of `~/Documents` is a total
        // outage of the feature, and it would ship green.
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("grux-denylist-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let notes = dir.appendingPathComponent("notes.md")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)

        XCTAssertNil(FilesystemTool.denyHit(notes.path),
                     "an ordinary path is hitting a denylist segment or fragment")
        XCTAssertNil(FilesystemTool.denyBasename(notes.path),
                     "an ordinary filename is hitting the basename or extension rule")
        XCTAssertFalse(Self.isDenied(notes.path),
                       "notes.md in a scratch directory is refused, so the denylist is not a "
                       + "denylist, it is an outage")

        // A near miss on both new rules, to prove the widening did not overreach.
        // `.envrc` is denied; `envrc.md` is a document about it. `.config` alone
        // is allowed; only `.config/gcloud` is not.
        XCTAssertFalse(Self.isDenied(dir.appendingPathComponent("envrc.md").path))
        XCTAssertFalse(Self.isDenied("/tmp/probe/.config/nvim/init.lua"))
        XCTAssertFalse(Self.isDenied("/tmp/probe/Library/Preferences/com.example.plist"))
    }
}
