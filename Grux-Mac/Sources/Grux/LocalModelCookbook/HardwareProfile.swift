import Foundation
import Metal

// Snapshot of the machine Grux is running on, used by the Cookbook to score
// which local Ollama models actually fit. Apple Silicon has unified memory,
// so the practical model budget is the GPU's recommended working set (Metal
// reports it directly), bounded by physical RAM. Anything without unified
// memory, and anything Metal declines to describe, is budgeted off RAM
// instead; `modelBudgetGB` says which machines those are and why that path is
// kept. Pure value type: detection lives in `detect()`, every field is
// injectable so tests can fabricate a MacBook Air or a Mac Studio without
// touching sysctl.
struct HardwareProfile: Codable, Equatable {
    // Marketing-ish chip string, e.g. "Apple M4 Pro". Falls back to the raw
    // CPU brand string on Intel.
    let chipName: String

    // Total physical RAM (sysctl hw.memsize).
    let physicalMemoryBytes: UInt64

    // Metal's recommendedMaxWorkingSetSize for the default GPU. On Apple
    // Silicon this is the unified-memory slice the GPU can realistically
    // address (~75 percent of RAM). 0 when no Metal device exists (CI, VM).
    let gpuWorkingSetBytes: UInt64

    let cpuCoreCount: Int

    // True when the default Metal device claims unified memory. A hardware
    // fact for the display card ("unified" / "discrete"), and deliberately NOT
    // the key the budget branches on: Intel INTEGRATED GPUs also report
    // hasUnifiedMemory == true, truthfully, they share system RAM with the
    // CPU, while their recommendedMaxWorkingSetSize is a gigabyte or two.
    // `isAppleSilicon` below is the fact that separates the machines where
    // the working set IS the model budget from the machines where it is not;
    // read the argument on `modelBudgetGB` before changing either one.
    let hasUnifiedMemory: Bool

    // Whether the machine is Apple silicon, which is the platform fact the
    // budget keys on. `detect()` reads it from the KERNEL
    // (`hw.optional.arm64`) rather than from `#if arch(arm64)`: the compile
    // arch answers "what was this binary built for", and `Package.swift`
    // carries no architecture restriction, so an x86_64 build genuinely can
    // run translated under Rosetta on an M-series Mac, where compile-time
    // arch would hand Apple silicon the Intel fallback while Metal is
    // reporting a working set worth budgeting against. Stored rather than
    // derived so every fixture states it and no test inherits the host's
    // answer.
    let isAppleSilicon: Bool

    var physicalMemoryGB: Double { Double(physicalMemoryBytes) / 1_073_741_824 }
    var gpuWorkingSetGB: Double { Double(gpuWorkingSetBytes) / 1_073_741_824 }

    // The memory budget the Cookbook scores models against. Prefer the GPU
    // working set when Metal reported one on Apple silicon, where the GPU
    // shares its memory with the CPU and the figure already discounts what
    // macOS and apps need; otherwise assume 70 percent of physical RAM is
    // usable.
    //
    // THE PLATFORM IS THE KEY, NOT THE HARDWARE'S CLAIM ABOUT ITS MEMORY.
    // This condition has been wrong twice, in two different directions. First
    // it branched on `gpuWorkingSetBytes > 0` alone, so a DISCRETE card's
    // VRAM was taken as the budget: an 8 GB card in a 64 GB Mac Pro capped
    // the budget at 8 GB, hiding every model above a 4B, and it was the wrong
    // 8 GB anyway, because Ollama does not serve a model out of discrete VRAM
    // on macOS, it runs on the CPU out of system RAM. The fix gated on
    // `hasUnifiedMemory`, and that is the second wrong key: Intel INTEGRATED
    // GPUs report unified memory too, truthfully, while their
    // recommendedMaxWorkingSetSize is a gigabyte or two, so an Intel source
    // build on a 16 GB machine budgeted roughly 1.5 GB instead of 11.2 and
    // rated nearly the whole catalog too big. What separates the machines
    // whose Metal working set IS the model budget from the machines whose is
    // not is the platform, so `isAppleSilicon` is what the branch reads.
    //
    // WHICH MACHINES REACH THE FALLBACK, written down because the shipped app
    // is arm64 and it would be reasonable to assume nothing does: every Intel
    // Mac, integrated or discrete graphics alike, plus arm64 with no Metal
    // device, which is CI and some VM configurations, the SHIPPED path
    // `CookbookTests.test_budget_fallsBackTo70PercentRAM_withoutMetal` has
    // always covered. No RELEASE lands on Intel, `Grux-Mac/build.sh` line 42
    // runs `swift build -c release --arch arm64` and the README requires
    // Apple silicon, but `Package.swift` carries no architecture restriction,
    // so a contributor who runs `swift build` on an Intel Mac does, and gets
    // a defensible budget rather than a wrong one. The branch is deliberately
    // not deleted: "we only ship arm64" is not the same claim as "nothing
    // else compiles", and removing it becomes a zero budget for the no-Metal
    // case, which rates every model in the catalog "Too big" on a machine
    // that is fine.
    //
    // 0.70 IS A JUDGEMENT CALL, NOT A MEASUREMENT, in the same spirit as
    // `budgetFraction` below. On Apple silicon Metal reports roughly 75 percent
    // of RAM as the working set it will admit to, and that figure already
    // discounts what macOS itself needs. With no usable Metal reading there is
    // no per-machine number at all, so this is that same 75 percent rounded down
    // for the fact that nothing measured THIS machine. It errs low on purpose:
    // too small hides a model from somebody who could have run it, too large
    // recommends one that swaps, and only the second is met by the user as the
    // app being wrong about their Mac.
    var modelBudgetGB: Double {
        if isAppleSilicon, gpuWorkingSetBytes > 0 {
            return min(gpuWorkingSetGB, physicalMemoryGB)
        }
        return physicalMemoryGB * 0.70
    }

    // The same budget, discounted by what the machine is actually doing.
    //
    // `modelBudgetGB` above is a DEVICE PROPERTY and it does not move.
    // `recommendedMaxWorkingSetSize` is roughly 75 percent of RAM on Apple
    // Silicon and reports the identical number on a freshly booted machine and
    // on one already holding a browser, an IDE and a video call. So on a 16 GB
    // machine the Cookbook called an 11 GB model a "Good fit" while most of that
    // budget was already spent, and the user met the verdict as swap rather than
    // as a warning: the fit label was right about the hardware and wrong about
    // the machine.
    //
    // The fix is NOT a smaller constant. A machine with nothing else running
    // really can hold that model, and permanently shaving the budget would hide
    // a model from the one user who could run it. The budget has to move, so it
    // takes the live headroom as an argument.
    //
    // Passed IN rather than read here, for the same reason `detect()` is the
    // only thing in this file that touches sysctl: this stays a pure value type
    // that a test can drive through every state without owning the hardware.
    func modelBudgetGB(headroom: MachineLoad.Headroom) -> Double {
        modelBudgetGB * Self.budgetFraction(for: headroom)
    }

    // What share of the device budget is safe to promise at each level.
    //
    // Deliberately blunt numbers. There is no measurement that turns "thermal
    // state is serious" into a byte count, and inventing a precise looking one
    // would only make the guess harder to argue with later. What they have to
    // get right is the DIRECTION and the size of the step: 0.70 has to be enough
    // to push a model that was scored "Good" on a loaded machine down a rating,
    // or the whole exercise changes nothing a user would notice.
    static func budgetFraction(for headroom: MachineLoad.Headroom) -> Double {
        switch headroom {
        case .full:    return 1.00
        case .reduced: return 0.70
        case .minimal: return 0.45
        }
    }

    // The live budget with the numbers that produced it still attached.
    func modelBudget(headroom: MachineLoad.Headroom) -> ModelBudget {
        ModelBudget(gigabytes: modelBudgetGB(headroom: headroom),
                    deviceGigabytes: modelBudgetGB,
                    headroom: headroom)
    }

    var memoryTier: MemoryTier { MemoryTier.tier(forMemoryGB: physicalMemoryGB) }

    // Live detection. Cheap (microseconds), safe to call on the main actor.
    static func detect() -> HardwareProfile {
        let mem = sysctlUInt64("hw.memsize")
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown chip"
        var gpuBytes: UInt64 = 0
        var unified = false
        if let device = MTLCreateSystemDefaultDevice() {
            gpuBytes = device.recommendedMaxWorkingSetSize
            unified = device.hasUnifiedMemory
        }
        return HardwareProfile(
            chipName: chip,
            physicalMemoryBytes: mem,
            gpuWorkingSetBytes: gpuBytes,
            cpuCoreCount: ProcessInfo.processInfo.activeProcessorCount,
            hasUnifiedMemory: unified,
            isAppleSilicon: detectIsAppleSilicon()
        )
    }

    // The platform read `detect()` and the legacy decode below share.
    // `hw.optional.arm64` reports the HARDWARE: 1 on Apple silicon from
    // native and Rosetta-translated processes alike, and the name does not
    // exist on Intel, where the failed read is the correct false. It is a
    // CTLTYPE_INT, so it gets its own four byte read rather than reusing
    // `sysctlUInt64`.
    static func detectIsAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return rc == 0 && value != 0
    }

    // MARK: - sysctl helpers

    private static func sysctlUInt64(_ name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let rc = sysctlbyname(name, &value, &size, nil, 0)
        return rc == 0 ? value : 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Decoding stays open to a cookbook.json written before `isAppleSilicon`
// existed. `CookbookState` loads with a fallback of `.empty`, so a thrown
// key-not-found here would cost an existing install its pulled list, its
// selected model and its auto-serve preference on the first launch after this
// field shipped, which is a data loss dressed as a schema change. The backfill
// is the same kernel read `detect()` takes, and it is honest for the same
// reason: `lastProfile` is a snapshot of the machine the file sits on, and the
// machine's architecture does not change between launches. Encoding stays
// synthesized, so a state written by this build carries the real value and
// never takes the backfill branch again.
//
// IN AN EXTENSION ON PURPOSE: an initializer in the main declaration would
// suppress the memberwise initializer, and every fixture in the test suite
// builds profiles through it.
extension HardwareProfile {
    private enum DecodeKeys: String, CodingKey {
        case chipName, physicalMemoryBytes, gpuWorkingSetBytes, cpuCoreCount,
             hasUnifiedMemory, isAppleSilicon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DecodeKeys.self)
        chipName = try c.decode(String.self, forKey: .chipName)
        physicalMemoryBytes = try c.decode(UInt64.self, forKey: .physicalMemoryBytes)
        gpuWorkingSetBytes = try c.decode(UInt64.self, forKey: .gpuWorkingSetBytes)
        cpuCoreCount = try c.decode(Int.self, forKey: .cpuCoreCount)
        hasUnifiedMemory = try c.decode(Bool.self, forKey: .hasUnifiedMemory)
        isAppleSilicon = try c.decodeIfPresent(Bool.self, forKey: .isAppleSilicon)
            ?? Self.detectIsAppleSilicon()
    }
}

// A model budget with its own arithmetic still attached.
//
// A fit label is a claim about a number, and the number was invisible. The
// Cookbook computed `model.estimatedMemoryGB / profile.modelBudgetGB`, threw the
// budget away and printed "Good fit", so a user who disagreed with the verdict
// had nothing to disagree WITH, and a support answer could only repeat the
// label back at them. Carrying both numbers makes the claim checkable: "17 GB
// budget, down from 24 GB" is something a reader can hold against Activity
// Monitor, "Good fit" is an opinion.
struct ModelBudget: Equatable {
    // What models should be scored against right now.
    let gigabytes: Double

    // What the device would allow with nothing else going on. Equal to
    // `gigabytes` at full headroom, and the gap between the two is the whole
    // point of showing both.
    let deviceGigabytes: Double

    let headroom: MachineLoad.Headroom

    // One line a fit label can sit next to. Says the numbers first and the
    // reason second, because the number is the part that can be checked.
    var summary: String {
        switch headroom {
        case .full:
            return String(format: "%.0f GB budget", gigabytes)
        case .reduced:
            return String(format: "%.0f GB budget, down from %.0f GB, the machine is under load",
                          gigabytes, deviceGigabytes)
        case .minimal:
            return String(format: "%.0f GB budget, down from %.0f GB, the machine is at its limit",
                          gigabytes, deviceGigabytes)
        }
    }
}

// Coarse RAM tier. The Cookbook keys its per-tier headline recommendation off
// this; fit scoring is continuous (modelBudgetGB) so the tier is mostly a
// label for the hardware card and for tests.
enum MemoryTier: String, Codable, CaseIterable, Comparable {
    case ram8
    case ram16
    case ram32
    case ram64
    case ram128

    static func tier(forMemoryGB gb: Double) -> MemoryTier {
        switch gb {
        case ..<12:  return .ram8
        case ..<24:  return .ram16
        case ..<48:  return .ram32
        case ..<96:  return .ram64
        default:     return .ram128
        }
    }

    var label: String {
        switch self {
        case .ram8:   return "8 GB class"
        case .ram16:  return "16 GB class"
        case .ram32:  return "32 GB class"
        case .ram64:  return "64 GB class"
        case .ram128: return "128 GB class"
        }
    }

    private var rank: Int {
        switch self {
        case .ram8: return 0
        case .ram16: return 1
        case .ram32: return 2
        case .ram64: return 3
        case .ram128: return 4
        }
    }

    static func < (lhs: MemoryTier, rhs: MemoryTier) -> Bool { lhs.rank < rhs.rank }
}
