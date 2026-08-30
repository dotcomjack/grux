import Foundation
import AVFoundation
import AppKit
import WhisperKit

// Continuous passive listener. Captures mic → 16 kHz mono Float32 → chunks on
// silence (VAD) or hard cap → WhisperKit transcription → AmbientState.
// Coordinates with VoiceInput (explicit dictation) and WakeWordListener so
// only one AVAudioEngine owns the mic at a time.
@MainActor
final class AmbientListener {
    static let shared = AmbientListener()

    private let buffer = AmbientAudioBuffer()
    private var audioEngine: AVAudioEngine?
    private var whisperKit: WhisperKit?
    private var whisperInitTask: Task<Void, Never>?
    private var chunkTimer: Timer?
    private var levelTimer: Timer?
    private var running = false
    // `private(set)` rather than `private`, so a test can assert the
    // arbitration state this listener is holding.
    //
    // A bespoke test-only accessor would have done the same job and been worse:
    // this way nothing outside the file can WRITE these, which is the property
    // that matters, and the seam is the ordinary Swift one. The alternative was
    // a suite that can only assert that a line of code exists, and the defect
    // these guard (an engine orphaned by a stale pause flag) is invisible to
    // that kind of test.
    private(set) var pausedForExplicit = false
    private(set) var pausedForSpeech = false
    // Third pause state - held while MeetingCaptureService owns the mic. Same
    // arbitration contract as pausedForExplicit / pausedForSpeech: resumeIfReady
    // only restarts the engine when ALL three are clear.
    private(set) var pausedForMeeting = false
    private var speechStartObs: Any?
    private var speechStopObs: Any?
    private var lastChunkAttemptAt: Date = .distantPast
    private var transcribeInFlight = false
    // If user said a bare "hey grux" we arm the listener so the NEXT chunk is
    // treated as the command. Cleared after consumption or expiry. Also
    // re-armed automatically after every Grux speech stop so follow-up turns
    // in a conversation don't need a fresh "hey grux" each time.
    private var wakeArmedUntil: Date = .distantPast
    private let wakeArmWindow: TimeInterval = 18
    private let conversationFollowUpWindow: TimeInterval = 30
    // Timestamp of the last Grux speech stop. Used to drop self-echo chunks
    // that leak in during the resume grace window.
    private var lastSpeechEndAt: Date = .distantPast
    private let postSpeechEchoGuardSeconds: TimeInterval = 2.5

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    // Model: reuse the same one VoiceInput uses so only one model lives in
    // the WhisperKit cache. argmaxinc/whisperkit-coreml/openai_whisper-small.en
    private let modelName = "openai_whisper-small.en"
    private let modelRepo = "argmaxinc/whisperkit-coreml"

    // VAD/chunking parameters
    private let silenceFlushSeconds: TimeInterval = 1.6
    private let minChunkSeconds: Double = 1.0
    private let maxChunkSeconds: Double = 22.0
    private let deadAirResetSeconds: Double = 12.0

    private init() {
        WakeLog.shared.log("ambient: init")
        installSpeechObservers()
    }

    private func installSpeechObservers() {
        speechStartObs = NotificationCenter.default.addObserver(
            forName: .gruxSpeechDidStart, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AmbientListener.shared.suspendForSpeech() }
        }
        speechStopObs = NotificationCenter.default.addObserver(
            forName: .gruxSpeechDidStop, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AmbientListener.shared.resumeAfterSpeech() }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !running else { return }
        // Hard mute - the user tapped the orb. Don't spin up the mic engine.
        let muted = await MainActor.run { AppState.shared.micMuted }
        if muted {
            WakeLog.shared.log("ambient: skipping start - micMuted")
            return
        }
        AmbientState.shared.status = "Starting ambient listener…"
        AmbientState.shared.error = nil

        // Mic auth - centralized in MicController (see comment there).
        guard await MicController.ensureAuthorized() else {
            AmbientState.shared.error = "Microphone not authorized."
            AmbientState.shared.status = "Mic permission needed"
            WakeLog.shared.log("ambient: mic not authorized")
            return
        }

        if whisperKit == nil {
            await initWhisperIfNeeded()
        }

        // RE-CHECK AFTER THE SUSPENSIONS. The guard at the top of this function
        // ran before an authorization prompt and a model load, either of which
        // can take seconds. A mute that lands in that window must not be
        // overtaken by the listener it was trying to stop: without this, muting
        // while ambient is starting gives you a muted UI and a live microphone.
        if await MainActor.run(body: { AppState.shared.micMuted }) {
            AmbientState.shared.status = "Muted"
            WakeLog.shared.log("ambient: aborting start - muted during setup")
            return
        }

        // Build engine
        do {
            try startEngine()
        } catch {
            AmbientState.shared.error = "Audio engine failed: \(error.localizedDescription)"
            AmbientState.shared.status = "Engine error"
            WakeLog.shared.log("ambient: engine start failed \(error)")
            return
        }

        running = true
        AmbientState.shared.isCapturing = true
        AmbientState.shared.status = "Listening"
        startChunkTimer()
        startLevelTimer()
        WakeLog.shared.log("ambient: STARTED")
    }

    func stop() {
        running = false
        // CLEAR THE ARBITRATION FLAGS, or the microphone is held forever.
        //
        // The reported shape: mute during a meeting fires a summariser that
        // takes seconds. Unmute inside that window called start(), which built
        // engine A. The summariser then finished and called resumeFromMeeting(),
        // which saw pausedForMeeting still true, and resumeIfReady built engine
        // B and assigned it over A WITHOUT STOPPING A. A later mute stopped only
        // B, so engine A kept its tap on the input node and the orange
        // microphone indicator stayed lit with every surface reading MUTED.
        //
        // stop() is a full reset of this listener, so the three pause reasons it
        // could have been holding are no longer true. A resume that arrives late
        // now hits its own `guard pausedForX else { return }` and does nothing,
        // which is the correct answer: whatever stopped us decides when we come
        // back, not a callback from before the stop.
        pausedForExplicit = false
        pausedForSpeech = false
        pausedForMeeting = false
        chunkTimer?.invalidate(); chunkTimer = nil
        levelTimer?.invalidate(); levelTimer = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        buffer.reset()
        SingingDetector.shared.stop()
        AmbientState.shared.isCapturing = false
        AmbientState.shared.liveLevel = 0
        AmbientState.shared.status = "Paused"
        WakeLog.shared.log("ambient: stopped")
    }

    // Temporarily release the mic for VoiceInput dictation. Resumes when that
    // session ends (caller invokes `resumeFromExplicitInput()`).
    func pauseForExplicitInput() {
        guard running, !pausedForExplicit else { return }
        pausedForExplicit = true
        tearDownCapture(reason: "dictation active")
    }

    func resumeFromExplicitInput() {
        guard pausedForExplicit else { return }
        pausedForExplicit = false
        resumeIfReady(reason: "after explicit input")
    }

    // Drop the mic while Grux is speaking (coach nudge / chat reply) so
    // we don't re-transcribe our own voice. Echo cancellation on the input
    // node helps, but the cleanest fix is to not capture at all during playback.
    func suspendForSpeech() {
        guard running, !pausedForSpeech else { return }
        pausedForSpeech = true
        tearDownCapture(reason: "Grux is speaking")
    }

    func resumeAfterSpeech() {
        guard pausedForSpeech else { return }
        pausedForSpeech = false
        lastSpeechEndAt = Date()
        // Keep the conversation open: re-arm the wake window so the user's
        // next utterance flows straight to chat without another "hey grux".
        wakeArmedUntil = Date().addingTimeInterval(conversationFollowUpWindow)
        WakeLog.shared.log("ambient: re-armed for follow-up (+\(Int(conversationFollowUpWindow))s)")
        resumeIfReady(reason: "speech ended")
    }

    // Release the mic + WhisperKit for MeetingCaptureService. Safe to call
    // whether or not ambient was running - if ambient wasn't listening we
    // still flip the flag so sharedWhisperKit() can hand out the instance
    // without ambient contending later.
    func pauseForMeeting() {
        guard !pausedForMeeting else { return }
        pausedForMeeting = true
        if running { tearDownCapture(reason: "meeting capture active") }
    }

    func resumeFromMeeting() {
        guard pausedForMeeting else { return }
        pausedForMeeting = false
        resumeIfReady(reason: "after meeting capture")
    }

    // Exposed to MeetingTranscriber. Loads the WhisperKit model if it wasn't
    // already - cheap when already cached on disk. Kept as an async accessor
    // so callers don't need to care whether init has happened yet.
    func sharedWhisperKit() async -> WhisperKit? {
        if whisperKit == nil { await initWhisperIfNeeded() }
        return whisperKit
    }

    // Shared teardown used by both pause paths. Cancels timers, stops engine,
    // and resets the rolling buffer so no in-flight samples survive the pause.
    private func tearDownCapture(reason: String) {
        chunkTimer?.invalidate(); chunkTimer = nil
        levelTimer?.invalidate(); levelTimer = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        buffer.reset()
        SingingDetector.shared.stop()
        AmbientState.shared.isCapturing = false
        AmbientState.shared.liveLevel = 0
        AmbientState.shared.status = "Paused (\(reason))"
        WakeLog.shared.log("ambient: paused - \(reason)")
    }

    // Only restart the engine once BOTH pauses are clear. If speech ends while
    // a dictation is still running (or vice versa) we stay down until both clear.
    private func resumeIfReady(reason: String) {
        guard running else { return }
        guard !pausedForExplicit, !pausedForSpeech, !pausedForMeeting else {
            WakeLog.shared.log("ambient: resume deferred (\(reason)) - other pause still active")
            return
        }
        // Small grace window so speaker tail audio settles before we open the mic.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard running, !self.pausedForExplicit, !self.pausedForSpeech, !self.pausedForMeeting else { return }
            do {
                try startEngine()
                AmbientState.shared.isCapturing = true
                AmbientState.shared.status = Date() < self.wakeArmedUntil
                    ? "Listening · conversation open"
                    : "Listening"
                startChunkTimer()
                startLevelTimer()
                WakeLog.shared.log("ambient: resumed - \(reason)")
            } catch {
                AmbientState.shared.error = "Resume failed: \(error.localizedDescription)"
                AmbientState.shared.status = "Error"
                WakeLog.shared.log("ambient: resume failed \(error)")
            }
        }
    }

    // MARK: - WhisperKit

    private func initWhisperIfNeeded() async {
        AmbientState.shared.status = "Loading Whisper model…"
        WakeLog.shared.log("ambient: whisper init (model=\(modelName))")
        if whisperInitTask == nil {
            whisperInitTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let cfg = WhisperKitConfig(
                        model: self.modelName,
                        modelRepo: self.modelRepo,
                        verbose: false,
                        prewarm: true,
                        load: true,
                        download: true
                    )
                    let kit = try await WhisperKit(cfg)
                    await MainActor.run {
                        self.whisperKit = kit
                        AmbientState.shared.whisperReady = true
                    }
                    WakeLog.shared.log("ambient: whisper READY")
                } catch {
                    await MainActor.run {
                        AmbientState.shared.error = "Whisper init failed: \(error.localizedDescription)"
                    }
                    WakeLog.shared.log("ambient: whisper init FAILED \(error)")
                }
            }
        }
        _ = await whisperInitTask?.value
    }

    // MARK: - Engine

    private func startEngine() throws {
        // NEVER ASSIGN OVER A LIVE ENGINE. Every caller is supposed to have
        // stopped first, and the orphaned-engine defect above proves that
        // "supposed to" is not a guarantee: an engine dropped without stopping
        // keeps its tap on the input node and holds the device for the life of
        // the process, with nothing left pointing at it to stop it.
        if let existing = audioEngine {
            WakeLog.shared.log("ambient: startEngine found a live engine, tearing it down first")
            existing.inputNode.removeTap(onBus: 0)
            existing.stop()
            audioEngine = nil
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // FaceTime / Phone use kAudioUnitSubType_VoiceProcessingIO under the
        // hood - Apple's hardware-level AEC + noise suppression + AGC. Great
        // for laptop built-in mics (cancels Music/YouTube out of the mic so
        // we never transcribe lyrics as user utterances). BUT enabling VPIO
        // forces the entire system output chain into the narrow-band
        // "communications" codec - Music/Safari/YouTube go tinny-mono until
        // the engine stops. External mics like the DJI Mic Mini have strong
        // on-device DSP and don't need our VPIO; the whitelist lets the user mark
        // specific mics "skip VPIO - preserve full-fidelity output".
        MicWhitelist.applyPreferredInputIfPossible()
        let activeInputUID = MicDevices.systemDefaultInputUID() ?? ""
        let bypassVPIO = MicWhitelist.isWhitelisted(uid: activeInputUID)
        // The global switch is read here as well as in VoiceInput. Until
        // 2026-08-22 this path consulted only the per-mic whitelist, so turning
        // voice processing off in Settings quieted dictation and left ambient
        // still forcing VPIO: the same narrow-band output, coming from the half
        // nobody thought to check.
        let wantsVPIO = AppState.shared.config.premiumNoiseCancellation
        if bypassVPIO || !wantsVPIO {
            let why = bypassVPIO ? "whitelisted mic \(activeInputUID)" : "voice processing off in Settings"
            WakeLog.shared.log("ambient: VPIO BYPASSED (\(why)) - speakers stay full-fidelity")
        } else {
            do {
                try input.setVoiceProcessingEnabled(true)
                WakeLog.shared.log("ambient: VoiceProcessingIO ENABLED (AEC/NS/AGC) for \(activeInputUID)")
            } catch {
                WakeLog.shared.log("ambient: VoiceProcessingIO enable FAILED \(error.localizedDescription)")
            }
        }

        let nativeFormat = input.outputFormat(forBus: 0)
        let nativeRate = nativeFormat.sampleRate
        let channelCount = Int(nativeFormat.channelCount)

        guard let nativeMonoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nativeRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: nativeMonoFormat, to: targetFormat) else {
            throw NSError(domain: "grux.ambient", code: 1, userInfo: [NSLocalizedDescriptionKey: "format/converter unavailable"])
        }

        input.removeTap(onBus: 0)
        let buf = buffer
        let tgt = targetFormat
        let mono = nativeMonoFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [buf, channelCount, converter, mono, tgt] inBuf, _ in
            AmbientListener.downmixAndResample(
                inBuf: inBuf, channels: channelCount, monoFormat: mono,
                converter: converter, target: tgt, buffer: buf
            )
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
        // Start the SoundAnalysis singing/music classifier on the same 16 kHz
        // mono Float32 stream that feeds Whisper. Its output gates command
        // dispatch in `transcribe()` below - transcription still runs so the
        // user sees what was heard, but sung lyrics don't get routed as
        // commands. Stop is handled in tearDownCapture / stop().
        SingingDetector.shared.start(inputFormat: targetFormat)
        WakeLog.shared.log("ambient: engine up  native=\(Int(nativeRate))Hz ch=\(channelCount)")
    }

    private nonisolated static func downmixAndResample(
        inBuf: AVAudioPCMBuffer,
        channels: Int,
        monoFormat: AVAudioFormat,
        converter: AVAudioConverter,
        target: AVAudioFormat,
        buffer: AmbientAudioBuffer
    ) {
        let n = Int(inBuf.frameLength)
        guard let inData = inBuf.floatChannelData, n > 0, channels > 0 else { return }

        guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        monoBuf.frameLength = AVAudioFrameCount(n)
        guard let mono = monoBuf.floatChannelData?[0] else { return }
        if channels == 1 {
            for i in 0..<n { mono[i] = inData[0][i] }
        } else {
            // Aggregate/virtual audio devices (e.g. 3-channel BlackHole-style
            // stacks) route the real mic to ONE channel and leave the others
            // silent. A naive sum/channels average then divides the real
            // signal by N, which pushed RMS down to ~0.0001 on one real setup
            // and the adaptive noise gate never tripped - "can't hear me"
            // even with the HUD showing "Listening." Pick the highest-energy
            // channel per buffer so one hot channel never gets diluted by
            // cold ones. For a true stereo mic (both channels carrying the
            // same voice) either channel is fine, so this doesn't regress
            // the normal laptop-mic case. Per-buffer decision means a device
            // swap mid-session self-corrects on the next tap callback.
            var bestCh = 0
            var bestEnergy: Float = 0
            for c in 0..<channels {
                var e: Float = 0
                for i in 0..<n { e += abs(inData[c][i]) }
                if e > bestEnergy { bestEnergy = e; bestCh = c }
            }
            for i in 0..<n { mono[i] = inData[bestCh][i] }
        }

        let rate = monoFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(n) * (target.sampleRate / rate) + 128)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }
        var consumed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true; outStatus.pointee = .haveData
            return monoBuf
        }
        if status == .error || err != nil { return }
        guard let outPtr = outBuf.floatChannelData?[0] else { return }
        let outCount = Int(outBuf.frameLength)
        guard outCount > 0 else { return }

        // VP-IO already AEC'd, noise-suppressed, and AGC'd this signal at the
        // hardware level - feed it straight to the rolling buffer.
        var sumSquares: Float = 0
        for i in 0..<outCount { sumSquares += outPtr[i] * outPtr[i] }
        let rms = sqrt(sumSquares / Float(outCount))
        buffer.appendSamples(outPtr, count: outCount, rms: rms)

        // Parallel feed for the long-horizon rolling ring used by
        // AudioExportStore.exportAmbientTail. Independent of the transcribe
        // buffer above so Whisper's per-turn drain doesn't evict audio the
        // user might want to save later.
        AmbientAudioRing.shared.append(outPtr, count: outCount)

        // Parallel feed for the SoundAnalysis-based singing/music classifier.
        // SingingDetector dispatches `analyze` onto its own serial queue, so
        // this call is non-blocking on the audio thread. When the classifier
        // reports sustained music/singing dominance, AmbientListener suppresses
        // command dispatch in `transcribe()`.
        SingingDetector.shared.process(buffer: outBuf)
    }

    // MARK: - Chunking

    private func startChunkTimer() {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.considerFlush() }
        }
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let snap = self.buffer.snapshot()
                AmbientState.shared.liveLevel = min(1, snap.rms * 6)
            }
        }
    }

    // Decide whether to flush the buffer into a transcription chunk.
    // Flush conditions:
    //   1) We've heard voice AND there's been >silenceFlushSeconds of silence since the last voice frame
    //   2) Buffer has grown past maxChunkSeconds (hard cap - split to keep latency bounded)
    //   3) No voice ever AND buffer past deadAirResetSeconds (drop silent audio)
    //   4) Fallback: buffer has audio but VAD never tripped AND peak is meaningfully
    //      non-zero - transcribe anyway so we don't drop quiet speech that sits below
    //      the VAD threshold (common with laptop-speaker TTS picked up at the mic).
    private var lastVadStatLogAt: Date = .distantPast
    private func considerFlush() {
        // Before any flush consideration, see if the WAKE-mode conversation
        // has aged out (30s post-Grux-reply silence). If so, exit early -
        // the engine is about to be torn down.
        checkSilenceTimeout()
        guard running, !pausedForExplicit, !transcribeInFlight else { return }
        let snap = buffer.snapshot()
        let now = Date()
        let silentFor = now.timeIntervalSince(snap.lastVoiceAt)

        // Diagnostic heartbeat: log VAD/peak every 5s so we can see why audio isn't chunking.
        if now.timeIntervalSince(lastVadStatLogAt) > 5 {
            lastVadStatLogAt = now
            // Until the first voiced frame, lastVoiceAt sits at .distantPast, so
            // silentFor is a ~64-billion-second epoch sentinel (silentFor=63920114471s),
            // not a real gap. Log "never" in that case instead of the garbage delta.
            let silentForStr = snap.voicedEver ? String(format: "%.1fs", silentFor) : "never"
            WakeLog.shared.log(String(format: "ambient vad: buf=%.1fs rms=%.4f peak=%.3f voiced=%@ silentFor=%@",
                                      snap.totalSeconds, Double(snap.rms), Double(snap.peak),
                                      snap.voicedEver ? "Y" : "N", silentForStr))
        }

        if snap.voicedEver && snap.totalSeconds >= minChunkSeconds && silentFor >= silenceFlushSeconds {
            flush()
            return
        }
        if snap.totalSeconds >= maxChunkSeconds {
            if snap.voicedEver {
                flush()
            } else if snap.peak >= 0.015 {
                // Fallback flush: peak made it above the whisper-silent floor
                // even though VAD never officially tripped. Better to transcribe
                // and let Whisper decide than to drop the audio silently.
                WakeLog.shared.log(String(format: "ambient: fallback flush (peak=%.3f, no VAD trip)", Double(snap.peak)))
                flush()
            } else {
                buffer.reset() // pure dead air - discard
            }
            return
        }
        if !snap.voicedEver && snap.totalSeconds >= deadAirResetSeconds {
            // Before resetting, check peak - if there was detectable audio (just
            // below the VAD threshold), transcribe instead of dropping.
            if snap.peak >= 0.015 {
                WakeLog.shared.log(String(format: "ambient: sub-VAD flush (peak=%.3f, buf=%.1fs)", Double(snap.peak), snap.totalSeconds))
                flush()
            } else {
                buffer.reset()
            }
        }
    }

    private func flush() {
        let drained = buffer.drain()
        guard drained.samples.count > 16000 / 2 else { return } // <0.5s: skip
        guard whisperKit != nil else { return }
        transcribeInFlight = true
        Task { await self.transcribe(drained.samples, peak: drained.peak) }
    }

    /// Compute the total voiced duration (seconds) in a 16 kHz mono Float32 buffer.
    /// A 20 ms frame is "voiced" if its RMS exceeds `threshold`. Used as a
    /// transient-rejection gate before Whisper so ~50ms keyboard clicks that
    /// cross the peak threshold still get dropped.
    static func voicedSeconds(_ samples: [Float], threshold: Float = 0.006) -> Float {
        let frameSize = 320 // 20 ms at 16 kHz
        guard samples.count >= frameSize else { return 0 }
        var voicedFrames = 0
        var i = 0
        while i + frameSize <= samples.count {
            var sumSq: Float = 0
            for j in 0..<frameSize { let s = samples[i + j]; sumSq += s * s }
            let rms = sqrtf(sumSq / Float(frameSize))
            if rms > threshold { voicedFrames += 1 }
            i += frameSize
        }
        return Float(voicedFrames) * Float(frameSize) / 16000.0
    }

    /// Segment-level confidence gate. Returns true if the segment should be kept.
    /// Short segments get tighter thresholds because Whisper's hallucination rate
    /// is much higher when it has little acoustic context (e.g. a 400ms chunk).
    static func passesConfidenceGate(noSpeechProb: Float, avgLogprob: Float, segmentDuration: Float) -> Bool {
        let isShort = segmentDuration < 1.0
        let noSpeechMax: Float = isShort ? 0.3 : 0.6
        let logprobMin: Float = isShort ? -0.6 : -1.0
        return noSpeechProb <= noSpeechMax && avgLogprob >= logprobMin
    }

    private func transcribe(_ samples: [Float], peak: Float) async {
        defer { Task { @MainActor in self.transcribeInFlight = false } }
        guard peak >= 0.004 else {
            WakeLog.shared.log("ambient: chunk skipped (peak=\(peak))")
            return
        }
        let voiced = Self.voicedSeconds(samples)
        guard voiced >= 0.35 else {
            WakeLog.shared.log(String(format: "ambient: chunk skipped (voiced=%.2fs < 0.35s - transient/noise)", Double(voiced)))
            return
        }
        await MainActor.run {
            AmbientState.shared.isTranscribing = true
            AmbientState.shared.status = "Transcribing…"
        }
        guard let kit = whisperKit else { return }
        let promptTokens = await MainActor.run { WhisperVocab.buildPromptTokens(tokenizer: kit.tokenizer) }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            promptTokens: promptTokens
        )
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            // Confidence gate: Whisper fabricates plausible-sounding captions
            // ("(upbeat music)", "Thanks for watching!") when fed low-speech
            // audio - keyboard clatter, music, HVAC hum. Those fabrications
            // carry characteristic telemetry: very-low avgLogprob (decoder
            // wasn't confident) and/or high noSpeechProb (VAD said no voice).
            // Drop segments that trip either threshold BEFORE the text
            // cleaner or downstream chat ever sees them.
            var keptTexts: [String] = []
            var droppedPreviews: [String] = []
            for r in results {
                for seg in r.segments {
                    let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    let segDur = Float(seg.end - seg.start)
                    if !Self.passesConfidenceGate(noSpeechProb: seg.noSpeechProb, avgLogprob: seg.avgLogprob, segmentDuration: segDur) {
                        droppedPreviews.append(
                            "'\(trimmed.prefix(60))' (nsp=\(String(format: "%.2f", seg.noSpeechProb)), alp=\(String(format: "%.2f", seg.avgLogprob)), dur=\(String(format: "%.2f", segDur)))"
                        )
                        continue
                    }
                    keptTexts.append(trimmed)
                }
            }
            if !droppedPreviews.isEmpty {
                WakeLog.shared.log("ambient: confidence-gated \(droppedPreviews.count) segment(s): \(droppedPreviews.joined(separator: " | "))")
            }
            let raw = keptTexts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = Self.cleanTranscript(raw)
            await MainActor.run {
                AmbientState.shared.isTranscribing = false
                AmbientState.shared.status = "Listening"
                if text.isEmpty {
                    // Log what Whisper actually heard so we can see why we dropped
                    // the chunk (hallucinations like "(typing)" / "[Silence]").
                    let preview = raw.prefix(80)
                    WakeLog.shared.log("ambient: dropped as noise/hallucination: '\(preview)'")
                    return
                }
                // Self-echo guard: Whisper sometimes catches the tail of
                // Grux's own speech within ~2s of the speech ending. If a
                // new chunk arrives that fast AND contains a wake phrase,
                // it's almost always Grux hearing itself, not the user.
                let sinceSpeech = Date().timeIntervalSince(self.lastSpeechEndAt)
                if sinceSpeech < self.postSpeechEchoGuardSeconds,
                   Self.startsWithWake(text) {
                    WakeLog.shared.log("ambient: dropped self-echo (\(String(format: "%.1f", sinceSpeech))s post-speech): \(text.prefix(80))")
                    return
                }
                AmbientState.shared.appendChunk(text)
                WakeLog.shared.log("ambient chunk: \(text.prefix(120))")
                Task { await AmbientMemoryExtractor.shared.onNewChunk(text) }
                // Watch for verbal frustration ("this is broken", "always
                // fails", "TODO ...") next to a clear subject, and offer to
                // draft a GitHub issue. Heuristic-gated so it only spends an
                // LLM call on a hit; nothing files without confirmation.
                Task { await IssueExtractor.shared.onNewChunk(text) }
                // Voice-to-cold-email: "Grux, draft outreach to <person> at
                // <company>". Regex-gated, debounced, and never sends on its
                // own (drafts open a confirm dialog). See Outreach/ColdEmail.
                Task { await ColdEmailEngine.shared.onTranscriptChunk(text) }

                // Singing/music gate. When SingingDetector's SoundAnalysis
                // classifier has been reporting sustained music/singing
                // dominance over speech, suppress command dispatch entirely.
                // The chunk is already in the transcript (above) so the user can
                // still see what was heard - we just don't fire a ChatService
                // round-trip or a mentor nudge on sung lyrics. The ONLY
                // exception: FOCUS mode where the user has explicitly opted
                // into full-time command routing - even there we drop the
                // chunk because sung lyrics aren't a real command intent,
                // just highly visible to the user via the transcript.
                if SingingDetector.shared.isSingingActive {
                    WakeLog.shared.log(String(format:
                        "ambient: SUPPRESSED command dispatch - singing active (music=%.2f speech=%.2f) text='%@'",
                        SingingDetector.shared.musicEMA,
                        SingingDetector.shared.speechEMA,
                        String(text.prefix(80))))
                    AmbientState.shared.status = "🎵 Singing/music - commands muted"
                    return
                }

                // Dismissal phrase: "go away", "bye grux", "we'll chat later",
                // "thanks grux we'll chat later", "shut up grux", etc. In WAKE
                // mode this exits the conversation immediately - mic + VP +
                // Whisper all tear down and we drop back to cheap wake-idle so
                // music plays clean again. In FOCUS mode dismissals are
                // ignored (focus is meant to be uninterrupted).
                if AppState.shared.config.ambientMode == .wake,
                   AmbientState.shared.conversationActive,
                   Self.isDismissal(text) {
                    WakeLog.shared.log("ambient: dismissal matched → exiting conversation: '\(text.prefix(80))'")
                    AmbientState.shared.exitConversation(reason: "dismissal phrase")
                    return
                }
                // Mentor trigger: if the user explicitly asked for advice
                // ("what do you think?", "any advice?"), fire a mentor
                // reminder + speak the answer. Don't also run wake dispatch.
                if MentorTriggerDetector.shared.evaluate(chunk: text) {
                    WakeLog.shared.log("mentor-trigger handled chunk, skipping wake dispatch")
                    return
                }
                self.handleInlineWakeOrCommand(text: text)
            }
        } catch {
            await MainActor.run {
                AmbientState.shared.isTranscribing = false
                AmbientState.shared.status = "Listening"
            }
            WakeLog.shared.log("ambient transcribe FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Inline wake / commands

    // Wake phrase can appear ANYWHERE in a chunk - Whisper often bundles
    // several utterances into one chunk when pauses are short ("Get your butt
    // up here. Hey, Grux." arrives as a single line). So these regexes are
    // NOT anchored to `^` - we scan the whole chunk and slice at the match.
    //
    // Flows:
    //   1. "... hey grux, <command>" → fire <command> now.
    //   2. "... hey grux" alone → chime, speak "yeah?", arm for next chunk.
    //
    // Normalized mishears (grix, grox, groggs, etc.) are already canonicalized
    // to "Grux" by `normalizeBrandMishears` before this regex sees the text.
    private static let inlineWakeRegex: NSRegularExpression = {
        // Non-anchored. Word-boundary on the wake verb so "okay" isn't caught
        // inside an unrelated word. Capture group 1 is the trailing command.
        let pattern = #"\b(?:hey|ok|okay|yo|hi|hay|aye|hi there|um|uh)[\s,.!?:;-]+gr[aeiouy]{1,3}[a-z]{0,3}s?[\s,.!?:;-]*(.*)$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Bare brand call: "grux!" / "grux," / standalone "grux" at a word
    // boundary. Also non-anchored. Conservative - only matches if preceded
    // by whitespace/start-of-string to avoid grabbing "agreeing grux" etc.
    private static let bareBrandWakeRegex: NSRegularExpression = {
        let pattern = #"(?:^|\s)gr[aeiouy]{1,3}[a-z]{0,3}s?[\s,.!?:;-]+(.*)$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // "Conversation over" detector for WAKE mode. Matches the phrases people
    // actually use to sign off ("go away", "we'll chat later", "bye grux",
    // "thanks grux we'll chat later", "shut up grux") plus close variants.
    // Tuned to NOT match mid-conversation usages: bare "thanks grux" with no
    // goodbye tail stays in conversation so the user can keep talking.
    private static let dismissalRegex: NSRegularExpression = {
        let pattern = #"""
        \b(?:
            go\s+away(?:\s+grux)?
          | shut\s+up(?:\s+grux)?
          | leave\s+me\s+alone
          | (?:good[\s-]?bye|goodbye|bye|bye[\s-]?bye|farewell|adios|peace(?:\s+out)?|later|catch\s+you\s+later|see\s+(?:ya|you)(?:\s+later)?)\s*(?:[,.!?]|\s+grux\b)
          | (?:grux)?[\s,]*(?:we'?ll|let'?s|gonna|i'?ll)\s+(?:chat|talk|catch\s+up|speak)(?:\s+(?:again))?\s+later
          | (?:thanks|thank\s+you|appreciate\s+it)\s*(?:grux)?[\s,]*(?:we'?ll|let'?s|gonna|i'?ll)\s+(?:chat|talk)\s+later
          | that(?:'?s|\s+is|'?ll\s+be|\s+will\s+be)\s+all(?:\s+grux)?
          | i'?m\s+(?:all\s+)?done(?:\s+talking)?(?:\s+grux)?
          | dismiss(?:ed)?(?:\s+grux)?
          | stand\s+down(?:\s+grux)?
        )\b
        """#
        return try! NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .allowCommentsAndWhitespace]
        )
    }()

    static func isDismissal(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return dismissalRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    @MainActor
    private func handleInlineWakeOrCommand(text: String) {
        // FOCUS MODE: every meaningful utterance is a command - no wake gate.
        // Safety rail: chunks shorter than 4 chars or that are pure fillers
        // are still ignored. Wake phrase prefixes get stripped so "hey grux,
        // count" still works naturally.
        if AppState.shared.config.ambientMode == .focus {
            // Optional stricter gate (OFF by default, preserves current wake-free
            // FOCUS UX): require a wake word even in FOCUS so a second person's
            // coherent sentence, or the user's own mid-sentence aside, can't fire a
            // command. Toggle on with:
            //   defaults write com.gruxai.grux requireWakeWordInFocus -bool true
            if UserDefaults.standard.bool(forKey: "requireWakeWordInFocus"), !Self.startsWithWake(text) {
                WakeLog.shared.log("ambient (focus): no wake word, strict gate on, skipped: '\(text.prefix(60))'")
                return
            }
            let stripped = Self.stripWakePrefixForFocus(text)
            let command = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.count >= 4, !Self.isFillerChunk(command), Self.passesCommandGate(command) else {
                WakeLog.shared.log("ambient (focus): skipped short/filler/incoherent: '\(text.prefix(60))'")
                return
            }
            WakeLog.shared.log("ambient (focus): → chat: \(command)")
            Task { @MainActor in
                await ChatService.shared.send(userText: command)
            }
            return
        }

        // WAKE MODE below. (Default.)
        // Case A: we're wake-armed from a prior "hey grux" - treat this chunk
        // as the follow-up command (unless it's ANOTHER wake phrase).
        if Date() < wakeArmedUntil, !Self.startsWithWake(text) {
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.count >= 4, !Self.isFillerChunk(command), Self.passesCommandGate(command) else {
                WakeLog.shared.log("ambient: armed-wake skipped short/filler/incoherent: '\(command.prefix(60))'")
                return
            }
            wakeArmedUntil = .distantPast
            WakeLog.shared.log("ambient: armed-wake consumed → command: \(command)")
            Task { @MainActor in
                await ChatService.shared.send(userText: command)
            }
            return
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let match = Self.inlineWakeRegex.firstMatch(in: text, options: [], range: range)
            ?? Self.bareBrandWakeRegex.firstMatch(in: text, options: [], range: range)
        guard let m = match,
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return }
        let command = String(text[r]).trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?:;-"))
        )

        WakeLog.shared.log("ambient: wake matched  text='\(text)'  cmd='\(command)'")
        (NSSound(named: "Tink") ?? NSSound(named: "Glass"))?.play()
        NotificationCenter.default.post(name: .gruxWakeDetected, object: nil)

        if command.count >= 3, Self.passesCommandGate(command) {
            // Single-breath command: fire immediately.
            Task { @MainActor in
                await ChatService.shared.send(userText: command)
            }
        } else if command.count >= 3 {
            // Wake matched but the trailing command is incoherent (garbled /
            // roster echo). Arm for the next chunk instead of acting on noise.
            wakeArmedUntil = Date().addingTimeInterval(wakeArmWindow)
            AmbientState.shared.status = "Armed - say your command"
            SpeechEngine.shared.speak("Yeah, boss?")
        } else {
            // Bare wake - acknowledge and arm for the next chunk.
            wakeArmedUntil = Date().addingTimeInterval(wakeArmWindow)
            AmbientState.shared.status = "Armed - say your command"
            SpeechEngine.shared.speak("Yeah, boss?")
        }
    }

    // Focus mode: if chunk leads with a wake phrase, strip it so Claude sees
    // the actual ask. If there's no wake phrase, just return the chunk as-is.
    private static func stripWakePrefixForFocus(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let m = inlineWakeRegex.firstMatch(in: text, options: [], range: range),
           m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) {
            return String(text[r])
        }
        if let m = bareBrandWakeRegex.firstMatch(in: text, options: [], range: range),
           m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) {
            return String(text[r])
        }
        return text
    }

    // Filter noise-y chunks in focus mode so random "uh huh" / "yeah" / etc.
    // don't trigger a full chat roundtrip.
    private static let fillerPhrases: Set<String> = [
        "yeah", "yeah.", "yep", "yep.", "nope", "nah", "mhm", "uh", "uh.",
        "um", "hmm", "oh", "oh.", "okay.", "ok", "k.", "right.", "sure.",
        "wait.", "huh.", "what?", "what.", "haha.", "lol."
    ]
    private static func isFillerChunk(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return fillerPhrases.contains(normalized)
    }

    // Stop-words for the coherence gate. A real command carries at least one
    // CONTENT word outside this set; an utterance made entirely of these is
    // ambient conversation/filler bleeding into the mic, not something aimed at
    // Grux. Deliberately excludes command verbs (stop, play, open, next, ...)
    // so terse one-word commands still pass.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "um", "uh", "er", "ah",
        "like", "you", "know", "i", "im", "i'm", "its", "it's", "that", "this",
        "is", "was", "were", "be", "been", "to", "of", "in", "on", "at", "for",
        "with", "as", "if", "then", "well", "just", "really", "kinda", "sorta",
        "yeah", "yep", "nah", "okay", "ok", "right", "mean", "gonna", "wanna",
        "he", "she", "they", "we", "me", "my", "your", "their", "our", "his",
        "her", "them", "us", "what", "huh", "oh", "hmm", "mhm", "anyway", "thing"
    ]

    // Pragmatic command gate (coherence, not speaker identity). Rejects garbled
    // looping transcripts, the Whisper vocab roster echoed back, and utterances
    // with zero content words. This is the honest approximation of "only act on
    // a clear, coherent utterance" - it can't tell WHO spoke, but it filters the
    // obvious ambient noise that was being acted on as if the user said it. Kept
    // conservative so a terse real command ("stop", "next") still passes.
    private static func passesCommandGate(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if VoiceInput.looksLikeRepeatedHallucination(t) {
            WakeLog.shared.log("ambient: command-gate reject (repetition): '\(t.prefix(60))'")
            return false
        }
        if VoiceInput.looksLikeRosterEcho(t, roster: WhisperVocab.rosterWordSet()) {
            WakeLog.shared.log("ambient: command-gate reject (roster echo): '\(t.prefix(60))'")
            return false
        }
        let words = t.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let contentWords = words.filter { !stopWords.contains($0) && $0.count >= 2 }
        if contentWords.isEmpty {
            WakeLog.shared.log("ambient: command-gate reject (all stop-words): '\(t.prefix(60))'")
            return false
        }
        return true
    }

    // Does a transcript chunk start with a wake phrase? Used to avoid
    // consuming a back-to-back second wake as the command of the first.
    private static func startsWithWake(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if inlineWakeRegex.firstMatch(in: text, options: [], range: range) != nil { return true }
        if bareBrandWakeRegex.firstMatch(in: text, options: [], range: range) != nil { return true }
        return false
    }

    // MARK: - Helpers

    private static func cleanTranscript(_ s: String) -> String {
        var out = s
        // Whisper stage-direction strip. The goal: obliterate every parenthetical
        // or bracket whose job is to describe ambient sound rather than carry
        // speech. Earlier attempts required EVERY word in the bracket to be on
        // a whitelist, which failed on things like "(upbeat music)" or
        // "(rock music)" - the adjective wasn't whitelisted so the whole thing
        // slipped through.
        //
        // New rule: if a bracket contains an ANCHOR word (music/noise/typing/
        // etc.) anywhere, the whole bracket dies regardless of the adjectives
        // around it. Brackets are length-capped at 40 chars so we don't eat
        // real speech that happens to contain the word "music" ("I hate the
        // music industry - too corporate"). The 40-char cap is generous
        // enough for every Whisper hallucination we've seen in the wild and
        // tight enough that a normal sentence never fits inside one.
        let soundAnchors = #"(?:music|noise|sound|sounds|audio|silence|typing|clicking|tapping|keyboard|mouse|click|clicks|keys|footsteps|rain|wind|chatter|voices|breathing|humming|hums|beeping|buzzing|buzzes|singing|sings|sung|crying|laughter|laughing|applause|clapping|coughing|sneezing|sighing|sighs|mumbling|whispering|whispers|static|crackle|crackling|crunch|crunches|thud|thuds|rustling|rustle|crickets|birds|chirping|bark|barking|hum|humming|muzak|jingle|jingles|song|songs|beat|beats|drum|drums|drumming|fan|fans|air|ambient|background)"#
        // (…) with an anchor somewhere inside, ≤40 chars of total content.
        out = out.replacingOccurrences(
            of: #"\(\s*[^()\n\r]{0,40}?\b\#(soundAnchors)\b[^()\n\r]{0,40}?\s*\)"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        // [...] with an anchor somewhere inside, ≤40 chars of total content.
        out = out.replacingOccurrences(
            of: #"\[\s*[^\[\]\n\r]{0,40}?\b\#(soundAnchors)\b[^\[\]\n\r]{0,40}?\s*\]"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        // Whisper's pseudo-XML timestamp/language tokens: <|en|>, <|0.00|>, etc.
        out = out.replacingOccurrences(of: #"<\|[^>]*\|>"#, with: "", options: .regularExpression)
        // Whisper's all-caps internal sentinels: [BLANK_AUDIO], [NO_SPEECH],
        // [INAUDIBLE], [UNKNOWN]. These leak through when VP-IO has cleaned
        // the input so aggressively that the model sees near-silence and
        // emits a label instead of text. Real speech transcripts never
        // contain bracketed UPPER_SNAKE tokens.
        out = out.replacingOccurrences(of: #"\[[A-Z][A-Z0-9_]*\]"#, with: "", options: .regularExpression)
        // Collapse any whitespace the stripping left behind so a trailing
        // period on its own hits the junk-set drop below.
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop chunks that are entirely a known Whisper hallucination. A
        // chunk must match one of these EXACTLY to be dropped - real speech
        // almost never hits any of these as the sole utterance. Ambient
        // stage-direction phrases that Whisper sometimes emits WITHOUT any
        // brackets (raw "Music playing" as the whole chunk) also live here.
        let junk: Set<String> = [
            "thanks for watching.", "thanks for watching!", "thank you.", "thank you!",
            "you", ".", "..", "...", "bye.", "bye!", "okay.", "okay", "mm-hmm.",
            "thank you for watching.", "please subscribe.", "please subscribe!",
            "music playing", "music playing.", "music.",
            "keyboard clicking", "keyboard clicking.", "keyboard typing", "keyboard typing.",
            "typing", "typing.", "typing sounds", "typing sounds.",
            "keys clicking", "keys clicking.", "keys typing", "keys typing.",
            "keyboard keys clicking", "keyboard keys clicking.",
            "mouse clicking", "mouse clicking.", "mouse click", "mouse click.",
            "clicking", "clicking.",
            "background noise", "background noise.", "background chatter", "background chatter.",
            "ambient noise", "ambient noise.",
            "fan noise", "fan noise.", "fan humming", "fan humming.",
            "silence", "silence.",
            "music is playing", "music is playing.",
            "soft music", "soft music.", "soft music playing", "soft music playing."
        ]
        if junk.contains(out.lowercased()) { return "" }
        out = Self.normalizeBrandMishears(out)
        return out
    }

    // Whisper small.en regularly mishears "Grux" (because it's a novel proper
    // noun) as gurex / grox / grooks / groks / gruks / gruck / grue / grooves /
    // grues / groose / grose / groots / etc. Normalize these back before storage
    // so both the HUD display and the Claude extractor see the app's own name.
    //
    // Only the app's OWN name is corrected here. This table used to carry one
    // person's brand roster, which silently rewrote a stranger's ordinary speech
    // into somebody else's product names. Person-specific spellings arrive from
    // that person's learned slang instead (same bar as WhisperVocab.baseTerms).
    private static let brandNormalizations: [(NSRegularExpression, String)] = {
        func rx(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            // Grux family - be aggressive with the vowel/consonant matrix.
            // Only match when preceded by word boundary to avoid grabbing
            // real words like "grass" or "gross".
            (rx(#"\b(?:gurex|gurecks|gurix|gurx|grux|grooks?|groks?|gruks?|gruex|gruck|gruffs?|grubs?|grooves?|grue|grues?|groose|grose|grouse|grotz|groots?|groot|grocks?|grox|grox's|groots|grix|grex|grax|grux's|grox's|gryx|groggs?|grog|grogs|grogg|grugs|grunch|grunts?)\b"#), "Grux"),
        ]
    }()

    private static func normalizeBrandMishears(_ s: String) -> String {
        var out = s
        for (rx, replacement) in brandNormalizations {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = rx.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: replacement)
        }
        return out
    }

    // Debug hook: inject a pre-transcribed chunk as if Whisper had produced it.
    // Lets us stress-test the wake/command/armed state machine without an
    // actual mic pipeline. Runs the same cleanTranscript + handleInlineWakeOrCommand
    // path real chunks take.
    func debugInjectChunk(_ text: String) {
        let cleaned = Self.cleanTranscript(text)
        guard !cleaned.isEmpty else {
            WakeLog.shared.log("debug inject: dropped empty-after-clean '\(text)'")
            return
        }
        WakeLog.shared.log("debug inject: '\(cleaned)'")
        AmbientState.shared.appendChunk(cleaned)
        handleInlineWakeOrCommand(text: cleaned)
    }

    // Called by AmbientState.enterConversation right BEFORE start(), so the
    // very first transcribed chunk post-"hey grux" is treated as the command
    // (routed through the existing armed-wake path in handleInlineWakeOrCommand)
    // instead of requiring yet another wake phrase.
    func armForConversationStart() {
        wakeArmedUntil = Date().addingTimeInterval(conversationFollowUpWindow)
        WakeLog.shared.log("ambient: armed for conversation start (+\(Int(conversationFollowUpWindow))s)")
    }

    // Called from considerFlush on every timer tick in WAKE mode with an
    // active conversation. If Grux has finished speaking and the armed-wake
    // window has expired with no follow-up utterance, the user has gone
    // quiet - exit the conversation so we stop burning cycles on VP + Whisper
    // and let music play clean again.
    @MainActor
    fileprivate func checkSilenceTimeout() {
        guard AppState.shared.config.ambientMode == .wake,
              AmbientState.shared.conversationActive,
              running,
              !pausedForSpeech,
              !pausedForExplicit else { return }
        // Never exit while Grux is mid-reply or a user chunk is mid-transcribe.
        guard !transcribeInFlight else { return }
        // Only trip once the armed-wake window (30s post-speech) has expired.
        // That window is set every time Grux finishes speaking; if the user
        // has answered at all since, it would have been consumed and reset.
        guard wakeArmedUntil != .distantPast, Date() >= wakeArmedUntil else { return }
        AmbientState.shared.exitConversation(reason: "silence timeout")
    }

    // MARK: - Manual "done talking" flush

    // User-triggered end of a speech turn. Drains whatever's in the rolling
    // buffer now (even if the silence timer hasn't fired) and kicks off an
    // extraction pass so memories/actions update without waiting.
    func flushNow() async {
        guard running, !pausedForExplicit, !pausedForSpeech else { return }
        let snap = buffer.snapshot()
        guard snap.totalSeconds >= 0.3 else {
            // Nothing in the buffer - just force an extraction pass over the
            // existing transcript so the user sees fresh memories/actions.
            await AmbientMemoryExtractor.shared.runExtraction()
            return
        }
        let drained = buffer.drain()
        transcribeInFlight = true
        await transcribe(drained.samples, peak: drained.peak)
        // Re-run extraction immediately on the freshly-appended chunk, bypassing
        // the extractor's own debounce - user explicitly asked for it.
        await AmbientMemoryExtractor.shared.runExtractionForcing()
    }
}

// MARK: - Thread-safe rolling buffer

final class AmbientAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastVoiceAt: Date = .distantPast
    private var voicedEver: Bool = false
    private var peak: Float = 0
    private var liveRms: Float = 0
    private let sampleRate: Int = 16000
    private let maxSeconds: Int = 30
    // Adaptive gate: learns the ambient noise floor so stationary fan/HVAC
    // noise doesn't keep refreshing `lastVoiceAt` and blocking turn-end.
    // Replaces the prior hard-coded `rms > 0.006` check, which was a fine
    // threshold in a quiet room but tripped constantly on a 3700+ RPM fan.
    private let noiseGate = AdaptiveNoiseGate()

    func appendSamples(_ ptr: UnsafePointer<Float>, count: Int, rms: Float) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        let cap = sampleRate * maxSeconds
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
        liveRms = rms
        for i in 0..<count { peak = max(peak, abs(ptr[i])) }
        if noiseGate.classify(rms: rms) {
            lastVoiceAt = Date()
            voicedEver = true
        }
    }

    func snapshot() -> (samples: [Float], lastVoiceAt: Date, voicedEver: Bool, totalSeconds: Double, peak: Float, rms: Float) {
        lock.lock(); defer { lock.unlock() }
        return (samples, lastVoiceAt, voicedEver, Double(samples.count) / Double(sampleRate), peak, liveRms)
    }

    func drain() -> (samples: [Float], peak: Float) {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        let p = peak
        samples.removeAll(keepingCapacity: false)
        lastVoiceAt = .distantPast
        voicedEver = false
        peak = 0
        liveRms = 0
        return (out, p)
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lastVoiceAt = .distantPast
        voicedEver = false
        peak = 0
        liveRms = 0
        lock.unlock()
    }
}
