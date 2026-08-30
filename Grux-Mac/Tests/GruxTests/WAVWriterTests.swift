import XCTest
@testable import Grux

// End-to-end coverage for the WAV export pipeline.
// Validates:
//   1. WAVWriter one-shot emits a valid RIFF/WAVE file (header + PCM data).
//   2. WAVWriter.Stream fixes up sizes on close, producing a playable file
//      with sample count equal to the sum of appended chunks.
//   3. AmbientAudioRing retains the newest N seconds and returns them
//      chronologically via snapshotLast.
//   4. AudioExportStore.exportAmbientTail writes under exportsDir and
//      names files with the expected shape.
//
// No AppKit, no mic hardware, we synthesize PCM in-process.
final class WAVWriterTests: XCTestCase {

    private func sine(seconds: Double, hz: Float = 440, sr: Double = 16_000) -> [Float] {
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Float(sin(2 * .pi * Double(hz) * Double(i) / sr)) * 0.5
        }
        return out
    }

    // MARK: WAV header round-trip

    func test_oneshot_writesValidWAVHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = sine(seconds: 0.5)
        try WAVWriter.write(samples: samples, to: url)

        let data = try Data(contentsOf: url)
        // Expect 44-byte standard PCM header + (samples * 2) bytes of data.
        let expectedDataBytes = samples.count * 2
        XCTAssertEqual(data.count, 44 + expectedDataBytes, "file size must be header (44) + pcm")

        // RIFF/WAVE magic
        XCTAssertEqual(data[0..<4], Data("RIFF".utf8))
        XCTAssertEqual(data[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(data[12..<16], Data("fmt ".utf8))
        XCTAssertEqual(data[36..<40], Data("data".utf8))

        // Format = 1 (PCM), channels = 1, sample rate = 16 kHz, bits = 16.
        XCTAssertEqual(readLE16(data, at: 20), 1, "fmt = PCM")
        XCTAssertEqual(readLE16(data, at: 22), 1, "channels = mono")
        XCTAssertEqual(readLE32(data, at: 24), 16_000, "sampleRate = 16000")
        XCTAssertEqual(readLE16(data, at: 34), 16, "bitsPerSample = 16")

        // data chunk size = sample_count * 2
        XCTAssertEqual(Int(readLE32(data, at: 40)), expectedDataBytes, "data chunk size")
    }

    // MARK: Streaming writer

    func test_stream_appendsAndFinalizesCorrectSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavstream-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = [sine(seconds: 0.2), sine(seconds: 0.3, hz: 880), sine(seconds: 0.5, hz: 220)]
        let stream = try WAVWriter.Stream(url: url)
        for c in chunks { stream.append(c) }
        let closed = stream.close()
        XCTAssertEqual(closed, url)

        let data = try Data(contentsOf: url)
        let totalSamples = chunks.reduce(0) { $0 + $1.count }
        XCTAssertEqual(data.count, 44 + totalSamples * 2)
        XCTAssertEqual(Int(readLE32(data, at: 40)), totalSamples * 2)
        XCTAssertEqual(readLE32(data, at: 24), 16_000)
        // RIFF chunk size = file size - 8
        XCTAssertEqual(Int(readLE32(data, at: 4)), data.count - 8)
    }

    func test_floatsToInt16_clipsAndScales() {
        let input: [Float] = [0.0, 1.0, -1.0, 2.0, -2.0, 0.5, -0.5]
        let out = WAVWriter.floatsToInt16(input)
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[1], Int16(Float(1.0) * 32767.0))
        XCTAssertEqual(out[2], Int16(Float(-1.0) * 32767.0))
        // 2.0 should clip to 1.0
        XCTAssertEqual(out[3], out[1], "positive overdrive clips")
        XCTAssertEqual(out[4], out[2], "negative overdrive clips")
        XCTAssertEqual(out[5], Int16(Float(0.5) * 32767.0))
        XCTAssertEqual(out[6], Int16(Float(-0.5) * 32767.0))
    }

    // MARK: AmbientAudioRing

    func test_ring_retainsAndSnapshotsNewestSeconds() {
        // Fresh window so any prior session state doesn't leak in.
        AmbientAudioRing.shared.setMaxSeconds(30)
        AmbientAudioRing.shared.clear()

        // Push 35 seconds of data at 16 kHz; only last 30 survive.
        let oneSec = sine(seconds: 1.0)
        for _ in 0..<35 {
            oneSec.withUnsafeBufferPointer { buf in
                AmbientAudioRing.shared.append(buf.baseAddress!, count: buf.count)
            }
        }
        let avail = AmbientAudioRing.shared.availableSeconds
        XCTAssertEqual(avail, 30.0, accuracy: 0.05, "ring clamps to max window")

        let last5 = AmbientAudioRing.shared.snapshotLast(seconds: 5.0)
        XCTAssertEqual(last5.count, 5 * 16_000)
        let last50 = AmbientAudioRing.shared.snapshotLast(seconds: 50.0)
        XCTAssertEqual(last50.count, 30 * 16_000, "can't get more than available")
    }

    // MARK: AudioExportStore end-to-end

    func test_exportStore_exportAmbientTail_writesFile() throws {
        AmbientAudioRing.shared.setMaxSeconds(30)
        AmbientAudioRing.shared.clear()

        let oneSec = sine(seconds: 1.0)
        for _ in 0..<3 {
            oneSec.withUnsafeBufferPointer { buf in
                AmbientAudioRing.shared.append(buf.baseAddress!, count: buf.count)
            }
        }

        let url = AudioExportStore.exportAmbientTail(seconds: 3.0)
        XCTAssertNotNil(url, "expected a URL back when ring has audio")
        guard let url else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertTrue(url.path.contains("audio-exports"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data[0..<4], Data("RIFF".utf8))
        XCTAssertEqual(data[8..<12], Data("WAVE".utf8))
        let expected = 44 + 3 * 16_000 * 2
        XCTAssertEqual(data.count, expected, "expected 3-second 16-bit mono 16 kHz WAV")
    }

    func test_exportStore_emptyRing_returnsNil() {
        AmbientAudioRing.shared.clear()
        XCTAssertNil(AudioExportStore.exportAmbientTail(seconds: 10.0))
    }

    // MARK: - Helpers

    private func readLE16(_ d: Data, at offset: Int) -> UInt16 {
        UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8)
    }
    private func readLE32(_ d: Data, at offset: Int) -> UInt32 {
        UInt32(d[offset])
            | (UInt32(d[offset + 1]) << 8)
            | (UInt32(d[offset + 2]) << 16)
            | (UInt32(d[offset + 3]) << 24)
    }
}
