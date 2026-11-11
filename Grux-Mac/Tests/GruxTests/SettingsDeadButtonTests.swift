import XCTest
@testable import Grux

/// D170 items 14 and 16 (sense pass 21): two Settings buttons were live with
/// nothing to do. Models' "Test API key" sent a request with an empty key, and
/// General's "Hand setup to your agent" sat above "Nothing left that an agent
/// can do".
@MainActor
final class SettingsDeadButtonTests: XCTestCase {

    private func settingsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/SettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTestAPIKeyNeedsAKey() throws {
        XCTAssertFalse(APIKeyTest.canTest(""))
        XCTAssertFalse(APIKeyTest.canTest("  \n"))
        XCTAssertTrue(APIKeyTest.canTest("sk-ant-x"))
        let source = try settingsSource()
        let button = try XCTUnwrap(source.range(of: "Button(\"Test API key\")"))
        let after = source[button.upperBound...].prefix(400)
        XCTAssertTrue(after.contains(".disabled(!APIKeyTest.canTest(apiKey))"), String(after))
        XCTAssertTrue(after.contains("APIKeyTest.emptyLine"), String(after))
    }

    func testTheHandoffIsOfferedOnlyWithWorkForAnAgent() throws {
        XCTAssertFalse(SettingsHandoff.offers(agentCount: 0))
        XCTAssertTrue(SettingsHandoff.offers(agentCount: 1))
        XCTAssertTrue(SettingsHandoff.offers(agentCount: nil))
        let source = try settingsSource()
        let button = try XCTUnwrap(source.range(of: "Button(\"Hand setup to your agent\")"))
        let after = source[button.upperBound...].prefix(300)
        XCTAssertTrue(after.contains(".disabled(!SettingsHandoff.offers(agentCount: handoffAgentCount))"), String(after))
        XCTAssertTrue(source.contains("handoffAgentCount = split.agent.count"))
    }
}
