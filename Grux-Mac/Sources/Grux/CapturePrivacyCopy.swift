import Foundation

/// The lead line of Settings, Privacy and capture. It said "Grux photographs
/// your screen on a timer" as a present fact while Screen Recording was not
/// allowed and nothing was captured (D168), then while Focus log skipped every
/// tick or the pane's unsaved toggle disagreed with the saved one (W56-FIX).
/// It reads what the watcher really does: the saved setting, whether it runs,
/// and the reason its last tick took no frame.
enum CapturePrivacyCopy {
    static func lead(analysisOn: Bool, watching: Bool, skip: FocusWatcher.Skip?, permitted: Bool) -> String {
        let does = "photographs your screen on a timer and sends the frame to a vision model"
        // `read_screen` takes a frame whenever macOS allows it, whatever the timer does.
        let ask = permitted ? " Asking Grux to look at your screen sends one frame each time." : ""
        if permitted && analysisOn && watching && skip == nil {
            return "Grux \(does).\(ask) " + lists
        }
        let why: String
        if !permitted { why = FocusWatcher.Skip.noScreenAccess.line }
        else if !analysisOn { why = FocusWatcher.Skip.screenAnalysisOff.line }
        else if !watching { why = "Focus is paused." }
        else { why = skip?.line ?? "" }
        return "While Focus log runs, Grux \(does). It takes no frame now: \(why)\(ask) " + lists
    }

    static let lists = "These are the things it refuses to look at. Excluded windows are removed before the frame is composited, so their pixels are never captured, even when the app is not in front."
}
