import XCTest

/// Every listening engine is built AFTER its microphone is chosen.
///
/// Measured 2026-09-21 on the running app, AirPods Max as the output: ambient
/// built its `AVAudioEngine` and touched `inputNode` before the listening guard
/// moved the default input off the AirPods. With voice processing on, that was
/// hidden, because voice processing rebuilds its own pairing of the current
/// defaults. P-R-9 turned voice processing off for headphones and exposed it:
/// the engine kept the AirPods' microphone (24 kHz, the Bluetooth call
/// profile, the exact quality loss P-R-9 set out to fix) and ambient heard
/// nothing, `buf=0.0s rms=0.0000` on every tick.
final class CaptureEngineOrderTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/" + rel), encoding: .utf8)
    }

    private func offset(of needle: String, in hay: String, file: String) throws -> Int {
        let r = try XCTUnwrap(hay.range(of: needle), "\(file) no longer contains `\(needle)`")
        return hay.distance(from: hay.startIndex, to: r.lowerBound)
    }

    func test_ambientBuildsItsEngineAfterTheGuardMovesTheMic() throws {
        let src = try source("Ambient/AmbientListener.swift")
        let body = try XCTUnwrap(src.components(separatedBy: "private func startEngine(deafAttempt: Int = 0) throws {").dropFirst().first)
        let claim = try offset(of: "ListeningMicGuard.shared.claim(\"ambient\")", in: body, file: "AmbientListener")
        let preferred = try offset(of: "MicWhitelist.applyPreferredInputIfPossible()", in: body, file: "AmbientListener")
        let engine = try offset(of: "let engine = AVAudioEngine()", in: body, file: "AmbientListener")
        XCTAssertGreaterThan(engine, claim, "ambient builds its engine before the guard moves the mic off a headset")
        XCTAssertGreaterThan(engine, preferred, "ambient builds its engine before the preferred mic is applied")
        XCTAssertTrue(body.contains("MicDevices.bindInput(input, toUID: activeInputUID)"),
                      "without voice processing the input must be bound to the chosen mic")
        XCTAssertTrue(body.contains("MicDevices.tapFormat(for: input, bound: boundToChosenMic)"),
                      "a bound input tapped in the stale output format delivers nothing")
        XCTAssertFalse(body.contains("let nativeFormat = input.outputFormat(forBus: 0)"))
    }

    func test_dictationBuildsItsEngineAfterThePreferredMic() throws {
        let src = try source("VoiceInput.swift")
        let preferred = try offset(of: "MicWhitelist.applyPreferredInputIfPossible()", in: src, file: "VoiceInput")
        // The property initializer `private var audioEngine = AVAudioEngine()`
        // is not a build of the session's engine; the rebuild is its own line.
        let engine = try offset(of: "\n        audioEngine = AVAudioEngine()", in: src, file: "VoiceInput")
        XCTAssertGreaterThan(engine, preferred, "dictation builds its engine before the preferred mic is applied")
        XCTAssertTrue(src.contains("MicDevices.bindInput(input, toUID: activeInputUID)"))
        XCTAssertTrue(src.contains("MicDevices.tapFormat(for: input, bound: boundToChosenMic)"),
                      "a bound input tapped in the stale output format delivers nothing")
    }

    /// Already right, and pinned so it stays right.
    func test_wakeWordBuildsItsEngineAfterTheGuard() throws {
        let src = try source("WakeWord.swift")
        let claim = try offset(of: "ListeningMicGuard.shared.claim(\"wake\")", in: src, file: "WakeWord")
        let engine = try offset(of: "let engine = AVAudioEngine()", in: src, file: "WakeWord")
        XCTAssertGreaterThan(engine, claim)
    }
}
