import Foundation

/// Where every Whisper model Grux loads lives on disk.
///
/// WhisperKit's default is `~/Documents/huggingface`. Measured 2026-09-27 on the loop
/// Mini: `grux transcribe` said "could not load the speech model" with the models sitting
/// right there, because `wake.log` read `invalidMetadataError("Could not remove corrupted
/// metadata file: config.json.metadata couldn't be removed because you don't have
/// permission")`. Documents is a folder macOS guards per app (a consent prompt, or a flat
/// refusal once declined), and with iCloud Desktop and Documents on it is also a folder
/// macOS empties to placeholders ("Resource deadlock avoided" on every `.mlmodelc`). A
/// speech model that dictation, meeting capture and the corpus all need cannot sit behind
/// either. Application Support is Grux's own, never prompts, and is not synced.
///
/// Every `WhisperKitConfig` passes this (`WhisperModelStoreTests` scans for it), so no
/// new loader can fall back to Documents by leaving the argument out.
enum WhisperModelStore {
    static var downloadBase: URL {
        let dir = Persistence.supportDir.appendingPathComponent("whisper-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether a loader may fetch a missing model. Never under test: the suite's
    /// `supportDir` is a fresh sandbox, so any test that wakes `VoiceInput.shared` would
    /// download 1.5 to 2.5 GB into it on every run (measured 2026-09-27: 24 runs filled
    /// the disk). A missing model then fails the load, which is what a test should see.
    static var mayDownload: Bool { !Persistence.isUnderTest }
}
