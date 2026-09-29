import XCTest
@testable import Grux

/// Dictation's Whisper model loads at launch only on a Mac that can dictate.
///
/// Measured 2026-09-27 on a Mac mini where Grux had no microphone it could use:
/// opening Chat woke `VoiceInput.shared`, whose init loaded large-v3-turbo, about
/// 87 s of ANECompilerService at 100% CPU on every launch, and the first panes
/// opened in that window rendered after 8 to 21 s. Nothing there could be dictated.
/// Without an input device and granted access the load waits for the first
/// dictation, which already asks for access and loads a missing model first.
@MainActor
final class VoiceInputPrewarmTests: XCTestCase {

    func test_cannotDictate_doesNotLoadWhisperAtInit() async {
        let voice = VoiceInput(canDictate: { false })
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(voice.whisperLoadRequested, "no usable microphone, so nothing to prewarm for")
        XCTAssertFalse(voice.whisperReady)
        XCTAssertTrue(voice.whisperStatus.contains("first dictation"), voice.whisperStatus)
    }

    /// The prewarm is a stub here: a real Whisper load (minutes of Neural Engine
    /// compile) started by a test outlived it and ran under every class after.
    func test_canDictate_loadsWhisperAtInit() async {
        final class Count { var n = 0 }
        let prewarms = Count()
        let voice = VoiceInput(canDictate: { true }, prewarm: { _ in prewarms.n += 1 })
        let deadline = Date().addingTimeInterval(5)
        while prewarms.n == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(prewarms.n, 1, "a Mac that can dictate keeps the launch prewarm")
        XCTAssertFalse(voice.whisperLoadRequested, "the stub ran, not the real load")
    }
}
