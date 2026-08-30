import Foundation
import Accelerate

// Float32 16 kHz mono mixer + fixed-length chunker.
//
// Both MeetingMicCapture and SystemAudioCapture push already-downmixed,
// already-resampled 16 kHz mono Float32 samples. The mixer keeps separate
// ring buffers per source, then on each chunk-flush sums them sample-by-sample
// (clipped to [-1, 1]) and emits a single mono [Float] chunk.
//
// We chose summing over averaging deliberately - averaging halves overlapping
// speech (the user + counterparty talking at once both come out as quiet). Summing
// keeps both audible; clipping only matters on actual volume peaks.
//
// Emission is driven by wall-clock via `flushIfDue(now:)` called from a timer
// on the orchestrator. Chunks are `chunkSeconds` long (default 10s). Late or
// missing audio from one source just gets zeros on the missing side.
final class MeetingAudioMixer {
    static let sampleRate: Double = 16_000

    private let chunkSeconds: Double
    private let samplesPerChunk: Int

    private var micBuffer: [Float] = []
    private var sysBuffer: [Float] = []
    private let lock = NSLock()

    var onMixedChunk: (([Float]) -> Void)?
    // Mic-only copy of the same chunk, emitted BEFORE onMixedChunk for the
    // same time window. Consumed by SpeakerDiarizer so clustering only sees
    // voices physically in the room (remote participants arrive through the
    // system audio path and already get speaker=.them). Unused when nil.
    var onMicChunk: (([Float]) -> Void)?

    init(chunkSeconds: Double = 10.0) {
        self.chunkSeconds = chunkSeconds
        self.samplesPerChunk = Int(Self.sampleRate * chunkSeconds)
    }

    func appendMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        micBuffer.append(contentsOf: samples)
    }

    func appendSystem(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        sysBuffer.append(contentsOf: samples)
    }

    // Flush complete chunks. Emits once per `chunkSeconds` of aligned audio.
    // If one source is ahead and the other starved, the shorter side gets
    // zero-padded up to `samplesPerChunk` so we still emit on time.
    func flushReadyChunks() {
        while let pair = takeNextChunkPair() {
            onMicChunk?(pair.mic)
            onMixedChunk?(pair.mixed)
        }
    }

    // Flush remaining audio even if partial. Call on stop.
    func flushFinalChunk() {
        lock.lock()
        let micLen = micBuffer.count
        let sysLen = sysBuffer.count
        let len = max(micLen, sysLen)
        guard len > 0 else { lock.unlock(); return }
        var mic = micBuffer
        var sys = sysBuffer
        micBuffer.removeAll(keepingCapacity: false)
        sysBuffer.removeAll(keepingCapacity: false)
        lock.unlock()
        padTo(&mic, length: len)
        padTo(&sys, length: len)
        let summed = Self.sumAndClip(mic, sys)
        if summed.count >= Int(Self.sampleRate * 0.4) {   // ignore <0.4s stragglers
            onMicChunk?(mic)
            onMixedChunk?(summed)
        }
    }

    func reset() {
        lock.lock()
        micBuffer.removeAll(keepingCapacity: false)
        sysBuffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func takeNextChunkPair() -> (mic: [Float], mixed: [Float])? {
        lock.lock(); defer { lock.unlock() }
        let available = min(micBuffer.count, sysBuffer.count)
        guard available >= samplesPerChunk else {
            // Desynced case: if one side has enough but the other is empty,
            // emit anyway (one participant is silent).
            if micBuffer.count >= samplesPerChunk && sysBuffer.count == 0 {
                let mic = Array(micBuffer.prefix(samplesPerChunk))
                micBuffer.removeFirst(samplesPerChunk)
                let mixed = Self.sumAndClip(mic, Array(repeating: 0, count: samplesPerChunk))
                return (mic, mixed)
            }
            if sysBuffer.count >= samplesPerChunk && micBuffer.count == 0 {
                let sys = Array(sysBuffer.prefix(samplesPerChunk))
                sysBuffer.removeFirst(samplesPerChunk)
                let mixed = Self.sumAndClip(Array(repeating: 0, count: samplesPerChunk), sys)
                return (Array(repeating: 0, count: samplesPerChunk), mixed)
            }
            return nil
        }
        let mic = Array(micBuffer.prefix(samplesPerChunk))
        let sys = Array(sysBuffer.prefix(samplesPerChunk))
        micBuffer.removeFirst(samplesPerChunk)
        sysBuffer.removeFirst(samplesPerChunk)
        return (mic, Self.sumAndClip(mic, sys))
    }

    private func padTo(_ arr: inout [Float], length: Int) {
        if arr.count < length {
            arr.append(contentsOf: Array(repeating: 0, count: length - arr.count))
        }
    }

    // vDSP sum + hard clip to [-1, 1]. Faster than element-wise Swift.
    static func sumAndClip(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == b.count, "sumAndClip: length mismatch \(a.count) vs \(b.count)")
        var out = [Float](repeating: 0, count: a.count)
        vDSP_vadd(a, 1, b, 1, &out, 1, vDSP_Length(a.count))
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(out, 1, &lo, &hi, &out, 1, vDSP_Length(out.count))
        return out
    }
}
