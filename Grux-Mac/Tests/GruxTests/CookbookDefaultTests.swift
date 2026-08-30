import XCTest
@testable import Grux

/// THE COOKBOOK TOLD AND NEVER ACTED, plus the pressure-aware half of the same
/// arithmetic.
///
/// `Cookbook.headline(for:)` has scored the whole catalog against real hardware
/// since the day that file was written, and nothing in the app called it to
/// decide anything. The shipped default was one hardcoded tag,
/// `GruxConfig.defaultLocalModel`, handed identically to an 8 GB laptop and a
/// 128 GB workstation, and the model it named was not even IN the catalog, so
/// the fit scorer could not see the one model the app actually ran. The catalog
/// scored thirteen models nobody used and none of the one everybody used.
///
/// Every machine here is fabricated, for the reason `HardwareProfile` was built
/// as a pure value type in the first place: a test that asserted against the Mac
/// running it would report a different verdict per developer, and the
/// interesting cases (the 8 GB laptop, the machine under memory pressure) are
/// exactly the ones no development machine is ever in.
final class CookbookDefaultTests: XCTestCase {

    /// Apple Silicon reports roughly 75 percent of RAM as the GPU working set,
    /// which is what the Cookbook budgets against. The GPU figure is passed in
    /// rather than derived so a test can also fabricate the awkward machines: a
    /// driver reporting more than RAM, or no Metal device at all.
    private func mac(ramGB: Double, gpuGB: Double) -> HardwareProfile {
        HardwareProfile(
            chipName: "Test Chip",
            physicalMemoryBytes: UInt64(ramGB * 1_073_741_824),
            gpuWorkingSetBytes: UInt64(gpuGB * 1_073_741_824),
            cpuCoreCount: 10,
            hasUnifiedMemory: true,
            isAppleSilicon: true)
    }

    /// The three machines this feature exists for. The GPU numbers match the
    /// fixtures already used in `CookbookTests`, so a change that moves one file
    /// and not the other shows up as a disagreement rather than as two green
    /// suites describing different hardware.
    private var airEightGB: HardwareProfile { mac(ramGB: 8, gpuGB: 5.5) }
    private var laptopSixteenGB: HardwareProfile { mac(ramGB: 16, gpuGB: 11) }
    private var studioSixtyFourGB: HardwareProfile { mac(ramGB: 64, gpuGB: 48) }

    /// `ModelFit` is deliberately not `Comparable`, because ordering it in the
    /// shipping type would invite somebody to sort by it. A test may still need
    /// the order, so it is spelled out here and nowhere else.
    private let generosity: [ModelFit: Int] = [.tooBig: 0, .tight: 1, .good: 2, .great: 3]

    // MARK: - The default is a decision, not a constant

    /// THE ONE THAT MUST NEVER REGRESS. `GruxConfig.migratingLocalModel` exists
    /// because changing a default alone helped nobody who already had Grux, and
    /// the lesson people take from that is usually "overwrite stored values more
    /// willingly". Applied here that is the same bug pointing the other way: this
    /// runs on every successful local discovery, so a version that ignored the
    /// chosen flag would replace a hand-typed model on every launch, forever.
    func test_defaultModelID_leavesAChosenModelAlone() {
        let chosen = "qwen3-coder:30b"
        XCTAssertEqual(
            Cookbook.defaultModelID(for: airEightGB, userHasChosen: true, current: chosen),
            chosen,
            "an 8 GB Mac overwrote a model the user typed")
        XCTAssertEqual(
            Cookbook.defaultModelID(for: studioSixtyFourGB, userHasChosen: true, current: chosen),
            chosen)
    }

    /// Including when the choice is WRONG for the machine. A 30B on an 8 GB Mac
    /// is a bad idea and it is still not ours to undo: the Cookbook already tells
    /// the user it does not fit, and telling them is the entire remit. Silently
    /// swapping a model somebody picked is how an app earns a reputation for
    /// changing settings behind your back.
    func test_defaultModelID_leavesAChosenModelAlone_evenWhenItCannotPossiblyFit() {
        let tooBig = "gpt-oss:120b"
        XCTAssertEqual(
            Cookbook.defaultModelID(for: airEightGB, userHasChosen: true, current: tooBig),
            tooBig)
    }

    /// The ids below are pinned ON PURPOSE, and `CookbookTests` deliberately does
    /// the opposite for its own assertions. That file asserts PROPERTIES because
    /// a catalog refresh must be free to change which model wins. This one
    /// asserts the exact tags because the value now lands in a config file that
    /// survives relaunch: a catalog edit that moves what a stranger's Mac
    /// defaults to should have to be a decision somebody took on purpose, not a
    /// side effect that ships green. If this test fails after a catalog refresh,
    /// read the new pick, agree with it, and update the string.
    func test_defaultModelID_picksTheHeadline_onAnEightGigMac() {
        XCTAssertEqual(
            Cookbook.defaultModelID(for: airEightGB,
                                    userHasChosen: false,
                                    current: GruxConfig.defaultLocalModel),
            "llama3.2:3b",
            "the 8 GB tier is the one this finding was about")
    }

    func test_defaultModelID_picksTheHeadline_onASixteenGigMac() {
        XCTAssertEqual(
            Cookbook.defaultModelID(for: laptopSixteenGB,
                                    userHasChosen: false,
                                    current: GruxConfig.defaultLocalModel),
            "qwen3-vl:4b")
    }

    func test_defaultModelID_picksTheHeadline_onASixtyFourGigMac() {
        XCTAssertEqual(
            Cookbook.defaultModelID(for: studioSixtyFourGB,
                                    userHasChosen: false,
                                    current: GruxConfig.defaultLocalModel),
            "qwen3.5:35b",
            "a 48 GB budget was handed a small model, which wastes the machine")
    }

    /// The three above must not be the same answer, or "reads your hardware" is
    /// decoration. Asserted separately from the ids so the failure message says
    /// which claim broke.
    func test_defaultModelID_actuallyDiffersByMachine() {
        let picks = [airEightGB, laptopSixteenGB, studioSixtyFourGB].map {
            Cookbook.defaultModelID(for: $0, userHasChosen: false, current: GruxConfig.defaultLocalModel)
        }
        XCTAssertEqual(Set(picks).count, 3, "three machine classes got \(picks)")
    }

    /// A Mac too small for anything in the catalog keeps what it had rather than
    /// being handed an empty tag. An empty model id is not a safe fallback: both
    /// `LocalLLM` and `SettingsView` read empty as the shipped default, so
    /// writing one back would be a no-op that LOOKS like a decision, and the
    /// honest surface for this machine is the "No local model" copy in
    /// `ModelUpdateReport`.
    func test_defaultModelID_keepsWhatItHad_whenNothingInTheCatalogFits() {
        let tiny = mac(ramGB: 2, gpuGB: 1.5)
        XCTAssertNil(Cookbook.headline(for: tiny), "the fixture stopped being too small")
        XCTAssertEqual(
            Cookbook.defaultModelID(for: tiny, userHasChosen: false, current: GruxConfig.defaultLocalModel),
            GruxConfig.defaultLocalModel)
    }

    /// An empty stored model is the default wearing different clothes, not a
    /// choice, so it is eligible for the pick.
    func test_userHasChosenModel_treatsEmptyAndTheShippedDefaultAsUnchosen() {
        XCTAssertFalse(Cookbook.userHasChosenModel(""))
        XCTAssertFalse(Cookbook.userHasChosenModel(GruxConfig.defaultLocalModel))
        XCTAssertTrue(Cookbook.userHasChosenModel("qwen3.5:9b"))
        XCTAssertTrue(Cookbook.userHasChosenModel(GruxConfig.supersededLocalModel),
                      "a stored qwen3:8b is migrated on decode, never re-decided here")
    }

    /// RUNS ONCE, NOT EVERY LAUNCH. Feeding the first answer back in must be a
    /// fixed point: the call site fires on every successful local discovery, so a
    /// version that kept re-deciding would fight any later edit the user made,
    /// and would do it silently.
    func test_defaultModelID_isIdempotent_acrossRelaunches() {
        let first = Cookbook.defaultModelID(for: laptopSixteenGB,
                                            userHasChosen: false,
                                            current: GruxConfig.defaultLocalModel)
        let second = Cookbook.defaultModelID(for: laptopSixteenGB,
                                             userHasChosen: Cookbook.userHasChosenModel(first),
                                             current: first)
        XCTAssertEqual(second, first)

        // And a user who edits the stored value afterwards keeps their edit.
        let edited = "gemma4:12b"
        XCTAssertEqual(
            Cookbook.defaultModelID(for: laptopSixteenGB,
                                    userHasChosen: Cookbook.userHasChosenModel(edited),
                                    current: edited),
            edited)
    }

    // MARK: - The small end, which is where the catalog was broken

    /// THE FINDING ITSELF. The tag the app ships as its default has to be
    /// scorable, or the fit column is an opinion about models nobody runs.
    func test_theShippedDefaultIsInTheCatalog() {
        XCTAssertTrue(Cookbook.catalog.contains { $0.id == GruxConfig.defaultLocalModel },
                      "\(GruxConfig.defaultLocalModel) is the shipped default and the fit "
                      + "scorer cannot see it, so it can never be the hardware-scored pick")
    }

    /// AN HONEST ASSERTION, AND NOT THE ONE THIS TEST WAS ASKED FOR.
    ///
    /// The ask was that the 8 GB tier gain a "Great fit" instead of a warning. It
    /// gains a "Good fit". Before this change the best rating an 8 GB Mac could
    /// see was "Tight", because the smallest entry was estimated at 5.0 GB
    /// against a budget near 5.5, and "Tight" plus "Too big" thirteen times is a
    /// warning with no answer attached.
    ///
    /// Reaching "Great" needs an entry under 2.65 GB, and there is no model whose
    /// figures could be sourced offline at that size: the provenance rule at the
    /// top of the catalog says a guessed number is worse than a missing model,
    /// and picking an estimate because it happens to clear a threshold is exactly
    /// the guess that rule forbids. A 1B class entry would do it and needs
    /// somebody with a network to read its published figures.
    ///
    /// So this asserts the improvement that actually happened, and pins the
    /// rating so the day a smaller entry lands, this test has to be revisited
    /// rather than quietly passing.
    func test_eightGigMac_isOfferedSomethingItCanLiveWith() {
        let best = Cookbook.recommended(for: airEightGB)
            .map { Cookbook.fit(of: $0, in: airEightGB) }
            .max { (generosity[$0] ?? 0) < (generosity[$1] ?? 0) }
        XCTAssertEqual(best, .good,
                       "the 8 GB tier's best rating moved off .good, which is either the "
                       + "regression this test was written for or a smaller catalog entry "
                       + "that should be celebrated here")

        let pick = try! XCTUnwrap(Cookbook.headline(for: airEightGB))
        XCTAssertEqual(pick.id, "llama3.2:3b")
        XCTAssertEqual(Cookbook.fit(of: pick, in: airEightGB), .good)
        XCTAssertLessThanOrEqual(pick.estimatedMemoryGB, airEightGB.modelBudgetGB,
                                 "\(pick.id) needs \(pick.estimatedMemoryGB) GB")
    }

    /// The pick for a 16 GB Mac used to depend on the sort implementation.
    /// qwen3-vl:4b and qwen3.5:4b are both estimated at 6.0 GB, so they tie on
    /// score AND on the smaller-model tie-break, and `sorted` promises an
    /// ordering rather than a stable one. That was survivable while the headline
    /// was a label; it stopped being survivable when it started being written
    /// into a config file, because the default a stranger gets would then change
    /// with a toolchain upgrade. The id comparison is arbitrary and it is
    /// arbitrary once.
    func test_headline_isDeterministic_whenTwoModelsTieExactly() {
        let tied = Cookbook.catalog.filter { $0.estimatedMemoryGB == 6.0 }.map(\.id).sorted()
        XCTAssertEqual(tied.count, 2, "the tie this test is about is gone: \(tied)")

        let picks = (0..<25).map { _ in
            Cookbook.headline(for: laptopSixteenGB)?.id
        }
        XCTAssertEqual(Set(picks.compactMap { $0 }).count, 1, "the headline moved between calls")
        XCTAssertEqual(picks.first ?? nil, tied.first)
    }

    // MARK: - Pressure aware scoring

    /// THE INVARIANT THAT MATTERS MOST. A busy machine may be told LESS than a
    /// quiet one and must never be told more, on any model, on any machine, at
    /// any headroom. If this ever inverts, the pressure work is not conservative,
    /// it is a second way to recommend something that will swap.
    func test_pressureAwareFit_isNeverMoreGenerousThanTheStaticOne() {
        let machines = [mac(ramGB: 8, gpuGB: 5.5), mac(ramGB: 16, gpuGB: 11),
                        mac(ramGB: 36, gpuGB: 27), mac(ramGB: 64, gpuGB: 48),
                        mac(ramGB: 128, gpuGB: 96), mac(ramGB: 16, gpuGB: 0)]
        for machine in machines {
            for model in Cookbook.catalog {
                let device = generosity[Cookbook.fit(of: model, in: machine)] ?? 0
                for headroom in MachineLoad.Headroom.allCases {
                    let live = generosity[Cookbook.fit(of: model, in: machine, headroom: headroom)] ?? 0
                    XCTAssertLessThanOrEqual(live, device,
                        "\(model.id) rated better at \(headroom.rawValue) headroom than on the idle machine")
                    XCTAssertGreaterThanOrEqual(
                        Cookbook.loadFactor(of: model, in: machine, headroom: headroom),
                        Cookbook.loadFactor(of: model, in: machine),
                        "\(model.id) claimed a smaller share of a smaller budget")
                }
            }
        }
    }

    /// The existing two-argument calls are the same arithmetic, not merely
    /// similar. `budgetFraction(for: .full)` is 1.00 and multiplying a Double by
    /// 1.00 is exact, so this asserts equality rather than an accuracy window: a
    /// tolerance here would hide precisely the rounding it is meant to catch.
    func test_fullHeadroom_isIdenticalToTheStaticScoring_forEveryModel() {
        for machine in [mac(ramGB: 8, gpuGB: 5.5), mac(ramGB: 16, gpuGB: 11),
                        mac(ramGB: 64, gpuGB: 48), mac(ramGB: 128, gpuGB: 96),
                        mac(ramGB: 32, gpuGB: 0), mac(ramGB: 0, gpuGB: 0)] {
            for model in Cookbook.catalog {
                XCTAssertEqual(Cookbook.loadFactor(of: model, in: machine),
                               Cookbook.loadFactor(of: model, in: machine, headroom: .full),
                               "\(model.id) loadFactor moved at full headroom")
                XCTAssertEqual(Cookbook.fit(of: model, in: machine),
                               Cookbook.fit(of: model, in: machine, headroom: .full),
                               "\(model.id) fit moved at full headroom")
                XCTAssertEqual(Cookbook.fitScore(of: model, in: machine),
                               Cookbook.fitScore(of: model, in: machine, headroom: .full),
                               "\(model.id) score moved at full headroom")
            }
            XCTAssertEqual(Cookbook.recommended(for: machine).map(\.id),
                           Cookbook.recommended(for: machine, headroom: .full).map(\.id),
                           "the recommendation list moved at full headroom")
            XCTAssertEqual(Cookbook.headline(for: machine)?.id,
                           Cookbook.headline(for: machine, headroom: .full)?.id)
        }
    }

    /// The list can only shrink, never reorder into something longer. A busy
    /// machine offered MORE options than an idle one would mean the filter and
    /// the budget disagree about which direction pressure runs.
    func test_recommendationsOnlyShrinkUnderPressure() {
        for machine in [airEightGB, laptopSixteenGB, studioSixtyFourGB] {
            let idle = Set(Cookbook.recommended(for: machine).map(\.id))
            for headroom in MachineLoad.Headroom.allCases {
                let live = Set(Cookbook.recommended(for: machine, headroom: headroom).map(\.id))
                XCTAssertTrue(live.isSubset(of: idle),
                    "at \(headroom.rawValue) headroom the machine gained \(live.subtracting(idle))")
            }
        }
    }

    /// DIRECTION AND STEP SIZE, which is the whole reason the headroom fractions
    /// are blunt round numbers rather than invented precision. A discount that
    /// never moves a rating changes nothing a user would notice, and this is the
    /// case the pressure work was written for: the 16 GB laptop that was told an
    /// 11 GB model was a "Good fit" while most of that budget was already spent.
    func test_aLoadedMachineActuallyLosesARating() {
        let model = try! XCTUnwrap(Cookbook.catalog.first { $0.id == "qwen3.5:9b" },
                                   "fixture model left the catalog")
        XCTAssertEqual(Cookbook.fit(of: model, in: laptopSixteenGB, headroom: .full), .tight)
        XCTAssertEqual(Cookbook.fit(of: model, in: laptopSixteenGB, headroom: .reduced), .tooBig)
    }

    /// A machine at its limit is allowed to have no answer at all, and saying so
    /// is better than naming a model that will swap. The 8 GB Mac reaches that
    /// state at `.minimal`, which is exactly the machine most likely to get
    /// there.
    func test_aMachineAtItsLimitIsAllowedToOfferNothing() {
        XCTAssertNotNil(Cookbook.headline(for: airEightGB, headroom: .full))
        XCTAssertNil(Cookbook.headline(for: airEightGB, headroom: .minimal),
                     "a 2.5 GB live budget was still offered a model")
    }

    // MARK: - The path the user is actually on

    /// EVERY TEST ABOVE THIS LINE CALLED THE OVERLOADS DIRECTLY, and for one
    /// wave that was the entire problem. The pressure-aware scoring was built,
    /// tested green, and reached nobody: measured across `Sources/`, every fit
    /// badge, every "Recommended" line and every "Too big" section still went
    /// through the two-argument device forms, so the tests below `Pressure aware
    /// scoring` proved arithmetic that no user could ever meet. The tests here
    /// go through `Cookbook.listing(for:headroom:)`, which is the one function
    /// `CookbookView` renders, so they fail if the wiring is pulled out again.
    ///
    /// A test that reaches the same function a second private way would prove
    /// the same nothing. That is why these assert on the listing and not on
    /// `fit(of:in:headroom:)` next to it.
    func test_theProductionListing_scoresLowerUnderPressure() {
        for machine in [airEightGB, laptopSixteenGB, studioSixtyFourGB] {
            let idle = Cookbook.listing(for: machine, headroom: .full)
            let squeezed = Cookbook.listing(for: machine, headroom: .minimal)

            XCTAssertLessThan(squeezed.budget.gigabytes, idle.budget.gigabytes,
                              "the live budget did not move")
            XCTAssertEqual(squeezed.budget.deviceGigabytes, idle.budget.gigabytes,
                           "the device number is a hardware fact and must not move")

            // Summed over the whole catalog rather than checked on one model,
            // because a single row moving could be a threshold coincidence. The
            // total can only fall if the budget the pane scored against fell.
            let idleTotal = Cookbook.catalog.reduce(0) { $0 + (generosity[idle.fit(of: $1)] ?? 0) }
            let liveTotal = Cookbook.catalog.reduce(0) { $0 + (generosity[squeezed.fit(of: $1)] ?? 0) }
            XCTAssertLessThan(liveTotal, idleTotal,
                              "the whole catalog rated the same on a machine at its limit")
        }
    }

    /// THE STEP SIZE, WITH THE NUMBERS WRITTEN DOWN. A discount that never moves
    /// a badge is a feature nobody can see, so this pins one full crossing on a
    /// real fixture: a 64 GB Studio budgets 48 GB and rates a 20 GB model "Great
    /// fit"; at its limit it budgets 21.6 GB and rates the same model "Tight".
    /// The load factors are asserted alongside the labels, because the label is
    /// the opinion and the factor is the thing that produced it.
    func test_aFitLabelMovesFromGreatToTight_underPressure() {
        let model = try! XCTUnwrap(Cookbook.catalog.first { $0.id == "gpt-oss:20b" },
                                   "fixture model left the catalog")
        XCTAssertEqual(model.estimatedMemoryGB, 20.0, "the fixture's footprint changed")

        let idle = Cookbook.listing(for: studioSixtyFourGB, headroom: .full)
        XCTAssertEqual(idle.budget.gigabytes, 48.0, accuracy: 0.0001)
        XCTAssertEqual(Cookbook.loadFactor(of: model, in: studioSixtyFourGB, headroom: .full),
                       20.0 / 48.0, accuracy: 0.0001)
        XCTAssertEqual(idle.fit(of: model), .great)

        let squeezed = Cookbook.listing(for: studioSixtyFourGB, headroom: .minimal)
        XCTAssertEqual(squeezed.budget.gigabytes, 21.6, accuracy: 0.0001)
        XCTAssertEqual(Cookbook.loadFactor(of: model, in: studioSixtyFourGB, headroom: .minimal),
                       20.0 / 21.6, accuracy: 0.0001)
        XCTAssertEqual(squeezed.fit(of: model), .tight,
                       "0.93 of the live budget is not a comfortable fit")

        // The one in between, so the ladder is pinned rather than its two ends.
        XCTAssertEqual(Cookbook.listing(for: studioSixtyFourGB, headroom: .reduced).fit(of: model),
                       .good)
    }

    /// THE LINE BETWEEN A LABEL AND A SETTING, and it is the one thing this
    /// feature could get catastrophically wrong. Memory pressure is a weather
    /// report: it arrives because somebody joined a video call and it leaves when
    /// they hang up. Labels are allowed to follow it. The model id written to
    /// config.json is not, because `userHasChosenModel` reads any non-default
    /// value back as a DECISION and refuses to revisit it, so one spike at the
    /// wrong second would pin a stranger's install to the smallest model in the
    /// catalog permanently, long after the machine went quiet.
    ///
    /// This asserts both halves at once: the displayed headline moves across all
    /// three headrooms, and the persisted value is the same string every time.
    func test_pressureMovesTheLabelsAndNeverTheStoredModelChoice() {
        let stored = Cookbook.defaultModelID(for: laptopSixteenGB,
                                             userHasChosen: false,
                                             current: GruxConfig.defaultLocalModel)
        XCTAssertEqual(stored, "qwen3-vl:4b")

        var shown: [String] = []
        for headroom in MachineLoad.Headroom.allCases {
            shown.append(Cookbook.listing(for: laptopSixteenGB, headroom: headroom).headline?.id ?? "none")
            XCTAssertEqual(
                Cookbook.defaultModelID(for: laptopSixteenGB,
                                        userHasChosen: false,
                                        current: GruxConfig.defaultLocalModel),
                stored,
                "the stored model changed with \(headroom.rawValue) headroom, which is a "
                + "transient reading writing itself into a config file")
        }
        XCTAssertEqual(Set(shown).count, MachineLoad.Headroom.allCases.count,
                       "the displayed headline did not move at all, so the half of this "
                       + "test that proves labels ARE live proves nothing: got \(shown)")

        // THE DIVERGENCE IS THE FEATURE, not something to reconcile later. On a
        // 16 GB laptop at its limit the pane names llama3.2:3b while config.json
        // still holds qwen3-vl:4b, and the config file is right to hold its
        // ground. Asserted out loud so a later change that "helpfully" re-syncs
        // the two has to delete this line rather than slip past a green suite.
        let underLoad = try! XCTUnwrap(
            Cookbook.listing(for: laptopSixteenGB, headroom: .minimal).headline?.id,
            "a 16 GB laptop at its limit was offered nothing at all")
        XCTAssertEqual(underLoad, "llama3.2:3b")
        XCTAssertNotEqual(underLoad, stored)
    }

    /// AT FULL HEADROOM NOTHING MOVED. The listing is the pane's only scoring
    /// path now, so an idle machine has to read bit for bit what it read when
    /// the view called the two-argument forms directly. `budgetFraction(for:
    /// .full)` is exactly 1.00 and multiplying a Double by 1.00 is exact, so this
    /// asserts equality rather than an accuracy window, for the same reason
    /// `test_fullHeadroom_isIdenticalToTheStaticScoring_forEveryModel` does: a
    /// tolerance would hide precisely the rounding it exists to catch.
    func test_theProductionListing_atFullHeadroom_isTheStaticScoring() {
        for machine in [mac(ramGB: 8, gpuGB: 5.5), mac(ramGB: 16, gpuGB: 11),
                        mac(ramGB: 64, gpuGB: 48), mac(ramGB: 128, gpuGB: 96),
                        mac(ramGB: 32, gpuGB: 0), mac(ramGB: 0, gpuGB: 0)] {
            let live = Cookbook.listing(for: machine, headroom: .full)

            XCTAssertEqual(live.budget.gigabytes, machine.modelBudgetGB)
            XCTAssertEqual(live.budget.deviceGigabytes, machine.modelBudgetGB)
            XCTAssertEqual(live.budget.headroom, .full)

            XCTAssertEqual(live.fitting.map(\.id), Cookbook.recommended(for: machine).map(\.id),
                           "the recommended section moved")
            XCTAssertEqual(live.tooBig.map(\.id),
                           Cookbook.catalog.filter { Cookbook.fit(of: $0, in: machine) == .tooBig }.map(\.id),
                           "the too-big section moved")
            XCTAssertEqual(live.headline?.id, Cookbook.headline(for: machine)?.id)

            for model in Cookbook.catalog {
                XCTAssertEqual(live.fit(of: model), Cookbook.fit(of: model, in: machine),
                               "\(model.id) got a different badge from the listing")
            }

            // THE SECTIONS AND THE BADGES CANNOT DISAGREE. The view used to score
            // the catalog three separate times, so a model could sit under
            // "RECOMMENDED FOR THIS MAC" wearing a "TOO BIG" badge if any one of
            // the three passes had been threaded differently. One pass and one
            // partition is what makes that unrepresentable.
            XCTAssertEqual(live.fitting.count + live.tooBig.count, Cookbook.catalog.count,
                           "the two sections do not partition the catalog")
            XCTAssertTrue(live.fitting.allSatisfy { live.fit(of: $0) != .tooBig },
                          "a model in the recommended section is rated too big")
            XCTAssertTrue(live.tooBig.allSatisfy { live.fit(of: $0) == .tooBig },
                          "a model in the too-big section is rated as fitting")
        }
    }

    // MARK: - The disk a 65 GB pull lands on

    /// Free bytes as the platform reports them, in the DECIMAL gigabytes both
    /// the Ollama library and macOS use for storage.
    ///
    /// Not the 1_073_741_824 the `mac(...)` fixture above converts RAM with, and
    /// the difference is the point rather than an inconsistency. `hw.memsize` is
    /// a power of two so gibibytes are right for a memory budget; a download
    /// size is not. Measured on a real install: llama3.2:3b is published as 2.0
    /// GB and its manifest layers total 2,019,393,189 bytes, which is 2.019
    /// decimal GB and 1.881 GiB. Using the memory constant here would have this
    /// test fabricate 7.4 percent more free space than it claims to.
    private func freeBytes(_ gb: Double) -> Int64 { Int64(gb * 1_000_000_000) }

    /// The model this finding was written about: the largest entry in the
    /// catalog, and the download a stranger is least able to absorb by accident.
    private var frontierModel: CookbookModel {
        try! XCTUnwrap(Cookbook.catalog.first { $0.id == "gpt-oss:120b" },
                       "fixture model left the catalog")
    }

    /// Where the fabricated readings claim to have been taken, spelled like the
    /// real default so the refusal assertions read like the sentence a user
    /// would see. Fabricated for the same reason the byte counts are: the real
    /// path belongs to whichever machine runs this.
    private let measuredAt = "/Users/example/.ollama/models"

    /// THE REFUSAL, WITH THE NUMBERS IN IT. "Insufficient disk space" is a
    /// verdict a user cannot act on; the figures are what turn it into an
    /// instruction. Asserted on the string and not only on the boolean, because
    /// the boolean is what the code does and the string is what the person
    /// reads, and only one of those two was the finding.
    func test_pullIsRefused_whenTheVolumeCannotHoldTheModel() {
        let model = frontierModel
        XCTAssertEqual(model.diskGB, 65.0, "the fixture's download size changed")

        let check = OllamaDiskCheck.forPull(downloadGB: model.diskGB,
                                            availableBytes: freeBytes(18),
                                            measuredPath: measuredAt)
        XCTAssertFalse(check.fits)
        XCTAssertEqual(check.requiredGB, 70.0, accuracy: 0.0001,
                       "a 65 GB model plus a 5 GB reserve")
        XCTAssertEqual(check.availableGB, 18.0, accuracy: 0.0001)
        XCTAssertTrue(check.refusal.contains("70.0 GB"), check.refusal)
        XCTAssertTrue(check.refusal.contains("65.0 GB"), check.refusal)
        XCTAssertTrue(check.refusal.contains("18.0 GB"), check.refusal)
        // THE PATH IS PART OF THE INSTRUCTION. The reading can be taken on the
        // wrong volume, and a figure with no provenance is indistinguishable
        // from a correct one: naming the measured path is what lets a reader
        // say "that is not where my models go" instead of distrusting the
        // arithmetic.
        XCTAssertTrue(check.refusal.contains(measuredAt), check.refusal)
    }

    /// And it proceeds when the room is there, which is the half that stops this
    /// being a guard that refuses everything and passes its own tests.
    func test_pullProceeds_whenTheVolumeHasRoom() {
        let check = OllamaDiskCheck.forPull(downloadGB: frontierModel.diskGB,
                                            availableBytes: freeBytes(200),
                                            measuredPath: measuredAt)
        XCTAssertTrue(check.fits)
    }

    /// THE BOUNDARY, PINNED. A threshold asserted only from far away can be off
    /// by its whole reserve and still look right from both ends. Exactly enough
    /// is enough; a gigabyte less is not.
    func test_theBoundaryIsTheModelPlusTheReserve_andNotOnlyTheModel() {
        let model = frontierModel
        let exactly = OllamaDiskCheck.forPull(downloadGB: model.diskGB,
                                              availableBytes: freeBytes(70),
                                              measuredPath: measuredAt)
        XCTAssertTrue(exactly.fits, "70 GB free for a 70 GB requirement was refused")

        let oneShort = OllamaDiskCheck.forPull(downloadGB: model.diskGB,
                                               availableBytes: freeBytes(69),
                                               measuredPath: measuredAt)
        XCTAssertFalse(oneShort.fits)

        // THE RESERVE IS WHAT DOES THE WORK HERE. A volume with room for the
        // model and nothing else is still refused, because a Mac with a few
        // hundred megabytes left is unusable for reasons that have nothing to do
        // with Ollama, and finishing the download is not the same thing as
        // leaving the machine working afterwards.
        let noHeadroom = OllamaDiskCheck.forPull(downloadGB: model.diskGB,
                                                 availableBytes: freeBytes(model.diskGB),
                                                 measuredPath: measuredAt)
        XCTAssertFalse(noHeadroom.fits,
                       "a volume with room for the model and nothing else was allowed")
        XCTAssertEqual(OllamaDiskCheck.reserveGB, 5.0,
                       "the reserve moved, so every number in this section needs rereading")
    }

    /// EVERY ENTRY, NOT ONLY THE BIG ONE. The 65 GB model is the dramatic case
    /// and it is not the common one: somebody on a nearly full 256 GB laptop is
    /// pulling a 2 GB model, and that has to be refused too. Both directions are
    /// swept, so a guard that had quietly become "always yes" or "always no"
    /// fails here rather than in front of a user.
    func test_everyCatalogEntry_isRefusedOnAFullDisk_andAllowedOnAnEmptyOne() {
        for model in Cookbook.catalog {
            XCTAssertFalse(
                OllamaDiskCheck.forPull(downloadGB: model.diskGB,
                                        availableBytes: freeBytes(1),
                                        measuredPath: measuredAt).fits,
                "\(model.id) was cleared to pull onto a volume with 1 GB free")
            XCTAssertTrue(
                OllamaDiskCheck.forPull(downloadGB: model.diskGB,
                                        availableBytes: freeBytes(500),
                                        measuredPath: measuredAt).fits,
                "\(model.id) was refused on a volume with 500 GB free")
        }
    }

    /// THE GUARD DRIVEN THROUGH THE BUTTON, ON A FABRICATED FULL DISK.
    ///
    /// Everything above this line is arithmetic, and arithmetic that reaches
    /// nobody is a failure this suite has already caught once: the
    /// pressure-aware scoring shipped green with zero production callers. So
    /// this goes through `OllamaManager.pull`, the exact function the PULL chip
    /// in `CookbookView` calls, and asserts what the row would render.
    ///
    /// THE CAPACITY IS FABRICATED SO THE TEST CANNOT PASS BY LUCK. Reading the
    /// real volume would assert nothing: a development machine has room, so the
    /// refusal would never fire and a green run would mean "this disk is not
    /// full today" rather than "the guard works". `availableDisk` exists to
    /// be replaced here, and is restored afterwards because the manager is a
    /// singleton the rest of the process shares.
    @MainActor
    func test_pull_refusesOnAFabricatedFullDisk_andStartsNothing() async {
        let ollama = OllamaManager.shared
        let realReading = ollama.availableDisk
        defer { ollama.availableDisk = realReading }
        // The refusal this leaves in `pulls` is NOT cleaned up, deliberately.
        // Nothing else in the suite reads that dictionary, and adding a reset
        // method to a shipping type so a test can tidy up after itself is a
        // worse trade than one stale entry in a process about to exit.

        // `pull` hands the gate the manager's LIVE posture, so all three of
        // its inputs are pinned rather than inherited: the shared manager has
        // served nothing in this process, and the base URL is forced to the
        // loopback default for the duration, because a host config pointing
        // Grux at another machine would stand the gate down and turn this
        // whole test into a nil that proves nothing.
        XCTAssertEqual(ollama.serverState, .stopped,
                       "another test started the server, so this no longer drives the gated posture")
        let realBase = AppState.shared.config.ollamaBaseURL
        defer { AppState.shared.config.ollamaBaseURL = realBase }
        AppState.shared.config.ollamaBaseURL = "http://localhost:11434"

        // The third pinned input, new with the adoption ordering: `pull` now
        // probes the port BEFORE the disk gate, so a development Mac genuinely
        // serving Ollama on 11434 would answer, get adopted as external, and
        // stand the gate down, turning this refusal into a real pull. A dead
        // probe is the posture this test is about: nothing answering, Grux
        // about to spawn with its own environment.
        let realProbe = ollama.serverAnswers
        defer { ollama.serverAnswers = realProbe }
        ollama.serverAnswers = { false }

        let model = frontierModel
        let eighteenGB = freeBytes(18)
        let path = measuredAt
        ollama.availableDisk = { (eighteenGB, path) }

        await ollama.pull(model.id)

        let shown = try! XCTUnwrap(ollama.pulls[model.id], "PULL produced no row state at all")
        XCTAssertTrue(shown.failed, "a doomed pull was presented as progress")
        XCTAssertTrue(shown.status.contains("65.0 GB"), shown.status)
        XCTAssertTrue(shown.status.contains("18.0 GB"), shown.status)
        XCTAssertTrue(shown.status.contains(measuredAt), shown.status)
        XCTAssertNil(shown.fraction, "a refused pull showed a progress fraction")

        // REFUSED, NOT FAILED PARTWAY. Had the guard let the task register and
        // then given up, the volume would be holding a part of a 65 GB blob and
        // the row would be stuck showing CANCEL. Nothing was started.
        XCTAssertFalse(ollama.isPulling(model.id), "a refused pull registered a task anyway")

        // And the same manager clears the same tag the moment the volume has
        // room, so this is a reading rather than a permanent verdict about the
        // model. Asserted at `diskShortfall`, the arithmetic `pullRefusal`
        // hands `pull`: calling `pull` again here would spawn `ollama serve`
        // and open a 3600 second stream to the network, which is a pull, not a
        // test.
        let plenty = freeBytes(500)
        ollama.availableDisk = { (plenty, path) }
        XCTAssertNil(ollama.diskShortfall(for: model.id,
                                          serverState: .stopped,
                                          baseURL: "http://localhost:11434"),
                     "a volume with 500 GB free still refused a 65 GB model")
    }

    /// A READING WE COULD NOT TAKE IS NOT A REFUSAL, and this is the direction
    /// the guard is deliberately wrong in.
    /// `volumeAvailableCapacityForImportantUsage` is unreported on network
    /// mounts and on anything that is not APFS or HFS+, so somebody with
    /// OLLAMA_MODELS pointed at a NAS reads nil. Blocking them would be
    /// inventing a problem out of a missing measurement, and it would be worse
    /// than the problem this guard was written for: they would be refused
    /// forever with nothing they could do to satisfy it. Driven at the
    /// managed-serve posture, where the gate is live, so the nil below means
    /// "the reading could not be taken" and not "the gate stood down".
    @MainActor
    func test_anUnreadableVolumeNeverBlocksAPull() {
        let ollama = OllamaManager.shared
        let realReading = ollama.availableDisk
        defer { ollama.availableDisk = realReading }

        ollama.availableDisk = { nil }
        XCTAssertNil(ollama.diskShortfall(for: frontierModel.id,
                                          serverState: .runningManaged,
                                          baseURL: "http://localhost:11434"))
    }

    /// A tag nobody published a size for is not measurable, so it is not
    /// refused. Every PULL button renders from a `CookbookModel`, so this is the
    /// hand-typed-tag case rather than a hole: the alternative is guessing a
    /// download size, and a guess presented as a refusal is the same mistake the
    /// catalog's own provenance rule forbids.
    @MainActor
    func test_aTagOutsideTheCatalogIsNeverRefused() {
        let ollama = OllamaManager.shared
        let realReading = ollama.availableDisk
        defer { ollama.availableDisk = realReading }

        let path = measuredAt
        ollama.availableDisk = { (0, path) }
        XCTAssertNil(ollama.diskShortfall(for: "some-model-nobody-catalogued:7b",
                                          serverState: .runningManaged,
                                          baseURL: "http://localhost:11434"))
        XCTAssertNotNil(ollama.diskShortfall(for: frontierModel.id,
                                             serverState: .runningManaged,
                                             baseURL: "http://localhost:11434"),
                        "zero free bytes cleared a 65 GB pull, so the line above proves nothing")
    }

    /// The models directory is where the reading is taken, and OLLAMA_MODELS is
    /// the one thing that moves it. Grux spawns `ollama serve` as a child, so it
    /// inherits this process's environment and the variable read here is the
    /// variable the server will honour.
    func test_modelsDirectory_followsOllamaModels_andOtherwiseSitsUnderHome() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(
            OllamaDiskCheck.modelsDirectory(environment: [:], home: home).path,
            "/Users/example/.ollama/models")
        XCTAssertEqual(
            OllamaDiskCheck.modelsDirectory(environment: ["OLLAMA_MODELS": "/Volumes/Fast/models"],
                                            home: home).path,
            "/Volumes/Fast/models")
        // An empty or whitespace value is an unset variable in a shell script's
        // clothing, not a request to write to the current directory.
        XCTAssertEqual(
            OllamaDiskCheck.modelsDirectory(environment: ["OLLAMA_MODELS": "   "], home: home).path,
            "/Users/example/.ollama/models")
    }

    /// The reading itself, on the one path a test can trust: the root volume
    /// always exists and always answers. Asserts only that a real number comes
    /// back, because the figure is a property of whichever machine is running
    /// this, and asserting on it would be asserting on the host, which is the
    /// thing every other test in this file is built to avoid.
    func test_availableCapacity_readsARealNumber_forADirectoryThatDoesNotExistYet() {
        let neverCreated = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("grux-cookbook-no-such-directory/models")
        XCTAssertFalse(FileManager.default.fileExists(atPath: neverCreated.path),
                       "the fixture path exists, so this proves nothing about the walk upward")
        let bytes = try! XCTUnwrap(OllamaDiskCheck.availableCapacityBytes(at: neverCreated),
                                   "the root volume reported no important-usage capacity")
        XCTAssertGreaterThan(bytes, 0)

        // The walk itself, pinned, because the refusal now NAMES the path it
        // stops at: two missing components up from /private/tmp must resolve
        // to /private/tmp, the deepest ancestor that exists.
        XCTAssertEqual(OllamaDiskCheck.nearestExistingAncestor(of: neverCreated).path,
                       "/private/tmp")
    }

    // MARK: - The gate stands down when the destination volume is not Grux's to know

    /// THE WRONG-VOLUME CASE THE GATE USED TO HARD-FAIL. An external server
    /// (the menu bar app, a terminal `ollama serve`) was launched with an
    /// environment this process never saw, so its OLLAMA_MODELS can point at a
    /// volume with two terabytes free while this process's own environment
    /// resolves ~/.ollama/models on a nearly full boot disk. The old gate
    /// measured the boot disk and refused forever. The honest posture is the
    /// one the nil-reading escape already takes: stand down and say nothing.
    @MainActor
    func test_theGateStandsDown_whenTheServingOllamaIsNotGruxsOwn() {
        let ollama = OllamaManager.shared
        let realReading = ollama.availableDisk
        defer { ollama.availableDisk = realReading }
        let nearlyFull = freeBytes(1)
        let path = measuredAt
        ollama.availableDisk = { (nearlyFull, path) }

        // External, and the two transients that may be about to become it.
        for state: OllamaManager.ServerState in [.runningExternal, .starting, .stopping] {
            XCTAssertNil(ollama.diskShortfall(for: frontierModel.id,
                                              serverState: state,
                                              baseURL: "http://localhost:11434"),
                         "\(state.label) refused on a volume it cannot know the pull lands on")
        }

        // The control that keeps the nils above honest: the same fabricated
        // disk and the same model still refuse in the two postures whose
        // serving environment IS this process's.
        for state: OllamaManager.ServerState in [.runningManaged, .stopped] {
            XCTAssertNotNil(ollama.diskShortfall(for: frontierModel.id,
                                                 serverState: state,
                                                 baseURL: "http://localhost:11434"),
                            "a fabricated 1 GB volume cleared a 65 GB pull at \(state.label)")
        }
    }

    /// A base URL that is not this machine is a server whose disks this
    /// process cannot stat, whatever the serve state says: `ollamaBaseURL` is
    /// user-editable in Settings, and a gate that stats the local volume while
    /// the pull lands on another machine would refuse hardware it never
    /// measured. 192.0.2.10 is the documentation range, so the fixture can
    /// never be a machine this test could actually reach.
    @MainActor
    func test_theGateStandsDown_whenTheBaseURLIsAnotherMachine() {
        let ollama = OllamaManager.shared
        let realReading = ollama.availableDisk
        defer { ollama.availableDisk = realReading }
        let nearlyFull = freeBytes(1)
        let path = measuredAt
        ollama.availableDisk = { (nearlyFull, path) }

        for base in ["http://192.0.2.10:11434", "https://ollama.example.com"] {
            XCTAssertNil(ollama.diskShortfall(for: frontierModel.id,
                                              serverState: .runningManaged,
                                              baseURL: base),
                         "\(base) is not this machine and the local reading refused anyway")
        }
        // Every spelling of THIS machine still gates, so the loop above proves
        // the host check rather than a gate that stopped firing at all.
        for base in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            XCTAssertNotNil(ollama.diskShortfall(for: frontierModel.id,
                                                 serverState: .runningManaged,
                                                 baseURL: base),
                            "\(base) is this machine and a 1 GB volume cleared a 65 GB pull")
        }
    }

    /// THE MENU BAR APP CASE, WHICH THE POSTURE SWEEP ABOVE CANNOT SEE.
    /// `serverState` only reads `.runningExternal` after something probed, and
    /// no health loop runs while the state is `.stopped`, so a user who starts
    /// the Ollama menu bar app after Grux launches leaves the label at
    /// `.stopped` while a healthy server answers on the port, with its
    /// OLLAMA_MODELS pointing wherever it likes. The old ordering ran the disk
    /// gate on that label and refused off this process's volume, naming a disk
    /// the download was never going to touch. `pullRefusal` is the gate `pull`
    /// now runs, and its first act is the same probe `runPull` trusts, so the
    /// answering server is adopted before any volume is measured.
    ///
    /// Asserted at `pullRefusal` rather than through `pull`, for the reason the
    /// refusal test above stops at `diskShortfall`: past a stood-down gate,
    /// `pull` registers a real pull, which is a network stream and not a test.
    @MainActor
    func test_theGateStandsDown_whenAHealthyServerAnswersWhileStopped() async {
        let ollama = OllamaManager.shared
        let realReading = ollama.availableDisk
        let realProbe = ollama.serverAnswers
        let realBase = AppState.shared.config.ollamaBaseURL
        defer {
            ollama.availableDisk = realReading
            ollama.serverAnswers = realProbe
            AppState.shared.config.ollamaBaseURL = realBase
        }
        AppState.shared.config.ollamaBaseURL = "http://localhost:11434"
        XCTAssertEqual(ollama.serverState, .stopped,
                       "another test started the server, so the stopped posture is not being driven")

        let nearlyFull = freeBytes(1)
        let path = measuredAt
        ollama.availableDisk = { (nearlyFull, path) }
        ollama.serverAnswers = { true }

        let refusal = await ollama.pullRefusal(for: frontierModel.id)
        XCTAssertNil(refusal,
                     "a healthy external server was answering and the gate refused off this process's volume anyway")
        XCTAssertEqual(ollama.serverState, .runningExternal,
                       "the answering server was not adopted, so the nil above could be standing down for the wrong reason")
        XCTAssertFalse(ollama.isPulling(frontierModel.id),
                       "settling the gate question started a pull")

        // The control that keeps the nil honest: same fabricated disk, same
        // model, nothing answering. `stop()` on an external posture only
        // forgets it locally, which is exactly the reset this needs, and it
        // also puts the shared singleton back where the refusal test's opening
        // assertion expects to find it.
        await ollama.stop()
        XCTAssertEqual(ollama.serverState, .stopped)
        ollama.serverAnswers = { false }
        let refused = await ollama.pullRefusal(for: frontierModel.id)
        XCTAssertNotNil(refused,
                        "nothing answering and a 1 GB volume still cleared a 65 GB pull")
        XCTAssertEqual(ollama.serverState, .stopped,
                       "a dead probe adopted a server anyway")
    }

    // MARK: - The branch a shipped build never reaches

    /// THE DISCRETE GPU PATH, WHICH IS NOT DEAD AND WAS NOT REACHABLE EITHER.
    ///
    /// `Grux-Mac/build.sh` line 42 runs `swift build -c release --arch arm64`
    /// and the README requires Apple silicon, so no shipped binary ever runs on
    /// a Mac with a discrete GPU. `Package.swift` carries no architecture
    /// restriction, so a contributor who runs `swift build` on an Intel Mac
    /// does, and the branch is kept for them rather than deleted.
    ///
    /// It was also keyed on the wrong fact. The budget branched on
    /// `gpuWorkingSetBytes > 0` alone, and a discrete GPU reports a working set
    /// too: its VRAM. So an 8 GB card in a 64 GB Mac Pro capped the model budget
    /// at 8 GB, which hides every model above a 4B from a machine with 64 GB in
    /// it, and it is the wrong number regardless, because Ollama serves on the
    /// CPU out of system RAM on that Mac.
    func test_aDiscreteGPUMac_budgetsOffRAM_andNotOffVRAM() {
        let macPro = HardwareProfile(
            chipName: "Test Chip",
            physicalMemoryBytes: UInt64(64 * 1_073_741_824),
            gpuWorkingSetBytes: UInt64(8 * 1_073_741_824),
            cpuCoreCount: 12,
            hasUnifiedMemory: false,
            isAppleSilicon: false)

        XCTAssertEqual(macPro.modelBudgetGB, 44.8, accuracy: 0.01,
                       "70 percent of 64 GB of system RAM")
        XCTAssertGreaterThan(macPro.modelBudgetGB, macPro.gpuWorkingSetGB,
                             "the discrete card's VRAM was taken as the model budget")

        // And the machine is then offered something worth its RAM, rather than
        // being told a 12B is too big, which is what the VRAM budget did.
        let pick = try! XCTUnwrap(Cookbook.headline(for: macPro),
                                  "a 64 GB Mac was offered no local model at all")
        XCTAssertGreaterThan(pick.estimatedMemoryGB, 8.0, "picked \(pick.id)")
    }

    /// THE OTHER WRONG KEY, found one review after the discrete fix. That fix
    /// gated the budget on `hasUnifiedMemory`, and Intel INTEGRATED GPUs
    /// report unified memory too, truthfully, they share system RAM with the
    /// CPU, while their `recommendedMaxWorkingSetSize` is a gigabyte or two:
    /// roughly 1.5 GB on an Iris Plus in a 16 GB machine. Keyed on the claim,
    /// an Intel source build budgeted that 1.5 GB instead of 11.2 and rated
    /// nearly the whole catalog too big. The platform is the key that actually
    /// separates the two memory models, so `isAppleSilicon` false takes the
    /// RAM fallback whatever the GPU claims about itself.
    func test_anIntelIntegratedGPU_budgetsOffRAM_andNotOffItsTinyWorkingSet() {
        let intelLaptop = HardwareProfile(
            chipName: "Intel(R) Core(TM) i5-1038NG7 CPU @ 2.00GHz",
            physicalMemoryBytes: UInt64(16) * 1_073_741_824,
            gpuWorkingSetBytes: UInt64(1.5 * 1_073_741_824),
            cpuCoreCount: 8,
            hasUnifiedMemory: true,
            isAppleSilicon: false)

        XCTAssertEqual(intelLaptop.modelBudgetGB, 11.2, accuracy: 0.01,
                       "70 percent of 16 GB of system RAM")
        XCTAssertGreaterThan(intelLaptop.modelBudgetGB, intelLaptop.gpuWorkingSetGB,
                             "the integrated GPU's working set was taken as the model budget")

        // And the catalog is scored against the machine rather than against
        // the GPU's claim: an 11.2 GB budget fits real models, a 1.5 GB
        // budget fits none of them.
        let pick = try! XCTUnwrap(Cookbook.headline(for: intelLaptop),
                                  "a 16 GB Mac was offered no local model at all")
        XCTAssertGreaterThan(pick.estimatedMemoryGB, 1.5, "picked \(pick.id)")
    }

    /// AND NOTHING MOVED FOR THE MACHINES THAT SHIP. Every fixture in this file
    /// has unified memory, so adding the flag to the condition has to be a no-op
    /// for all of them, bit for bit. If this fails, the discrete-GPU fix changed
    /// what a real user sees, which it has no business doing.
    func test_unifiedMemoryMacs_areUnchangedByTheDiscreteGPUCondition() {
        for machine in [airEightGB, laptopSixteenGB, studioSixtyFourGB,
                        mac(ramGB: 128, gpuGB: 96)] {
            XCTAssertEqual(machine.modelBudgetGB, machine.gpuWorkingSetGB,
                           "a \(machine.physicalMemoryGB) GB Mac stopped budgeting off its "
                           + "Metal working set")
        }
        // The clamp still wins over a driver claiming more than the machine has.
        XCTAssertEqual(mac(ramGB: 16, gpuGB: 20).modelBudgetGB, 16, accuracy: 0.01)
    }

    /// THE FALLBACK IS NOT AN INTEL-ONLY BRANCH, which is the part that makes
    /// deleting it the wrong call. An arm64 build with no Metal device, which is
    /// CI and some VM configurations, lands here on hardware that HAS unified
    /// memory: the flag is true and the working set is zero. Deleting the branch
    /// would hand that machine a zero budget and rate every catalog entry "Too
    /// big" on a Mac that is fine.
    func test_theRAMFallbackAlsoCoversAppleSiliconWithNoMetalDevice() {
        let noMetal = mac(ramGB: 32, gpuGB: 0)
        XCTAssertTrue(noMetal.hasUnifiedMemory)
        XCTAssertEqual(noMetal.modelBudgetGB, 22.4, accuracy: 0.01, "70 percent of 32 GB")
        XCTAssertNotNil(Cookbook.headline(for: noMetal),
                        "a machine Metal would not describe was offered nothing")
    }

    /// A cookbook.json written before `isAppleSilicon` existed must still
    /// decode. CookbookStore.load falls back to `.empty` on ANY decode
    /// failure, so a strict decoder here would have silently wiped an
    /// existing install's pulled list, selected model and auto-serve
    /// preference on first launch after the update. The tolerant
    /// `init(from:)` backfills the missing key from the same kernel read
    /// `detect()` uses; this test feeds it a pre-update payload and proves
    /// both the survival of every legacy field and the backfill itself.
    func test_aProfileSavedBeforeTheAppleSiliconKey_stillDecodes_andBackfills() throws {
        let legacy = """
        {"chipName":"Apple M2","physicalMemoryBytes":17179869184,
         "gpuWorkingSetBytes":11453246122,"cpuCoreCount":8,
         "hasUnifiedMemory":true}
        """
        let decoded = try JSONDecoder().decode(HardwareProfile.self,
                                               from: Data(legacy.utf8))
        XCTAssertEqual(decoded.chipName, "Apple M2")
        XCTAssertEqual(decoded.physicalMemoryBytes, 17_179_869_184)
        XCTAssertEqual(decoded.gpuWorkingSetBytes, 11_453_246_122)
        XCTAssertEqual(decoded.cpuCoreCount, 8)
        XCTAssertTrue(decoded.hasUnifiedMemory)
        XCTAssertEqual(decoded.isAppleSilicon, HardwareProfile.detectIsAppleSilicon(),
                       "the missing key backfills from the kernel read, not a constant")

        // The migration is one-way: re-encoding writes the key, so the
        // backfill runs once per legacy file, not on every launch forever.
        let reencoded = String(decoding: try JSONEncoder().encode(decoded),
                               as: UTF8.self)
        XCTAssertTrue(reencoded.contains("\"isAppleSilicon\""),
                      "re-encoded profile still omits the key")
    }
}
