import XCTest
@testable import Grux

/// D-COOKBOOK (3.2): the Cookbook ranks local models by MEASURED quality on
/// Grux's own jobs, not by how much memory they take.
///
/// The S1 eval (273 synthetic cases over 11 of Grux's local-model jobs, sent
/// exactly as this code sends them, with `"think": false`) measured that size is
/// not quality: gemma4:26b scored 0.945 and llama3.3:70b 0.668. Ranking by
/// `estimatedMemoryGB` handed a 64 GB Mac the 35B and a 16 GB Mac a vision model
/// that returned empty on every triage call it was given.
final class CookbookMeasuredQualityTests: XCTestCase {

    private func mac(ramGB: Double, gpuGB: Double) -> HardwareProfile {
        HardwareProfile(
            chipName: "Test Chip",
            physicalMemoryBytes: UInt64(ramGB * 1_073_741_824),
            gpuWorkingSetBytes: UInt64(gpuGB * 1_073_741_824),
            cpuCoreCount: 10,
            hasUnifiedMemory: true,
            isAppleSilicon: true)
    }

    private func model(_ id: String, memoryGB: Double, quality: Double?) -> CookbookModel {
        CookbookModel(
            id: id, displayName: "Test", parameterLabel: "0B",
            diskGB: memoryGB * 0.66, estimatedMemoryGB: memoryGB,
            contextTokens: 131_072, strengths: "fixture", supportsTools: true,
            measuredQuality: quality, qualitySource: quality == nil ? nil : "fixture")
    }

    // MARK: - The headline per memory tier

    /// Grux Local, Grux's own trained model (operator note 10, 2026-10-23),
    /// served by gruxai.com to `ollama pull`.
    private let gruxLocal4B = "gruxai.com/grux/grux-local:4b"
    private let gruxLocal2B = "gruxai.com/grux/grux-local:2b"

    /// The GPU figures are the ones the other Cookbook suites use (about 75
    /// percent of RAM), plus the 11.84 GB one real 16 GB Mac reads from Metal.
    /// Since Grux Local joined the catalog it is the headline on every tier: the
    /// 4B scored 0.975 on Grux's jobs, above every larger model, and the 2B
    /// (0.939) is the best that rates Great on an 8 GB budget.
    func test_theHeadlinePerMemoryTier_isTheBestMeasuredModelThatFits() {
        let expected: [(HardwareProfile, String, String)] = [
            (mac(ramGB: 8, gpuGB: 5.5), gruxLocal2B, "8 GB"),
            (mac(ramGB: 16, gpuGB: 11), gruxLocal4B, "16 GB"),
            (mac(ramGB: 16, gpuGB: 11.84), gruxLocal4B, "16 GB at a measured 11.84 GB Metal budget"),
            (mac(ramGB: 32, gpuGB: 24), gruxLocal4B, "32 GB"),
            (mac(ramGB: 64, gpuGB: 48), gruxLocal4B, "64 GB"),
            (mac(ramGB: 128, gpuGB: 96), gruxLocal4B, "128 GB"),
        ]
        for (machine, id, tier) in expected {
            XCTAssertEqual(Cookbook.headline(for: machine)?.id, id, "the \(tier) headline")
            XCTAssertEqual(
                Cookbook.defaultModelID(for: machine, userHasChosen: false,
                                        current: GruxConfig.defaultLocalModel),
                id, "the \(tier) default written to config.json")
        }
    }

    // MARK: - The score

    /// The fit factors (1.00, 0.85, 0.40, 0) are unchanged; only what they
    /// multiply moved from footprint to measured quality.
    func test_theFitFactorsMultiplyMeasuredQuality() {
        let machine = mac(ramGB: 16, gpuGB: 10)
        let great = model("t:great", memoryGB: 4.9, quality: 0.8)  // 0.49 of the budget
        let good = model("t:good", memoryGB: 5.0, quality: 0.8)    // exactly 0.50
        let tight = model("t:tight", memoryGB: 7.5, quality: 0.8)  // exactly 0.75
        let tooBig = model("t:big", memoryGB: 9.5, quality: 0.8)   // exactly 0.95
        XCTAssertEqual(Cookbook.fit(of: great, in: machine), .great)
        XCTAssertEqual(Cookbook.fit(of: good, in: machine), .good)
        XCTAssertEqual(Cookbook.fit(of: tight, in: machine), .tight)
        XCTAssertEqual(Cookbook.fit(of: tooBig, in: machine), .tooBig)
        XCTAssertEqual(Cookbook.fitScore(of: great, in: machine), 0.8, accuracy: 1e-12)
        XCTAssertEqual(Cookbook.fitScore(of: good, in: machine), 0.8 * 0.85, accuracy: 1e-12)
        XCTAssertEqual(Cookbook.fitScore(of: tight, in: machine), 0.8 * 0.40, accuracy: 1e-12)
        XCTAssertEqual(Cookbook.fitScore(of: tooBig, in: machine), 0)
    }

    /// An unmeasured model scores its footprint over 100, so a measured model
    /// always outranks an unmeasured one of equal fit, and among unmeasured
    /// models the old bigger-first order still holds.
    func test_aMeasuredModelOutranksAnUnmeasuredOneOfEqualFit() {
        let machine = mac(ramGB: 128, gpuGB: 96)
        let unmeasuredBig = model("t:unmeasured", memoryGB: 47.9, quality: nil)
        let measuredSmall = model("t:measured", memoryGB: 3.0, quality: 0.6)
        let unmeasuredSmall = model("t:unmeasured-small", memoryGB: 3.0, quality: nil)
        XCTAssertEqual(Cookbook.fit(of: unmeasuredBig, in: machine), .great)
        XCTAssertEqual(Cookbook.fitScore(of: unmeasuredBig, in: machine), 0.479, accuracy: 1e-12)
        XCTAssertEqual(
            Cookbook.ranked([unmeasuredBig, measuredSmall, unmeasuredSmall], for: machine,
                            headroom: .full).map(\.id),
            ["t:measured", "t:unmeasured", "t:unmeasured-small"])
    }

    /// Two models with the same score break toward the smaller footprint, and
    /// two that tie on score AND footprint break on id, once and written down.
    func test_ties_breakTowardTheSmallerModel_thenById() {
        let machine = mac(ramGB: 64, gpuGB: 48)
        let a = model("t:b", memoryGB: 6.0, quality: 0.9)
        let b = model("t:a", memoryGB: 6.0, quality: 0.9)
        let c = model("t:c", memoryGB: 5.0, quality: 0.9)
        for order in [[a, b, c], [c, b, a], [b, c, a]] {
            XCTAssertEqual(Cookbook.ranked(order, for: machine, headroom: .full).map(\.id),
                           ["t:c", "t:a", "t:b"])
        }
    }

    /// The real catalog has an exact quality tie (gemma4:12b and qwen3.8:27b,
    /// both 0.927). On a 36 GB budget both rate Great and gemma4:26b only Good,
    /// so the tie decides which of the two ranks first, and it goes to the
    /// smaller model. (It decided the headline until Grux Local outranked both.)
    func test_theCatalogsQualityTie_goesToTheSmallerModel() {
        let machine = mac(ramGB: 48, gpuGB: 36)
        XCTAssertEqual(Cookbook.fit(of: entry("gemma4:26b"), in: machine), .good)
        XCTAssertEqual(Cookbook.fitScore(of: entry("gemma4:12b"), in: machine),
                       Cookbook.fitScore(of: entry("qwen3.8:27b"), in: machine))
        let order = Cookbook.recommended(for: machine).map(\.id)
        XCTAssertEqual(order.filter { $0 == "gemma4:12b" || $0 == "qwen3.8:27b" },
                       ["gemma4:12b", "qwen3.8:27b"])
    }

    // MARK: - The figures

    private func entry(_ id: String) -> CookbookModel {
        guard let m = Cookbook.catalog.first(where: { $0.id == id }) else {
            XCTFail("\(id) is not in the catalog")
            return model(id, memoryGB: 1, quality: nil)
        }
        return m
    }

    func test_everyCatalogModelCarriesItsS1Score() {
        let s1: [String: Double] = [
            "llama3.2:3b": 0.637, "qwen3.5:2b": 0.752, "qwen3-vl:4b": 0.490,
            "qwen3.5:4b": 0.868, "qwen3.5:9b": 0.853, "gemma4:12b": 0.927,
            "mistral-small3.2:24b": 0.781, "gpt-oss:20b": 0.786, "qwen3.8:27b": 0.927,
            "gemma4:26b": 0.945, "qwen3-coder:30b": 0.829, "qwen3.5:35b": 0.840,
            "llama3.3:70b": 0.668, "gpt-oss:120b": 0.856,
        ]
        let s2: [String: Double] = [gruxLocal4B: 0.975, gruxLocal2B: 0.939]
        XCTAssertEqual(Set(Cookbook.catalog.map(\.id)), Set(s1.keys).union(s2.keys))
        for m in Cookbook.catalog where s1[m.id] != nil {
            XCTAssertEqual(m.measuredQuality, s1[m.id], "\(m.id)")
            XCTAssertEqual(m.qualitySource, "S1 2026-10-22", "\(m.id)")
        }
        for (id, score) in s2 {
            XCTAssertEqual(entry(id).measuredQuality, score, id)
            XCTAssertTrue(entry(id).qualitySource?.hasPrefix("S2 sweep") == true, id)
        }
    }

    /// Operator note 10 and 11: Grux Local as Jack shipped it, figures measured
    /// on a 16 GB Mac mini (Ollama /api/ps, MLX nvfp4), and the pitch says the
    /// model was TRAINED to ignore hidden instructions, not that it always does
    /// (65 of 70 and 66 of 70 on the held out set).
    func test_gruxLocal_entriesAreAsShipped() {
        let big = entry(gruxLocal4B), small = entry(gruxLocal2B)
        XCTAssertEqual([big.displayName, small.displayName], ["Grux Local", "Grux Local"])
        XCTAssertEqual([big.parameterLabel, small.parameterLabel], ["4B", "2B"])
        XCTAssertEqual([big.diskGB, small.diskGB], [4.3, 2.6])
        XCTAssertEqual([big.estimatedMemoryGB, small.estimatedMemoryGB], [4.44, 2.65])
        XCTAssertEqual([big.contextTokens, small.contextTokens], [262_144, 262_144])
        XCTAssertTrue(big.supportsTools && small.supportsTools)
        let pitch = "Trained on Grux's own jobs, and to ignore instructions hidden in pasted text"
        XCTAssertEqual([big.strengths, small.strengths], [pitch, pitch])
    }

    /// Read from Ollama at a 16K window, one request at a time.
    func test_theMeasuredFootprintsReplaceTheEstimates() {
        let measured: [String: Double] = [
            "qwen3.5:2b": 2.6, "qwen3.5:4b": 4.4, "qwen3.5:9b": 6.2,
            "gemma4:12b": 9.4, "gemma4:26b": 19.2, "qwen3.8:27b": 17.4,
        ]
        for (id, gb) in measured {
            XCTAssertEqual(entry(id).estimatedMemoryGB, gb, "\(id)")
        }
    }
}
