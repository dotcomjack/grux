import Foundation

/// Appearance's "Animate window edges red/green when I drift or re-focus" read
/// on while screen analysis never ran (D197 item 9). The red and green edges come
/// only from screen analysis verdicts (`FocusWatcher.handleTransition`), so the
/// switch reads off and greyed until analysis runs, the choice kept for then.
enum DriftGlowToggleTruth {
    static func usable(analysisOn: Bool, granted: Bool) -> Bool {
        AutoPromoteToggleTruth.usable(analysisOn: analysisOn, granted: granted)
    }

    static func shown(choice: Bool, analysisOn: Bool, granted: Bool) -> Bool {
        choice && usable(analysisOn: analysisOn, granted: granted)
    }

    static func line(analysisOn: Bool, granted: Bool) -> String? {
        guard !usable(analysisOn: analysisOn, granted: granted) else { return nil }
        let lead = "The red and green edges follow what screen analysis sees, so they are off until you"
        switch (analysisOn, granted) {
        case (false, true):
            return lead + " turn on screen analysis in Settings, General."
        case (true, false):
            return lead + " allow Screen Recording for Grux; Settings, General has the button."
        default:
            // The screen analysis switch is greyed until Screen Recording is allowed.
            return lead + " allow Screen Recording for Grux and then turn on screen analysis, both in Settings, General."
        }
    }
}
