import XCTest
@testable import Grux

/// The composer's model chip names the model the next turn goes to, and a
/// choice in its menu changes the route, not just a stored id.
///
/// Seen live 2026-09-21: chat routed to OpenRouter (DeepSeek) while the chip
/// read "Llama3.2", because it showed `offlineLLMModel` for any route that was
/// not Anthropic; and picking a Claude model while the custom route was active
/// set `config.model` and changed nothing.
final class ComposerModelChipTests: XCTestCase {
    private func chatView() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)
    }

    func test_theChipNamesTheRoutedModel() throws {
        let src = try chatView()
        let body = try XCTUnwrap(src.components(separatedBy: "private var activeModelId: String {").dropFirst().first)
        XCTAssertTrue(body.prefix(80).contains("registry.modelId()"), "the chip reads something other than the route")
        XCTAssertEqual(ComposerFooter.displayName(id: "deepseek/deepseek-v4-flash-0731", registryName: nil),
                       "Deepseek V4 Flash 0731")
    }

    func test_everyMenuChoiceSwitchesTheRoute() throws {
        let src = try chatView()
        let menu = try XCTUnwrap(src.components(separatedBy: "private var modelChip: some View {").dropFirst().first)
        let block = String(menu.prefix(2_600))
        XCTAssertTrue(block.contains("registry.setActiveProvider(.anthropic)"), "a Claude choice leaves the route alone")
        XCTAssertTrue(block.contains("registry.setActiveProvider(.local)"), "a local choice leaves the route alone")
        XCTAssertTrue(block.contains("registry.setActiveProvider(.custom(ep.id))"), "an endpoint choice leaves the route alone")
        XCTAssertFalse(block.contains("state.config.offlineLLMModel = ep.name"), "an endpoint's name is written as a model id again")
    }
}
