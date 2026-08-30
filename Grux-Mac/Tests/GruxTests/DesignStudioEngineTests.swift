import XCTest
@testable import Grux

// Pure, seam-free unit tests for the DesignStudioEngine estimate math and the
// assistant-summary composition. These exercise the static helpers directly, so
// they need no network, no disk, and no bound seams. MainActor-isolated because
// the engine (and thus its static helpers) is MainActor-isolated.
@MainActor
final class DesignStudioEngineTests: XCTestCase {

    // MARK: - Estimate input-token folding

    func testApproxInputTokensFoldsDesignSystemChars() {
        let base = DesignStudioEngine.approxInputTokens(
            transcriptChars: 400, briefChars: 0, designSystemChars: 0, systemPromptBudget: 0)
        let withDS = DesignStudioEngine.approxInputTokens(
            transcriptChars: 400, briefChars: 0, designSystemChars: 400, systemPromptBudget: 0)
        XCTAssertEqual(base, 100, "400 chars / 4")
        XCTAssertEqual(withDS, 200, "800 chars / 4, the design system is folded in")
        XCTAssertGreaterThan(withDS, base, "a bound design system raises the priced input")
    }

    func testApproxInputTokensFoldsEveryBucketAndFloorsAtOne() {
        XCTAssertEqual(
            DesignStudioEngine.approxInputTokens(transcriptChars: 40, briefChars: 40, designSystemChars: 40, systemPromptBudget: 40),
            40, "160 chars / 4")
        XCTAssertEqual(
            DesignStudioEngine.approxInputTokens(transcriptChars: 0, briefChars: 0, designSystemChars: 0, systemPromptBudget: 0),
            1, "never below 1 token")
    }

    // MARK: - Draft mode

    func testDraftModeSelectsHaikuAndSmallerBudget() {
        XCTAssertEqual(DesignStudioEngine.effectiveModel(draftMode: true, requested: "claude-opus-4-8"),
                       "claude-haiku-4-5-20251001")
        XCTAssertEqual(DesignStudioEngine.effectiveModel(draftMode: false, requested: "claude-opus-4-8"),
                       "claude-opus-4-8")
        XCTAssertNil(DesignStudioEngine.effectiveModel(draftMode: false, requested: nil))
        XCTAssertEqual(DesignStudioEngine.effectiveMaxTokens(draftMode: true), 4000)
        XCTAssertEqual(DesignStudioEngine.effectiveMaxTokens(draftMode: false),
                       DesignStudioEngine.maxGenerationTokens)
    }

    // MARK: - Assistant summary composition

    func testComposeSummaryDoesNotDoubleThePrefix() {
        let summary = DesignStudioEngine.composeAssistantSummary(
            prose: "Built a hero.",
            filesWritten: ["site/index.html"],
            critique: "Critique: pass on all 5 dimensions.")
        XCTAssertTrue(summary.contains("Critique: pass on all 5 dimensions."))
        XCTAssertFalse(summary.contains("Critique: Critique:"), "the critic prefix is never doubled")
    }

    func testComposeSummaryCarriesSkipNoteVerbatim() {
        let summary = DesignStudioEngine.composeAssistantSummary(
            prose: "",
            filesWritten: ["site/index.html"],
            critique: "(critique skipped: no API key)")
        XCTAssertTrue(summary.contains("(critique skipped: no API key)"))
        XCTAssertFalse(summary.contains("Critique:"), "a skip note is not relabeled")
    }

    func testComposeSummaryOmitsEmptyCritique() {
        let summary = DesignStudioEngine.composeAssistantSummary(
            prose: "Done.", filesWritten: ["site/index.html"], critique: nil)
        XCTAssertFalse(summary.contains("Critique"))
        XCTAssertTrue(summary.contains("Wrote 1 file: site/index.html."))
    }

    // MARK: - Estimate agrees with generation (window + pinned design system)

    // Captures the DesignEstimateContext the engine builds so the priced input
    // can be asserted against what generation actually sends.
    private final class CapturingEstimator: DesignRunEstimating {
        var lastContext: DesignEstimateContext?
        func estimate(for context: DesignEstimateContext) -> DesignRunEstimate? {
            lastContext = context
            return DesignRunEstimate(
                inputTokens: context.approxInputTokens,
                maxOutputTokens: context.maxOutputTokens,
                primary: DesignRouteCost(route: context.route, modelId: context.modelId ?? "x",
                                         estimatedUSD: 0, label: "$0 estimated"))
        }
    }

    // Design-system seam whose active count and pinned markdown are set by the test.
    private final class FakeDesignSystemProvider: DesignSystemProviding {
        var activeChars = 0
        var pinnedMarkdownByFile: [String: String] = [:]
        func activeSystemMarkdown(brandSlug: String?) -> String? { nil }
        func activeSystemLabel(brandSlug: String?) -> String? { nil }
        func activeSystemCharCount(brandSlug: String?) -> Int { activeChars }
        func systemMarkdown(forPinnedFile file: String) -> String? { pinnedMarkdownByFile[file] }
    }

    private func makeTempStore() -> DesignProjectStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-engine-est-\(UUID().uuidString)", isDirectory: true)
        return DesignProjectStore(rootDir: dir)
    }

    func testEstimatePricesOnlyTheLastTwentyMessages() {
        let store = makeTempStore()
        let engine = DesignStudioEngine(store: store)
        let capturing = CapturingEstimator()
        let priorEstimator = DesignStudioEngine.estimator
        let priorProvider = DesignStudioEngine.designSystemProvider
        DesignStudioEngine.estimator = capturing
        DesignStudioEngine.designSystemProvider = nil
        defer {
            DesignStudioEngine.estimator = priorEstimator
            DesignStudioEngine.designSystemProvider = priorProvider
        }

        let proj = store.create(title: "Long chat")
        let msg = String(repeating: "x", count: 40)
        let config = DesignRunConfig(route: .api)

        // Fill exactly the window, then keep priced input.
        for _ in 0..<DesignStudioEngine.transcriptWindow {
            store.appendMessage(id: proj.id, DesignChatMessage(role: .user, text: msg))
        }
        _ = engine.estimate(brief: "", config: config, projectId: proj.id)
        let atWindow = capturing.lastContext?.approxInputTokens

        // Ten MORE identical messages must NOT raise the priced input: generation
        // sends only the last `transcriptWindow`, so the estimate prices the same.
        for _ in 0..<10 {
            store.appendMessage(id: proj.id, DesignChatMessage(role: .user, text: msg))
        }
        _ = engine.estimate(brief: "", config: config, projectId: proj.id)
        let overWindow = capturing.lastContext?.approxInputTokens

        XCTAssertNotNil(atWindow)
        XCTAssertEqual(atWindow, overWindow, "pricing the whole transcript overstates cost")
    }

    func testEstimateFoldsPinnedDesignSystemNotJustBrandActive() {
        let store = makeTempStore()
        let engine = DesignStudioEngine(store: store)
        let capturing = CapturingEstimator()
        let provider = FakeDesignSystemProvider()
        provider.activeChars = 40                                    // brand-active system
        provider.pinnedMarkdownByFile["acme-design"] = String(repeating: "y", count: 4000)  // the pin
        let priorEstimator = DesignStudioEngine.estimator
        let priorProvider = DesignStudioEngine.designSystemProvider
        DesignStudioEngine.estimator = capturing
        DesignStudioEngine.designSystemProvider = provider
        defer {
            DesignStudioEngine.estimator = priorEstimator
            DesignStudioEngine.designSystemProvider = priorProvider
        }

        // A project pinned to a specific design-system file: generation injects the
        // PINNED markdown (4000 chars), not the brand's active system (40 chars).
        let proj = store.create(title: "Pinned", brandSlug: "acme", designSystemFile: "acme-design")
        _ = engine.estimate(brief: "", config: DesignRunConfig(route: .api, brandSlug: "acme"), projectId: proj.id)
        let priced = capturing.lastContext?.approxInputTokens ?? 0
        // The pin's 4000 chars (~1000 tokens) must be priced; the active count (40)
        // would understate by nearly that whole amount.
        XCTAssertGreaterThan(priced, 4000 / 4, "the pinned design system is folded into the priced input")
    }
}
