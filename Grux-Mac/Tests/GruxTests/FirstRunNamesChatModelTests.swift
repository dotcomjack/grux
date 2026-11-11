import XCTest
@testable import Grux

/// D135 items 1 and 2 (sense pass 14, `fr75/update-1.png`, `fr75/modelKey-1.png`).
/// (1) First run's last screen headlined "Grux Local 4B runs here (great fit)" and
/// never named the model chat would use, which Connect a model had just set to
/// Qwen 3.5 4B. It now says which model chat uses. (2) Connect a model showed
/// "Get Ollama, free, at ollama.com" under "There is already a model on this Mac".
@MainActor
final class FirstRunNamesChatModelTests: XCTestCase {

    private let mini = HardwareProfile(chipName: "Apple M4", physicalMemoryBytes: 16 * 1_073_741_824,
                                       gpuWorkingSetBytes: 12 * 1_073_741_824, cpuCoreCount: 10,
                                       hasUnifiedMemory: true, isAppleSilicon: true)
    private let tags = ["qwen3.5:4b", "gruxai.com/grux/grux-local:4b"]

    private func report(cloud: Bool, chat: String?, tags: [String]? = nil) -> ModelUpdateReport {
        ModelUpdateReport.build(profile: mini, hasCloudModel: cloud, routesToCloud: cloud,
                                localServerRunning: true, installedTags: tags ?? self.tags,
                                chatModel: chat)
    }

    func test_routedLocal_namesTheChatModelByItsName() {
        XCTAssertEqual(report(cloud: false, chat: "qwen3.5:4b").chatSummary, "Qwen 3.5 4B, on this Mac.")
        XCTAssertEqual(report(cloud: false, chat: "gruxai.com/grux/grux-local:4b").chatSummary,
                       "Grux Local 4B, on this Mac.")
    }

    func test_aModelTheCatalogDoesNotKnow_isNamedByItsTag() {
        XCTAssertEqual(report(cloud: false, chat: "mistral:7b", tags: ["mistral:7b"]).chatSummary,
                       "mistral:7b, on this Mac.")
    }

    func test_noLineWhenChatIsNotOnALocalModel() {
        XCTAssertNil(report(cloud: true, chat: "qwen3.5:4b").chatSummary, "chat routes to the cloud")
        XCTAssertNil(report(cloud: false, chat: nil).chatSummary)
        XCTAssertNil(report(cloud: false, chat: "  ").chatSummary)
        XCTAssertNil(report(cloud: false, chat: "llama3.2:3b").chatSummary, "a model that is not installed")
    }

    /// Ollama serves a bare name as its ":latest" tag (`OllamaManager.isInstalled`); wave 38 round 1.
    func test_aBareName_matchesItsLatestTag() {
        XCTAssertEqual(report(cloud: false, chat: "llama3.2", tags: ["llama3.2:latest"]).chatSummary,
                       "llama3.2, on this Mac.")
        XCTAssertNil(report(cloud: false, chat: "llama3.2", tags: ["llama3.2:3b"]).chatSummary)
    }

    func test_installedMatchIgnoresCase() {
        XCTAssertEqual(report(cloud: false, chat: "Qwen3.5:4B").chatSummary, "Qwen 3.5 4B, on this Mac.")
    }

    func test_theScreenDrawsTheLine_andPassesTheRoutedModel() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift"))
        XCTAssertTrue(src.contains("if let chat = report.chatSummary { line(\"Chat uses\", chat) }"))
        XCTAssertTrue(src.contains("chatModel: ModelRegistry.shared.resolvedProvider == .local ? ModelRegistry.shared.modelId() : nil"))
    }

    // MARK: - Item 2

    func test_ollamaLink_onlyWhenNoModelWasFound() {
        XCTAssertTrue(ModelGate.offersOllamaLink(.none))
        XCTAssertFalse(ModelGate.offersOllamaLink(.found("qwen3.5:4b")))
    }

    func test_connectAModel_drawsTheLinkBehindTheRule() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"))
        XCTAssertTrue(src.contains("if ModelGate.offersOllamaLink(probe) {\n                    Link(ModelGate.ollamaLink"))
    }
}
