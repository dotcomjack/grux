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

    /// The press is the only fetch: the button passes fetchRecommended, the
    /// pinned "use the model on this Mac" does not, and the pressed model is
    /// the one chat is pointed at.
    func test_onlyTheButtonFetchesGruxLocalAndChatUsesIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"),
                             encoding: .utf8)
        XCTAssertEqual(src.components(separatedBy: "useLocalModel(fetchRecommended: true)").count - 1, 1)
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
}
