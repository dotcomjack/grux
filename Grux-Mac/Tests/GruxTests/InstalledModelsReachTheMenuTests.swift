import XCTest
@testable import Grux

/// Wave 65 round 2 P2: "click PULL on its card to download it, then pick it in
/// the model menu under the message box". The composer's model menu lists
/// `ModelRegistry.localTags`, which only `discoverLocal` fills, and a finished
/// pull refreshed `OllamaManager.installedTags` alone, so the pulled model was
/// missing from the menu until Settings opened or Grux relaunched. Every
/// change to what Ollama holds now tells the registry.
@MainActor
final class InstalledModelsReachTheMenuTests: XCTestCase {

    private var saved: (@MainActor () -> Void)!
    private var savedTags: [String] = []

    override func setUp() async throws {
        saved = OllamaManager.installedChanged
        savedTags = OllamaManager.shared.installedTags
    }

    override func tearDown() async throws {
        OllamaManager.installedChanged = {}
        OllamaManager.shared.applyInstalled(savedTags)
        OllamaManager.installedChanged = saved
    }

    func test_aChangeToWhatOllamaHoldsTellsTheRegistry() {
        var calls = 0
        OllamaManager.installedChanged = { calls += 1 }
        OllamaManager.shared.applyInstalled(["gruxai.com/grux/grux-local:2b"])
        XCTAssertEqual(calls, 1, "a pulled model is a change")
        OllamaManager.shared.applyInstalled(["gruxai.com/grux/grux-local:2b"])
        XCTAssertEqual(calls, 1, "the same list again is not")
        OllamaManager.shared.applyInstalled(["gruxai.com/grux/grux-local:2b", "gruxai.com/grux/grux-local:4b"])
        XCTAssertEqual(calls, 2)
        OllamaManager.shared.applyInstalled([])
        XCTAssertEqual(calls, 3, "a stop that empties the list is a change too")
    }

    /// Every writer goes through the one property, and the default hook asks
    /// the registry to discover again (never under test: no network here).
    func test_theDefaultHookRediscoversAndEveryWriterIsCovered() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/LocalModelCookbook/OllamaManager.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("didSet { if installedTags != oldValue { Self.installedChanged() } }"), "the hook sits on the property")
        XCTAssertTrue(src.contains("await ModelRegistry.shared.discoverLocal()"), "the default hook rediscovers")
        XCTAssertTrue(src.contains("guard !Persistence.isUnderTest else { return }"), "never under test")
    }
}
