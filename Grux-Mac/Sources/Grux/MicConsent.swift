import AppKit
import Foundation

/// What a person is agreeing to when they switch on a listening feature.
///
/// Ambient capture and the wake word both ship OFF, and both hold the
/// microphone continuously once on. That second part was never stated
/// anywhere. A user turned them on, later muted Grux, went to record a voice
/// memo, and found the machine behaving in ways nothing had prepared them for.
///
/// The fix for the mute bug itself is elsewhere. This is the other half: a
/// feature that takes a shared piece of hardware for as long as it runs should
/// say so before it starts, not after somebody notices.
///
/// WHAT THIS DELIBERATELY DOES NOT CLAIM. An earlier draft said other apps
/// could not record while Grux listened. Measured on this machine, that is
/// false: macOS shares the input device, and a second recorder captured real
/// audio with ambient running. Saying otherwise would trade one wrong
/// explanation for another, so the copy names only what is verifiable, the
/// microphone being held and the macOS indicator staying lit.
enum MicConsent {

    static let title = "This keeps the microphone open"

    /// The shared cost, true of both features.
    private static let shared = """
        Grux holds the microphone the whole time this is on, and macOS shows the \
        orange microphone dot in the menu bar while it does.

        Music and video can sound worse while it listens. Apple's voice processing \
        narrows system output to a call codec, so Music, Safari and YouTube go tinny \
        unless you have turned voice processing off or whitelisted your microphone \
        in Settings.

        You can mute it any time from the orb or the menu bar, which releases the \
        microphone immediately. It stays off until you turn it back on.
        """

    /// WHERE THE AUDIO GOES IS NOT THE SAME FOR BOTH, AND SAYING SO WRONGLY IS
    /// THE ONE MISTAKE HERE WITH LEGAL WEIGHT.
    ///
    /// Ambient transcribes with Whisper on this Mac. The wake word uses Apple's
    /// speech recogniser with `requiresOnDeviceRecognition = false`
    /// (`WakeWord.swift:179`), a deliberate choice its own comment explains:
    /// on-device has a smaller language model and mishears a novel word like
    /// "grux". So wake-word audio can leave the machine.
    ///
    /// A first version of this file told both users "Audio is transcribed on
    /// this Mac", and a test asserted that sentence was present, which locked
    /// the false claim in. Review caught it. Consent copy that is wrong about
    /// where a person's voice goes is worse than no consent copy.
    static func body(for feature: Feature) -> String {
        switch feature {
        case .ambient:
            return "Ambient mode transcribes with Whisper on this Mac, and the audio does not leave it.\n\n" + shared
        case .wakeWord:
            return "The wake word uses Apple's speech recognition, which may send short audio to Apple to "
                 + "recognise the phrase. Apple's on-device recogniser mishears \"grux\", so Grux does not "
                 + "force it.\n\n" + shared
        }
    }

    enum Feature { case ambient, wakeWord }

    static let confirmTitle = "Turn it on"
    static let cancelTitle = "Not now"

    /// Shown under the toggle once the feature is running, so the cost stays
    /// visible rather than being explained once and forgotten.
    static let runningNote =
        "The microphone is open while this is on, and system audio drops to a call codec. "
      + "Mute from the orb to release it."
}

// MARK: - The gate

/// THE DIALOG LIVED IN ONE VIEW AND THE FEATURE HAD THREE DOORS.
///
/// The first version of this consent put an `.alert` on `SettingsView` and set
/// it from that view's two toggles. `ambient.enable()` is also called from
/// `MenuBarView` and from the capture pill in `AmbientHUD`, and neither asked
/// anything: flipping the menu bar switch took the microphone with no
/// disclosure at all. Worse, the test that was supposed to cover this swept
/// `SettingsView.swift` only, so it reported full coverage of a feature with
/// two open side doors.
///
/// So the gate moved to the choke point, which is the same correction
/// `RecordingConsent` already applies to meeting capture, for the same reason
/// stated in that file: a gate at the call sites is one chance per call site to
/// miss it, and the next caller written misses it for free.
///
/// `NSAlert` rather than a SwiftUI alert, and that is what makes the choke
/// point possible at all. Ambient can be enabled from a menu bar popover or a
/// floating HUD panel, and a SwiftUI alert needs a view hierarchy to attach to.
/// An alert works from every entry point in every window state.
extension MicConsent {

    /// Has this specific feature been acknowledged?
    ///
    /// Per feature, not one shared flag, because the two dialogs make different
    /// promises about where the audio goes. Answering the ambient one must not
    /// consent on the user's behalf to sending audio to Apple.
    @MainActor
    static func isAcknowledged(_ feature: Feature) -> Bool {
        switch feature {
        case .ambient:  return AppState.shared.config.ambientConsentAcknowledged
        case .wakeWord: return AppState.shared.config.wakeWordConsentAcknowledged
        }
    }

    /// Injectable so the gate can be driven in a test without a modal.
    ///
    /// This is not decoration. Without a seam here the only provable statement
    /// about the gate is that a line of code exists somewhere, which is exactly
    /// the kind of source-text assertion that let the two ungated doors ship. A
    /// test can now enable ambient with the answer stubbed to "no" and assert
    /// the microphone was never taken.
    @MainActor
    static var presenter: (Feature) -> Bool = { presentPrompt(for: $0) }

    /// True when the feature may take the microphone. Asks once, then remembers.
    ///
    /// A decline is a legitimate answer and not an error: the caller must treat
    /// false as "do not start", and nothing is persisted, so the next attempt
    /// asks again.
    @MainActor
    static func ensureAcknowledged(for feature: Feature) -> Bool {
        if isAcknowledged(feature) { return true }
        let accepted = presenter(feature)
        guard accepted else {
            WakeLog.shared.log("mic consent: \(feature) declined, listener not started")
            return false
        }
        switch feature {
        case .ambient:  AppState.shared.config.ambientConsentAcknowledged = true
        case .wakeWord: AppState.shared.config.wakeWordConsentAcknowledged = true
        }
        AppState.shared.saveConfig()
        WakeLog.shared.log("mic consent: \(feature) acknowledged")
        return true
    }

    @MainActor
    static func presentPrompt(for feature: Feature) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body(for: feature)
        alert.addButton(withTitle: confirmTitle)   // .alertFirstButtonReturn
        alert.addButton(withTitle: cancelTitle)
        // AppKit wires Escape to a button titled exactly "Cancel". This one says
        // "Not now", so without this the dialog cannot be dismissed from the
        // keyboard at all, which for a modal in a menu bar app is a trap.
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.buttons.last?.setAccessibilityIdentifier("mic-consent-decline")
        alert.buttons.first?.setAccessibilityIdentifier("mic-consent-accept")
        // Ambient can be switched on from the menu bar while Grux is in the
        // background. An alert behind another window is an alert nobody answers.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Settings needs to be able to put this back, or a one-time answer is a
    /// trap: a user who clicks through it can never read what they agreed to.
    @MainActor
    static func reset(_ feature: Feature) {
        switch feature {
        case .ambient:  AppState.shared.config.ambientConsentAcknowledged = false
        case .wakeWord: AppState.shared.config.wakeWordConsentAcknowledged = false
        }
        AppState.shared.saveConfig()
    }
}
