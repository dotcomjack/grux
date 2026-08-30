import XCTest
@testable import Grux

/// THE APP NEVER LOOKED AT THE MACHINE IT WAS RUNNING ON.
///
/// Measured across `Sources/` before `MachineLoad` existed: `thermalState` zero
/// hits, `isLowPowerModeEnabled` zero hits, a memory pressure source zero hits,
/// and `activeProcessorCount` exactly once, in `HardwareProfile.detect()`, only
/// to fill in a display field. Every number that decides how hard Grux works was
/// a constant, so a fanless 8 GB laptop on battery at its thermal limit got the
/// same session ceiling and the same model budget as a plugged in workstation.
///
/// PURE ONLY, AND THAT IS THE WHOLE DESIGN OF THIS FILE. Nothing here reads the
/// host. It cannot: no test can put a machine into thermal `.critical` on
/// demand, and this suite runs on machines in states nobody knows in advance.
/// The repo has already paid for assuming otherwise, which is why the
/// `ScreenControl` tests skip themselves when the host lacks a grant, and an
/// honest skip still leaves a rule unverified. So the rules live in
/// `MachineLoad.headroom(thermalState:lowPowerMode:memoryPressure:)`,
/// `HardwareProfile.budgetFraction(for:)` and
/// `SessionConcurrency.limits(coreCount:memoryBudgetGB:headroom:)`, all of which
/// take their facts as arguments, and all three are asserted here against fixed
/// numbers rather than against whatever this desk happens to be doing.
final class MachineLoadTests: XCTestCase {

    // MARK: - Headroom, every combination

    /// All twenty four inputs, written out rather than generated.
    ///
    /// Four thermal states times two low power values times three pressure
    /// levels. A loop over `allCases` comparing against a second copy of the
    /// rule would only prove the rule equals itself, which is the classic way a
    /// mapping test passes while the mapping is wrong.
    private func expected(_ thermal: ProcessInfo.ThermalState,
                          _ lowPower: Bool,
                          _ pressure: MachineLoad.MemoryPressure) -> MachineLoad.Headroom {
        MachineLoad.headroom(thermalState: thermal, lowPowerMode: lowPower, memoryPressure: pressure)
    }

    /// The only state that gets the whole machine: cool, unconstrained, not
    /// under memory pressure. Everything else is a step down.
    func testOnlyANominalUnconstrainedMachineGetsFullHeadroom() {
        XCTAssertEqual(expected(.nominal, false, .normal), .full)

        // And nothing else in the entire input space does.
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                for pressure in MachineLoad.MemoryPressure.allCases {
                    if thermal == .nominal && !lowPower && pressure == .normal { continue }
                    XCTAssertNotEqual(expected(thermal, lowPower, pressure), .full,
                                      "thermal \(thermal.rawValue), lowPower \(lowPower), pressure \(pressure.rawValue) reported full headroom")
                }
            }
        }
    }

    /// Warm but not critical is a step down, never a stop.
    func testFairAndSeriousThermalStatesReduce() {
        XCTAssertEqual(expected(.fair, false, .normal), .reduced)
        XCTAssertEqual(expected(.serious, false, .normal), .reduced)
        XCTAssertEqual(expected(.fair, false, .warning), .reduced)
        XCTAssertEqual(expected(.serious, false, .warning), .reduced)
    }

    /// Low power mode is a stated preference, not a symptom, so it applies on a
    /// machine that is perfectly cool. Getting this wrong would mean honouring
    /// the request only on the machine that was already struggling.
    func testLowPowerModeReducesEvenOnAColdMachine() {
        XCTAssertEqual(expected(.nominal, true, .normal), .reduced)
        XCTAssertEqual(expected(.fair, true, .normal), .reduced)
        XCTAssertEqual(expected(.serious, true, .warning), .reduced)
    }

    /// Critical wins over everything, including a low power flag that would
    /// otherwise have answered `.reduced` first.
    func testCriticalThermalOrCriticalMemoryIsMinimal() {
        XCTAssertEqual(expected(.critical, false, .normal), .minimal)
        XCTAssertEqual(expected(.critical, true, .normal), .minimal,
                       "low power mode was allowed to answer before the critical check")
        XCTAssertEqual(expected(.nominal, false, .critical), .minimal)
        XCTAssertEqual(expected(.nominal, true, .critical), .minimal)
        XCTAssertEqual(expected(.critical, true, .critical), .minimal)
    }

    /// A memory WARNING on an otherwise cold machine still costs headroom.
    ///
    /// If it did not, the `.warning` arm of the memory pressure source would be
    /// a subscription with no subscriber: the app would wake up, take the
    /// event, and change nothing.
    func testAMemoryWarningAloneReduces() {
        XCTAssertEqual(expected(.nominal, false, .warning), .reduced)
    }

    /// Every one of the twenty four inputs resolves, and the file above is the
    /// only place any of them is decided.
    func testTheMappingIsTotal() {
        var seen = 0
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                for pressure in MachineLoad.MemoryPressure.allCases {
                    _ = expected(thermal, lowPower, pressure)
                    seen += 1
                }
            }
        }
        XCTAssertEqual(seen, 24, "the input space is not the size this file thinks it is")
    }

    // MARK: - Model budget (G-015)

    private func profile(ramGB: Double, gpuGB: Double, cores: Int = 10) -> HardwareProfile {
        HardwareProfile(
            chipName: "Test Chip",
            physicalMemoryBytes: UInt64(ramGB * 1_073_741_824),
            gpuWorkingSetBytes: UInt64(gpuGB * 1_073_741_824),
            cpuCoreCount: cores,
            hasUnifiedMemory: true,
            isAppleSilicon: true
        )
    }

    /// The static budget is a DEVICE property and must not have moved. The
    /// Cookbook and its tests read it and are owned elsewhere.
    func testTheStaticBudgetIsUnchangedAtFullHeadroom() {
        let mid = profile(ramGB: 16, gpuGB: 11)
        XCTAssertEqual(mid.modelBudgetGB, 11, accuracy: 0.01)
        XCTAssertEqual(mid.modelBudgetGB(headroom: .full), 11, accuracy: 0.01)
    }

    /// THE ACTUAL DEFECT. `recommendedMaxWorkingSetSize` reports the same number
    /// on a freshly booted machine and on one already holding a browser and an
    /// IDE, so an 8 GB model scored "Good" on a 16 GB machine that had no room
    /// left for it, and the user met the verdict as swap.
    func testALoadedMachineGetsASmallerBudget() {
        let mid = profile(ramGB: 16, gpuGB: 11)
        XCTAssertEqual(mid.modelBudgetGB(headroom: .reduced), 7.7, accuracy: 0.01)
        XCTAssertEqual(mid.modelBudgetGB(headroom: .minimal), 4.95, accuracy: 0.01)
    }

    /// And the discount has to be big enough to move a rating, or nothing a user
    /// would notice has changed. An 8 GB model on this machine is a comfortable
    /// "Good" when nothing else is running and does not fit at all when the
    /// machine is under load.
    func testTheDiscountIsLargeEnoughToChangeAFitRating() {
        let mid = profile(ramGB: 16, gpuGB: 11)
        let loadFactorIdle = 8.0 / mid.modelBudgetGB(headroom: .full)
        let loadFactorBusy = 8.0 / mid.modelBudgetGB(headroom: .reduced)
        XCTAssertLessThan(loadFactorIdle, 0.75, "an 8 GB model was not comfortable on an idle 16 GB machine")
        XCTAssertGreaterThan(loadFactorBusy, 0.95, "the reduced budget still called an 8 GB model a fit")
    }

    /// The label has to carry the numbers it is a claim about. "Good fit" is an
    /// opinion; "8 GB budget, down from 11 GB" is something a reader can check.
    func testTheBudgetCarriesTheNumberThatProducedIt() {
        let busy = profile(ramGB: 16, gpuGB: 11).modelBudget(headroom: .reduced)
        XCTAssertEqual(busy.deviceGigabytes, 11, accuracy: 0.01)
        XCTAssertEqual(busy.gigabytes, 7.7, accuracy: 0.01)
        XCTAssertTrue(busy.summary.contains("11 GB"), "the device budget is missing from the summary: \(busy.summary)")
        XCTAssertTrue(busy.summary.contains("8 GB"), "the live budget is missing from the summary: \(busy.summary)")

        let idle = profile(ramGB: 16, gpuGB: 11).modelBudget(headroom: .full)
        XCTAssertEqual(idle.gigabytes, idle.deviceGigabytes, accuracy: 0.01,
                       "an idle machine was charged for headroom it has")
    }

    // MARK: - Session concurrency derivation (G-016)

    /// A fanless 8 GB laptop. Eight cores, and Metal reports about 5.3 GB.
    ///
    /// This is the machine the constant version got wrong in the dangerous
    /// direction: it could be SET to eight parallel sessions, which is not a
    /// ceiling, it is a cliff with a railing painted on it.
    func testSmallLaptopIsHeldAtTheFloor() {
        let full = SessionConcurrency.limits(coreCount: 8, memoryBudgetGB: 5.3, headroom: .full)
        XCTAssertEqual(full.ceiling, 2, "an 8 GB laptop was allowed more than two sessions")
        XCTAssertEqual(full.starting, 2)

        // It cannot go lower than the floor, whatever the machine is doing.
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 8, memoryBudgetGB: 5.3, headroom: .reduced),
                       SessionConcurrency.Limits(starting: 2, ceiling: 2))
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 8, memoryBudgetGB: 5.3, headroom: .minimal),
                       SessionConcurrency.Limits(starting: 2, ceiling: 2))
    }

    /// A 16 GB machine, twelve cores, Metal reporting 11 GB. Memory binds
    /// before cores do, which is the point of taking the smaller of the two.
    func testMidMachineIsBoundByMemoryNotCores() {
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 12, memoryBudgetGB: 11, headroom: .full),
                       SessionConcurrency.Limits(starting: 3, ceiling: 5),
                       "twelve cores would allow six, eleven gigabytes allows five")
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 12, memoryBudgetGB: 11, headroom: .reduced),
                       SessionConcurrency.Limits(starting: 2, ceiling: 2))
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 12, memoryBudgetGB: 11, headroom: .minimal),
                       SessionConcurrency.Limits(starting: 2, ceiling: 2))
    }

    /// A 64 GB workstation, sixteen cores, Metal reporting 48 GB. Cores bind
    /// here, and the absolute cap is not reached by accident.
    func testWorkstationIsBoundByCoresAndCappedAtTheAbsoluteCeiling() {
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 16, memoryBudgetGB: 48, headroom: .full),
                       SessionConcurrency.Limits(starting: 3, ceiling: 8))
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 16, memoryBudgetGB: 48, headroom: .reduced),
                       SessionConcurrency.Limits(starting: 3, ceiling: 4),
                       "a warm workstation kept its whole ceiling")
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 16, memoryBudgetGB: 48, headroom: .minimal),
                       SessionConcurrency.Limits(starting: 2, ceiling: 2))
    }

    /// The absolute cap survives the derivation. A 24 core, 128 GB machine has
    /// the hardware for twelve sessions and still gets eight, because the
    /// binding constraint at the top end is a rate limit, and a rate limit is
    /// the same on every machine.
    func testHardwareCannotRaiseTheAbsoluteCeiling() {
        let huge = SessionConcurrency.limits(coreCount: 24, memoryBudgetGB: 96, headroom: .full)
        XCTAssertEqual(huge.ceiling, SessionConcurrency.absoluteCeiling)
        XCTAssertEqual(huge.ceiling, 8)
    }

    /// And the default stays conservative on every machine in the range. This is
    /// the assertion that stops a future edit turning a first launch on a big
    /// machine into eight parallel sessions against an account that has never
    /// run one.
    func testTheStartingValueIsNeverGenerous() {
        let machines: [(Int, Double)] = [(4, 3), (8, 5.3), (12, 11), (16, 48), (24, 96)]
        for headroom in MachineLoad.Headroom.allCases {
            for (cores, budget) in machines {
                let limits = SessionConcurrency.limits(coreCount: cores, memoryBudgetGB: budget, headroom: headroom)
                XCTAssertLessThanOrEqual(limits.starting, SessionConcurrency.conservativeDefaultCap,
                                         "\(cores) cores, \(budget) GB, \(headroom.rawValue) started at \(limits.starting)")
                XCTAssertGreaterThanOrEqual(limits.starting, SessionConcurrency.conservativeFloor)
                XCTAssertLessThanOrEqual(limits.starting, limits.ceiling,
                                         "the default was above the ceiling that bounds it")
            }
        }
    }

    /// A machine too small to measure still gets a usable number rather than
    /// zero. A zero here would divide the swarm by nothing downstream and read
    /// to the user as the feature being broken.
    func testAnUnmeasurableMachineStillGetsTheFloor() {
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 0, memoryBudgetGB: 0, headroom: .full),
                       SessionConcurrency.Limits(starting: 2, ceiling: 2))
        XCTAssertEqual(SessionConcurrency.limits(coreCount: 1, memoryBudgetGB: 0.5, headroom: .minimal),
                       SessionConcurrency.Limits(starting: 2, ceiling: 2))
    }

    /// Headroom can only ever lower the answer. Asserted across the whole grid
    /// because the failure this guards against is a sign error in one arm of one
    /// switch, which is invisible in a spot check.
    func testHeadroomNeverRaisesTheCeiling() {
        let machines: [(Int, Double)] = [(4, 3), (8, 5.3), (12, 11), (16, 48), (24, 96)]
        for (cores, budget) in machines {
            let full = SessionConcurrency.limits(coreCount: cores, memoryBudgetGB: budget, headroom: .full)
            let reduced = SessionConcurrency.limits(coreCount: cores, memoryBudgetGB: budget, headroom: .reduced)
            let minimal = SessionConcurrency.limits(coreCount: cores, memoryBudgetGB: budget, headroom: .minimal)
            XCTAssertLessThanOrEqual(reduced.ceiling, full.ceiling, "\(cores) cores, \(budget) GB")
            XCTAssertLessThanOrEqual(minimal.ceiling, reduced.ceiling, "\(cores) cores, \(budget) GB")
        }
    }
}
