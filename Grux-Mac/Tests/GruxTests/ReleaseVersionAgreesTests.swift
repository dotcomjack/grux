import XCTest

/// P-G-1: the version is written in four files that nobody diffs against each
/// other, and a build that reports the wrong number to the person who installed
/// it is how that drift shows up. The app's `Info.plist` is the source; the npm
/// front door, the CHANGELOG and the README must agree with it.
final class ReleaseVersionAgreesTests: XCTestCase {

    private var macRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var repoRoot: URL { macRoot.deletingLastPathComponent() }

    private func appVersion() throws -> (short: String, build: String) {
        let data = try Data(contentsOf: macRoot.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return (try XCTUnwrap(plist["CFBundleShortVersionString"] as? String),
                try XCTUnwrap(plist["CFBundleVersion"] as? String))
    }

    func test_theAppAndTheNpmFrontDoorCarryTheSameVersion() throws {
        let app = try appVersion()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("npm/package.json"))
        let pkg = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(pkg["version"] as? String, app.short,
                       "npm/package.json and Info.plist disagree on the version")
        XCTAssertNotNil(Int(app.build), "CFBundleVersion is not a whole number: \(app.build)")
    }

    func test_theChangelogAndTheReadmeNameTheSameVersion() throws {
        let short = try appVersion().short
        let changelog = try String(contentsOf: repoRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        XCTAssertTrue(changelog.contains("\n## [\(short)]"), "the CHANGELOG has no entry for \(short)")
        let parts = short.split(separator: ".")
        let spoken = parts.count >= 3 && parts[2] == "0" ? parts.prefix(2).joined(separator: ".") : short
        let readme = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("currently \(spoken).**"), "the README's status line does not say \(spoken)")
        XCTAssertTrue(readme.contains("Download Grux \(spoken) for Apple silicon"),
                      "the README's download button names another version")
    }
}
