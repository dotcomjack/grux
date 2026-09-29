import XCTest

/// `build.sh` falls back to this Mac's own Apple Development certificate when the
/// pinned one is absent, through `scripts/first-dev-identity.sh`.
///
/// RV30: it read the hash as `awk -F'[ "]' '{print $4}'`. `security find-identity`
/// right-aligns the list index, so from the tenth identity on the padding shrinks and
/// field 4 is empty: the build fell through to ad-hoc signing while a certificate sat
/// in the keychain, and every permission prompted again after each install.
final class FirstDevIdentityTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func first(_ listing: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/first-dev-identity.sh").path]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(listing.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func row(_ index: Int, _ hash: String, _ name: String) -> String {
        String(repeating: " ", count: max(0, 3 - String(index).count)) + "\(index)) \(hash) \"\(name)\""
    }

    func test_aDevelopmentIdentityPastTheNinthRowIsFound() throws {
        var rows = (1...9).map { row($0, String(repeating: "\($0)", count: 40), "Apple Distribution: Someone (AAAAAAAAAA)") }
        let dev = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
        rows.append(row(10, dev, "Apple Development: Someone (ABCDE12345)"))
        let listing = "Policy: Code Signing\n" + rows.joined(separator: "\n") + "\n     10 valid identities found\n"
        XCTAssertEqual(try first(listing), dev)
    }

    func test_theFirstDevelopmentIdentityWins_andNoneReadsEmpty() throws {
        let a = String(repeating: "A", count: 40), b = String(repeating: "B", count: 40)
        let listing = [row(1, b, "Developer ID Application: X (T)"), row(2, a, "Apple Development: X (T)"),
                       row(3, b, "Apple Development: Y (U)")].joined(separator: "\n") + "\n"
        XCTAssertEqual(try first(listing), a)
        XCTAssertEqual(try first(row(1, b, "Developer ID Application: X (T)") + "\n"), "")
    }

    func test_buildShReadsTheHashThroughTheHelper() throws {
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("| bash scripts/first-dev-identity.sh)"), "build.sh no longer uses the helper")
        XCTAssertFalse(build.contains("print $4"), "a fixed awk field is back")
    }
}
