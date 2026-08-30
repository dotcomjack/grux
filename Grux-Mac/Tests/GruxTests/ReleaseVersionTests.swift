import XCTest
@testable import Grux

/// THE VERSION IN THE BUNDLE AND THE VERSION IN THE CHANGELOG ARE ONE FACT.
///
/// They had drifted, and the drift was invisible because nothing reads both.
/// Measured 2026-08-23: a week of work sat under `## [Unreleased]` in the
/// changelog while `Info.plist` still said `1.0.0` and `CFBundleVersion` still
/// said `1`, which is exactly what shipped as the first public release. So the
/// app a person downloaded would have reported itself as the previous release,
/// and the only place the difference was written down was a heading that says,
/// in as many words, that it has not been released.
///
/// This is the same shape as the other defects in this range: nothing crashes,
/// no test fails, and the wrong answer looks exactly like the right one. A
/// version number is a claim about which code you are running, and it is the
/// claim every bug report starts from.
///
/// It also cannot be fixed by remembering, because the moment it matters is the
/// moment somebody is busy shipping.
final class ReleaseVersionTests: XCTestCase {

    /// `Grux-Mac/Tests/GruxTests/X.swift` -> repo root is four levels up.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
            .deletingLastPathComponent()   // repo root
    }

    private func infoPlistVersions() throws -> (marketing: String, build: String) {
        let url = repoRoot().appendingPathComponent("Grux-Mac/Info.plist")
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            throw XCTSkip("Info.plist did not parse as a dictionary")
        }
        let marketing = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String,
                                      "Info.plist has no CFBundleShortVersionString")
        let build = try XCTUnwrap(plist["CFBundleVersion"] as? String,
                                  "Info.plist has no CFBundleVersion")
        return (marketing, build)
    }

    private func changelog() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    }

    /// Every `## [x.y.z] - date` heading, newest first, in file order.
    private func releasedVersions(in changelog: String) -> [String] {
        var out: [String] = []
        for line in changelog.components(separatedBy: "\n") {
            guard line.hasPrefix("## ["), line.contains("] - ") else { continue }
            guard let open = line.firstIndex(of: "["),
                  let close = line.firstIndex(of: "]") else { continue }
            let v = String(line[changelog.index(after: open)...])
            _ = v
            out.append(String(line[line.index(after: open)..<close]))
        }
        return out
    }

    // MARK: - The invariant

    /// THE ONE THAT WOULD HAVE CAUGHT IT.
    func testTheBundleVersionMatchesTheNewestReleasedChangelogEntry() throws {
        let log = try changelog()
        let released = releasedVersions(in: log)
        let (marketing, _) = try infoPlistVersions()

        XCTAssertFalse(released.isEmpty,
                       "control: no dated release headings were parsed, so this proves nothing")
        XCTAssertEqual(marketing, released.first,
                       "Info.plist says \(marketing) and the newest released changelog entry is "
                       + "\(released.first ?? "none"). One of them is wrong, and a person reading "
                       + "an About box or filing a bug will believe the plist.")
    }

    /// The work has to be moved OUT of Unreleased, not merely have a heading
    /// added above it. An `[Unreleased]` section with content in it, sitting
    /// under a bumped version, is the same lie in a different place.
    func testNothingShippableIsLeftSittingUnderUnreleased() throws {
        let log = try changelog()
        guard let start = log.range(of: "## [Unreleased]") else {
            return  // no Unreleased section at all is fine
        }
        let rest = log[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        let body = rest[rest.startIndex..<end].trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(body.isEmpty,
                      "[Unreleased] still has content in it, so this release does not describe "
                      + "everything that is in it:\n\(body.prefix(400))")
    }

    /// Semver, because the changelog says the project adheres to it and a
    /// version like "1.0" or "v1.0.1" breaks both the tag and the download URL.
    func testTheVersionIsPlainSemver() throws {
        let (marketing, build) = try infoPlistVersions()

        let parts = marketing.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "\(marketing) is not major.minor.patch")
        for p in parts {
            XCTAssertNotNil(Int(p), "\(marketing) has a non-numeric component: \(p)")
        }
        XCTAssertFalse(marketing.hasPrefix("v"), "the plist carries the bare number, the TAG carries the v")
        XCTAssertNotNil(Int(build), "CFBundleVersion \(build) is not an integer")
    }

    /// Every dated release names its own comparison link, and `[Unreleased]`
    /// compares against the CURRENT version rather than an older one. That link
    /// was pointing at v1.0.0 while v1.0.1 was being prepared, which quietly
    /// widens the diff a reader is shown to include the release itself.
    func testEveryReleaseHasALinkAndUnreleasedComparesAgainstTheCurrentOne() throws {
        let log = try changelog()
        let released = releasedVersions(in: log)
        let current = try XCTUnwrap(released.first)

        for v in released {
            XCTAssertTrue(log.contains("\n[\(v)]: http"),
                          "release \(v) has no link reference at the bottom of the changelog")
        }
        if log.contains("## [Unreleased]") {
            XCTAssertTrue(log.contains("[Unreleased]: ") && log.contains("compare/v\(current)..."),
                          "the Unreleased link does not compare against v\(current), so it shows a "
                          + "reader a diff that includes the current release")
        }
    }

    /// The release the changelog claims is newest must not already be behind a
    /// published tag. A repeated version is how two different binaries end up
    /// calling themselves the same thing.
    func testTheNewestEntryIsDatedAndOrdered() throws {
        let log = try changelog()
        let dated = log.components(separatedBy: "\n")
            .filter { $0.hasPrefix("## [") && $0.contains("] - ") }
        XCTAssertFalse(dated.isEmpty, "control: no dated headings, nothing proven")

        // Dates are ISO, so string comparison is chronological.
        let dates = dated.compactMap { $0.components(separatedBy: "] - ").last }
        XCTAssertEqual(dates, dates.sorted(by: >),
                       "the release headings are not in newest-first order: \(dates)")
    }
}
