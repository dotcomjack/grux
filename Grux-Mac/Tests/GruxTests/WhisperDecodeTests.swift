import XCTest
import WhisperKit
@testable import Grux

/// A clip no longer than WhisperKit's end clip is never decoded at all.
///
/// Measured 2026-09-27: `grux transcribe` of a 0.9 s recording of "open Today" came back
/// empty, and the same words with half a second of silence on either side came back as
/// "Open today.". WhisperKit stops seeking `windowClipTime` (1.0 s by default) before the
/// end of the audio to keep it from inventing words over a trailing tail, so on audio that
/// short its decode loop never runs a single window. Every Whisper call in Grux goes
/// through `WhisperDecode`, which pads such a clip with silence first.
final class WhisperDecodeTests: XCTestCase {

    private let rate = WhisperKit.sampleRate
    private let options = DecodingOptions()

    /// WhisperKit's own loop condition (`TranscribeTask`: `seek < end - windowPadding`),
    /// read off the options so the test follows the library if its default moves.
    private func decodesAWindow(_ count: Int) -> Bool {
        0 < count - Int(options.windowClipTime * Float(rate))
    }

    func test_aClipShorterThanTheEndClipIsPaddedUntilWhisperDecodesIt() {
        let speech = [Float](repeating: 0.25, count: rate * 9 / 10)   // 0.9 s, like "open Today"
        XCTAssertFalse(decodesAWindow(speech.count), "the premise: 0.9 s alone decodes nothing")

        let padded = WhisperDecode.padded(speech, options: options)
        XCTAssertTrue(decodesAWindow(padded.count), "padded to \(padded.count) samples, still not decoded")
        XCTAssertEqual(Array(padded.prefix(speech.count)), speech, "the speech itself must be untouched")
        XCTAssertTrue(padded.dropFirst(speech.count).allSatisfy { $0 == 0 }, "only silence is added")
    }

    func test_aClipAtExactlyTheEndClipIsPaddedToo() {
        let speech = [Float](repeating: 0.25, count: Int(options.windowClipTime * Float(rate)))
        XCTAssertTrue(decodesAWindow(WhisperDecode.padded(speech, options: options).count))
    }

    func test_aClipLongEnoughAlreadyIsLeftAlone() {
        let speech = [Float](repeating: 0.25, count: rate * 3)
        XCTAssertEqual(WhisperDecode.padded(speech, options: options), speech)
    }

    /// Nothing in, nothing out: silence padded onto nothing is where Whisper invents
    /// "Thanks for watching."
    func test_emptyAudioStaysEmpty() {
        XCTAssertEqual(WhisperDecode.padded([], options: options), [])
    }

    /// A custom end clip is honored, not the default assumed.
    func test_theOptionsEndClipIsTheOneHonored() {
        var longer = DecodingOptions()
        longer.windowClipTime = 2.5
        let speech = [Float](repeating: 0.25, count: rate * 2)
        let padded = WhisperDecode.padded(speech, options: longer)
        XCTAssertGreaterThan(padded.count, Int(2.5 * Float(rate)))
    }

    /// The class of bug, closed: a new Whisper call that skips the padding fails here.
    func test_onlyWhisperDecodeCallsWhisperKitTranscribe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            guard rel != "Sources/Grux/Voice/WhisperDecode.swift" else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.range(of: #"\.transcribe\(\s*audioArray:"#, options: .regularExpression) != nil {
                    offenders.append("\(rel):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 500, "the scan found almost no source, so it proves nothing")
        XCTAssertEqual(offenders, [], "call WhisperDecode.transcribe so a short clip is not dropped")
    }
}
