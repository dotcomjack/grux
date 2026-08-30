import XCTest
@testable import Grux

// End-to-end playability gate: produce a real WAV on disk at a known path,
// then the outer test harness runs `afinfo` on it to confirm macOS CoreAudio
// parses it as a 16 kHz mono 16-bit PCM file. Complements WAVWriterTests
// (which validates the header bytes we wrote) with external-tool validation
// (which proves a fresh CoreAudio decoder accepts the file).
//
// Path is deterministic so the shell step can find it without scraping stdout.
final class WAVPlayabilityTest: XCTestCase {

    static let emitPath = "/tmp/grux-wav-playability.wav"

    func test_emitPlayableWAV() throws {
        let url = URL(fileURLWithPath: Self.emitPath)
        try? FileManager.default.removeItem(at: url)

        // 2 seconds of a 440 Hz tone.
        let sr: Double = 16_000
        let n = Int(2.0 * sr)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = Float(sin(2 * .pi * 440.0 * Double(i) / sr)) * 0.6
        }
        try WAVWriter.write(samples: samples, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Sanity-check minimum size on our side too.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(size, 44 + n * 2, "file size matches header + PCM samples")
    }
}
