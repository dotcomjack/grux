import AppKit

/// The one-time "you will tell them" gate in front of every meeting recording.
///
/// Recording a call captures every person on it, and only one of them is holding the mouse.
/// In several US states and most of Europe that is a legal question and not a courtesy one.
/// Grux already shows the OWNER a red dot in the menu bar for the duration, so the operator
/// always knows; nothing tells anyone else, and nobody has ever been asked to.
///
/// **This lives at the choke point on purpose.** `MeetingCaptureService.start()` is the
/// single function every path goes through: the menu bar pill, the Meetings tab, the
/// floating panel, the keyboard shortcut, and `start_meeting_capture`, which is a
/// MODEL-CALLABLE tool. A gate placed at the five call sites instead would be five chances
/// to miss one, and the sixth caller written next month would miss it for free.
///
/// It is an `NSAlert` rather than a SwiftUI sheet, and that is the bulletproofing. Grux is a
/// menu-bar app: a recording can be started with no window on screen at all, and a sheet
/// needs a window to attach to. An alert works from every entry point in every window state,
/// including the one where the assistant decided to start recording while the user was in
/// another app entirely.
@MainActor
enum RecordingConsent {

    /// Shown once, then remembered. Deliberately plain: it names what happens, who it
    /// affects, and what the reader is agreeing to do, with no reassurance padding.
    static let title = "Recording captures everyone on the call"
    static let body = """
        Grux records all sides of the call, transcribes it on your Mac, and keeps it locally. \
        The other people on the call are recorded too, and Grux has no way to tell them.

        In some places you are required to say so first. Confirm you will, and Grux will not \
        ask again.
        """
    static let confirmTitle = "I will tell them"
    static let cancelTitle = "Not now"

    /// True when recording may proceed. Prompts once if it has not been answered.
    ///
    /// Returns false when the user declines, which the caller must treat as "do not record"
    /// rather than as an error: declining is a legitimate answer, not a failure.
    /// Injectable so the gate can be driven in a test without a modal.
    ///
    /// Added after the same seam went into `MicConsent`. Every test in this file
    /// was a source-text sweep: they proved the gate is CALLED from the choke
    /// point and that the copy reads well, and not one of them ever established
    /// whether declining actually stops a recording. For the one gate in this
    /// app with legal weight, "the call site looks right" is the weaker half of
    /// the question.
    static var presenter: () -> Bool = { presentPrompt() }

    static func ensureAcknowledged() async -> Bool {
        if AppState.shared.config.recordingConsentAcknowledged { return true }
        // Deliberately not cached in memory. If the user declines, the next attempt asks
        // again, because a decline is about this moment and not a permanent preference.
        let accepted = presenter()
        if accepted {
            // THROUGH THE ONE WRITER, which sets the same config flag, saves, and rewrites
            // setup-status.json. Setting the flag here directly left that snapshot saying
            // the consent was still outstanding, and the snapshot is the only thing the CLI
            // can read: `grux meeting start` refused with exit 2 and sent somebody to go and
            // answer a dialog they had answered a second earlier, which the check above
            // guarantees they will never be shown again. Nothing rewrote the file until the
            // next launch or an unrelated status write, and this is a menu-bar app that runs
            // for weeks.
            CapabilityResolver.markStepCompleted(.stepRecordingConsentAcknowledged, true)
            WakeLog.shared.log("meeting: recording consent acknowledged")
        } else {
            WakeLog.shared.log("meeting: recording consent declined, capture not started")
        }
        return accepted
    }

    /// Split out so a test can exercise the decision without an alert, and so the alert
    /// itself is one place rather than one per entry point.
    static func presentPrompt() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: confirmTitle)   // .alertFirstButtonReturn
        alert.addButton(withTitle: cancelTitle)
        // AppKit wires Escape to a button titled exactly "Cancel". This one says
        // "Not now", so without this the dialog could not be dismissed from the
        // keyboard at all. It can be raised by a MODEL-CALLABLE tool while the
        // user is in another app, which makes a keyboard escape the difference
        // between a prompt and a trap.
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        // The app can be in the background when the assistant calls the tool, and an alert
        // behind another window is an alert nobody answers.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Settings needs to be able to put this back, or the one-time answer is a trap: a user
    /// who clicks through it can never see what they agreed to again.
    static func reset() {
        // The same one writer, for the same reason and against a worse failure. Clearing
        // only the config left setup-status.json still saying the consent was given, so
        // `grux meeting start --yes` passed its own gate from a script or a cron job, sent
        // the start over the socket, and landed on the modal below with nobody there to
        // click it. The CLI held its 120 second deadline, printed that Grux was probably
        // busy starting up, and left the dialog standing on the Mac. Both callers reach
        // here without a terminal involved: Settings > "Ask me again", and grux reset
        // consent through the control socket.
        CapabilityResolver.markStepCompleted(.stepRecordingConsentAcknowledged, false)
        WakeLog.shared.log("meeting: recording consent reset")
    }
}
