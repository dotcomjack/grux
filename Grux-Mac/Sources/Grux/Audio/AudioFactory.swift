import AVFoundation

/// Every AVAudioEngine Grux builds comes from here, so a test can count them.
///
/// An engine wired to a device is an AUHAL I/O context, and on a clean Mac
/// merely building one at launch made coreaudiod ask for the microphone
/// (W4 build 10, 2026-10-13). Engines are built on first use: the speech
/// graph on the first thing that plays, the listeners and dictation when they
/// start. `CleanMacFirstRunTests` fails if launch or first paint builds one.
@MainActor
enum AudioFactory {
    /// How many engines have been built, for tests.
    private(set) static var enginesBuilt = 0
    /// The last purpose asked for, for a test's failure message.
    private(set) static var lastPurpose = ""

    /// For tests: what builds the engine.
    static var makeEngine: () -> AVAudioEngine = { AVAudioEngine() }

    static func engine(_ purpose: String) -> AVAudioEngine {
        enginesBuilt += 1
        lastPurpose = purpose
        return makeEngine()
    }
}
