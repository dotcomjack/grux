import Foundation

// In-memory rolling ring buffer of raw Float32 16 kHz mono PCM for Ambient.
//
// Why it exists: Grux Ambient already has a small `AmbientAudioBuffer` that
// drains every time Whisper transcribes - useful for chunking, useless for
// "save the last 15 minutes to a WAV". This buffer runs in parallel: the
// AmbientListener mic tap feeds both buffers, and this one retains up to
// `maxSeconds` of history so the user can reach back and export any tail
// window - trust signal for a local-first app ("your audio never left the
// machine, and you can prove it with a button").
//
// Memory footprint: 16 kHz × 4 bytes × 900 s = ~55 MB for a 15-min window.
// Capped in-memory; nothing persists between launches unless the user
// explicitly exports.
//
// All public API is thread-safe via a single NSLock. The mic-tap callback
// runs off-main, the UI snapshot runs on-main; both route through this lock.
final class AmbientAudioRing: @unchecked Sendable {
    static let shared = AmbientAudioRing()

    // Default ceiling. Exported WAV duration is always min(ringWindow, requested).
    static let defaultMaxSeconds: Int = 900   // 15 min
    static let sampleRate: Int = 16_000

    private let lock = NSLock()
    private var storage: [Float]
    private var capacitySamples: Int
    private var writeIndex: Int = 0
    private var filledSamples: Int = 0
    private var enabled: Bool = true
    private var lastAppend: Date = .distantPast

    private init(maxSeconds: Int = AmbientAudioRing.defaultMaxSeconds) {
        let cap = maxSeconds * Self.sampleRate
        self.capacitySamples = cap
        self.storage = [Float](repeating: 0, count: cap)
    }

    var windowSeconds: Int {
        lock.lock(); defer { lock.unlock() }
        return capacitySamples / Self.sampleRate
    }

    var hasAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return filledSamples > 0
    }

    var availableSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(filledSamples) / Double(Self.sampleRate)
    }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    var lastAppendAt: Date {
        lock.lock(); defer { lock.unlock() }
        return lastAppend
    }

    func setMaxSeconds(_ seconds: Int) {
        let newCap = max(Self.sampleRate * 10, seconds * Self.sampleRate)   // min 10s
        lock.lock(); defer { lock.unlock() }
        guard newCap != capacitySamples else { return }
        let preserved = readLastLocked(maxSamples: min(filledSamples, newCap))
        storage = [Float](repeating: 0, count: newCap)
        capacitySamples = newCap
        writeIndex = 0
        filledSamples = 0
        writeLocked(preserved)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        writeIndex = 0
        filledSamples = 0
        lastAppend = .distantPast
    }

    func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = on
        if !on {
            writeIndex = 0
            filledSamples = 0
        }
    }

    // Called from the AmbientListener mic-tap callback. Thread-safe.
    func append(_ ptr: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard enabled, capacitySamples > 0 else { return }
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let room = capacitySamples - writeIndex
            let n = min(remaining, room)
            storage.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                (base + writeIndex).update(from: ptr + offset, count: n)
            }
            writeIndex = (writeIndex + n) % capacitySamples
            filledSamples = min(capacitySamples, filledSamples + n)
            remaining -= n
            offset += n
        }
        lastAppend = Date()
    }

    // Return the newest `seconds` of audio (or all available, whichever is
    // less). Chronological order, oldest-first.
    func snapshotLast(seconds: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let want = max(0, min(filledSamples, Int(seconds * Double(Self.sampleRate))))
        return readLastLocked(maxSamples: want)
    }

    // MARK: - Private (locked)

    private func readLastLocked(maxSamples: Int) -> [Float] {
        guard maxSamples > 0, filledSamples > 0 else { return [] }
        let take = min(maxSamples, filledSamples)
        var out = [Float](repeating: 0, count: take)
        let cap = capacitySamples
        let startIdx = ((writeIndex - take) % cap + cap) % cap
        out.withUnsafeMutableBufferPointer { dst in
            storage.withUnsafeBufferPointer { src in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                if startIdx + take <= cap {
                    d.update(from: s + startIdx, count: take)
                } else {
                    let first = cap - startIdx
                    let second = take - first
                    d.update(from: s + startIdx, count: first)
                    (d + first).update(from: s, count: second)
                }
            }
        }
        return out
    }

    private func writeLocked(_ samples: [Float]) {
        let cap = capacitySamples
        guard cap > 0, !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { src in
            guard let sp = src.baseAddress else { return }
            var remaining = samples.count
            var offset = 0
            while remaining > 0 {
                let room = cap - writeIndex
                let n = min(remaining, room)
                storage.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    (base + writeIndex).update(from: sp + offset, count: n)
                }
                writeIndex = (writeIndex + n) % cap
                filledSamples = min(cap, filledSamples + n)
                remaining -= n
                offset += n
            }
        }
    }
}
