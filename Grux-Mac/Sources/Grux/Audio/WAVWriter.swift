import Foundation

// Minimal streaming WAV encoder. Mono Int16 PCM (fmt=1). Designed for 16 kHz
// Float32 input from WhisperKit's pipeline - we clip to [-1, 1] and convert
// to signed 16-bit on the way out so the resulting file opens in QuickTime,
// Audacity, Voice Memos, iMessage, and anything else that hasn't been updated
// since 1991. Written as a free function + a stream writer so callers can
// either one-shot a buffer to disk OR append chunks as they arrive.
//
// Why not Float32 WAV? Max compat. A 16 kHz mono Int16 file is ~1.9 MB/min -
// small enough that 15 min of ambient audio is ~28 MB, and an hour of meeting
// audio is ~110 MB. No need to complicate with floats or Opus.
enum WAVWriter {

    static let sampleRate: UInt32 = 16_000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    // One-shot: write a whole [Float] buffer to a .wav at `url`. Creates
    // intermediate dirs. Throws on IO failure.
    static func write(samples: [Float], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }

        let pcm = floatsToInt16(samples)
        var data = Data()
        data.append(wavHeader(dataByteCount: UInt32(pcm.count * 2)))
        pcm.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        try data.write(to: url, options: .atomic)
    }

    // Streaming writer: open a file, append chunks, close. Keeps an open
    // FileHandle with a placeholder header; `close()` rewinds and rewrites the
    // RIFF/data sizes so the file is playable even if the app dies mid-append
    // (you'll lose the in-flight chunk, not the whole session).
    final class Stream {
        private let url: URL
        private var handle: FileHandle?
        private var totalSampleCount: Int = 0
        private let lock = NSLock()

        init(url: URL) throws {
            self.url = url
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            fm.createFile(atPath: url.path, contents: nil, attributes: nil)
            let h = try FileHandle(forWritingTo: url)
            // Write placeholder header; we'll rewrite sizes on close().
            try h.write(contentsOf: WAVWriter.wavHeader(dataByteCount: 0))
            self.handle = h
        }

        func append(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            guard let h = handle else { return }
            let pcm = WAVWriter.floatsToInt16(samples)
            pcm.withUnsafeBufferPointer { buf in
                let data = Data(buffer: buf)
                do {
                    try h.write(contentsOf: data)
                    totalSampleCount += samples.count
                } catch {
                    WakeLog.shared.log("wav-stream: append failed: \(error.localizedDescription)")
                }
            }
        }

        // Close the stream and fix up RIFF + data chunk sizes. Idempotent.
        @discardableResult
        func close() -> URL? {
            lock.lock(); defer { lock.unlock() }
            guard let h = handle else { return url }
            handle = nil
            do {
                try h.synchronize()
                let dataByteCount = UInt32(totalSampleCount * 2)
                let header = WAVWriter.wavHeader(dataByteCount: dataByteCount)
                try h.seek(toOffset: 0)
                try h.write(contentsOf: header)
                try h.close()
                return url
            } catch {
                WakeLog.shared.log("wav-stream: close failed: \(error.localizedDescription)")
                try? h.close()
                return url
            }
        }

        var sampleCount: Int { totalSampleCount }
        var durationSeconds: Double { Double(totalSampleCount) / Double(WAVWriter.sampleRate) }
    }

    // MARK: - Internals

    static func floatsToInt16(_ samples: [Float]) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples.count)
        let scale: Float = 32767.0
        for i in 0..<samples.count {
            let s = max(-1.0, min(1.0, samples[i]))
            out[i] = Int16(s * scale)
        }
        return out
    }

    static func wavHeader(dataByteCount: UInt32) -> Data {
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let fmtChunkSize: UInt32 = 16          // PCM
        let riffChunkSize: UInt32 = 4 + (8 + fmtChunkSize) + (8 + dataByteCount)

        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        d.appendLE(riffChunkSize)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.appendLE(fmtChunkSize)
        d.appendLE(UInt16(1))                  // audio format = PCM
        d.appendLE(channels)
        d.appendLE(sampleRate)
        d.appendLE(byteRate)
        d.appendLE(blockAlign)
        d.appendLE(bitsPerSample)
        d.append(contentsOf: "data".utf8)
        d.appendLE(dataByteCount)
        return d
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
