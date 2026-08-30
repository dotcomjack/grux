import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// System-audio capture for meetings. Uses SCStream with capturesAudio=true,
// sampleRate=16000, channelCount=1 to get meeting-app output (Zoom/Meet/
// FaceTime/Teams/Webex). excludesCurrentProcessAudio=true keeps Grux TTS out
// of the feed so we don't loop our own voice into the transcript.
//
// Why SCStream and not CATapDescription? Grux already holds screen-recording
// permission for the focus watcher, so the extra red-dot cost is zero. SCStream
// is the officially-supported Apple API with much less format-conversion
// surface area than aggregate-device IOProcs. We can swap to CATapDescription
// later if no-red-dot capture is wanted - the callback shape stays the same.
@available(macOS 14.0, *)
@MainActor
final class SystemAudioCapture: NSObject {

    private var stream: SCStream?
    private var sampleHandler: SystemAudioSampleHandler?

    // Callback fires with 16 kHz mono Float32 samples. Called on an arbitrary
    // background queue - consumers must dispatch to their own actor if needed.
    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var isRunning = false

    func start() async throws {
        guard !isRunning else { return }

        // Resolve a content filter. For audio-only capture we still need a
        // filter; pick the main display + exclude nothing. `captureVideo` is
        // false so no frames flow.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "grux.meeting.systemAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No displays found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(MeetingAudioMixer.sampleRate)   // 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        // Minimum video footprint. We can't turn video off entirely in this
        // API, but we can starve it - 1x1 @ 1fps.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let handler = SystemAudioSampleHandler { [weak self] samples in
            self?.onSamples?(samples)
        }
        try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        // Add a video output sink too so the stream has a consumer for the
        // (minuscule) video frames. Without this SCStream seems to back-pressure
        // the audio on some macOS 14.x point releases.
        try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .utility))

        try await stream.startCapture()
        self.stream = stream
        self.sampleHandler = handler
        self.isRunning = true
        WakeLog.shared.log("meeting: system-audio stream started")
    }

    func stop() async {
        guard let s = stream else { isRunning = false; return }
        do {
            try await s.stopCapture()
            WakeLog.shared.log("meeting: system-audio stream stopped")
        } catch {
            WakeLog.shared.log("meeting: system-audio stopCapture error \(error.localizedDescription)")
        }
        self.stream = nil
        self.sampleHandler = nil
        self.isRunning = false
    }
}

@available(macOS 14.0, *)
extension SystemAudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        WakeLog.shared.log("meeting: system-audio didStopWithError \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            self?.isRunning = false
            self?.onError?(error)
        }
    }
}

// Separate output handler - SCStreamOutput can't be on the MainActor-bound
// capture class because the protocol methods are called off-main with
// `nonisolated` semantics on the framework side.
@available(macOS 14.0, *)
final class SystemAudioSampleHandler: NSObject, SCStreamOutput {
    private let onSamples: ([Float]) -> Void

    init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.extractFloat32Mono(sampleBuffer: sampleBuffer) else { return }
        if !samples.isEmpty { onSamples(samples) }
    }

    // Pull 16 kHz mono Float32 samples out of a CMSampleBuffer. SCStream hands
    // us a buffer shaped according to SCStreamConfiguration (we asked for 16k
    // mono Float32), but we defensively handle Int16 / non-mono / alternate
    // rates by downmixing and copying verbatim - SCStream may coerce formats
    // differently across macOS versions.
    static func extractFloat32Mono(sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = sampleBuffer.formatDescription else { return nil }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        guard let asbd else { return nil }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channelCount > 0, bytesPerFrame > 0, frameCount > 0 else { return nil }

        // Extract raw audio bytes.
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let bufferList = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        guard let first = bufferList.first, let mData = first.mData else { return nil }
        let byteLength = Int(first.mDataByteSize)

        if isFloat {
            let floats = mData.bindMemory(to: Float.self, capacity: byteLength / MemoryLayout<Float>.size)
            let totalFloats = byteLength / MemoryLayout<Float>.size
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: floats, count: totalFloats))
            }
            // Interleaved N-channel Float32 → mono mixdown.
            let perChan = totalFloats / channelCount
            var out = [Float](repeating: 0, count: perChan)
            for f in 0..<perChan {
                var acc: Float = 0
                for c in 0..<channelCount { acc += floats[f * channelCount + c] }
                out[f] = acc / Float(channelCount)
            }
            return out
        } else {
            // Int16 interleaved path.
            let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
            guard bytesPerSample == 2 else { return nil }
            let totalSamples = byteLength / bytesPerSample
            let ints = mData.bindMemory(to: Int16.self, capacity: totalSamples)
            if channelCount == 1 {
                var out = [Float](repeating: 0, count: totalSamples)
                for i in 0..<totalSamples { out[i] = Float(ints[i]) / 32768.0 }
                return out
            }
            let perChan = totalSamples / channelCount
            var out = [Float](repeating: 0, count: perChan)
            for f in 0..<perChan {
                var acc: Int32 = 0
                for c in 0..<channelCount { acc += Int32(ints[f * channelCount + c]) }
                out[f] = Float(acc) / (32768.0 * Float(channelCount))
            }
            return out
        }
    }
}
