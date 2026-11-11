import Foundation

/// Settings, General's "Auto-promote detected task to NOW" read on while screen
/// analysis was off or macOS had not allowed Screen Recording (D187 item 1).
/// Auto-promote acts only on what screen analysis sees (`FocusWatcher`), so it
/// reads off and greyed until analysis runs, the choice kept for then.
enum AutoPromoteToggleTruth {
    static func usable(analysisOn: Bool, granted: Bool) -> Bool {
        analysisOn && granted
    }

    static func shown(choice: Bool, analysisOn: Bool, granted: Bool) -> Bool {
        choice && usable(analysisOn: analysisOn, granted: granted)
    }

    static func line(analysisOn: Bool, granted: Bool) -> String? {
        guard !usable(analysisOn: analysisOn, granted: granted) else { return nil }
        return "Auto-promote works from what screen analysis sees, so it is off until screen analysis is on."
    }
}
