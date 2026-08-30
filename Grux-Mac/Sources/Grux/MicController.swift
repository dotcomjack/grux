import Foundation
import AVFoundation

// Central switchboard for the mic. The orb is bound to `toggle()` - one
// tap stops whichever listener is active; another tap restarts the one that
// matches the current config (ambient > wake). Mute state lives on AppState
// (`micMuted`) so any UI can reflect it - menu bar glyph, orb, status pill.
//
// Also the single point of TCC auth. All four capture paths (VoiceInput,
// WakeWord, AmbientListener, MeetingMicCapture) route through
// ensureAuthorized() so the prompt lifecycle is observable in one place,
// and so a cdhash-bound grant that keeps getting re-prompted is visible
// in wake.log ("status=.notDetermined despite prior grant").
//
// Why it lives here and not in AmbientListener or WakeWordListener: those
// two already have independent start/stop lifecycles, and a bunch of other
// code paths call into them (pauseForExplicitInput, etc). This keeps the
// user-facing "mic on / mic off" semantics in one place.
@MainActor
enum MicController {
    private static let priorGrantKey = "grux.mic.grantedOnce"

    /// Called once at app launch (from AppDelegate.applicationDidFinishLaunching).
    /// Reads authorizationStatus from a known-good launched-from-/Applications
    /// state BEFORE FocusWatcher, Ambient, or any hotkey handler runs. Pins
    /// the responsible process that coreaudiod's SecCode lookup will later
    /// see, so the next TCC grant binds to the properly-signed bundle rather
    /// than to whatever stale LaunchServices copy might win the race.
    static func prewarmAtLaunch() {
        _ = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Single entry point for "can I touch the mic?". Handles the three
    /// TCC states uniformly, logs the cdhash-rebind case so it's visible
    /// when it happens, and remembers that we've been granted at least
    /// once so re-prompts can be detected across launches.
    ///
    /// Returns true iff the app is (or became) authorized.
    static func ensureAuthorized() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            UserDefaults.standard.set(true, forKey: priorGrantKey)
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            // notDetermined after a prior grant ⇒ TCC's stored csreq no
            // longer matches this binary (classic cdhash-rebind: grant
            // was bound to an unsigned copy, or the signing identity /
            // cdhash shifted between runs). Surface it so the audit log
            // catches the next time it happens.
            if UserDefaults.standard.bool(forKey: priorGrantKey) {
                WakeLog.shared.log(
                    "mic: status=.notDetermined despite prior grant - TCC csreq binding likely broken, prompt will re-appear"
                )
            }
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
            if ok { UserDefaults.standard.set(true, forKey: priorGrantKey) }
            return ok
        @unknown default:
            return false
        }
    }

    static func toggle() {
        let state = AppState.shared
        if state.micMuted {
            unmute()
        } else {
            mute()
        }
    }

    static func mute() {
        let state = AppState.shared
        guard !state.micMuted else { return }
        state.micMuted = true
        // EVERY microphone owner, not the two that were easiest to remember.
        //
        // Reported 2026-08-24 with a screenshot: Grux showing MUTED and
        // "Paused", the macOS orange microphone indicator still lit, and Voice
        // Memos unable to record. This stopped AmbientListener and
        // WakeWordListener. The app has FOUR input taps. It stopped two, so
        // dictation and meeting capture kept the device and the UI said
        // otherwise.
        //
        // Muting a background assistant is a promise that the machine is the
        // user's again. Holding the device anyway is worse than not offering
        // mute at all. MicMuteReleasesDeviceTests sweeps the tree for
        // `installTap(onBus:` and fails if a new owner is added without a stop
        // here, because the real failure mode is a fifth tap written by
        // somebody who does not know this function exists.
        AmbientListener.shared.stop()
        WakeWordListener.shared.stop()
        VoiceInput.shared.stop()
        // A meeting in progress is stopped through its SERVICE, not by reaching
        // past it into the capture object, so the transcript is summarised and
        // saved rather than dropped. Muting must free the microphone; it must
        // not silently destroy a recording the user is relying on.
        // isCapturing ALONE LEAVES A HOLE, and review found it reproduces the
        // exact reported symptom. MeetingCaptureService installs the mic tap,
        // then awaits ScreenCaptureKit setup (hundreds of ms, can prompt), and
        // only THEN sets isCapturing. Mute inside that window saw false, did
        // nothing, and the meeting came up holding the microphone while every
        // surface read MUTED. isInitializing covers the window.
        if MeetingCaptureService.shared.isCapturing || MeetingCaptureService.shared.isInitializing {
            // HELD, NOT DROPPED. Summarising a meeting takes seconds, so this
            // work outlives the call. Anything that wants to report the state
            // mute() REACHED, rather than the state it was in when mute() was
            // called, has to be able to wait for it.
            pendingWork = Task { await MeetingCaptureService.shared.stop(summarize: true) }
        }
        // Pull the ambient HUD's live "isEnabled" pill down so every surface
        // (sidebar orb, HUD capture pill, menu bar ambient row, focus overlay)
        // tells the same story: mic is OFF globally. config.ambientEnabled
        // (the persisted preference) is intentionally NOT touched - unmute
        // restores it from there.
        AmbientState.shared.isEnabled = false
        AmbientState.shared.status = "Muted"
        WakeLog.shared.log("mic: MUTED (user tapped orb) - ambient isEnabled pulled to false")
    }

    static func unmute() {
        let state = AppState.shared
        guard state.micMuted else { return }
        state.micMuted = false
        // Restart whichever listener matches the user's persistent config.
        // Ambient wins when both are enabled (matches AppDelegate launch logic).
        // HELD, for the same reason mute() holds its work. Measured on a live
        // build: unmute, then read the status file, and it said
        // ambientCapturing false. Three seconds later the same read said true.
        // Starting a listener loads a Whisper model, so the file was describing
        // the moment before the restart it had just asked for, which is the
        // exact staleness this file was fixed for on the mute side and missed
        // on this one.
        if state.config.ambientEnabled {
            AmbientState.shared.isEnabled = true
            pendingWork = Task { @MainActor in await AmbientListener.shared.start() }
            WakeLog.shared.log("mic: UNMUTED → ambient listener restarting")
        } else if state.config.wakeWordEnabled {
            pendingWork = Task { @MainActor in await WakeWordListener.shared.start() }
            WakeLog.shared.log("mic: UNMUTED → wake-word listener restarting")
        } else {
            WakeLog.shared.log("mic: UNMUTED but no listener enabled in config")
        }
    }

    /// Work started by `mute()` or `unmute()` that has not finished yet.
    ///
    /// Deliberately not `private`: `MicStatusFileTests` installs a probe task
    /// here to prove that `writeMicStatus` actually waits, which is the whole
    /// contract and is otherwise only assertable by reading the source.
    static var pendingWork: Task<Void, Never>?

    /// One line of truth about the microphone, for a caller that cannot click.
    ///
    /// STALE BY CONSTRUCTION UNTIL THIS AWAITED. Both `mute()` and `unmute()`
    /// finish their real work in a detached task, because stopping a meeting
    /// summarises a transcript and starting a listener loads a Whisper model,
    /// and neither can block the caller. The file was written the instant they
    /// returned, so it reported `meetingCapturing` true right after a
    /// successful mute and `ambientCapturing` false right after a successful
    /// unmute. Measured on a live build for the unmute case: false, then true
    /// three seconds later, with nothing having changed in between except the
    /// restart the file had already been asked to describe.
    @MainActor
    static func writeMicStatus(dir: URL) async {
        await pendingWork?.value
        pendingWork = nil
        let s = AppState.shared
        let payload: [String: Any] = [
            "micMuted": s.micMuted,
            // THE PREFERENCE AND THE RUNTIME STATE ARE DIFFERENT QUESTIONS and
            // this file used to answer the second under the name of the first.
            // `AmbientState.isEnabled` is pulled to false by mute() while
            // `config.ambientEnabled` deliberately survives it, which is what
            // unmute restores from. A caller asking "is ambient turned on"
            // wants the preference; a caller asking "is it listening right now"
            // wants the other two.
            "ambientEnabledPreference": s.config.ambientEnabled,
            "wakeWordEnabledPreference": s.config.wakeWordEnabled,
            "ambientListening": AmbientState.shared.isEnabled,
            "ambientCapturing": AmbientState.shared.isCapturing,
            "meetingCapturing": MeetingCaptureService.shared.isCapturing,
            "meetingInitializing": MeetingCaptureService.shared.isInitializing,
            "voiceInputRecording": VoiceInput.shared.isRecording,
            "wakeWordListening": WakeWordListener.shared.isListening,
            "at": ISO8601DateFormatter().string(from: Date())
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) else { return }
        // ATOMIC. A reader polling this file in a loop is the intended use, and
        // a plain write truncates first, so the poll that lands in the gap gets
        // an empty or half-written file and fails to parse. Writing to a
        // temporary and renaming makes every read see one whole version or the
        // previous one.
        try? d.write(to: dir.appendingPathComponent("mic-status.json"), options: .atomic)
    }
}
