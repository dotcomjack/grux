import XCTest

/// Keeps one person's DIRECTORY LAYOUT out of the shipped sources.
///
/// `NoPersonalIdentityTests` already bans one person's name, city, brands and
/// hostnames. It did not catch this, and the reason is worth stating: its
/// needles are NOUNS. `Code/AI` is not a name, not a brand and not a hostname.
/// It is a folder that happens to exist on exactly one Mac, and six string
/// literals pointed at it:
///
///   ~/Code/AI/grux-feature-review.html
///   ~/Code/AI/grux-quality-gate.html
///   ~/Code/AI/grux-email-preview.html
///   ~/Code/AI/.worktrees/grux-main   (twice)
///   ~/Code/AI/.quarantine
///
/// Two costs, and the second is the one that bit a user. The layout shipped
/// inside a public binary. And the Feature Review "Export to Chrome" button
/// wrote with `try?` into a directory no other Mac has, then opened the file it
/// had just failed to write, so the button silently did nothing for everybody
/// except its author.
///
/// ## The rule
///
/// A path literal anchored to the user's home may only start with a segment
/// this app actually owns. Everything else is somebody's personal layout, no
/// matter how reasonable it looks to the person who has that folder.
final class NoPersonalPathsTests: XCTestCase {

    /// First path segment under `~` that the app legitimately owns.
    ///
    /// `Projects` is here because SwarmWorker documents `~/Projects/GruxApps` as
    /// a sanctioned swarm root. It is the loosest entry and the one to re-argue
    /// first if this list ever needs tightening.
    private static let sanctionedRoots: Set<String> = [
        // The app's own.
        ".grux", "Library", "Documents", "Projects", "Applications", "Desktop", "Downloads",
        // Standard per-user tool locations. These are the same on every Mac, so
        // they are a convention rather than one person's layout. The first draft
        // of this guard flagged all of them and was 31 false positives to 0 real
        // findings, which is a guard nobody would keep.
        ".local", ".bun", ".claude", ".ssh", ".config", ".cache", ".npm", ".cargo", ".nvm",
    ]

    /// Absolute system roots. Present on every Mac, owned by nobody, so a
    /// literal starting here is not a personal layout.
    private static let systemRoots: Set<String> = [
        "usr", "opt", "bin", "sbin", "etc", "var", "tmp", "private", "System",
        "Applications", "Library", "dev", "Volumes",
    ]

    /// Lines that mention home get their literals checked. A literal is only
    /// interesting if it names a path, so bare words are skipped.
    private static let homeMarkers = ["NSHomeDirectory()", "homeDirectoryForCurrentUser"]

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private struct Hit { let file: String; let line: Int; let literal: String }

    /// Walks every Swift file. For each line that references the home directory,
    /// collects string literals on that line and the next three, because
    /// `appendingPathComponent` chains wrap.
    private func homeAnchoredLiterals() throws -> [Hit] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) else {
            XCTFail("cannot walk \(sourcesRoot.path)"); return []
        }
        var hits: [Hit] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                guard Self.homeMarkers.contains(where: { raw.contains($0) }) else { continue }
                let window = lines[i...min(i + 3, lines.count - 1)].joined(separator: "\n")
                for lit in Self.stringLiterals(in: window) {
                    // Only literals that look like a path fragment matter.
                    guard lit.contains("/") || lit.hasPrefix(".") else { continue }
                    // A leading slash is AMBIGUOUS and both readings appear here.
                    // `"/usr/bin/scp"` is an absolute system path. But the bug
                    // this guard exists for is `NSHomeDirectory() + "/Code/AI/x"`,
                    // where the same leading slash is a SEPARATOR. An earlier
                    // draft skipped every leading-slash literal and went green on
                    // a planted regression, which is a guard that cannot fail.
                    // So the slash is stripped and the first segment decides.
                    let cleaned = lit.hasPrefix("~/") ? String(lit.dropFirst(2))
                                : lit.hasPrefix("/") ? String(lit.dropFirst()) : lit
                    // Interpolations are runtime values, not a baked layout. The
                    // literal extractor drops the backslash, so an interpolated
                    // segment arrives as "(home)" and a check for a backslash
                    // never fires. Match the parenthesis instead.
                    if cleaned.contains("(") { continue }
                    // Prose, not a path. Test names and log lines contain slashes.
                    if cleaned.contains(" ") { continue }
                    // A single segment is a filename or an extension, not a root:
                    // "/test-comms.json", ".git", ".ics" are appended to a
                    // directory that was already checked on its own line.
                    let segs = cleaned.split(separator: "/").map(String.init)
                    guard segs.count >= 2 else { continue }
                    guard let first = segs.first else { continue }
                    if Self.sanctionedRoots.contains(first) { continue }
                    if Self.systemRoots.contains(first) { continue }
                    hits.append(Hit(file: url.lastPathComponent, line: i + 1, literal: lit))
                }
            }
        }
        return hits
    }

    private static func stringLiterals(in text: String) -> [String] {
        var out: [String] = [], cur = "", inside = false, esc = false
        for ch in text {
            if esc { if inside { cur.append(ch) }; esc = false; continue }
            if ch == "\\" { esc = true; continue }
            if ch == "\"" {
                if inside { out.append(cur); cur = ""; inside = false } else { inside = true }
                continue
            }
            if inside { cur.append(ch) }
        }
        return out
    }

    /// Anti-vacuity, and it runs first. A walker that finds no files, or a
    /// literal extractor that returns nothing, would make the real test below
    /// pass forever in silence.
    func testTheScannerActuallyReadsHomeAnchoredPaths() throws {
        let fm = FileManager.default
        var swiftFiles = 0
        if let w = fm.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) {
            for case let u as URL in w where u.pathExtension == "swift" { swiftFiles += 1 }
        }
        XCTAssertGreaterThan(swiftFiles, 100, "only \(swiftFiles) Swift files walked; the scan is looking in the wrong place")

        let lits = Self.stringLiterals(in: #"let p = "Documents/Grux" + "Code/AI/thing.html""#)
        XCTAssertTrue(lits.contains("Documents/Grux"), "literal extractor is broken, it found \(lits)")
        XCTAssertTrue(lits.contains("Code/AI/thing.html"), "literal extractor is broken, it found \(lits)")
    }

    /// The invariant.
    func testNoHomeAnchoredPathOutsideTheAppsOwnDirectories() throws {
        let offenders = try homeAnchoredLiterals()
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) home-anchored path literal(s) start outside the directories this app owns \
            (\(Self.sanctionedRoots.sorted().joined(separator: ", "))):
            \(offenders.map { "  \($0.file):\($0.line)  \"\($0.literal)\"" }.joined(separator: "\n"))
            A path under someone's home that this app does not own is that person's layout. It ships \
            inside the binary and it silently no-ops for every other user. Read it from config, or \
            move it under a directory the app owns.
            """)
    }
}
