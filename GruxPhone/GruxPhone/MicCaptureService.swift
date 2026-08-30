import Foundation
import AVFoundation
import Combine

// Captures the iPhone mic, converts to 16 kHz mono Int16 PCM, and emits
// 10 ms frames (160 samples = 320 B each) on `framesPublisher`. Matches the
// wire format consumed by the Mac receiver.
//
// Uses AVAudioEngine with a tap on the input node at the hardware's native
// format, then converts through an AVAudioConverter. Converter handles the
// sample-rate change + channel down-mix, so the mic can stay at whatever
// rate iOS picks (typically 44.1k / 48k).
//
// Frames are published on the main queue at ~100 fps. That's cheap for
// SwiftUI (it coalesces updates between runloop ticks).
//
// TEST HOOK: if UserDefaults has `UseSyntheticAudio = true` we bypass the
// mic entirely and emit a 440 Hz sine so simulator/CI runs can exercise the
// full pipeline without depending on host-mic permission dialogs.
final class MicCaptureService: ObservableObject {
    static let shared = MicCaptureService()

    @Published var isRunning: Bool = false
    @Published var levelRMS: Float = 0.0
    @Published var framesEmittedThisSession: Int = 0

    // Emits fully-formed AudioFramePayloads ready to encode + send.
    let framesPublisher = PassthroughSubject<AudioFramePayload, Never>()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var sequence: UInt32 = 0

    // Output format: 16 kHz, mono, Int16 interleaved little-endian.
    private let targetFormat: AVAudioFormat = {
        var desc = AudioStreamBasicDescription(
            mSampleRate: Double(PhoneWire.micSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &desc)!
    }()

    private init() {}

    func start() throws {
        if UserDefaults.standard.bool(forKey: "UseSyntheticAudio") {
            startSyntheticTone()
            return
        }
        guard !engine.isRunning else { return }
        // Ask for mic permission on-demand. Callers pre-request to dodge the
        // "tap button → nothing happens because no permission" path.
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        converterInputFormat = inputFormat
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        // Tap buffer size ≈ 10 ms worth of SOURCE samples (not target). Keeps
        // the per-tap cost bounded and aligns well with the output frame rate.
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.02)  // 20 ms in
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buf, _ in
            self?.ingest(buffer: buf)
        }

        engine.prepare()
        try engine.start()
        DispatchQueue.main.async {
            self.isRunning = true
            self.framesEmittedThisSession = 0
            self.sequence = 0
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        stopSyntheticTone()
        DispatchQueue.main.async {
            self.isRunning = false
            self.levelRMS = 0.0
        }
    }

    // Keeps the RMS dB indicator drawable. Input is the raw mic buffer.
    private func updateLevel(_ buf: AVAudioPCMBuffer) {
        guard let floatBuf = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n {
            let s = floatBuf[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(n))
        DispatchQueue.main.async {
            self.levelRMS = rms
        }
    }

    private func ingest(buffer: AVAudioPCMBuffer) {
        updateLevel(buffer)
        guard let converter, let converterInputFormat else { return }

        // Output capacity: targetFormat samples that could come out of this
        // input buffer, plus slack for the resampler's internal state.
        let outCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / converterInputFormat.sampleRate * 1.5 + 16
        )
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        var inputConsumed = false
        let status = converter.convert(to: outBuf, error: nil) { _, inputStatus in
            if !inputConsumed {
                inputConsumed = true
                inputStatus.pointee = .haveData
                return buffer
            } else {
                inputStatus.pointee = .noDataNow
                return nil
            }
        }
        if status == .error || outBuf.frameLength == 0 { return }

        // outBuf.int16ChannelData[0] has outBuf.frameLength Int16 samples of
        // resampled audio. Chop into 160-sample frames for the wire. We
        // buffer a partial remainder across calls so we never emit a partial
        // frame that the Mac would reject.
        guard let ch = outBuf.int16ChannelData?[0] else { return }
        let produced = Int(outBuf.frameLength)
        buffer16(UnsafeBufferPointer(start: ch, count: produced))
    }

    // Running 160-sample carry between converter bursts so we always emit
    // complete frames. A typical 20 ms input → 320 output samples = 2 frames
    // exactly at 16 kHz, but resampler phase can drift ±1 sample.
    private var carry: [Int16] = []
    private func buffer16(_ source: UnsafeBufferPointer<Int16>) {
        let frameSize = PhoneWire.micSamplesPerFrame
        var combined = carry
        combined.reserveCapacity(carry.count + source.count)
        combined.append(contentsOf: source)
        var offset = 0
        while combined.count - offset >= frameSize {
            let frame = Array(combined[offset..<offset + frameSize])
            offset += frameSize
            emit(frame)
        }
        carry = Array(combined[offset...])
    }

    private func emit(_ samples: [Int16]) {
        sequence &+= 1
        let payload = AudioFramePayload(
            seq: sequence,
            samples: samples,
            sampleRate: PhoneWire.micSampleRate
        )
        framesPublisher.send(payload)
        DispatchQueue.main.async {
            self.framesEmittedThisSession &+= 1
        }
    }

    // MARK: - Synthetic tone fallback (simulator / CI)

    private var syntheticTimer: DispatchSourceTimer?
    private var syntheticPhase: Double = 0

    private func startSyntheticTone() {
        let q = DispatchQueue(label: "com.dcj.gruxphone.synth")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.tick() }
        syntheticTimer = t
        t.resume()
        DispatchQueue.main.async {
            self.isRunning = true
            self.framesEmittedThisSession = 0
            self.sequence = 0
        }
    }

    private func stopSyntheticTone() {
        syntheticTimer?.cancel()
        syntheticTimer = nil
    }

    private func tick() {
        let n = PhoneWire.micSamplesPerFrame
        var buf = [Int16](repeating: 0, count: n)
        let freq = 440.0
        let sr = Double(PhoneWire.micSampleRate)
        let step = 2.0 * .pi * freq / sr
        for i in 0..<n {
            let v = sin(syntheticPhase) * 0.25
            buf[i] = Int16(clamping: Int(v * Double(Int16.max)))
            syntheticPhase += step
            if syntheticPhase > 2 * .pi { syntheticPhase -= 2 * .pi }
        }
        let rms = Float(sqrt(buf.map { Double($0 * $0) }.reduce(0, +) / Double(n))) / Float(Int16.max)
        DispatchQueue.main.async { self.levelRMS = rms }
        emit(buf)
    }
}
