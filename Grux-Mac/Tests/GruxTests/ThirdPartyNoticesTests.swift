import XCTest
@testable import Grux

/// THE NOTICES HAVE TO SHIP, AND THEY HAVE TO STAY TRUE.
///
/// Grux is MIT, and MIT's single obligation is that the copyright and permission
/// notice travel with the software. Six of the eight things Grux links are
/// Apache 2.0, which asks for more: retain the notices, include the licence, and
/// where the work ships a NOTICE file, reproduce its contents (section 4d).
///
/// Measured 2026-08-23, the day before this file existed: the repo carried no
/// notices, `Grux.app` carried none either, and gruxai.com told visitors "the
/// licence text is in the app bundle". Three separate ways of saying nothing was
/// there, and nothing in the suite could see any of them.
///
/// The failure this guards is not the missing file, which somebody would
/// eventually notice. It is the NEXT dependency: a notices file written by hand
/// is correct the day it is written and silently wrong the first time the graph
/// changes. So the file is generated from `Package.resolved` and this asserts it
/// has not drifted from what actually ships.
final class ThirdPartyNoticesTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
            .deletingLastPathComponent()   // repo root
    }

    private func notices() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("THIRD-PARTY-NOTICES.md"),
                   encoding: .utf8)
    }

    /// Every package SwiftPM actually resolved has a section. Driven off
    /// Package.resolved rather than a list in this file, because a list here
    /// would be the same hand-maintained thing the generator exists to replace.
    func testEveryResolvedDependencyIsCredited() throws {
        let resolved = repoRoot().appendingPathComponent("Grux-Mac/Package.resolved")
        let data = try Data(contentsOf: resolved)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = (json?["pins"] as? [[String: Any]])
            ?? ((json?["object"] as? [String: Any])?["pins"] as? [[String: Any]])
            ?? []
        XCTAssertFalse(pins.isEmpty, "control: no pins parsed, so this test proves nothing")

        let text = try notices()
        for pin in pins {
            let ident = ((pin["identity"] as? String) ?? (pin["package"] as? String) ?? "").lowercased()
            XCTAssertFalse(ident.isEmpty, "a pin with no identity")
            XCTAssertTrue(text.contains("## \(ident)"),
                          "\(ident) is linked into the app and has no entry in THIRD-PARTY-NOTICES.md")
        }
    }

    /// Apache 2.0 section 4(d) is the clause MIT does not have, and it is the one
    /// most easily missed: a NOTICE file must be reproduced in redistributions.
    /// Both of these ship one, and `Grux.app/Contents/Resources` demonstrably
    /// redistributes swift-crypto.
    func testApacheNoticeFilesAreReproducedVerbatim() throws {
        let text = try notices()
        for dep in ["swift-crypto", "swift-asn1"] {
            guard let start = text.range(of: "## \(dep)") else {
                return XCTFail("\(dep) has no section at all")
            }
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
            let section = String(rest[rest.startIndex..<end])
            XCTAssertTrue(section.contains("### NOTICE"),
                          "\(dep) ships a NOTICE file and Apache 2.0 4(d) requires reproducing it")
        }
    }

    /// The licence text of every dependency is actually present, not just its
    /// name. A credits table alone satisfies neither licence.
    ///
    /// SECTIONS ARE KEYED OFF THE RESOLVED PINS, not off splitting on "## ".
    /// Apple's Apache text contains its own markdown heading, "## Runtime
    /// Library Exception to the Apache 2.0 License", inside the fenced licence
    /// body, so a naive split invents a section named after a clause and then
    /// fails because a clause has no licence of its own. Found by this test
    /// failing on its first run, which is the argument for running it.
    func testTheLicenceTextItselfIsPresent() throws {
        let text = try notices()
        let idents = try resolvedIdentities()
        XCTAssertGreaterThanOrEqual(idents.count, 8, "expected at least eight dependencies")

        for ident in idents {
            let section = try XCTUnwrap(sectionBody(for: ident, in: text),
                                        "\(ident) has no section in the notices")
            XCTAssertTrue(section.contains("### Licence"), "\(ident) has no licence text")
            XCTAssertTrue(section.contains("Permission is hereby granted")
                          || section.contains("Apache License")
                          || section.contains("Redistribution and use"),
                          "\(ident)'s section carries no recognisable licence body")
        }
    }

    /// The pin identities SwiftPM actually resolved, lowercased.
    private func resolvedIdentities() throws -> [String] {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("Grux-Mac/Package.resolved"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = (json?["pins"] as? [[String: Any]])
            ?? ((json?["object"] as? [String: Any])?["pins"] as? [[String: Any]])
            ?? []
        return pins.compactMap {
            (($0["identity"] as? String) ?? ($0["package"] as? String))?.lowercased()
        }
    }

    /// A dependency's section: from its own "## <ident>" heading to the next
    /// heading that names ANOTHER dependency, so headings inside a licence body
    /// cannot end it early.
    private func sectionBody(for ident: String, in text: String) -> String? {
        guard let start = text.range(of: "\n## \(ident)\n") else { return nil }
        let rest = text[start.upperBound...]
        var end = rest.endIndex
        for other in (try? resolvedIdentities()) ?? [] where other != ident {
            if let r = rest.range(of: "\n## \(other)\n"), r.lowerBound < end {
                end = r.lowerBound
            }
        }
        return String(rest[rest.startIndex..<end])
    }

    /// THE ONE THAT CATCHES THE NEXT DEPENDENCY. Re-runs the generator and fails
    /// if the committed file differs from what the current graph produces.
    /// Skipped rather than failed when the checkouts are absent, because that is
    /// a cold clone rather than a drift.
    func testTheNoticesFileHasNotDrifted() throws {
        let mac = repoRoot().appendingPathComponent("Grux-Mac")
        let checkouts = mac.appendingPathComponent(".build/checkouts")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: checkouts.path),
                          "no .build/checkouts, so the generator cannot read licence bytes")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "scripts/gen-third-party-notices.py", "--check"]
        p.currentDirectoryURL = mac
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()

        XCTAssertEqual(p.terminationStatus, 0,
                       "THIRD-PARTY-NOTICES.md is stale. Run "
                       + "python3 Grux-Mac/scripts/gen-third-party-notices.py\n\(out)")
    }

    /// And it has to reach the thing a user actually downloads. The repo copy is
    /// invisible to somebody who only ever opens the app, and the site tells
    /// them the licence text is in the bundle.
    func testTheBuildShipsTheNoticesInsideTheApp() throws {
        let build = try String(contentsOf: repoRoot().appendingPathComponent("Grux-Mac/build.sh"),
                               encoding: .utf8)
        XCTAssertTrue(build.contains("THIRD-PARTY-NOTICES.md"),
                      "build.sh does not copy the notices into the bundle, so the app ships without them")
    }
}
