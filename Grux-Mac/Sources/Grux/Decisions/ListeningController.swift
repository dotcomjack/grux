import Foundation

/// The only thing that starts or stops the two listeners. Every other path
/// (Settings, the CLI triggers, launch) sets `config.listeningMode` and calls
/// `apply`, so the mode and what is actually running cannot drift apart.
///
/// It drives the EXISTING doors rather than the engines underneath them:
/// `AmbientState.enable()` and `WakeWordListener.enable()` own the consent
/// dialogs, the coach, the HUD and the old preference flags that mute and
/// unmute restore from. Going around them would take the microphone with no
/// disclosure, which is the exact bug those doors were built to close.
@MainActor
final class ListeningController {
    static let shared = ListeningController(
        startWake: { await WakeWordListener.shared.enable() },
        stopWake: { WakeWordListener.shared.disable() },
        startAmbient: {
            // Always on is the continuous pipeline; the wake sub-mode is
            // what the After Hey Grux state is for.
            AppState.shared.config.ambientMode = .focus
            await AmbientState.shared.enable()
        },
        stopAmbient: { AmbientState.shared.disable() },
        isRunning: { mode in
            switch mode {
            case .alwaysOn: return AmbientState.shared.isEnabled
            case .wakeWord: return AppState.shared.config.wakeWordEnabled
            case .off: return true
            }
        })

    private(set) var current: ListeningMode?
    private let startWake: () async -> Void
    private let stopWake: () -> Void
    private let startAmbient: () async -> Void
    private let stopAmbient: () -> Void
    private let isRunning: (ListeningMode) -> Bool

    init(startWake: @escaping () async -> Void, stopWake: @escaping () -> Void,
         startAmbient: @escaping () async -> Void, stopAmbient: @escaping () -> Void,
         isRunning: @escaping (ListeningMode) -> Bool) {
        self.startWake = startWake; self.stopWake = stopWake
        self.startAmbient = startAmbient; self.stopAmbient = stopAmbient
        self.isRunning = isRunning
    }

    /// Applies a mode and returns the mode that is actually in effect. A
    /// declined consent dialog is an answer: the listener did not start, so
    /// the effective mode is off and the caller should save that, not the
    /// mode that was asked for.
    // Two callers arriving together (a Settings tap and a CLI trigger, or two
    // triggers) must not interleave their stop/start pairs. Measured on the
    // first live run: interleaving wrote a transient off while ambient was
    // in fact capturing. Each apply waits for the previous one to finish.
    private var inflight: Task<ListeningMode, Never>?

    @discardableResult
    func apply(mode: ListeningMode) async -> ListeningMode {
        let previous = inflight
        let task = Task<ListeningMode, Never> { @MainActor in
            _ = await previous?.value
            return await self.applyNow(mode: mode)
        }
        inflight = task
        return await task.value
    }

    private func applyNow(mode: ListeningMode) async -> ListeningMode {
        switch mode {
        case .alwaysOn:
            stopWake(); await startAmbient()
        case .wakeWord:
            stopAmbient(); await startWake()
        case .off:
            stopWake(); stopAmbient()
        }
        let effective: ListeningMode = isRunning(mode) ? mode : .off
        current = effective
        return effective
    }

    /// Reads the saved mode, applies it, and writes back the effective mode.
    func apply() async {
        let wanted = AppState.shared.config.listeningMode
        let effective = await apply(mode: wanted)
        if effective != wanted {
            AppState.shared.config.listeningMode = effective
            AppState.shared.saveConfig()
        }
    }

    /// Launch never opens a consent dialog over the first screen. A fresh
    /// install (always on, never asked) starts with the listeners closed and
    /// is asked once from onboarding or Settings; an install that already
    /// acknowledged consent picks up where it left off.
    func applyAtLaunch() async {
        let c = AppState.shared.config
        switch c.listeningMode {
        case .alwaysOn where !c.ambientConsentAcknowledged: return
        case .wakeWord where !c.wakeWordConsentAcknowledged: return
        default: await apply()
        }
    }
}
