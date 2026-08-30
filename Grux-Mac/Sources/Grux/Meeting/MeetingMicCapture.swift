import Foundation
import AVFoundation

// Dedicated AVAudioEngine mic capture for meeting mode. A SEPARATE engine
// from AmbientListener / VoiceInput / WakeWord - those get paused while
// a meeting is active (see MeetingCaptureService) so there's a single mic
// owner at any time.
//
// Output is always 16 kHz mono Float32. Downmix and resample happen inside
// the tap block, same pattern AmbientListener uses. No VPIO - we WANT to
// capture the user speaking into the call without the OS narrowing the output
// codec, and SCStream's excludesCurrentProcessAudio already stops our own
// TTS from looping into the mic source.
@MainActor
final class MeetingMicCapture {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var nativeMonoFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: MeetingAudioMixer.sampleRate,
        channels: 1,
        interleaved: false
    )!

    var onSamples: (([Float]) -> Void)?
    private(set) var isRunning = false

    func start() throws {
        // Same contract as every other microphone owner: a muted Grux does not
        // take the device back. Throws rather than silently no-opping so the
        // caller can tell the user why the capture did not begin.
        if MainActor.assumeIsolated({ AppState.shared.micMuted }) {
            WakeLog.shared.log("meeting mic: refusing to start, micMuted")
            throw NSError(domain: "Grux.Meeting", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The microphone is muted. Unmute Grux to record a meeting."
            ])
        }
        guard !isRunning else { return }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            throw NSError(domain: "grux.meeting.mic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone not authorized"])
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        let nativeRate = nativeFormat.sampleRate
        let channelCount = Int(nativeFormat.channelCount)
        guard nativeRate > 0, channelCount > 0 else {
            throw NSError(domain: "grux.meeting.mic", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid mic format (rate=\(nativeRate) ch=\(channelCount))"])
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nativeRate,
            channels: 1,
            interleaved: false
        ), let conv = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw NSError(domain: "grux.meeting.mic", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Format/converter unavailable"])
        }

        self.converter = conv
        self.nativeMonoFormat = monoFormat

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] inBuf, _ in
            guard let self else { return }
            let samples = MeetingMicCapture.downmixAndResample(
                inBuf: inBuf,
                channels: channelCount,
                monoFormat: monoFormat,
                converter: conv,
                target: self.targetFormat
            )
            if !samples.isEmpty {
                Task { @MainActor [weak self] in
                    self?.onSamples?(samples)
                }
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        self.isRunning = true
        WakeLog.shared.log("meeting-mic: engine up native=\(Int(nativeRate))Hz ch=\(channelCount)")
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        nativeMonoFormat = nil
        isRunning = false
    }

    // Downmix N-channel native-rate Float32 → 1-channel native-rate Float32 →
    // AVAudioConverter → 1-channel 16 kHz Float32 → [Float].
    private nonisolated static func downmixAndResample(
        inBuf: AVAudioPCMBuffer,
        channels: Int,
        monoFormat: AVAudioFormat,
        converter: AVAudioConverter,
        target: AVAudioFormat
    ) -> [Float] {
        let n = Int(inBuf.frameLength)
        guard let inData = inBuf.floatChannelData, n > 0, channels > 0 else { return [] }

        guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)) else { return [] }
        monoBuf.frameLength = AVAudioFrameCount(n)
        guard let mono = monoBuf.floatChannelData?[0] else { return [] }
        if channels == 1 {
            for i in 0..<n { mono[i] = inData[0][i] }
        } else {
            // Average channels - simple and adequate for meetings.
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += inData[c][i] }
                mono[i] = sum / Float(channels)
            }
        }

        // Resample native-rate → 16 kHz.
        let ratio = target.sampleRate / monoFormat.sampleRate
        let outFrameCap = AVAudioFrameCount(Double(n) * ratio + 32)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrameCap) else { return [] }
        var error: NSError?
        var supplied = false
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return monoBuf
        }
        if status == .error || error != nil { return [] }
        let outCount = Int(outBuf.frameLength)
        guard let outPtr = outBuf.floatChannelData?[0], outCount > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: outPtr, count: outCount))
    }
}
