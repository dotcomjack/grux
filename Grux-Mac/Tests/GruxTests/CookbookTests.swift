import XCTest
@testable import Grux

// Item 4 (Local Model Cookbook) coverage. Pure logic only: tier mapping,
// memory budgeting, fit scoring, and recommendation ordering, all against
// fabricated HardwareProfile values so no test ever touches sysctl or Metal.
final class CookbookTests: XCTestCase {

    private func makeProfile(ramGB: Double, gpuGB: Double, unified: Bool = true,
                             appleSilicon: Bool = true) -> HardwareProfile {
        HardwareProfile(
            chipName: "Test Chip",
            physicalMemoryBytes: UInt64(ramGB * 1_073_741_824),
            gpuWorkingSetBytes: UInt64(gpuGB * 1_073_741_824),
            cpuCoreCount: 10,
            hasUnifiedMemory: unified,
            isAppleSilicon: appleSilicon
        )
    }

    /// A FABRICATED model, for the same reason HardwareProfile is fabricated above:
    /// so no test depends on the shipping catalog.
    ///
    /// This used to be `Cookbook.catalog.first { $0.id == id }!`, pinning five real
    /// tags as fixtures. That made the fit MATH untestable without freezing a
    /// catalog whose entire purpose is to move, and it did exactly what a force
    /// unwrap does when the catalog was refreshed on 2026-08-21: the suite did not
    /// fail, it CRASHED with signal 5, taking all seventeen tests in this file with
    /// it and reporting nothing about the thing that actually changed.
    private func makeModel(memoryGB: Double, id: String = "test:model") -> CookbookModel {
        CookbookModel(
            id: id, displayName: "Test", parameterLabel: "0B",
            diskGB: memoryGB * 0.66, estimatedMemoryGB: memoryGB,
            contextTokens: 131_072, strengths: "fixture", supportsTools: true)
    }

    // MARK: - Tier selection

    func test_tierMapping_boundaries() {
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 8), .ram8)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 11.9), .ram8)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 16), .ram16)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 23.9), .ram16)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 24), .ram32)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 36), .ram32)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 64), .ram64)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 128), .ram128)
        XCTAssertEqual(MemoryTier.tier(forMemoryGB: 512), .ram128)
    }

    func test_tierOrdering_isComparable() {
        XCTAssertTrue(MemoryTier.ram8 < MemoryTier.ram16)
        XCTAssertTrue(MemoryTier.ram64 < MemoryTier.ram128)
        XCTAssertFalse(MemoryTier.ram32 < MemoryTier.ram16)
    }

    func test_profileExposesTier() {
        XCTAssertEqual(makeProfile(ramGB: 16, gpuGB: 11).memoryTier, .ram16)
        XCTAssertEqual(makeProfile(ramGB: 128, gpuGB: 96).memoryTier, .ram128)
    }

    // MARK: - Model budget

    func test_budget_usesGPUWorkingSet_whenReported() {
        let p = makeProfile(ramGB: 32, gpuGB: 24)
        XCTAssertEqual(p.modelBudgetGB, 24, accuracy: 0.01)
    }

    func test_budget_clampsGPUWorkingSet_toPhysicalRAM() {
        // Defensive: a driver reporting a working set above RAM must not
        // inflate the budget.
        let p = makeProfile(ramGB: 16, gpuGB: 20)
        XCTAssertEqual(p.modelBudgetGB, 16, accuracy: 0.01)
    }

    func test_budget_fallsBackTo70PercentRAM_withoutMetal() {
        let p = makeProfile(ramGB: 32, gpuGB: 0, unified: false)
        XCTAssertEqual(p.modelBudgetGB, 22.4, accuracy: 0.01)
    }

    // MARK: - Fit rating

    func test_fit_thresholds() {
        // Budget 20 GB. The ratios are what is under test, not any particular
        // model: 4 -> 0.20 great, 9 -> 0.45 great, 13 -> 0.65 good,
        // 15 -> 0.75 tight, 22 -> 1.10 tooBig.
        let p = makeProfile(ramGB: 32, gpuGB: 20)
        XCTAssertEqual(Cookbook.fit(of: makeModel(memoryGB: 4),  in: p), .great)
        XCTAssertEqual(Cookbook.fit(of: makeModel(memoryGB: 9),  in: p), .great)
        XCTAssertEqual(Cookbook.fit(of: makeModel(memoryGB: 13), in: p), .good)
        XCTAssertEqual(Cookbook.fit(of: makeModel(memoryGB: 15), in: p), .tight)
        XCTAssertEqual(Cookbook.fit(of: makeModel(memoryGB: 22), in: p), .tooBig)
    }

    func test_fit_zeroBudget_isAlwaysTooBig() {
        let p = makeProfile(ramGB: 0, gpuGB: 0)
        for m in Cookbook.catalog {
            XCTAssertEqual(Cookbook.fit(of: m, in: p), .tooBig, "\(m.id) should be tooBig on a zero-budget machine")
        }
    }

    func test_fit_neverDegrades_whenBudgetGrows() {
        let small = makeProfile(ramGB: 16, gpuGB: 11)
        let big = makeProfile(ramGB: 128, gpuGB: 96)
        let order: [ModelFit: Int] = [.tooBig: 0, .tight: 1, .good: 2, .great: 3]
        for m in Cookbook.catalog {
            let a = order[Cookbook.fit(of: m, in: small)]!
            let b = order[Cookbook.fit(of: m, in: big)]!
            XCTAssertGreaterThanOrEqual(b, a, "\(m.id) got a worse fit on bigger hardware")
        }
    }

    // MARK: - Recommendations

    func test_recommended_excludesTooBig() {
        let p = makeProfile(ramGB: 8, gpuGB: 5.5)
        let recs = Cookbook.recommended(for: p)
        XCTAssertFalse(recs.isEmpty)
        for m in recs {
            XCTAssertNotEqual(Cookbook.fit(of: m, in: p), .tooBig)
        }
        XCTAssertFalse(recs.contains { $0.id == "llama3.3:70b" })
    }

    func test_recommended_sortedByScoreDescending() {
        let p = makeProfile(ramGB: 64, gpuGB: 48)
        let recs = Cookbook.recommended(for: p)
        let scores = recs.map { Cookbook.fitScore(of: $0, in: p) }
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    // These two assert BEHAVIOUR rather than a tag. Pinning "llama3.2:3b" and
    // "llama3.3:70b" made a correct catalog refresh look like a regression: the
    // 2026-08-21 refresh replaced both with newer models and the only thing that
    // had actually changed was the recommendation getting better.
    //
    // What must stay true is the property: a small machine is offered something it
    // can actually run, a big machine is not condescended to with a 2B, and neither
    // is handed a model that does not fit.

    func test_headline_smallMachine_picksSomethingThatActuallyFits() {
        // 8 GB Air class.
        let p = makeProfile(ramGB: 8, gpuGB: 5.5)
        let pick = Cookbook.headline(for: p)
        let m = try! XCTUnwrap(pick, "an 8 GB Mac should still be offered something")
        XCTAssertLessThanOrEqual(m.estimatedMemoryGB, 5.5,
            "\(m.id) needs \(m.estimatedMemoryGB) GB and the budget is 5.5")
        XCTAssertNotEqual(Cookbook.fit(of: m, in: p), .tooBig)
    }

    func test_headline_bigMachine_reachesForRealCapacity() {
        // Mac Studio class: 96 GB GPU budget.
        let p = makeProfile(ramGB: 128, gpuGB: 96)
        let m = try! XCTUnwrap(Cookbook.headline(for: p))
        XCTAssertGreaterThan(m.estimatedMemoryGB, 20,
            "a 96 GB budget was offered \(m.id) at \(m.estimatedMemoryGB) GB, which wastes the machine")
        XCTAssertNotEqual(Cookbook.fit(of: m, in: p), .tooBig)
    }

    /// The headline must never exceed the budget, at any size. This is the
    /// invariant the two tests above are specific cases of.
    func test_headline_neverExceedsBudget_atAnySize() {
        for gpu in [2.0, 5.5, 12.0, 20.0, 48.0, 96.0, 192.0] {
            let p = makeProfile(ramGB: gpu * 1.5, gpuGB: gpu)
            guard let m = Cookbook.headline(for: p) else { continue }
            XCTAssertLessThanOrEqual(m.estimatedMemoryGB, gpu,
                "at a \(gpu) GB budget the headline was \(m.id) needing \(m.estimatedMemoryGB) GB")
        }
    }

    func test_headline_nil_whenNothingFits() {
        let p = makeProfile(ramGB: 2, gpuGB: 1.5)
        XCTAssertNil(Cookbook.headline(for: p))
    }

    // MARK: - Persistence model

    func test_cookbookState_roundTrips() throws {
        var s = CookbookState.empty
        s.selectedModelId = "qwen3:14b"
        s.pulledModelIds = ["llama3.1:8b", "qwen3:14b"]
        s.autoServeOnLaunch = true
        s.lastProfile = makeProfile(ramGB: 24, gpuGB: 18)

        let enc = JSONEncoder()
        let dec = JSONDecoder()
        let decoded = try dec.decode(CookbookState.self, from: try enc.encode(s))
        XCTAssertEqual(decoded, s)
    }

    func test_cookbookState_decodesEmptyObject_withDefaults() throws {
        // A pre-existing empty cookbook.json must not explode.
        let decoded = try JSONDecoder().decode(CookbookState.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.selectedModelId)
        XCTAssertEqual(decoded.pulledModelIds, [])
        XCTAssertFalse(decoded.autoServeOnLaunch)
        XCTAssertNil(decoded.lastProfile)
    }

    // MARK: - Catalog sanity

    func test_catalog_idsAreUnique_andFiguresArePositive() {
        let ids = Cookbook.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for m in Cookbook.catalog {
            XCTAssertGreaterThan(m.diskGB, 0)
            XCTAssertGreaterThan(m.estimatedMemoryGB, m.diskGB * 0.5)
            XCTAssertGreaterThan(m.contextTokens, 0)
        }
    }
}
