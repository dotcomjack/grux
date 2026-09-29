import XCTest
@testable import GruxAgentCore

// A Claude CLI installed with npm under a node version manager lives in the home
// folder, and a Finder launch of Grux has no PATH that reaches it. These pin that
// Grux still finds it, so the Agents pane stops calling it missing.
final class ClaudeBinaryLocatorTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func plant(_ relative: String) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testFindsNothingInAnEmptyHome() {
        XCTAssertNil(ClaudeBinaryLocator.locate(home: home.path, environment: [:]))
    }

    func testFindsAnNpmInstallUnderNvmAndPrefersTheNewestNode() throws {
        try plant(".nvm/versions/node/v9.11.2/bin/claude")
        let newest = try plant(".nvm/versions/node/v22.3.0/bin/claude")
        try plant(".nvm/versions/node/v20.18.1/bin/claude")
        XCTAssertEqual(ClaudeBinaryLocator.locate(home: home.path, environment: [:]), newest)
    }

    func testSkipsAnNvmNodeWithoutClaude() throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".nvm/versions/node/v24.0.0/bin"),
            withIntermediateDirectories: true)
        let installed = try plant(".nvm/versions/node/v18.0.0/bin/claude")
        XCTAssertEqual(ClaudeBinaryLocator.locate(home: home.path, environment: [:]), installed)
    }

    func testFindsVoltaAndNpmGlobalInstalls() throws {
        let volta = try plant(".volta/bin/claude")
        XCTAssertEqual(ClaudeBinaryLocator.locate(home: home.path, environment: [:]), volta)
        try FileManager.default.removeItem(atPath: volta)
        let npmGlobal = try plant(".npm-global/bin/claude")
        XCTAssertEqual(ClaudeBinaryLocator.locate(home: home.path, environment: [:]), npmGlobal)
    }

    func testTheNativeInstallerStillWinsOverAVersionManager() throws {
        try plant(".nvm/versions/node/v22.3.0/bin/claude")
        let native = try plant(".local/bin/claude")
        XCTAssertEqual(ClaudeBinaryLocator.locate(home: home.path, environment: [:]), native)
    }

    func testClaudeBinOverrideWins() throws {
        try plant(".nvm/versions/node/v22.3.0/bin/claude")
        let override = try plant("custom/claude")
        XCTAssertEqual(
            ClaudeBinaryLocator.locate(home: home.path, environment: ["CLAUDE_BIN": override]),
            override)
    }

    // A JS build of the CLI starts with `#!/usr/bin/env node`; the node it needs sits
    // beside it, so the spawn PATH has to lead with that folder.
    func testSpawnPathLeadsWithTheBinaryFolder() {
        XCTAssertEqual(
            ClaudeBinaryLocator.spawnPATH(for: "/h/.nvm/versions/node/v22.3.0/bin/claude", base: "/usr/bin:/bin"),
            "/h/.nvm/versions/node/v22.3.0/bin:/usr/bin:/bin")
        XCTAssertEqual(ClaudeBinaryLocator.spawnPATH(for: "claude", base: "/usr/bin:/bin"), "/usr/bin:/bin")
        XCTAssertEqual(
            ClaudeBinaryLocator.spawnPATH(for: "/usr/bin/claude", base: "/usr/bin:/bin"), "/usr/bin:/bin")
    }
}
