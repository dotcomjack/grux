import AVFoundation

/// Ambient's crash-safe capture caption read "replays the PCM through Whisper"
/// beside a folder path, on a Mac where nothing had been recorded (D197 item 9).
/// The same switch keeps the whole meeting's audio for Export WAV
/// (`AudioExportStore`), as well as the rolling buffer a crash is recovered
/// from, so the caption says both (wave 68 round 1). It names the delete in
/// Meetings (D198) and the button that opens the kept audio's folder (round 3). The switch stays live: a person may want it off before the first
/// meeting.
enum CrashSafeAudioCaption {
    /// The button under the caption. The folder is inside the hidden Library,
    /// which Finder search skips, so the caption names this instead (round 3).
    static let showButton = "Show kept audio in Finder"
    static func line(on: Bool, micStatus: AVAuthorizationStatus) -> String {
        let kept = "To remove kept audio, delete its meeting in Meetings; \(showButton), below, opens its folder."
        let what = on
            ? "While Grux records a meeting, it keeps the whole meeting's audio on this Mac, for Export WAV. It also saves the audio as it goes, so a crash mid-call can be recovered. Turn this off to keep the transcript and its notes without audio. " + kept
            : "Off: when Grux records a meeting, it keeps the transcript and its notes, no audio. Any audio kept earlier stays until you delete its meeting in Meetings; \(showButton), below, opens its folder."
        switch micStatus {
        case .authorized:
            return what
        case .denied, .restricted:
            return what + " Nothing is recorded now: macOS has not allowed Grux the microphone."
        default:
            return what + " Nothing is recorded yet: Grux asks for the microphone when you first record a meeting."
        }
    }
}
