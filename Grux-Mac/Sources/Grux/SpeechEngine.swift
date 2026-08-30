import Foundation
import AVFoundation

extension Notification.Name {
    static let gruxSpeechDidStart = Notification.Name("gruxSpeechDidStart")
    static let gruxSpeechDidStop = Notification.Name("gruxSpeechDidStop")
}

/// Output-only speech engine. Streams PCM_24000 Int16 from ElevenLabs and
/// plays it through an AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer
/// chain. Mic input is owned exclusively by AmbientListener (which enables
/// kAudioUnitSubType_VoiceProcessingIO - Apple's FaceTime-grade AEC + NS +
/// AGC) and by VoiceInput / WakeWordListener for explicit dictation. Barge-in
/// is intentionally not handled here - two AVAudioEngines fighting for the
/// same mic was the source of the silent-playback / wedged-engine class of
/// bugs. The user can interrupt by tapping the orb to mute, or speaking after
/// Grux finishes (the post-speech wake-window keeps the conversation open).
@MainActor
final class SpeechEngine: NSObject, ObservableObject {
    static let shared = SpeechEngine()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentVoiceName: String = "Brian"
    @Published private(set) var outputLevel: Float = 0   // 0..1 for UI waveform

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var playbackFormat: AVAudioFormat!

    /// Playback speed multiplier (1.0 = natural, 1.5 = 50% faster).
    /// Pitch stays natural because AVAudioUnitTimePitch time-stretches.
    /// Default used before config loads; real value comes from
    /// `AppState.shared.config.voicePlaybackRate` via `applyPlaybackRate()`.
    static let defaultPlaybackRate: Float = 1.5
    private var currentTask: Task<Void, Never>?
    private var scheduledFrames: Int64 = 0
    private var playedFrames: Int64 = 0
    // Player sampleTime at the moment the FIRST audio buffer of a session is
    // scheduled. The player is .play()-ing (rendering silence) from the instant
    // the engine starts, which is BEFORE the TTS fetch returns, so the render
    // clock accrues "pre-roll" silence equal to the fetch latency. We subtract
    // this baseline in awaitPlaybackEnd so the completion check fires at the true
    // end of audio instead of fetch-latency early (which clipped the last words).
    private var playbackBaselineFrames: Int64 = 0
    private var hasStartedEngine = false
    private var sessionId: UUID = UUID()
    private var lastScheduledEndHostTime: UInt64 = 0

    override init() {
        super.init()
        setup()
    }

    private func setup() {
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.rate = Self.clampedRate(Float(AppState.shared.config.voicePlaybackRate))
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!
        // player → timePitch → mixer. TimePitch time-stretches audio so pitch
        // stays natural even at rate=1.5.
        engine.connect(player, to: timePitch, format: playbackFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: playbackFormat)
    }

    // MARK: - Public API

    /// Live-update the TTS playback speed. Safe to call while speaking -
    /// AVAudioUnitTimePitch time-stretches so pitch stays natural.
    func applyPlaybackRate(_ rate: Double) {
        timePitch.rate = Self.clampedRate(Float(rate))
    }

    private static func clampedRate(_ r: Float) -> Float {
        min(max(r, 0.5), 2.5)
    }

    func speak(_ text: String) {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return }
        let state = AppState.shared
        // Offline mode forces system voice (AVSpeechSynthesizer, fully
        // on-device) by short-circuiting the ElevenLabs branch - cloud TTS is a
        // network feature. The existing system-voice fallback below handles it.
        let useEL = state.config.useElevenLabs && !state.elevenLabsKey.isEmpty && !state.offlineMode

        stop(reason: "new speak()")
        sessionId = UUID()
        let mySession = sessionId

        if useEL {
            WakeLog.shared.log("elevenlabs → \(cleaned.prefix(80))")
            isBuffering = true
            NotificationCenter.default.post(name: .gruxSpeechDidStart, object: nil)
            WakeWordListener.shared.suspendForSpeaking()
            startEngineIfNeeded()
            currentTask = Task { [weak self] in
                await self?.streamElevenLabs(text: cleaned, session: mySession)
            }
        } else {
            WakeLog.shared.log("system-tts → \(cleaned.prefix(80))")
            Speaker.shared.speak(cleaned)
        }
    }

    /// Queue an utterance to play only AFTER any current Grux speech, chat
    /// reply, or streaming session completes - so coach nudges never cut in
    /// mid-thought. If no quiet window arrives within `maxWaitSeconds`, the
    /// message is dropped (stale - a nudge about something that happened
    /// 30 seconds ago isn't useful anymore). A single polite-queue slot
    /// prevents stacking: if another polite utterance is already waiting,
    /// this one replaces it with the fresher text.
    func speakAfterCurrent(_ text: String, maxWaitSeconds: Double = 30) {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return }
        enqueuePoliteAction(maxWaitSeconds: maxWaitSeconds) { [weak self] in
            self?.speak(cleaned)
        }
    }

    /// Core polite-wait primitive. Queues an arbitrary closure to fire once
    /// the engine is quiet (no active speech, no chat in-flight, no active
    /// stream). Supports E2E tests that want to observe the wait→fire
    /// lifecycle without triggering real TTS.
    ///
    /// Single-slot semantics: a second call supersedes the first, and the
    /// older closure is guaranteed never to fire. If quiet doesn't arrive
    /// within `maxWaitSeconds`, the action is dropped.
    func enqueuePoliteAction(maxWaitSeconds: Double = 30, action: @escaping @MainActor () -> Void) {
        politeCancelPending()
        let myToken = UUID()
        politePendingToken = myToken

        Task { [weak self] in
            guard let self else { return }
            let start = Date()
            while true {
                let token = self.politePendingToken
                if token != myToken { return } // superseded by a newer enqueue
                let speaking = self.isSpeaking || self.isBuffering
                let thinking = AppState.shared.isThinking
                let streaming = self.streamingWorker != nil
                if !speaking && !thinking && !streaming { break }
                if Date().timeIntervalSince(start) > maxWaitSeconds {
                    WakeLog.shared.log("polite action stale - never got quiet in \(Int(maxWaitSeconds))s")
                    if self.politePendingToken == myToken { self.politePendingToken = nil }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard self.politePendingToken == myToken else { return }
            self.politePendingToken = nil
            // Small settle delay so the speech-stop event + any trailing
            // audio flush are truly done before the action claims the engine.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard self.politePendingToken == nil || self.politePendingToken == myToken else { return }
            action()
        }
    }

    // UUID-token gate for speakAfterCurrent so successive polite requests
    // don't stack - the most recent nudge wins and stale ones get dropped.
    private var politePendingToken: UUID?

    /// Read-only probe for tests/diagnostics: is a polite utterance queued
    /// and waiting for a quiet window?
    var hasPendingPoliteSpeak: Bool { politePendingToken != nil }

    /// Public cancel: drop any queued polite utterance. Safe to call at any
    /// time - if nothing is pending it's a no-op. Useful when the user
    /// starts a new conversation and a stale coach nudge shouldn't fire
    /// after Grux's upcoming reply.
    func cancelPendingPoliteSpeak() {
        politePendingToken = nil
    }

    private func politeCancelPending() {
        politePendingToken = nil
    }

    // MARK: - Streaming speech

    // Append a sentence to an active streaming speech session. First call
    // starts the engine and begins playback; subsequent calls fetch audio
    // for each chunk and schedule it on the SAME player so sentences play
    // continuously in order. Call `endStreaming()` when done.
    //
    // Lets ChatService start TTS on the first sentence Claude streams back
    // instead of waiting for the full reply - big perceived-latency win.
    private var streamingQueue: [String] = []
    private var streamingWorker: Task<Void, Never>?
    private var streamingFinalizeRequested = false
    private var streamingSession: UUID?

    func appendStreaming(_ text: String) {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return }
        let cfg = AppState.shared.config
        // Offline mode forces the on-device system-voice path (same guard as
        // speak()) so streamed replies never reach for cloud TTS.
        let useEL = cfg.useElevenLabs && !AppState.shared.elevenLabsKey.isEmpty && !AppState.shared.offlineMode
        if !useEL {
            // System TTS doesn't support append-style streaming well. Each
            // AVSpeechUtterance is queued independently, so fall back to
            // serial speaks (will still play in order because Speaker.swift
            // calls stopSpeaking(.immediate) which replaces the current
            // utterance - NOT ideal, but avoids breaking no-API-key paths).
            Speaker.shared.speak(cleaned)
            return
        }

        // Stale-worker recovery: if a previous streaming session is wedged
        // (worker still alive but the underlying engine isn't actually
        // running - happens when sys-audio-tap interrupts mid-playback and
        // the completion callback never fires), force a clean reset so the
        // new chat reply isn't dropped into a queue nobody's reading from.
        if streamingWorker != nil && !engine.isRunning {
            WakeLog.shared.log("appendStreaming: stale worker (engine stopped) - resetting")
            stop(reason: "stale streaming worker")
        }

        if streamingWorker == nil {
            // First chunk of a new streaming session. Stop whatever was
            // playing, start a fresh session. MUST happen before queue
            // append - stop() calls streamingQueue.removeAll().
            stop(reason: "new streaming session")
            sessionId = UUID()
            streamingSession = sessionId
            isBuffering = true
            streamingFinalizeRequested = false
            NotificationCenter.default.post(name: .gruxSpeechDidStart, object: nil)
            WakeWordListener.shared.suspendForSpeaking()
            startEngineIfNeeded()

            let sid = sessionId
            streamingWorker = Task { [weak self] in
                await self?.streamingLoop(session: sid)
            }
        }

        streamingQueue.append(cleaned)
    }

    // Signal that no more chunks are coming. Once the queue drains and the
    // last buffer plays through, the engine tears down.
    func endStreaming() {
        guard streamingWorker != nil else { return }
        streamingFinalizeRequested = true
    }

    private func streamingLoop(session: UUID) async {
        defer {
            Task { @MainActor in
                self.streamingWorker = nil
                self.streamingFinalizeRequested = false
                self.streamingSession = nil
            }
        }
        while true {
            if Task.isCancelled { return }
            if session != streamingSession { return }
            let next: String? = await MainActor.run {
                self.streamingQueue.isEmpty ? nil : self.streamingQueue.removeFirst()
            }
            guard let text = next else {
                // Queue empty. Are we done?
                let shouldFinalize = await MainActor.run { self.streamingFinalizeRequested }
                if shouldFinalize { break }
                // Wait briefly for more
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            await fetchAndSchedule(text: text, session: session)
        }
        // Wait for any remaining scheduled audio to drain, then stop.
        await awaitPlaybackEnd(session: session)
        await MainActor.run {
            if self.streamingSession == session {
                self.stop(reason: "streaming drained")
            }
        }
    }

    // Fetches ElevenLabs audio for `text` and schedules it on the player
    // without tearing the engine down after. Keeps playback continuous
    // across sentence boundaries.
    private func fetchAndSchedule(text: String, session: UUID) async {
        let cfg = AppState.shared.config
        let voiceId = cfg.elevenLabsVoiceId
        let modelId = cfg.elevenLabsModelId
        let apiKey = AppState.shared.elevenLabsKey
        var comp = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        comp.queryItems = [
            URLQueryItem(name: "output_format", value: "pcm_24000"),
            URLQueryItem(name: "optimize_streaming_latency", value: "3")
        ]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.45,
                "similarity_boost": 0.8,
                "style": 0.15,
                "use_speaker_boost": true
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        do {
            let t0 = Date()
            let (data, resp) = try await URLSession.shared.data(for: req)
            if Task.isCancelled || session != streamingSession { return }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let errBody = String(data: data.prefix(300), encoding: .utf8) ?? ""
                WakeLog.shared.log("eleven stream HTTP \(http.statusCode): \(errBody)")
                return
            }
            let dt = Date().timeIntervalSince(t0)
            WakeLog.shared.log(String(format: "eleven stream: %d bytes in %.2fs for %d chars", data.count, dt, text.count))
            await MainActor.run {
                guard session == self.streamingSession else { return }
                self.scheduleFullBuffer(data: data)
                self.isBuffering = false
                self.isSpeaking = true
            }
        } catch is CancellationError {
            return
        } catch {
            WakeLog.shared.log("eleven stream error: \(error.localizedDescription)")
        }
    }

    func stop(reason: String = "user") {
        currentTask?.cancel()
        currentTask = nil
        // Tear down any in-flight streaming session too. Without this, a
        // streaming worker stuck in awaitPlaybackEnd (sys-audio-tap glitch
        // mid-playback can leave the player's completion callback never
        // firing) holds streamingWorker non-nil forever, so subsequent
        // appendStreaming calls just queue text that never gets fetched.
        streamingWorker?.cancel()
        streamingWorker = nil
        streamingFinalizeRequested = false
        streamingSession = nil
        streamingQueue.removeAll()
        if player.isPlaying { player.stop() }
        player.reset()
        if engine.isRunning { engine.stop() }
        // Always reset hasStartedEngine - even when engine.isRunning is false,
        // because macOS audio-route changes / sys-audio-tap interruptions can
        // silently stop the engine. If we leave the flag true, the next
        // startEngineIfNeeded() bails via its `guard !hasStartedEngine` and we
        // schedule audio onto a dead player → no sound, awaitPlaybackEnd hangs.
        hasStartedEngine = false
        let wasSpeaking = isSpeaking || isBuffering
        isSpeaking = false
        isBuffering = false
        outputLevel = 0
        scheduledFrames = 0
        playedFrames = 0
        playbackBaselineFrames = 0
        if wasSpeaking {
            WakeLog.shared.log("speech stop (\(reason))")
            NotificationCenter.default.post(name: .gruxSpeechDidStop, object: nil)
            WakeWordListener.shared.resumeAfterSpeaking()
        }
    }

    // MARK: - Engine lifecycle

    private func startEngineIfNeeded() {
        guard !hasStartedEngine else { return }
        do {
            engine.prepare()
            try engine.start()
            hasStartedEngine = true
            if !player.isPlaying { player.play() }
            WakeLog.shared.log("speech engine started (out=\(playbackFormat!.sampleRate))")
        } catch {
            WakeLog.shared.log("speech engine start FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - ElevenLabs streaming

    private func streamElevenLabs(text: String, session: UUID) async {
        let cfg = AppState.shared.config
        let voiceId = cfg.elevenLabsVoiceId
        let modelId = cfg.elevenLabsModelId
        let apiKey = AppState.shared.elevenLabsKey

        // Use non-streaming endpoint for simplicity + reliability; latency for
        // short replies is ~700ms-1.2s with turbo v2.5. Upgrade to streaming
        // WebSocket later if needed.
        var comp = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        comp.queryItems = [
            URLQueryItem(name: "output_format", value: "pcm_24000"),
            URLQueryItem(name: "optimize_streaming_latency", value: "3")
        ]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.45,
                "similarity_boost": 0.8,
                "style": 0.15,
                "use_speaker_boost": true
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        do {
            let t0 = Date()
            let (data, response) = try await URLSession.shared.data(for: req)
            if Task.isCancelled || session != sessionId { return }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let errBody = String(data: data.prefix(400), encoding: .utf8) ?? ""
                WakeLog.shared.log("elevenlabs HTTP \(http.statusCode): \(errBody)")
                self.stop(reason: "elevenlabs \(http.statusCode)")
                Speaker.shared.speak(text)
                return
            }
            let dt = Date().timeIntervalSince(t0)
            WakeLog.shared.log(String(format: "elevenlabs fetched %d bytes in %.2fs", data.count, dt))

            self.scheduleFullBuffer(data: data)
            // Fan the same PCM bytes out to the iPhone companion. The
            // TTSBroadcaster subscriber list is usually 0 or 1 - no cost
            // when no phone is paired. Bracketed by speakStart / speakEnd
            // so the phone mutes its mic during playback (echo prevention).
            TTSBroadcaster.shared.speakStart()
            TTSBroadcaster.shared.feedPCM24(data)
            self.isBuffering = false
            self.isSpeaking = true

            await self.awaitPlaybackEnd(session: session)
            TTSBroadcaster.shared.speakEnd()
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession throws URLError.cancelled (not Swift.CancellationError)
            // when Task.cancel() fires mid-request - happens any time a newer
            // speak() supersedes this one (coach nudge + chat reply overlap,
            // back-to-back wake responses, etc.). If we fell through to the
            // generic catch below it would pipe the cancelled text through
            // Speaker.shared.speak() in the system default voice - which is
            // exactly the "COACH sounds like the Mac voice" bug.
            return
        } catch {
            WakeLog.shared.log("elevenlabs error: \(error.localizedDescription) - falling back to system TTS")
            self.stop(reason: "elevenlabs error")
            Speaker.shared.speak(text)
        }
    }

    private func scheduleFullBuffer(data: Data) {
        guard hasStartedEngine else { return }
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                             frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let dst = buffer.floatChannelData?[0] else { return }
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                dst[i] = Float(base[i]) / 32768.0
            }
        }
        // Peak for UI waveform
        var peak: Float = 0
        for i in 0..<sampleCount { peak = max(peak, abs(dst[i])) }
        outputLevel = min(1, peak * 1.4)

        // First audio buffer of this session: snapshot the render clock so the
        // pre-roll silence the player rendered while waiting on the TTS fetch is
        // baselined out of the completion check (see playbackBaselineFrames).
        if scheduledFrames == 0 {
            if let lastRender = player.lastRenderTime,
               let pt = player.playerTime(forNodeTime: lastRender) {
                playbackBaselineFrames = pt.sampleTime
            } else {
                playbackBaselineFrames = 0
            }
        }

        scheduledFrames += Int64(sampleCount)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playedFrames += Int64(sampleCount)
            }
        }
    }

    // How a playback wait ended, so the caller can size the tail drain.
    private enum PlaybackEndReason {
        case playedBack   // .dataPlayedBack confirmed the last buffer (accurate)
        case renderClock  // render-clock backstop fired (callback was flaky)
        case timeout      // wall-clock cap (device interrupted mid-utterance)
    }

    // Wall-clock tail to drain before teardown. The render clock reports frames
    // PULLED into the pipeline; when it trips the audio is still in flight
    // through the time-pitch unit AND the output device, so stopping right then
    // clips the last word. Drain that pipeline first. Built-in output is a few
    // ms; Bluetooth (AirPods) is 150-300ms. We read the device + time-pitch
    // latency and clamp so we never clip the tail yet never hang noticeably
    // after the last word. At rate=1.5 a clipped tail eats 1.5x as many source
    // words, so erring long here is the safe direction.
    private func pipelineTailDrainSeconds() -> Double {
        let outputLatency = engine.outputNode.presentationLatency          // device output (incl. Bluetooth)
        let pitchLatency = timePitch.auAudioUnit.latency                   // time-stretch processing latency
        let raw = outputLatency + pitchLatency + 0.18                      // safety margin
        return min(max(raw, 0.30), 0.80)
    }

    private func awaitPlaybackEnd(session: UUID) async {
        // Completion is driven by TWO signals with a clear priority:
        //
        // 1. PRIMARY - `playedFrames`, incremented by the `.dataPlayedBack`
        //    buffer-completion callback. This is the accurate signal: it fires
        //    when the data has actually played through the FULL pipeline
        //    (time-pitch + output device + Bluetooth latency all included), so
        //    when it confirms the last buffer we can tear down with only a hair
        //    of slack and never clip the tail.
        //
        // 2. BACKSTOP - `player.lastRenderTime` / `playerTime(forNodeTime:)`,
        //    the render clock. `pt.sampleTime` counts frames PULLED into the
        //    render pipeline, which runs AHEAD of what the speaker has actually
        //    played by the time-pitch + output latency. It keeps ticking even
        //    when the .dataPlayedBack callback stalls (the documented
        //    VoiceProcessingIO case), so it is our backstop - but because it
        //    runs ahead we must NOT stop the instant it trips. We give the
        //    accurate callback a grace window to confirm, and if it never does
        //    we exit via the backstop and drain a full pipeline-latency tail.
        //
        // Earlier this was "whichever trips first wins" with a fixed 250ms
        // slack. The render clock almost always tripped first, and 250ms did not
        // cover the time-pitch + Bluetooth output latency, so the last word(s)
        // got clipped. Preferring the accurate callback, and sizing the tail
        // drain to the real pipeline latency on the backstop path, fixes that.
        //
        // Wall-clock backstop: when sys-audio-tap interrupts the playback device
        // mid-utterance, BOTH the callback AND lastRenderTime stop advancing, so
        // neither completion path trips. Cap total wait at 2x expected duration
        // plus 5s slack so we exit cleanly and the next reply can start fresh.
        let waitStart = Date()
        var renderClockDoneAt: Date? = nil
        let callbackGrace = 0.25   // window for the accurate callback to confirm after the render clock completes
        var reason: PlaybackEndReason = .timeout
        while true {
            if Task.isCancelled || session != sessionId { return }
            try? await Task.sleep(nanoseconds: 60_000_000)   // tight poll so we stop promptly after the true end

            // Wall-clock cap evaluated FIRST so we always exit even if
            // scheduledFrames never grows (eg fetch failed / queue stayed
            // empty). When we have frames, scale the cap to expected
            // duration; when we don't, use a fixed 10s nothing-happened cap.
            let elapsed = Date().timeIntervalSince(waitStart)
            let cap: Double
            if scheduledFrames > 0 {
                let expected = Double(scheduledFrames) / 24000.0
                cap = max(expected * 2.0 + 5.0, 10.0)
            } else {
                cap = 10.0
            }
            if elapsed > cap {
                WakeLog.shared.log(String(format: "awaitPlaybackEnd timeout: %.1fs > cap %.1fs (scheduled=%d played=%d, engine.isRunning=%@)", elapsed, cap, scheduledFrames, playedFrames, engine.isRunning ? "true" : "false"))
                reason = .timeout
                break
            }

            guard scheduledFrames > 0 else { continue }

            // PRIMARY: accurate end-of-playback. Already accounts for the full
            // pipeline + output latency, so we exit immediately.
            if playedFrames >= scheduledFrames { reason = .playedBack; break }

            // BACKSTOP: render clock shows all frames pulled. `sampleTime` is
            // baselined by the pre-roll silence captured at the first buffer, so
            // (sampleTime - baseline) is the count of REAL audio frames pulled.
            // Do NOT stop the instant it crosses scheduledFrames; give the
            // accurate callback a grace window to confirm. Only fall through to
            // the backstop exit if the callback never catches up (the dead
            // VoiceProcessingIO case, where played stays 0 the whole utterance).
            if let lastRender = player.lastRenderTime,
               let pt = player.playerTime(forNodeTime: lastRender),
               (pt.sampleTime - playbackBaselineFrames) >= scheduledFrames {
                if renderClockDoneAt == nil { renderClockDoneAt = Date() }
                if Date().timeIntervalSince(renderClockDoneAt!) >= callbackGrace {
                    reason = .renderClock
                    break
                }
            }
        }
        // Drain the right amount of tail before teardown:
        //  - playedBack: the data already finished playing, just a hair of slack.
        //  - renderClock: audio is still in the time-pitch + output pipeline,
        //    drain a full latency-sized tail or the last word clips.
        //  - timeout: device is wedged, nothing left to drain.
        let drain: Double
        let reasonLabel: String
        switch reason {
        case .playedBack:  drain = 0.08; reasonLabel = "playedBack"
        case .renderClock: drain = pipelineTailDrainSeconds(); reasonLabel = "renderClock"
        case .timeout:     drain = 0.0; reasonLabel = "timeout"
        }
        var renderPos: Int64 = -1
        if let lastRender = player.lastRenderTime, let pt = player.playerTime(forNodeTime: lastRender) {
            renderPos = pt.sampleTime - playbackBaselineFrames
        }
        WakeLog.shared.log(String(format: "awaitPlaybackEnd done: reason=%@ played=%d/%d renderPos=%d baseline=%d drain=%.2fs", reasonLabel, playedFrames, scheduledFrames, renderPos, playbackBaselineFrames, drain))
        if drain > 0 {
            try? await Task.sleep(nanoseconds: UInt64(drain * 1_000_000_000))
        }
        if session == sessionId { stop(reason: "natural end") }
    }

    // MARK: - Voice catalog

    func fetchVoices() async -> [ElevenLabsVoice] {
        let apiKey = AppState.shared.elevenLabsKey
        guard !apiKey.isEmpty else { return [] }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                WakeLog.shared.log("voices HTTP \(http.statusCode)")
                return []
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["voices"] as? [[String: Any]] else { return [] }
            return arr.compactMap { v in
                guard let vid = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
                let cat = v["category"] as? String ?? "premade"
                let desc = (v["labels"] as? [String: String])?.values.joined(separator: ", ")
                return ElevenLabsVoice(voiceId: vid, name: name, category: cat, description: desc)
            }
        } catch {
            return []
        }
    }

    // MARK: - Helpers

    private static let stageDirectionLineRegex: NSRegularExpression = {
        // Matches a whole line that's just a screenplay heading or visual-blocking cue.
        // Caller anchors per-line; pattern is deliberately narrow so prose like
        // "the orb glows" inside a real sentence doesn't get nuked.
        let p = #"^\s*(?:scene\s+\d+\b[^\n]*|beat\.?|fade\s+(?:in|out|to)\b[^\n]*|cut\s+to\b[^\n]*|pillar\s+\d+\b[^\n]*|(?:orb|waveform|card|screen|gold\s+card|terminal\s+window|memory\s+card)\s+(?:blooms?|shifts?|pulses?|fades?|animates?|appears?|slides?|glows?|returns?)\b[^\n]*|pause\s+for\s+effect\b[^\n]*|let\s+the\s+screen\s+settle\b[^\n]*|narration[,:].*|address\s+complete\.?)\s*$"#
        return try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }()

    private static func clean(_ s: String) -> String {
        var out = s
        if out.hasPrefix("⚠️") { out.removeFirst(1) }
        out = out.replacingOccurrences(of: "**", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .replacingOccurrences(of: "`", with: "")
        // Strip bracketed visual blocking ("[Orb pulses gently]") and parenthetical
        // acting notes ("(beat)"). Length-capped so a stray "[" from real prose
        // can't eat the rest of the reply.
        out = out.replacingOccurrences(of: #"\[[^\]\n]{0,200}\]"#, with: "", options: .regularExpression)
                 .replacingOccurrences(of: #"\([^)\n]{0,200}\)"#, with: "", options: .regularExpression)
        // Drop lines that are pure screenplay cues. Operates per-line so we keep
        // ordinary sentences that merely contain words like "scene" or "fade".
        let kept = out.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let str = String(line)
            let r = NSRange(str.startIndex..<str.endIndex, in: str)
            return stageDirectionLineRegex.firstMatch(in: str, options: [], range: r) == nil
        }
        out = kept.joined(separator: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
