import XCTest
@testable import Grux

// Coverage for the read-only MCP server core (the tested reference for the
// standalone grux-mcp executable). Drives the framing seam directly with
// newline-delimited JSON-RPC and decodes the response frames, so no threads or
// real pipes are needed. Fixtures are written into temp roots.
final class MCPServerCoreTests: XCTestCase {

    private var docs: URL!
    private var support: URL!
    private var core: MCPServerCore!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        docs = root.appendingPathComponent("Documents/Grux", isDirectory: true)
        support = root.appendingPathComponent("Application Support/Grux", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        core = MCPServerCore(roots: MCPServerRoots(documentsRoot: docs, supportRoot: support))
    }

    override func tearDownWithError() throws {
        if let parent = docs?.deletingLastPathComponent().deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    // MARK: - Handshake

    func testInitializeRoundTrip() throws {
        let responses = drive(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        XCTAssertEqual(responses.count, 1)
        let resp = responses[0]
        XCTAssertEqual(resp["id"] as? Int, 1)
        let result = try XCTUnwrap(resp["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "grux-mcp")
        let caps = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(caps["tools"])
    }

    func testInitializedNotificationProducesNoReply() {
        let responses = drive(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertTrue(responses.isEmpty, "notifications must never get a reply")
    }

    // MARK: - tools/list

    func testToolsListReturnsReadOnlyCatalog() throws {
        let responses = drive(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        let result = try XCTUnwrap(responses.first?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, [
            "grux_list_design_projects", "grux_get_design_project",
            "grux_list_design_systems", "grux_get_design_system",
            "grux_list_skills", "grux_list_brands"
        ])
    }

    // MARK: - tools/call happy paths

    func testListDesignProjectsReadsIndex() throws {
        let designDir = docs.appendingPathComponent("design", isDirectory: true)
        try FileManager.default.createDirectory(at: designDir, withIntermediateDirectories: true)
        let index = "[{\"id\":\"1\",\"slug\":\"hero\",\"title\":\"Hero Page\",\"kind\":\"prototype\",\"starred\":true,\"updatedAt\":\"2026-07-17T00:00:00Z\"}]"
        try index.write(to: designDir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)

        let text = try callText("grux_list_design_projects", arguments: [:])
        XCTAssertTrue(text.contains("Hero Page"))
        XCTAssertTrue(text.contains("slug: hero"))
        XCTAssertTrue(text.contains("[starred]"))
    }

    func testGetDesignProjectReadsProjectAndSiteFiles() throws {
        let projectDir = docs.appendingPathComponent("design/hero", isDirectory: true)
        let siteDir = projectDir.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try "{\"id\":\"1\",\"slug\":\"hero\",\"title\":\"Hero Page\",\"kind\":\"prototype\",\"tags\":[\"landing\"]}"
            .write(to: projectDir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: siteDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let text = try callText("grux_get_design_project", arguments: ["slug": "hero"])
        XCTAssertTrue(text.contains("Title: Hero Page"))
        XCTAssertTrue(text.contains("Tags: landing"))
        XCTAssertTrue(text.contains("index.html"))
    }

    func testGetDesignProjectMissingSlug() throws {
        let text = try callText("grux_get_design_project", arguments: ["slug": "nope"])
        XCTAssertTrue(text.contains("No design project found"))
    }

    func testListDesignSystems() throws {
        let dsDir = docs.appendingPathComponent("design-systems/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: dsDir, withIntermediateDirectories: true)
        try "# Acme".write(to: dsDir.appendingPathComponent("DESIGN.md"), atomically: true, encoding: .utf8)

        let text = try callText("grux_list_design_systems", arguments: [:])
        XCTAssertTrue(text.contains("acme"))
    }

    func testGetDesignSystemReadsContent() throws {
        let dsDir = docs.appendingPathComponent("design-systems/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: dsDir, withIntermediateDirectories: true)
        try "# Acme Design System\nGold is #B8842E.".write(to: dsDir.appendingPathComponent("DESIGN.md"), atomically: true, encoding: .utf8)

        let text = try callText("grux_get_design_system", arguments: ["slug": "acme"])
        XCTAssertTrue(text.contains("Gold is #B8842E"))
    }

    func testListSkills() throws {
        let skills = "[{\"id\":\"1\",\"name\":\"ship-ios\",\"trigger\":\"when shipping an iOS app\",\"procedure\":\"x\",\"usageCount\":0,\"createdAt\":\"2026-07-17T00:00:00Z\",\"updatedAt\":\"2026-07-17T00:00:00Z\"}]"
        try skills.write(to: support.appendingPathComponent("skills.json"), atomically: true, encoding: .utf8)

        let text = try callText("grux_list_skills", arguments: [:])
        XCTAssertTrue(text.contains("ship-ios"))
        XCTAssertTrue(text.contains("when shipping an iOS app"))
    }

    func testListBrands() throws {
        let brands = "[{\"id\":\"1\",\"name\":\"Acme Goods\",\"slug\":\"acme\",\"rootPath\":\"/x\",\"status\":\"active\"}]"
        try brands.write(to: support.appendingPathComponent("projects-cache.json"), atomically: true, encoding: .utf8)

        let text = try callText("grux_list_brands", arguments: [:])
        XCTAssertTrue(text.contains("Acme Goods"))
        XCTAssertTrue(text.contains("slug: acme"))
        XCTAssertTrue(text.contains("status: active"))
    }

    func testMissingStoresReturnGracefulText() throws {
        // No fixture files written: every list tool must return a friendly
        // empty message, never an error frame.
        XCTAssertTrue(try callText("grux_list_design_projects", arguments: [:]).contains("No design projects"))
        XCTAssertTrue(try callText("grux_list_skills", arguments: [:]).contains("No skills"))
        XCTAssertTrue(try callText("grux_list_brands", arguments: [:]).contains("No brands"))
    }

    // MARK: - Path traversal containment

    // A crafted slug must never read a file outside the design-systems root.
    // The happy path returns file contents; a blocked path returns the same
    // "No design system found" text, never contents.
    func testGetDesignSystemBlocksTraversalSlugs() throws {
        // A real design system so the tool has something legitimate to find.
        let dsDir = docs.appendingPathComponent("design-systems/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: dsDir, withIntermediateDirectories: true)
        try "# Acme\nGold is #B8842E.".write(to: dsDir.appendingPathComponent("DESIGN.md"), atomically: true, encoding: .utf8)
        // A secret planted where a "../.." climb out of the root would land.
        try "SECRET-DS-abc123".write(to: docs.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)

        for slug in ["../../../../etc/passwd", "/etc/hosts", "..%2F..%2Fx", "../secret", "~/secret"] {
            let text = try callText("grux_get_design_system", arguments: ["slug": slug])
            XCTAssertTrue(text.contains("No design system found"), "slug \(slug) must be not-found")
            XCTAssertFalse(text.contains("SECRET-DS-abc123"), "slug \(slug) must not leak the planted secret")
            XCTAssertFalse(text.lowercased().contains("root:"), "slug \(slug) must not leak /etc/passwd")
        }

        // A legit slug still resolves to its contents.
        let ok = try callText("grux_get_design_system", arguments: ["slug": "acme"])
        XCTAssertTrue(ok.contains("Gold is #B8842E"), "a real slug must still resolve after hardening")
    }

    // A ".md" symlink planted inside the root that points at a file outside it
    // IS enumerated as a design system (its name ends in ".md"), so it passes
    // the allowlist. Reading it must still be refused because the resolved path
    // escapes the root: this exercises the boundary check as a second layer,
    // with a slug that carries no ".." to short-circuit on shape.
    func testGetDesignSystemBlocksSymlinkEscape() throws {
        let outsideFile = docs.deletingLastPathComponent().appendingPathComponent("leak.md")
        try "secret-token-xyz".write(to: outsideFile, atomically: true, encoding: .utf8)
        let dsRoot = docs.appendingPathComponent("design-systems", isDirectory: true)
        try FileManager.default.createDirectory(at: dsRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dsRoot.appendingPathComponent("evil.md"), withDestinationURL: outsideFile)

        // Enumerated as slug "evil" (the ".md" is stripped in the listing)...
        XCTAssertTrue(try callText("grux_list_design_systems", arguments: [:]).contains("evil"))
        // ...but reading it is refused because it resolves outside the root.
        let text = try callText("grux_get_design_system", arguments: ["slug": "evil"])
        XCTAssertTrue(text.contains("No design system found"))
        XCTAssertFalse(text.contains("secret-token-xyz"))
    }

    func testGetDesignProjectBlocksTraversalSlugs() throws {
        // A real project so the tool has something legitimate to find.
        let projectDir = docs.appendingPathComponent("design/hero", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "{\"slug\":\"hero\",\"title\":\"Hero\"}"
            .write(to: projectDir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        // A well-formed project.json planted outside the design root.
        try "{\"slug\":\"x\",\"title\":\"LEAKED-PROJECT\"}"
            .write(to: docs.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        for slug in ["../../../../etc/passwd", "/etc/hosts", "..%2F..%2Fx", "..", "~/x"] {
            let text = try callText("grux_get_design_project", arguments: ["slug": slug])
            XCTAssertTrue(text.contains("No design project found"), "slug \(slug) must be not-found")
            XCTAssertFalse(text.contains("LEAKED-PROJECT"), "slug \(slug) must not leak an out-of-root project")
            XCTAssertFalse(text.contains("Title:"), "slug \(slug) must not return project fields")
        }

        // A legit slug still resolves.
        let ok = try callText("grux_get_design_project", arguments: ["slug": "hero"])
        XCTAssertTrue(ok.contains("Title: Hero"), "a real slug must still resolve after hardening")
    }

    func testGetDesignProjectBlocksSymlinkEscape() throws {
        let outside = docs.deletingLastPathComponent().appendingPathComponent("outside-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "{\"slug\":\"x\",\"title\":\"LEAKED-VIA-SYMLINK\"}"
            .write(to: outside.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        let designDir = docs.appendingPathComponent("design", isDirectory: true)
        try FileManager.default.createDirectory(at: designDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: designDir.appendingPathComponent("evil"), withDestinationURL: outside)

        let text = try callText("grux_get_design_project", arguments: ["slug": "evil"])
        XCTAssertTrue(text.contains("No design project found"))
        XCTAssertFalse(text.contains("LEAKED-VIA-SYMLINK"))
    }

    // MARK: - Errors + id echo

    func testUnknownToolReturnsRPCError() throws {
        let responses = drive([
            "jsonrpc": "2.0", "id": 9, "method": "tools/call",
            "params": ["name": "grux_does_not_exist", "arguments": [:]]
        ])
        let err = try XCTUnwrap(responses.first?["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, -32602)
        XCTAssertTrue((err["message"] as? String ?? "").contains("grux_does_not_exist"))
    }

    func testUnknownMethodReturnsMethodNotFound() throws {
        let responses = drive(["jsonrpc": "2.0", "id": 10, "method": "resources/list", "params": [:]])
        let err = try XCTUnwrap(responses.first?["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, -32601)
    }

    func testStringIDIsEchoedVerbatim() throws {
        let responses = drive(["jsonrpc": "2.0", "id": "abc-123", "method": "tools/list", "params": [:]])
        XCTAssertEqual(responses.first?["id"] as? String, "abc-123",
                       "string ids must round-trip as strings, not be coerced to ints")
    }

    func testMultipleFramesInOneReadAreAllAnswered() throws {
        var blob = Data()
        blob.append(frame(["jsonrpc": "2.0", "id": 1, "method": "ping", "params": [:]]))
        blob.append(frame(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]))
        let responses = core.drain(blob).map(decode)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0]["id"] as? Int, 1)
        XCTAssertEqual(responses[1]["id"] as? Int, 2)
    }

    // MARK: - Helpers

    private func frame(_ obj: [String: Any]) -> Data {
        var d = try! JSONSerialization.data(withJSONObject: obj)
        d.append(0x0A)
        return d
    }

    private func decode(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // Feed one request through the framing seam and decode the response frames.
    private func drive(_ request: [String: Any]) -> [[String: Any]] {
        core.drain(frame(request)).map(decode)
    }

    // Call a tool and return the flattened text content of the result.
    private func callText(_ name: String, arguments: [String: Any]) throws -> String {
        let responses = drive([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ])
        let result = try XCTUnwrap(responses.first?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
