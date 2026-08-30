import XCTest

/// TWO BUILD PRODUCTS THAT DIFFER ONLY IN CASE ARE ONE FILE ON THIS MACHINE.
///
/// APFS is case-insensitive by default. A product named `grux` beside an executable target
/// named `Grux` writes to the same path in `.build`, and whichever built last wins. Measured
/// 2026-08-28: both names resolved to inode 268139998, a 100 MB binary, and running what
/// looked like the CLI launched the whole app, started every scheduler and aborted with
/// `bundleProxyForCurrentProcess is nil`.
///
/// Nothing failed at build time. `swift build` was green, the tests were green, and the only
/// symptom was a command that did something completely different from what it said.
final class PackageLayoutTests: XCTestCase {

    private func packageManifest() throws -> String {
        // Grux-Mac/Tests/GruxTests/X.swift -> the package root is THREE ascents up, not two.
        // The first version stopped at Tests/ and every assertion below turned into a
        // file-not-found, which is a test that cannot fail for the reason it was written.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
            .appendingPathComponent("Package.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every name that becomes a file in `.build`, lowercased, must be unique.
    func testNoTwoBuildArtifactsCollideCaseInsensitively() throws {
        let manifest = try packageManifest()

        func names(_ pattern: String) -> [String] {
            let re = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(manifest.startIndex..., in: manifest)
            return re.matches(in: manifest, range: range).compactMap {
                Range($0.range(at: 1), in: manifest).map { String(manifest[$0]) }
            }
        }

        let executables = names(#"\.executable\(name: "([^"]+)""#)
            + names(#"\.executableTarget\(\s*name: "([^"]+)""#)

        XCTAssertFalse(executables.isEmpty,
                       "control: parsed no executables, so this proves nothing")

        var seen: [String: String] = [:]
        for name in executables {
            let key = name.lowercased()
            if let existing = seen[key], existing != name {
                XCTFail("""
                    "\(existing)" and "\(name)" differ only in case, so on a case-insensitive
                    filesystem they are ONE file in .build and the last target to build wins.
                    This already happened once: a product named grux clobbered the app binary
                    named Grux and running the CLI launched the app.
                    """)
            }
            seen[key] = name
        }
    }

    /// The command a person types is still `grux`, whatever the build product is called.
    /// If this ever stops being true, the rename went further than the artifact path.
    func testTheInstalledCommandIsStillCalledGrux() throws {
        let manifest = try packageManifest()
        XCTAssertTrue(manifest.contains(#"name: "grux-cli""#),
                      "the CLI product was renamed again; check build.sh installs it as grux")
        XCTAssertTrue(manifest.contains(#"name: "GruxCLI""#),
                      "the CLI target vanished")
    }
}
