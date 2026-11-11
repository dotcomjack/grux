import XCTest
@testable import Grux

/// D111: FIRST RUN NAMES THE MODEL IT WILL USE, IN WORDS.
///
/// Walked on the Mac Mini 2026-11-01: "Connect a model" said "Grux found
/// gruxai.com/grux/grux-local:2b running here. Use it", and "Use the model on
/// this Mac" then kept `qwen3.5:4b`. The line named Ollama's most recently
/// pulled tag; the button adopted the configured model, then the headline, then
/// the first. One function now answers both, and the line says the catalog name.
@MainActor
final class FirstRunNamesTheModelItUsesTests: XCTestCase {

    private let grux2 = "gruxai.com/grux/grux-local:2b"
    private let grux4 = "gruxai.com/grux/grux-local:4b"

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[rest.startIndex..<end.lowerBound])
    }

    // MARK: - The model named is the model adopted

    /// The Mini's case: a configured model that is installed is kept, whatever
    /// Ollama listed first.
    func test_aConfiguredInstalledModelIsTheOneNamed() {
        XCTAssertEqual(ModelGate.modelToUse(configured: "qwen3.5:4b",
                                            installed: [grux2, "grux-local:4b", "qwen3.5:4b"],
                                            headline: grux4),
                       "qwen3.5:4b")
    }

    /// A stranger who pulled Grux Local after another model: the headline wins
    /// over the shipped default and over the listing order.
    func test_theInstalledHeadlineIsNamedOverTheListingOrder() {
        XCTAssertEqual(ModelGate.modelToUse(configured: GruxConfig.defaultLocalModel,
                                            installed: ["mistral:7b", grux4],
                                            headline: grux4),
                       grux4)
    }

    /// Nothing better known: the configured model when it is here, else the first usable.
    func test_withNoHeadlineInstalledTheFallbacksMatchTheAdoption() {
        XCTAssertEqual(ModelGate.modelToUse(configured: "llama3.2:3b",
                                            installed: ["mistral:7b", "llama3.2:3b"], headline: grux4),
                       "llama3.2:3b")
        XCTAssertEqual(ModelGate.modelToUse(configured: "llama3.2:3b",
                                            installed: ["mistral:7b", "phi4:14b"], headline: grux4),
                       "mistral:7b")
        XCTAssertNil(ModelGate.modelToUse(configured: "llama3.2:3b", installed: [], headline: grux4))
        XCTAssertNil(ModelGate.modelToUse(configured: "llama3.2:3b",
                                          installed: [GruxConfig.supersededLocalModel], headline: nil),
                     "the superseded model is not something to offer")
    }

    /// Exhaustive over small inputs: whatever the order, the named model is
    /// exactly what `installedModelToAdopt` would leave configured.
    func test_theNamedModelIsAlwaysWhatTheButtonLeavesConfigured() {
        let pool = [grux2, grux4, "qwen3.5:4b", "llama3.2:3b", GruxConfig.supersededLocalModel]
        var lists: [[String]] = [[]]
        for tag in pool { lists += lists.map { $0 + [tag] } }
        for installed in lists {
            for order in [installed, installed.reversed()] {
                for configured in pool + ["absent:1b"] {
                    for headline in [nil, grux4, grux2] as [String?] {
                        let named = ModelGate.modelToUse(configured: configured, installed: order, headline: headline)
                        let adopt = GruxConfig.installedModelToAdopt(configured: configured, installed: order,
                                                                     headline: headline)
                        let usable = GruxConfig.usableLocalModels(order)
                        let after = usable.isEmpty ? nil : (adopt ?? configured)
                        XCTAssertEqual(named, after, "installed \(order) configured \(configured) headline \(String(describing: headline))")
                    }
                }
            }
        }
    }

    // MARK: - In words

    func test_aCatalogModelIsNamedByItsCatalogName() {
        XCTAssertEqual(Cookbook.personName(for: grux2), "Grux Local 2B")
        XCTAssertEqual(Cookbook.personName(for: grux4), "Grux Local 4B")
        XCTAssertEqual(Cookbook.personName(for: "qwen3.5:4b"), "Qwen 3.5 4B")
        XCTAssertEqual(Cookbook.personName(for: "GRUXAI.COM/grux/grux-local:2b"), "Grux Local 2B")
    }

    func test_aTagOutsideTheCatalogIsNamedAsItIs() {
        XCTAssertEqual(Cookbook.personName(for: "mistral:7b"), "mistral:7b")
        XCTAssertEqual(Cookbook.personName(for: "grux-local:2b"), "grux-local:2b")
    }

    /// The next screen counted "7 model(s) installed".
    func test_theFoundScreenCountsModelsInWords() {
        func line(_ tags: [String]) -> String {
            ModelUpdateReport.build(profile: HardwareProfile.detect(), hasCloudModel: false, routesToCloud: false,
                                    localServerRunning: true, installedTags: tags).localServerSummary
        }
        XCTAssertEqual(line([]), "Ollama is running, with no models installed yet.")
        XCTAssertEqual(line([grux2]), "Ollama is running, 1 model installed.")
        XCTAssertEqual(line([grux2, grux4]), "Ollama is running, 2 models installed.")
    }

    /// D170 item 5: "9 models installed" over a catalog with two Installed
    /// chips reads as seven missing. The count says how many are in the catalog.
    func test_theCountSaysHowManyAreInTheCatalog() throws {
        func line(_ tags: [String]) -> String {
            ModelUpdateReport.build(profile: HardwareProfile.detect(), hasCloudModel: false, routesToCloud: false,
                                    localServerRunning: true, installedTags: tags).localServerSummary
        }
        XCTAssertEqual(line([grux2, "mistral:7b", "phi3:latest"]),
                       "Ollama is running, 3 models installed, 1 of them in Grux's catalog.")
        XCTAssertEqual(line(["mistral:7b"]),
                       "Ollama is running, 1 model installed, not from Grux's catalog.")
        XCTAssertEqual(Cookbook.installedCountPhrase([grux2, grux4, "mistral:7b"]),
                       "3 models installed, 2 of them in Grux's catalog")
        XCTAssertEqual(Cookbook.installedCountPhrase(["mistral:7b", "phi3"]),
                       "2 models installed, none of them in Grux's catalog")
        // W57-FIX P3 7: "1 of them in Grux's catalog on this Mac" read as a catalog kept on this Mac.
        XCTAssertEqual(Cookbook.installedCountPhrase([grux2, "mistral:7b", "phi3"], onThisMac: true),
                       "3 models installed on this Mac, 1 of them in Grux's catalog")
        XCTAssertEqual(Cookbook.installedCountPhrase(["mistral:7b"], onThisMac: true),
                       "1 model installed on this Mac, not from Grux's catalog")
        XCTAssertEqual(Cookbook.installedCountPhrase([grux2], onThisMac: true), "1 model installed on this Mac")
        XCTAssertEqual(Cookbook.installedCountPhrase([], onThisMac: true), "0 models installed on this Mac")
        let view = try source("Sources/Grux/LocalModelCookbook/CookbookView.swift")
        XCTAssertTrue(view.contains("Text(Cookbook.installedCountPhrase(ollama.installedTags, onThisMac: true))"),
                      "the Cookbook pane counts installed models its own way again")
    }

    // MARK: - The screen uses both

    func test_theProbeAndTheButtonAskTheSameFunction() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        let probe = try XCTUnwrap(body(of: "private func probeForLocalModel()", in: src))
        XCTAssertTrue(probe.contains("ModelGate.modelToUse("), "the found line names a model of its own choosing")
        XCTAssertFalse(probe.contains("installedTags).first"), "the found line names Ollama's listing order")
        XCTAssertTrue(probe.contains("isHealthy()"),
                      "the probe must read the server version before the headline, as the button does (D25)")
        let use = try XCTUnwrap(body(of: "private func useLocalModel(", in: src))
        XCTAssertTrue(use.contains("ModelGate.modelToUse("), "the button adopts by a different rule than the line names")
        XCTAssertFalse(use.contains("GruxConfig.installedModelToAdopt("))
        XCTAssertTrue(src.contains("ModelGate.foundDetail(model: Cookbook.personName(for: found))"),
                      "the found line shows a raw pull tag")
    }
}
