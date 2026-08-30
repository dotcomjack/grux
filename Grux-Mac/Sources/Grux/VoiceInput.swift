import Foundation
import AVFoundation
import AppKit
import WhisperKit

/// Thread-safe rolling buffer for 16kHz Float32 mono samples.
/// Audio taps run on a dedicated audio thread, so we keep the buffer
/// outside MainActor isolation and guard with a lock.
final class WhisperAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastVoiceAt: Date = .distantPast
    private var voicedEver: Bool = false
    private var peak: Float = 0
    private var liveRms: Float = 0
    private var tapInvocations: Int = 0
    private var framesIn: Int = 0
    private let sampleRate: Int = 16000
    private let maxSeconds: Int = 30

    func noteTapInvocation(framesIn: Int) {
        lock.lock()
        defer { lock.unlock() }
        tapInvocations += 1
        self.framesIn += framesIn
    }

    func debugCounts() -> (taps: Int, framesIn: Int) {
        lock.lock(); defer { lock.unlock() }
        return (tapInvocations, framesIn)
    }

    func appendSamples(_ ptr: UnsafePointer<Float>, count: Int, rms: Float) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        let cap = sampleRate * maxSeconds
        if samples.count > cap {
            samples.removeFirst(samples.count - cap)
        }
        liveRms = rms
        for i in 0..<count { peak = max(peak, abs(ptr[i])) }
        if rms > 0.012 {
            lastVoiceAt = Date()
            voicedEver = true
        }
    }

    func snapshot() -> (samples: [Float], lastVoiceAt: Date, voicedEver: Bool, totalSeconds: Double, peak: Float, rms: Float) {
        lock.lock(); defer { lock.unlock() }
        return (samples, lastVoiceAt, voicedEver, Double(samples.count) / Double(sampleRate), peak, liveRms)
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lastVoiceAt = .distantPast
        voicedEver = false
        peak = 0
        liveRms = 0
        tapInvocations = 0
        framesIn = 0
        lock.unlock()
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
        tapInvocations = 0
        framesIn = 0
        return (out, p)
    }
}

@MainActor
final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcript: String = ""
    @Published var liveLevel: Float = 0
    @Published var error: String?
    @Published var needsMicSettings = false
    @Published var needsSpeechSettings = false
    @Published var autoSendRequested = false
    @Published var whisperReady = false
    @Published var whisperStatus: String = "loading Whisper model…"

    // Rebuilt fresh for every recording session. AVAudioEngine + the
    // shared mic HAL can get into a wedged state if we reuse the same
    // instance after SpeechEngine (with AEC) has also used the mic. A
    // fresh engine per session sidesteps all of that.
    private var audioEngine = AVAudioEngine()
    private var silenceTimer: Timer?
    private var levelTimer: Timer?
    private var startedAt: Date = .distantPast
    private var autoSendOnSilence = false
    private var consecutiveSilentCaptures: Int = 0

    private let audioBuffer = WhisperAudioBuffer()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private var whisperKit: WhisperKit?
    private var whisperInitTask: Task<Void, Never>?

    // Whisper large-v3 (turbo) running 100% on-device via WhisperKit on the
    // Apple Neural Engine. This IS the free, open-source OpenAI Whisper model
    // (MIT licensed); "openai_whisper-..." is just its name, nothing calls any
    // OpenAI API and no audio leaves the Mac. large-v3 is a real accuracy jump
    // over medium.en (lower word-error rate, much better on accents, fast
    // speech, and uncommon proper nouns the user's own vocab list biases for).
    // The turbo variant keeps near-large-v3 accuracy at roughly 2x the decode
    // speed, so push-to-talk dictation stays snappy. The TranscriptCorrector
    // (Haiku) then repairs any single remaining mishear from context. To trade
    // accuracy for speed/size use "openai_whisper-medium.en"; for maximum
    // accuracy use "openai_whisper-large-v3". (large-v3 is multilingual; we
    // force English via DecodingOptions.language = "en".)
    private let modelName = "openai_whisper-large-v3_turbo"
    private let modelRepo = "argmaxinc/whisperkit-coreml"

    init() {
        whisperInitTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.initWhisper()
        }
    }

    private func initWhisper() async {
        WakeLog.shared.log("whisper: initializing (model=\(modelName), repo=\(modelRepo))")
        await MainActor.run { self.whisperStatus = "downloading/loading \(self.modelName)…" }
        do {
            let config = WhisperKitConfig(
                model: modelName,
                modelRepo: modelRepo,
                verbose: false,
                prewarm: true,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            await MainActor.run {
                self.whisperKit = kit
                self.whisperReady = true
                self.whisperStatus = "ready"
            }
            WakeLog.shared.log("whisper: READY")
        } catch {
            let msg = "whisper init FAILED: \(error.localizedDescription)"
            WakeLog.shared.log(msg)
            await MainActor.run {
                self.whisperStatus = "init failed: \(error.localizedDescription)"
            }
        }
    }

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start(autoSendOnSilence: Bool = false, prefix: [Float] = []) async {
        // MUTE MUST PREVENT, NOT ONLY STOP. MicController.mute() stops this
        // listener, but without this guard dictation takes the microphone
        // straight back while every surface still shows MUTED. Ambient and the
        // wake word have always checked; these two never did, which is the
        // reported "grux is still utilizing the mic" surviving the stop-side fix.
        if AppState.shared.micMuted {
            WakeLog.shared.log("voice input: refusing to start, micMuted")
            return
        }
        self.autoSendOnSilence = autoSendOnSilence
        error = nil
        needsMicSettings = false
        needsSpeechSettings = false
        transcript = ""
        audioBuffer.reset()

        // Barge-in path seeds us with the user's opening words (captured by
        // SpeechEngine's mic ring buffer while Grux was still speaking). We
        // want those in the Whisper buffer BEFORE the engine-start call so
        // live samples append cleanly on top.
        if !prefix.isEmpty {
            prefix.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var sum: Float = 0
                for i in 0..<prefix.count { sum += prefix[i] * prefix[i] }
                let rms = prefix.isEmpty ? 0 : sqrt(sum / Float(prefix.count))
                audioBuffer.appendSamples(base, count: prefix.count, rms: rms)
            }
            WakeLog.shared.log("voice: seeded \(prefix.count) prefix samples (\(String(format: "%.2f", Double(prefix.count)/16000.0))s) from barge-in")
        }

        // Ambient mode may own the mic - pause it for this explicit dictation.
        if AmbientState.shared.isCapturing {
            AmbientListener.shared.pauseForExplicitInput()
        }

        // DO NOT activate Grux here. This function is called from background
        // triggers (wake word + barge-in) while the user is working in another
        // app on another macOS Space. Activating would steal focus AND
        // switch their visible Space to wherever Grux's chat window lives.
        // The mic permission prompt (requestAccess below) fires as a
        // system-modal dialog regardless of frontmost status, so no
        // activation is needed to surface it.

        // Mic authorization - single source of truth in MicController so
        // cdhash-rebind regressions (prompt reappears despite prior grant)
        // are logged in wake.log and not silently reprompted at every edge.
        guard await MicController.ensureAuthorized() else {
            error = "Microphone denied. Open Settings → Privacy → Microphone and enable Grux, then tap the mic again."
            needsMicSettings = true
            return
        }

        // Make sure WhisperKit is ready before recording. If init was never
        // kicked off (shouldn't happen), start it now.
        if whisperInitTask == nil {
            whisperInitTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.initWhisper()
            }
        }
        if whisperKit == nil {
            WakeLog.shared.log("whisper: waiting for model before recording…")
            _ = await whisperInitTask?.value
        }
        guard whisperKit != nil else {
            error = "Whisper model not loaded. Check network for first-run download."
            return
        }

        // RE-CHECK AFTER THE SUSPENSIONS. The mute guard at the top of this
        // function ran before a TCC prompt and a Whisper model load, and the
        // first-run download of that model is measured in tens of seconds. A
        // mute during it must win, or dictation takes the microphone back while
        // every surface reads MUTED.
        if AppState.shared.micMuted {
            WakeLog.shared.log("voice input: aborting start - muted during setup")
            return
        }

        // Rebuild the audio engine fresh every session. Reusing a stopped
        // engine after SpeechEngine has touched the mic can leave the HAL
        // in a wedged state where taps never fire or deliver silence.
        audioEngine = AVAudioEngine()

        // Mic tap pipeline:
        //   1) explicit channel averaging (AVAudioConverter's default multi→mono
        //      silently picks channel 0 which is often muted on aggregate
        //      devices like AirPods + built-in mic),
        //   2) AVAudioConverter for sample-rate conversion only (mono→mono).
        // This handles any native rate (24k / 44.1k / 48k / 96k) cleanly.
        let input = audioEngine.inputNode

        // Premium noise cancellation: Apple's hardware voice processing I/O
        // (AEC + noise suppression + AGC). Great for the built-in mic BUT
        // turning it on here forces system-wide output to comm-mode codec
        // (tinny mono) for the duration of dictation. For mics the user has
        // whitelisted as "preserve fidelity" (e.g. DJI Mic Mini - already
        // has excellent on-device DSP), we skip VPIO entirely.
        MicWhitelist.autoWhitelistKnownExternalMics()
        MicWhitelist.applyPreferredInputIfPossible()
        let activeInputUID = MicDevices.systemDefaultInputUID() ?? ""
        let bypassVPIO = MicWhitelist.isWhitelisted(uid: activeInputUID)
        if AppState.shared.config.premiumNoiseCancellation && !bypassVPIO {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Don't bypass - we want the chain active.
                input.isVoiceProcessingBypassed = false
                // Ducking off: other-app audio pausing mid-command is jarring.
                // AGC on for normalized levels into Whisper.
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false,
                            duckingLevel: .min
                        )
                }
                input.isVoiceProcessingAGCEnabled = true
                input.isVoiceProcessingInputMuted = false
                WakeLog.shared.log("voice: premium noise cancellation ENABLED (hw AEC + NS + AGC) for \(activeInputUID)")
            } catch {
                WakeLog.shared.log("voice: premium noise cancellation unavailable (\(error.localizedDescription)); using software pipeline")
            }
        } else if bypassVPIO {
            WakeLog.shared.log("voice: VPIO BYPASSED (whitelisted mic \(activeInputUID)) - speakers stay full-fidelity")
        }
        let nativeFormat = input.outputFormat(forBus: 0)
        let nativeRate = nativeFormat.sampleRate
        let channelCount = Int(nativeFormat.channelCount)
        WakeLog.shared.log("whisper capture: native=\(Int(nativeRate))Hz ch=\(channelCount) → 16000Hz mono")

        guard let nativeMonoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nativeRate,
            channels: 1,
            interleaved: false
        ) else {
            error = "Failed to build intermediate mono format."
            return
        }
        guard let srConverter = AVAudioConverter(from: nativeMonoFormat, to: targetFormat) else {
            error = "Audio sample-rate converter unavailable."
            return
        }

        input.removeTap(onBus: 0)
        let buffer = audioBuffer
        let target = targetFormat
        let monoFmt = nativeMonoFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [buffer, channelCount, srConverter, monoFmt, target] inBuf, _ in
            VoiceInput.downmixAndResample(
                inBuf: inBuf,
                channels: channelCount,
                monoFormat: monoFmt,
                converter: srConverter,
                target: target,
                buffer: buffer
            )
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            let ns = error as NSError
            NSLog("[Grux] audio engine start failed: %@ / code %d", ns.domain, ns.code)
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .denied || status == .restricted || status == .notDetermined {
                self.error = "Microphone access needed. Open Settings → Privacy → Microphone and enable Grux."
                self.needsMicSettings = true
            } else {
                self.error = "Audio engine failed: \(error.localizedDescription)"
            }
            return
        }

        isRecording = true
        liveLevel = 0
        startedAt = Date()
        startLevelPump()
        if self.autoSendOnSilence { startSilenceTimer() }
    }

    /// Step 1: average all input channels into a single mono buffer at the
    /// native sample rate. Step 2: hand that mono buffer to AVAudioConverter
    /// which does proper sample-rate conversion (arbitrary ratios supported).
    /// Writes 16kHz Float32 mono to the Whisper buffer + updates RMS for VAD.
    nonisolated static func downmixAndResample(
        inBuf: AVAudioPCMBuffer,
        channels: Int,
        monoFormat: AVAudioFormat,
        converter: AVAudioConverter,
        target: AVAudioFormat,
        buffer: WhisperAudioBuffer
    ) {
        let n = Int(inBuf.frameLength)
        buffer.noteTapInvocation(framesIn: n)
        guard let inData = inBuf.floatChannelData else { return }
        guard n > 0, channels > 0 else { return }

        // 1) Downmix to mono at native rate
        guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)) else {
            WakeLog.shared.log("voice: downmix alloc failed (monoBuf, n=\(n))")
            return
        }
        monoBuf.frameLength = AVAudioFrameCount(n)
        guard let mono = monoBuf.floatChannelData?[0] else {
            WakeLog.shared.log("voice: downmix mono channel data missing")
            return
        }
        let invC = 1.0 / Float(channels)
        for i in 0..<n {
            var sum: Float = 0
            for c in 0..<channels { sum += inData[c][i] }
            mono[i] = sum * invC
        }

        // 2) Sample-rate convert to 16kHz mono
        let rate = monoFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(n) * (target.sampleRate / rate) + 128)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            WakeLog.shared.log("voice: resample alloc failed (outBuf)")
            return
        }
        var consumed = false
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return monoBuf
        }
        if status == .error || convErr != nil {
            WakeLog.shared.log("voice: resample failed (status=\(status.rawValue), err=\(convErr?.localizedDescription ?? "nil"))")
            return
        }
        guard let outPtr = outBuf.floatChannelData?[0] else {
            WakeLog.shared.log("voice: resample output channel data missing")
            return
        }
        let outCount = Int(outBuf.frameLength)
        guard outCount > 0 else { return }

        var sumSquares: Float = 0
        for i in 0..<outCount { sumSquares += outPtr[i] * outPtr[i] }
        let rms = sqrt(sumSquares / Float(outCount))
        buffer.appendSamples(outPtr, count: outCount, rms: rms)
    }

    func stop() {
        silenceTimer?.invalidate(); levelTimer?.invalidate()
        silenceTimer = nil; levelTimer = nil
        // READING `inputNode` BUILDS IT. It is a lazy property on AVAudioEngine
        // that instantiates the node and queries the current input hardware, so
        // the old unguarded version touched the microphone stack every time
        // anything called stop() defensively, including MicController.mute() on
        // an install where dictation had never run once.
        //
        // Nothing below this line is meaningful when no session was recording:
        // there is no tap to remove, no engine running, and ambient was never
        // paused for us, so resuming it would be resuming something we did not
        // suspend.
        guard isRecording else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false
        liveLevel = 0

        // If ambient was paused for this session, resume it now.
        if AmbientState.shared.isEnabled {
            AmbientListener.shared.resumeFromExplicitInput()
        }

        let dbg = audioBuffer.debugCounts()
        let drained = audioBuffer.drain()
        let samples = drained.samples
        // Require at least 0.3s of audio before transcribing
        if samples.count > 16000 * 3 / 10 {
            WakeLog.shared.log(String(format: "whisper: captured %d samples (%.2fs) peak=%.3f  [taps=%d framesIn=%d]",
                                      samples.count, Double(samples.count)/16000.0, Double(drained.peak),
                                      dbg.taps, dbg.framesIn))
            Task { await self.transcribe(samples: samples, peak: drained.peak) }
        } else {
            WakeLog.shared.log("whisper: skipped transcribe (only \(samples.count) samples) [taps=\(dbg.taps) framesIn=\(dbg.framesIn)]")
            NotificationCenter.default.post(name: .gruxVoiceInputDidStop, object: nil)
        }
    }

    private func startLevelPump() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let snap = self.audioBuffer.snapshot()
                // Normalize: typical speech RMS ~0.03-0.15 → map to 0..1
                self.liveLevel = min(1, snap.rms * 6)
            }
        }
    }

    private func transcribe(samples: [Float], peak: Float) async {
        guard let kit = whisperKit else {
            NotificationCenter.default.post(name: .gruxVoiceInputDidStop, object: nil)
            return
        }
        await MainActor.run { self.isTranscribing = true }
        let seconds = Double(samples.count) / 16000.0

        // Early out: if the peak amplitude is effectively zero the mic didn't
        // capture anything. Don't waste a transcription and don't send junk.
        if peak < 0.002 {
            consecutiveSilentCaptures += 1
            WakeLog.shared.log(String(format: "whisper: skipped (mic silent, peak=%.4f, %.2fs, run=%d)",
                                      Double(peak), seconds, consecutiveSilentCaptures))
            await MainActor.run {
                self.isTranscribing = false
                self.transcript = ""
                // 1st-2nd silent capture: neutral nudge. 3rd+: escalate to settings guidance.
                if self.consecutiveSilentCaptures >= 3 {
                    self.error = "Microphone returned silence three times in a row. Check System Settings → Sound → Input and verify your mic is selected and unmuted."
                } else {
                    self.error = "Didn't catch that - try speaking closer to the mic."
                }
                NotificationCenter.default.post(name: .gruxVoiceInputDidStop, object: nil)
            }
            return
        }

        WakeLog.shared.log("whisper: transcribing \(samples.count) samples (\(String(format: "%.2f", seconds))s)")
        let t0 = Date()
        // Build a fresh vocab prompt per call so newly-taught slang is picked
        // up immediately. Tokenizer lookup is cheap on WhisperKit.
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
            let raw = results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = Self.stripWhisperSpecials(raw)
            let text = Self.stripWakePrefix(stripped)
            let elapsed = Date().timeIntervalSince(t0)
            let display = text.isEmpty ? "(blank/hallucinated)" : text
            WakeLog.shared.log(String(format: "whisper heard in %.2fs: %@ (raw: %@)", elapsed, display, raw))
            // Reject hallucinated transcripts before they can be auto-sent. The
            // vocab roster fed to Whisper as a decoding prompt can echo back as
            // a looped run of roster terms with no glue words between them, on a
            // near-silent or noisy capture. Auto-sending that garbage made Grux
            // message itself, and the repeat then tripped a false "you're
            // looping, you okay?" reply. Drop it instead.
            let rosterWords = await MainActor.run { WhisperVocab.rosterWordSet() }
            let isHallucinated = Self.looksLikeRepeatedHallucination(text)
                || Self.looksLikeRosterEcho(text, roster: rosterWords)
            if isHallucinated {
                await MainActor.run {
                    self.consecutiveSilentCaptures = 0
                    WakeLog.shared.log("whisper: rejected repeated/hallucinated transcript: \(text.prefix(70))")
                    self.transcript = ""
                    self.isTranscribing = false
                    self.error = "Didn't catch that clearly - try again."
                    NotificationCenter.default.post(name: .gruxVoiceInputDidStop, object: nil)
                }
                return
            }
            // Repair obvious mis-hearings (homophones, similar-sounding words, a
            // wrong brand name) using sentence context BEFORE the transcript
            // becomes a command, so one misheard word does not break the whole
            // thing. Best-effort + time-boxed: falls back to the raw text on any
            // failure, so it never blocks or worsens dictation.
            let finalText = await TranscriptCorrector.correct(text)
            await MainActor.run {
                self.consecutiveSilentCaptures = 0
                self.transcript = finalText
                self.isTranscribing = false
                if self.autoSendOnSilence && !finalText.isEmpty {
                    self.autoSendRequested = true
                }
                NotificationCenter.default.post(name: .gruxVoiceInputDidStop, object: nil)
            }
        } catch {
            WakeLog.shared.log("whisper transcribe FAILED: \(error.localizedDescription)")
            await MainActor.run {
                self.isTranscribing = false
                self.error = "Transcription failed: \(error.localizedDescription)"
                NotificationCenter.default.post(name: .gruxVoiceInputDidStop, object: nil)
            }
        }
    }

    /// WhisperKit surfaces special tags like `[BLANK_AUDIO]`, `[INAUDIBLE]`,
    /// `<|nospeech|>`, `(silence)`, etc. when the model decides the audio has
    /// no speech. Strip all of those + common music-video hallucinations
    /// ("thanks for watching"). Returns "" when the transcript is pure noise.
    private static func stripWhisperSpecials(_ s: String) -> String {
        var out = s
        // Drop [TAG] and <|tag|> style markers.
        out = out.replacingOccurrences(of: #"\[[A-Z_ ]+\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<\|[^>]*\|>"#, with: "", options: .regularExpression)
        // Drop bracketed onomatopoeia.
        out = out.replacingOccurrences(of: #"\((?:silence|music|applause|laughter|inaudible)\)"#,
                                       with: "", options: [.regularExpression, .caseInsensitive])
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Known Whisper hallucinations on silence.
        let junk: Set<String> = [
            "thanks for watching.", "thanks for watching!", "thank you.", "thank you!",
            "you", ".", "..", "...", "bye.", "bye!"
        ]
        if junk.contains(out.lowercased()) { return "" }
        return out
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let snap = self.audioBuffer.snapshot()
                let now = Date()
                let sinceStart = now.timeIntervalSince(self.startedAt)
                let silentFor = now.timeIntervalSince(snap.lastVoiceAt)

                if snap.voicedEver && silentFor > 1.5 {
                    self.stop()
                    return
                }
                // No voice detected at all - give up after 10s
                if !snap.voicedEver && sinceStart > 10 {
                    WakeLog.shared.log("whisper: no voice detected in 10s, aborting")
                    self.stop()
                    return
                }
                // Hard cap at 28s to stay under buffer's 30s rolling window
                if sinceStart > 28 {
                    self.stop()
                    return
                }
            }
        }
    }

    /// Whisper often captures the tail of the wake phrase ("Hey Grox, …") because
    /// capture starts ~350ms after detection and the user is still speaking.
    /// Strip a leading "hey grux"-like fragment (same loose pattern as the
    /// wake regex) so the command sent to Claude is clean.
    private static let wakePrefixRegex: NSRegularExpression = {
        let pattern = #"^\s*(?:(?:hey|ok|okay|yo|hi|hay|aye|a)\s+)?gr[aeiouy]{1,3}[a-z]{0,3}s?[\s,.!?:;-]*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func stripWakePrefix(_ s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let stripped = wakePrefixRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a transcript is an obvious decode hallucination: the same short
    /// phrase repeated back to back, or so few distinct words across a long
    /// transcript that it is clearly looping (the vocab-roster echo failure).
    /// Deliberately conservative so it never rejects real dictated speech.
    nonisolated static func looksLikeRepeatedHallucination(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard words.count >= 4 else { return false }

        // A phrase of 1...4 words repeating 3+ times consecutively (aligned).
        for win in 1...4 where words.count >= win * 3 {
            var run = 1
            var i = win
            while i + win <= words.count {
                if Array(words[i..<i + win]) == Array(words[i - win..<i]) {
                    run += 1
                    if run >= 3 { return true }
                } else {
                    run = 1
                }
                i += win
            }
        }

        // Long transcript with very few distinct words is looping garbage.
        if words.count >= 8 {
            let distinctRatio = Double(Set(words).count) / Double(words.count)
            if distinctRatio < 0.4 { return true }
        }
        return false
    }

    /// True when a transcript is the Whisper vocab-roster prompt echoed back: a
    /// run of roster terms with no command verb or glue word between them. A
    /// real command always carries non-roster words ("play <term>", "open
    /// <term>"), so we only reject when nearly EVERY significant word is a
    /// roster term. Conservative on purpose: a legit utterance with one
    /// ordinary word survives.
    nonisolated static func looksLikeRosterEcho(_ text: String, roster: Set<String>) -> Bool {
        guard !roster.isEmpty else { return false }
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        guard words.count >= 2 else { return false }
        let rosterHits = words.filter { roster.contains($0) }.count
        // 85%+ of words are roster terms and at least two of them: this is the
        // prompt list bleeding through, not something the user said.
        return rosterHits >= 2 && Double(rosterHits) / Double(words.count) >= 0.85
    }

    static func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openSpeechSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }
}
