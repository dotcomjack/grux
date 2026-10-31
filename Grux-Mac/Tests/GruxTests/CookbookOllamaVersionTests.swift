import XCTest
@testable import Grux

/// D25: most of the catalog needs a recent Ollama. Read from each model's own
/// registry config on 2026-10-29 (`requires`): Qwen 3.5, Qwen 3 VL and gpt-oss
/// need 0.30.0, Gemma 4 0.30.9, Qwen 3.8 0.32.12, Grux Local 0.19.0. A Mac on an
/// older Ollama (this Mini ran 0.22.0 a week before) was offered Pull on a
/// headline its server cannot run. Grux now reads the server's version and
/// recommends only what it runs, and says what needs updating.
final class CookbookOllamaVersionTests: XCTestCase {

    private func mac(ramGB: Double, gpuGB: Double) -> HardwareProfile {
        HardwareProfile(
            chipName: "Test Chip",
            physicalMemoryBytes: UInt64(ramGB * 1_073_741_824),
            gpuWorkingSetBytes: UInt64(gpuGB * 1_073_741_824),
            cpuCoreCount: 10,
            hasUnifiedMemory: true,
            isAppleSilicon: true)
    }

    private func needing(_ minimum: String?) -> CookbookModel {
        CookbookModel(
            id: "fixture:1b", displayName: "Fixture", parameterLabel: "1B",
            diskGB: 1, estimatedMemoryGB: 1.5, contextTokens: 8192,
            strengths: "fixture", supportsTools: true, minimumOllama: minimum)
    }

    private func entry(_ id: String) throws -> CookbookModel {
        try XCTUnwrap(Cookbook.catalog.first { $0.id == id }, "no catalog entry \(id)")
    }

    // MARK: - What each model needs

    /// The registry readings, one per catalog entry (`logs/d25-registry-requires.txt`).
    func test_everyCatalogModelCarriesTheOllamaItsRegistryConfigRequires() {
        let measured: [String: String?] = [
            "llama3.2:3b": nil,
            "qwen3.5:2b": "0.30.0",
            "gruxai.com/grux/grux-local:2b": "0.19.0",
            "qwen3-vl:4b": "0.30.0",
            "qwen3.5:4b": "0.30.0",
            "gruxai.com/grux/grux-local:4b": "0.19.0",
            "qwen3.5:9b": "0.30.0",
            "gemma4:12b": "0.30.9",
            "mistral-small3.2:24b": nil,
            "gpt-oss:20b": "0.30.0",
            "qwen3.8:27b": "0.32.12",
            "gemma4:26b": "0.30.9",
            "qwen3-coder:30b": nil,
            "qwen3.5:35b": "0.30.0",
            "llama3.3:70b": nil,
            "gpt-oss:120b": "0.30.0",
        ]
        XCTAssertEqual(Set(Cookbook.catalog.map(\.id)), Set(measured.keys),
                       "a catalog entry was added or removed: read its registry config's requires")
        for model in Cookbook.catalog {
            XCTAssertEqual(model.minimumOllama, measured[model.id] ?? nil, model.id)
        }
    }

    // MARK: - The comparison, on and around every boundary

    func test_aModelRunsOnItsMinimumAndNewer_andNotOneUnder() {
        let m = needing("0.19.0")
        XCTAssertTrue(Cookbook.runs(m, onOllama: "0.19.0"), "equal to the minimum")
        XCTAssertTrue(Cookbook.runs(m, onOllama: "0.19.1"), "one patch over")
        XCTAssertTrue(Cookbook.runs(m, onOllama: "0.20"), "a two-part version over")
        XCTAssertTrue(Cookbook.runs(m, onOllama: "1.0.0"), "a major over")
        XCTAssertFalse(Cookbook.runs(m, onOllama: "0.18.99"), "one under")
        XCTAssertFalse(Cookbook.runs(m, onOllama: "0.18"), "a two-part version under")
        XCTAssertFalse(Cookbook.runs(m, onOllama: "0.4.0"), "compared as numbers, not text")
    }

    func test_partsCompareAsNumbers() {
        XCTAssertTrue(Cookbook.runs(needing("0.30.9"), onOllama: "0.30.10"))
        XCTAssertFalse(Cookbook.runs(needing("0.32.12"), onOllama: "0.32.9"))
        XCTAssertTrue(Cookbook.runs(needing("0.32.12"), onOllama: "0.40.8"))
    }

    /// A release candidate of the minimum carries what the minimum carries.
    func test_aPrereleaseOfTheMinimumRuns_andOneOfAnOlderDoesNot() {
        XCTAssertTrue(Cookbook.runs(needing("0.30.0"), onOllama: "0.30.0-rc1"))
        XCTAssertFalse(Cookbook.runs(needing("0.30.0"), onOllama: "0.29.0-rc4"))
    }

    /// What Grux cannot read hides nothing: no version yet, an empty or unreadable
    /// one, and 0.0.0 (what an Ollama built from source reports).
    func test_anUnknownVersionHidesNothing() {
        let m = needing("0.30.0")
        for v in [nil, "", "garbage", "0.0.0"] as [String?] {
            XCTAssertTrue(Cookbook.runs(m, onOllama: v), "version \(v ?? "nil")")
        }
        XCTAssertTrue(Cookbook.runs(needing(nil), onOllama: "0.1.0"), "a model that states no minimum")
    }

    // MARK: - The recommendation

    /// On an Ollama too old for Grux Local the headline is the best model it runs,
    /// and the default written to config.json follows it.
    func test_theHeadlineIsTheBestModelThisOllamaRuns() {
        let sixteen = mac(ramGB: 16, gpuGB: 11.84)
        XCTAssertEqual(Cookbook.headline(for: sixteen, ollamaVersion: "0.18.0")?.id, "llama3.2:3b")
        XCTAssertEqual(Cookbook.headline(for: mac(ramGB: 8, gpuGB: 5.5), ollamaVersion: "0.18.0")?.id, "llama3.2:3b")
        XCTAssertEqual(Cookbook.defaultModelID(for: sixteen, userHasChosen: false,
                                               current: GruxConfig.defaultLocalModel,
                                               ollamaVersion: "0.18.0"),
                       "llama3.2:3b")
        for v in ["0.18.0", "0.22.0", "0.30.0"] {
            for model in Cookbook.recommended(for: mac(ramGB: 128, gpuGB: 96), ollamaVersion: v) {
                XCTAssertTrue(Cookbook.runs(model, onOllama: v), "\(model.id) recommended on \(v)")
            }
        }
    }

    /// Grux Local needs 0.19.0, so from there it headlines every tier again.
    func test_gruxLocalHeadlinesFromItsMinimumUp() {
        let tiers = [mac(ramGB: 8, gpuGB: 5.5), mac(ramGB: 16, gpuGB: 11.84), mac(ramGB: 64, gpuGB: 48)]
        for machine in tiers {
            XCTAssertEqual(Cookbook.headline(for: machine, ollamaVersion: "0.19.0")?.displayName, "Grux Local")
            XCTAssertEqual(Cookbook.headline(for: machine, ollamaVersion: "0.22.0")?.displayName, "Grux Local")
            XCTAssertNotEqual(Cookbook.headline(for: machine, ollamaVersion: "0.18.99")?.displayName, "Grux Local")
        }
    }

    /// The pane lists what this Ollama cannot run in its own section, never as a
    /// Pull in the recommended one and never as too big.
    func test_theListingSetsAsideWhatNeedsANewerOllama() throws {
        let live = Cookbook.listing(for: mac(ramGB: 16, gpuGB: 11.84), headroom: .full, ollamaVersion: "0.22.0")
        let ids = Set(live.needsNewerOllama.map(\.id))
        XCTAssertTrue(ids.contains("qwen3.5:4b"))
        XCTAssertTrue(ids.contains("qwen3.5:2b"))
        XCTAssertFalse(ids.contains("gruxai.com/grux/grux-local:4b"), "0.22.0 runs Grux Local")
        XCTAssertTrue(Set(live.fitting.map(\.id)).isDisjoint(with: ids))
        XCTAssertTrue(Set(live.tooBig.map(\.id)).isDisjoint(with: ids), "too big wins: it is listed once")
        XCTAssertEqual(live.headline?.id, live.fitting.first?.id)
        XCTAssertEqual(live.ollamaVersion, "0.22.0")

        let current = Cookbook.listing(for: mac(ramGB: 16, gpuGB: 11.84), headroom: .full, ollamaVersion: "0.40.8")
        XCTAssertEqual(current.needsNewerOllama, [], "a current Ollama runs everything")
    }

    func test_theRowSaysWhichOllamaItNeedsAndWhatThisMacHas() throws {
        XCTAssertEqual(Cookbook.needsNewerOllamaLine(try entry("qwen3.5:4b"), have: "0.22.0"),
                       "Needs Ollama 0.30.0 or newer; this Mac has 0.22.0.")
        XCTAssertEqual(Cookbook.needsNewerOllamaLine(try entry("gruxai.com/grux/grux-local:2b"), have: "0.18.0"),
                       "Needs Ollama 0.19.0 or newer; this Mac has 0.18.0.")
    }

    // MARK: - Where the version comes from

    func test_theVersionIsReadFromTheServersOwnAnswer() {
        XCTAssertEqual(OllamaManager.version(fromVersionBody: Data(#"{"version":"0.40.8"}"#.utf8)), "0.40.8")
        XCTAssertNil(OllamaManager.version(fromVersionBody: Data("not json".utf8)))
        XCTAssertNil(OllamaManager.version(fromVersionBody: Data(#"{"name":"x"}"#.utf8)))
        XCTAssertNil(OllamaManager.version(fromVersionBody: Data(#"{"version":"  "}"#.utf8)))
    }
}
