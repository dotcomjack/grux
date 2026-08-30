import Foundation

/// How many agent sessions Grux will run at once, and the one place that decides.
///
/// BEFORE THIS, NOTHING DECIDED. `AgentTools` read the count straight off the
/// tool-call arguments, `let maxPar = (input["max_parallel"] as? Int) ?? 3`,
/// with no clamp, and handed it to the swarm. The number of concurrent sessions
/// was therefore chosen by the model, per call, unbounded: a prompt asking for
/// fifty workers would have started fifty.
///
/// That is the behaviour most likely to push a subscription into its rate
/// limits, and it is the one onboarding now tells users to keep low. Telling
/// somebody to keep a number low while the number is out of their hands is not
/// advice, it is decoration. This makes it theirs.
///
/// THEN THE NUMBERS THEMSELVES WERE STILL NOBODY'S. The first version closed the
/// unbounded case with two constants, `fallback = 2` and `hardCeiling = 8`, and
/// neither had anything to do with the machine underneath. A 24 core workstation
/// with 128 GB was held at eight, and a fanless 8 GB laptop was allowed to be
/// SET to eight, which is not a ceiling, it is a cliff with a railing painted on
/// it. Both now come out of `limits(coreCount:memoryBudgetGB:headroom:)`, and
/// the constants that used to be the answer are kept as the floor and the
/// absolute cap so the argument above still holds: the model cannot raise this,
/// and neither can the hardware past the point a subscription can feed.
///
/// Stored in UserDefaults rather than `GruxConfig` on purpose. The step flags
/// already live there, it needs no Codable migration on a struct every install
/// decodes at launch, and the failure mode of a missing key is the conservative
/// default rather than a decode error.
enum SessionConcurrency {

    /// Namespaced to match the `grux.step.` convention `CapabilityResolver` uses.
    static let defaultsKey = "grux.sessions.max_parallel"

    /// The floor the derivation may never go under. Two sessions is the point
    /// below which the feature stops being a swarm, and a machine too small for
    /// two is a machine too small for the feature, which is a different
    /// conversation than a ceiling.
    static let conservativeFloor = 2

    /// The absolute cap, whatever the hardware says. This is the constant that
    /// used to BE `hardCeiling`, and it is kept because the binding constraint
    /// at the top end is not the machine: an account's rate limit is the same on
    /// a laptop and on a workstation, and a stored value can be typed, migrated
    /// or corrupted, none of which should be able to reintroduce the unbounded
    /// case this type exists to close.
    static let absoluteCeiling = 8

    /// The most the out-of-box default may rise to on any machine.
    ///
    /// The default is deliberately NOT free to track the hardware upward, for
    /// the reason the doc comment above gives: a user who has never opened
    /// Settings is the one who has never thought about rate limits, and rate
    /// limits do not get more generous when you buy more cores. Hardware may
    /// nudge this by one and may push it back down to the floor. It may not turn
    /// a first launch into eight parallel sessions.
    static let conservativeDefaultCap = 3

    /// Roughly what one agent session costs in memory, in GB.
    ///
    /// A session is a `claude --print` subprocess plus whatever tool
    /// subprocesses it starts, so this is an estimate and not a measurement, and
    /// it is a deliberately generous one. Erring high costs a user one worker.
    /// Erring low costs them the machine, and they experience that as Grux
    /// having hung rather than as a setting they could have changed.
    static let memoryGBPerSession = 2.0

    /// The two numbers the hardware decides.
    struct Limits: Equatable {
        /// What an install that never opens Settings gets.
        let starting: Int
        /// The most the user is allowed to set.
        let ceiling: Int
    }

    /// THE DERIVATION, as a pure function of the three facts that decide it.
    ///
    /// Pure for the same reason `MachineLoad.headroom` and
    /// `ChatReadiness.evaluate` are: the live inputs read a real machine in a
    /// state nobody can arrange, so a test of the live path can only ever assert
    /// whatever the host happens to be. Given the arguments, a small laptop, a
    /// mid machine and a workstation are all testable from one desk.
    ///
    /// - Parameters:
    ///   - coreCount: `HardwareProfile.cpuCoreCount`. Halved, because a session
    ///     is a subprocess that will happily take a core and the user still has
    ///     to be able to type while it does.
    ///   - memoryBudgetGB: `HardwareProfile.modelBudgetGB`. Used as the honest
    ///     measure of machine size rather than raw `hw.memsize`, which counts
    ///     memory the machine has already promised elsewhere.
    ///   - headroom: what the machine is doing right now. Can only ever lower
    ///     the answer.
    static func limits(coreCount: Int,
                       memoryBudgetGB: Double,
                       headroom: MachineLoad.Headroom) -> Limits {
        let byCore = coreCount / 2
        let byMemory = Int(memoryBudgetGB / memoryGBPerSession)
        // The smaller of the two, because a machine with the cores for six
        // sessions and the memory for two has memory for two.
        let raw = min(byCore, byMemory)

        let scaled: Int
        switch headroom {
        case .full:    scaled = raw
        case .reduced: scaled = raw / 2
        case .minimal: scaled = 0   // Floored below. A busy machine gets the floor, not zero.
        }

        let ceiling = min(max(scaled, conservativeFloor), absoluteCeiling)
        return Limits(starting: min(ceiling, conservativeDefaultCap), ceiling: ceiling)
    }

    /// Detected once, on first use.
    ///
    /// `HardwareProfile.detect()` reads sysctl and creates a Metal device. That
    /// is microseconds, not free, and `clamp` sits on the path of every swarm
    /// start and every render of the Settings stepper. The chip and the core
    /// count do not change while the process is running; the headroom does, and
    /// it is read live below.
    private static let profile = HardwareProfile.detect()

    /// The live limits for this machine.
    static var hardwareLimits: Limits {
        limits(coreCount: profile.cpuCoreCount,
               memoryBudgetGB: profile.modelBudgetGB,
               headroom: MachineLoad.current)
    }

    /// The machine's structural maximum, ignoring what it happens to be doing.
    ///
    /// This is what a STORED preference is clamped against, and the distinction
    /// is not academic. Clamping the write against the live ceiling would let a
    /// thermal blip permanently rewrite a number the user chose: they would set
    /// six on a warm laptop, get two stored, and find the setting moved with
    /// nothing on screen able to explain it. A preference is a statement about
    /// the machine. The headroom discount belongs on the read, where it can come
    /// back when the machine cools.
    static var structuralCeiling: Int {
        limits(coreCount: profile.cpuCoreCount,
               memoryBudgetGB: profile.modelBudgetGB,
               headroom: .full).ceiling
    }

    /// What an install that never opens Settings gets. Deliberately low: the
    /// user least likely to have thought about rate limits is the one who never
    /// changed this. Now floored and capped by the machine as well, so a laptop
    /// that cannot hold two sessions is never handed two.
    static var fallback: Int { hardwareLimits.starting }

    /// The ceiling on the user's own ceiling, derived from the hardware and
    /// bounded by `absoluteCeiling`. A small machine can no longer be SET to a
    /// number it cannot run, which was the half of the problem the constant
    /// version left open: it stopped the model asking for fifty and cheerfully
    /// let the user ask for eight on a machine with four cores.
    static var hardCeiling: Int { hardwareLimits.ceiling }

    /// The effective ceiling, always in `1...hardCeiling`.
    ///
    /// A stored zero would switch sessions off silently, which reads as "the
    /// feature is broken" rather than "you set it to zero", so it floors at one.
    static var ceiling: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int else {
                return fallback
            }
            return min(max(stored, 1), hardCeiling)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 1), structuralCeiling), forKey: defaultsKey)
        }
    }

    /// Never raises a request, only lowers it. A caller that asks for one worker
    /// gets one worker even when the ceiling is eight, because the caller knows
    /// something the ceiling does not: `RDWorker` asks for exactly 1 on purpose.
    static func clamp(_ requested: Int) -> Int {
        min(max(requested, 1), ceiling)
    }
}
