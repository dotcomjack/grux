import Foundation
import AVFoundation

// Plays incoming Grux TTS audio (24 kHz Int16 PCM mono) through the phone
// speaker. Uses AVAudioEngine + AVAudioPlayerNode; enqueue() is cheap and
// thread-safe. Called from TransportService on the main thread.
//
// Buffers are scheduled as they arrive, so a 480-sample (20 ms) chunk
// plays with minimal jitter. Playback starts on first start() and stops on
// finish() once the buffer queue drains.
final class TTSPlayer {
    static let shared = TTSPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var engineStarted = false

    private init() {
        // Source format: 24 kHz, Int16 mono, matches wire payload.
        var srcDesc = AudioStreamBasicDescription(
            mSampleRate: 24_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1,
            mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        inputFormat = AVAudioFormat(streamDescription: &srcDesc)!
        // AVAudioPlayerNode won't accept Int16 directly on some iOS builds, so
        // resample/convert to Float32 at the engine's processing format.
        outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 24_000, channels: 1
        )!
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    }

    // Make sure the AVAudioSession is right for output. Safe to call
    // repeatedly, iOS no-ops when already in the requested mode.
    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            NSLog("[TTSPlayer] audio session: \(error)")
        }
    }

    func start() {
        prepareAudioSession()
        if !engineStarted {
            engine.prepare()
            do { try engine.start(); engineStarted = true }
            catch { NSLog("[TTSPlayer] engine start: \(error)"); return }
        }
        if !player.isPlaying { player.play() }
    }

    func enqueue(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        // Build input buffer in 24 kHz Int16.
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = inBuf.int16ChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                _ = memcpy(ch, src.baseAddress, samples.count * 2)
            }
        }
        // Convert to Float32 @ 24 kHz.
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: AVAudioFrameCount(samples.count * 2)) else { return }
        var consumed = false
        let status = converter.convert(to: outBuf, error: nil) { _, inputStatus in
            if !consumed { consumed = true; inputStatus.pointee = .haveData; return inBuf }
            inputStatus.pointee = .noDataNow; return nil
        }
        if status == .error || outBuf.frameLength == 0 { return }
        player.scheduleBuffer(outBuf, completionCallbackType: .dataPlayedBack) { _ in }
    }

    func finish() {
        // Do not stop the player node, upcoming speech would otherwise have
        // a perceptible start-up gap. Just let the queue drain naturally.
    }

    func hardStop() {
        player.stop()
        if engineStarted { engine.stop(); engineStarted = false }
    }
}
