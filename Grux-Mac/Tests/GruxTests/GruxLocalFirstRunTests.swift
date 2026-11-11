import XCTest
@testable import Grux

/// Grux 3.2: first run names the Grux Local this Mac's headline is, with its
/// download, and one press of that button fetches it and points chat at it,
/// even when another local model is already installed.
@MainActor
final class GruxLocalFirstRunTests: XCTestCase {
    private func entry(_ id: String) throws -> CookbookModel {
        try XCTUnwrap(Cookbook.catalog.first { $0.id == id })
    }

    func test_theButtonNamesGruxLocalAndItsDownload() throws {
        let four = try entry("gruxai.com/grux/grux-local:4b")
        XCTAssertEqual(ModelGate.recommendedLocal(four), four)
        XCTAssertNil(ModelGate.recommendedLocal(try entry("llama3.2:3b")), "only a Grux Local is named")
        XCTAssertNil(ModelGate.recommendedLocal(nil))
        XCTAssertEqual(ModelGate.localButton(four), "Use Grux Local 4B, recommended for this Mac (4.3 GB download)")
        XCTAssertEqual(ModelGate.localButton(four, installed: true), "Use Grux Local 4B, recommended for this Mac")
        XCTAssertEqual(ModelGate.localButton(nil), "Use a local model instead")
        XCTAssertTrue(ModelGate.gruxLocalLine(four).contains("Nothing downloads until you press the button"))
        for text in [ModelGate.localButton(four), ModelGate.gruxLocalLine(four)] {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
        }
    }

    /// The press is the only fetch: the button passes fetchRecommended (and
    /// its Try again, after a download gave up), the pinned "use the model on
    /// this Mac" does not, and the pressed model is the one chat is pointed at.
    func test_onlyTheButtonFetchesGruxLocalAndChatUsesIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"),
                             encoding: .utf8)
        // The button, its Try again, and the same press asked from outside
        // (fire-first-run-local), on appearing and while the step is up.
        XCTAssertEqual(src.components(separatedBy: "useLocalModel(fetchRecommended: true)").count - 1, 3)
        XCTAssertTrue(src.contains("guard model.stage == .modelKey, !probingLocal, !model.validating else {"),
                      "the asked press runs while the step is busy or gone")
        XCTAssertTrue(src.contains("guard !probingLocal, !model.validating else { return }\n        localError = nil"),
                      "a second press runs beside the first")
        XCTAssertTrue(src.contains("installed: recommendedLocal.map { ollama.isInstalled($0.id) } ?? false)) {\n                            useLocalModel(fetchRecommended: true)"),
                      "the Grux Local button does not fetch")
        XCTAssertTrue(src.contains("Button(ModelGate.tryAgain) { useLocalModel(fetchRecommended: true) }"),
                      "a fetch other than the button and its Try again")
        XCTAssertFalse(src.contains("} else if probe.model != nil {\n            useLocalModel(fetchRecommended: true)"),
                       "the pinned use-what-is-here button fetches")
        XCTAssertTrue(src.contains("let wanted = fetchRecommended ? recommendedLocal : nil"))
        XCTAssertTrue(src.contains("guard let pick = wanted ?? Cookbook.headline(for: HardwareProfile.detect())"))
        XCTAssertTrue(src.contains("if let chosen = wanted.map({ settledPick ?? $0 }), OllamaManager.shared.isInstalled(chosen.id) {"))
    }

    /// Every Grux Local tag in the catalog is the host-qualified one gruxai.com
    /// serves, so Pull never asks ollama.com for a model it does not have.
    func test_everyGruxLocalTagIsHostQualified() {
        let ids = Cookbook.catalog.filter { $0.displayName == "Grux Local" }.map(\.id)
        XCTAssertEqual(ids.sorted(), ["gruxai.com/grux/grux-local:2b", "gruxai.com/grux/grux-local:4b",
                                      "gruxai.com/grux/grux-local:9b"])
    }

    /// fire-first-run-local brings a showing flow to the model step and asks
    /// for one press; with no flow showing it asks nothing; finishing,
    /// resetting or leaving the step drops an unanswered ask.
    func test_anAskedPressReachesTheModelStepOnce() throws {
        let m = OnboardingModel.shared
        let url = Persistence.supportDir.appendingPathComponent("onboarding.json")
        let savedBytes = try? Data(contentsOf: url)
        let savedStage = m.stage, savedSkipped = m.skippedFirstLook
        let savedHub = OptimizeHubState.shared.isExpanded, savedTab = AppState.shared.requestedTab
        defer {
            if savedStage == .done {
                if m.stage != .done { m.finish(skippedFirstLook: savedSkipped, sendFirstExchange: false) }
            } else {
                m.reset()
                var hops = 0
                while m.stage != savedStage, m.stage != .done, hops < 20 { m.advance(from: m.stage); hops += 1 }
            }
            if let savedBytes { try? savedBytes.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
            OptimizeHubState.shared.isExpanded = savedHub
            AppState.shared.requestedTab = savedTab
        }
        m.reset()
        XCTAssertTrue(m.requestLocalPress())
        XCTAssertEqual(m.stage, .modelKey)
        XCTAssertTrue(m.takeLocalPress())
        XCTAssertFalse(m.takeLocalPress(), "one request pressed twice")

        XCTAssertTrue(m.requestLocalPress())
        m.finish(skippedFirstLook: true, sendFirstExchange: false)
        XCTAssertFalse(m.takeLocalPress(), "an ask outlived the finished flow")
        XCTAssertFalse(m.requestLocalPress(), "pressed with no first run showing")

        m.reset()
        XCTAssertTrue(m.requestLocalPress())
        m.reset()
        XCTAssertFalse(m.takeLocalPress(), "an ask outlived a reset")

        XCTAssertTrue(m.requestLocalPress())
        m.completeModelKey()
        XCTAssertFalse(m.takeLocalPress(), "an ask outlived leaving the step")
    }
}
