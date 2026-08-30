import Foundation
import IOKit.ps

/// Lock box so `MachineLoad.current`, a nonisolated static read from any thread,
/// can consult the last observed memory pressure without hopping to the main
/// actor. Same shape as the suspension box in MotionSuspension.swift, and for
/// the same reason.
private final class MemoryPressureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MachineLoad.MemoryPressure = .normal
    var pressure: MachineLoad.MemoryPressure {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private let memoryPressureBox = MemoryPressureBox()

/// What the machine can afford right now, and the one place that decides.
///
/// NOTHING IN THE APP READ THE MACHINE. Measured across `Sources/` before this
/// file existed: `thermalState` appeared zero times, `isLowPowerModeEnabled`
/// zero times, a memory pressure source zero times, and `activeProcessorCount`
/// exactly once, in `HardwareProfile.detect()`, only to fill a display field. So
/// Grux behaved identically on a fanless 8 GB laptop running on battery at its
/// thermal limit and on a plugged in workstation: same session ceiling, same
/// model budget, same everything. The laptop met that decision as a fan, a
/// stall, and an answer that arrived after the user had given up on it.
///
/// ONE DERIVED VALUE, NOT FOUR RAW ONES. Callers read `headroom`. If every
/// consumer branched on the raw thermal state for itself the policy would be
/// spread across as many files as there are consumers, and whichever one was
/// written first would quietly become the standard for the rest. The raw values
/// stay published because a diagnostics surface should be able to show a reader
/// what produced the verdict, but the verdict is computed in exactly one
/// function.
///
/// THE RULE IS PURE AND THE READING IS NOT, and they are split for a reason this
/// repo has hit before. `CapabilityResolver.keyIsSatisfied` and
/// `ChatReadiness.evaluate` were both pulled out of their environment-reading
/// callers because a test on a real machine can only ever observe whatever that
/// machine happens to be doing. Here it is worse: nobody can put a test host
/// into thermal `.critical` on demand, and the `ScreenControl` tests already
/// skip themselves rather than assume the host. So `headroom(thermalState:
/// lowPowerMode:memoryPressure:)` takes the three facts as arguments and reads
/// nothing, and every combination of them is asserted in `MachineLoadTests`.
@MainActor
final class MachineLoad: ObservableObject {
    static let shared = MachineLoad()

    /// How much of the machine the app should be willing to spend.
    ///
    /// Three levels on purpose. Two would collapse "the machine is warm" into
    /// either "carry on" or "stop", and the honest answer to a warm machine is
    /// neither of those. More than three would hand every consumer a policy
    /// opinion, which is the thing this type exists to take away from them.
    enum Headroom: String, CaseIterable, Sendable {
        case full
        case reduced
        case minimal
    }

    /// The three levels a memory pressure source reports, as a plain enum.
    ///
    /// Not `DispatchSource.MemoryPressureEvent`, which is an OptionSet: it can
    /// hold two flags at once, it has no ordering, and a test asserting on it
    /// would be asserting on a bitmask rather than on a state. The mapping from
    /// the OptionSet happens once, in the event handler.
    enum MemoryPressure: String, CaseIterable, Sendable {
        case normal
        case warning
        case critical
    }

    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var memoryPressure: MemoryPressure = .normal
    @Published private(set) var onBattery: Bool = !MachineLoad.isOnACPower()

    /// The one value consumers read.
    var headroom: Headroom {
        Self.headroom(thermalState: thermalState,
                      lowPowerMode: lowPowerMode,
                      memoryPressure: memoryPressure)
    }

    /// The same verdict, readable from any thread and without this observable
    /// having been started.
    ///
    /// `SessionConcurrency` is nonisolated and runs on whatever thread starts a
    /// swarm, and it must not depend on some view having called
    /// `startIfNeeded()` first. A headroom that reads `.full` because nobody
    /// switched the observable on is worse than no headroom at all, because it
    /// looks like a measurement. Thermal state and low power mode are cheap
    /// nonisolated reads and so are always live here. Memory pressure is the one
    /// input that genuinely needs a running source, so it reports `.normal`
    /// until `startIfNeeded()` has run. That is the safe direction to be wrong
    /// in: it can only ever make this MORE generous than the truth, never less,
    /// and it never fabricates a restriction the user cannot explain.
    nonisolated static var current: Headroom {
        headroom(thermalState: ProcessInfo.processInfo.thermalState,
                 lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                 memoryPressure: memoryPressureBox.pressure)
    }

    /// THE RULE, as a pure function of the three facts that decide it.
    nonisolated static func headroom(thermalState: ProcessInfo.ThermalState,
                                     lowPowerMode: Bool,
                                     memoryPressure: MemoryPressure) -> Headroom {
        // Critical comes first and is unconditional. Thermal `.critical` is the
        // level at which macOS itself has already started throttling, and
        // critical memory pressure is the level at which the kernel starts
        // killing processes to get memory back. Neither of those is a hint.
        if thermalState == .critical || memoryPressure == .critical { return .minimal }
        // Low power mode is a STATED PREFERENCE, not a symptom. A user who
        // turned it on has asked for less work, and honouring it only when the
        // machine also happens to be warm would mean ignoring the request on
        // precisely the machine that is coping with it.
        if lowPowerMode { return .reduced }
        switch thermalState {
        case .nominal:
            // A memory warning is not in the same class as the two cases above,
            // and it does not by itself mean the machine is in trouble. It is
            // still worth a step down, because a source armed for `.warning`
            // that changed nothing would be a subscription with no subscriber.
            return memoryPressure == .warning ? .reduced : .full
        case .fair, .serious:
            return .reduced
        case .critical:
            // Unreachable, handled above, and kept so this switch stays
            // exhaustive over the real enum rather than over today's shortcut.
            return .minimal
        @unknown default:
            // A thermal state Apple adds later will not be cooler than the ones
            // that already exist.
            return .reduced
        }
    }

    // MARK: - Live sources

    // Every source below is a registration that outlives the call that made it,
    // and each is held here because letting go of it stops it: an unretained
    // DispatchSource is cancelled, and an unretained CFRunLoopSource is freed
    // out from under the run loop.
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var memorySource: DispatchSourceMemoryPressure?
    private var powerSourceRunLoop: CFRunLoopSource?

    private init() {}

    /// Idempotent, the way `LocalHealthMonitor.startIfNeeded()` is, and for the
    /// same reason: the natural caller is a view's `.onAppear`, which fires
    /// again every time the user reopens the surface. A second registration
    /// would double every callback and leave a source nothing ever cancels.
    func startIfNeeded() {
        guard !started else { return }
        started = true

        let nc = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification,
                     NSNotification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MachineLoad.shared.refresh() }
            })
        }

        // ARMED FOR `.normal` TOO, AND THAT IS THE POINT. A source armed only
        // for `.warning` and `.critical` can only ratchet one way: it fires when
        // pressure rises and stays silent when it falls, so the first warning of
        // a session would pin the app at reduced headroom until the next launch,
        // and the user would report Grux as permanently slow after doing nothing
        // at all. The recovery edge is the one that has to be subscribed to.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler {
            // The queue is `.main`, so this is already on the main actor and the
            // event can be read synchronously. Hopping through a Task would read
            // `data` after the handler had returned, by which point the pending
            // event has been consumed and the read reports nothing.
            MainActor.assumeIsolated {
                let load = MachineLoad.shared
                load.apply(load.memorySource?.data ?? [])
            }
        }
        source.activate()
        memorySource = source

        // There is no Foundation notification for AC versus battery.
        // `NSProcessInfoPowerStateDidChange` covers low power mode only, and on
        // a Mac set to "Low Power Mode: only on battery" the two look like the
        // same event right up until somebody sets it to "always". IOKit's power
        // source run loop source is the real signal, and IOKit.ps is already a
        // dependency of this target rather than a framework pulled in for one
        // boolean. The callback captures nothing so it converts to a plain C
        // function pointer, which is why it can reach the singleton by name
        // instead of trampolining a context pointer through `Unmanaged`.
        if let runLoopSource = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in MachineLoad.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            powerSourceRunLoop = runLoopSource
        }

        refresh()
    }

    /// Re-reads the three values that have no event payload of their own.
    ///
    /// Each assignment is guarded, because these are `@Published` and every
    /// unchanged write is a SwiftUI invalidation of whatever observes this. The
    /// power source source in particular fires on battery percentage changes,
    /// which on a laptop means roughly once a minute forever.
    private func refresh() {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != thermalState { thermalState = thermal }

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPower != lowPowerMode { lowPowerMode = lowPower }

        let battery = !Self.isOnACPower()
        if battery != onBattery { onBattery = battery }
    }

    /// Collapses the OptionSet the source hands over into one level, worst flag
    /// wins. Both `.warning` and `.critical` can be set in a single event.
    private func apply(_ event: DispatchSource.MemoryPressureEvent) {
        let pressure: MemoryPressure
        if event.contains(.critical) {
            pressure = .critical
        } else if event.contains(.warning) {
            pressure = .warning
        } else {
            pressure = .normal
        }
        guard pressure != memoryPressure else { return }
        memoryPressure = pressure
        // The box, not the published property, is what `current` reads, so it
        // has to be written on the same line of code that changes the state.
        // Two stores that can drift are one store and one bug.
        memoryPressureBox.pressure = pressure
    }

    /// True when the providing power source is AC.
    ///
    /// Deliberately duplicated from `FoundryGovernor.isOnACPower()` rather than
    /// shared. This type sits at the bottom of the stack and is read by
    /// `SessionConcurrency` on the path of every swarm start, so pointing it at
    /// a Foundry symbol would make the concurrency ceiling depend on a feature
    /// module. The failure direction is identical in both: on any error assume
    /// AC, because a desktop Mac reports no battery sources at all and must
    /// never be handled as a laptop running flat.
    nonisolated static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        // Get (not Copy) rule: the providing-type CFString is not owned by us.
        guard let typeCF = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (typeCF as String) == kIOPMACPowerKey
    }
}
