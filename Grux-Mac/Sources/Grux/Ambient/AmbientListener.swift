import Foundation
import AVFoundation
import AppKit
import CoreAudio
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
    /// The model, loaded once and shared; a failed load is tried again on the next ask.
    private lazy var whisper = RetryableLoad<WhisperKit> { [modelName, modelRepo] in
        let cfg = WhisperKitConfig(
            model: modelName,
            downloadBase: WhisperModelStore.downloadBase,
            modelRepo: modelRepo,
            verbose: false,
            prewarm: true,
            load: true,
            download: WhisperModelStore.mayDownload
        )
        return try await WhisperKit(cfg)
    }
    private var whisperKit: WhisperKit? { whisper.value }
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
    /// Internal, not private, so a test can see a dry run left it alone.
    var wakeArmedUntil: Date = .distantPast
    private let wakeArmWindow: TimeInterval = 18
    private let conversationFollowUpWindow: TimeInterval = 30
    // Timestamp of the last Grux speech stop. Used to drop self-echo chunks
    // that leak in during the resume grace window.
    private var lastSpeechEndAt: Date = .distantPast
    private let postSpeechEchoGuardSeconds: TimeInterval = 2.5
    // Whether the engine last built by startEngine() asked for voice
    // processing. Compared when the default output device changes, so capture
    // restarts only when the decision actually flips.
    private var voiceProcessingDecision: Bool?
    /// Total samples the buffer had at the last growth check, and when it
    /// last actually grew. Drives the running deaf watchdog.
    private var lastAppendedEver: UInt64 = 0
    /// Measured on the MONOTONIC clock, not `Date`. `ProcessInfo.systemUptime`
    /// does not advance while the Mac is asleep, and `Date` does: with a wall
    /// clock, the first timer tick after an eight hour lid close reads
    /// "no new audio for 28800.0s" and reports a dead microphone on every
    /// single wake. A forward NTP step does the same with no fault at all.
    private var lastAudioGrowthUptime = ProcessInfo.processInfo.systemUptime
    /// True once `deafStartAction` has returned `.giveUp`, cleared the moment
    /// audio actually arrives again.
    ///
    /// WITHOUT THIS THE WATCHDOG DEFEATS `maxDeafRestarts`. `.giveUp` does not
    /// tear anything down: it sets the error and returns, leaving `running`
    /// true, the engine non-nil and the chunk timer alive. So eight seconds
    /// later the watchdog sees a live engine with no audio and calls
    /// `restartAfterDeafStart(attempt: 0)`, which starts the whole five step
    /// ladder over with a fresh count, forever. Measured shape on a genuinely
    /// dead input: a roughly 122 second cycle, six CoreAudio rebuilds and six
    /// mic-guard claims per cycle, with the orb flickering between Listening
    /// and Error instead of settling on the "Tap the orb to try again" state
    /// that `.giveUp` exists to produce.
    private var gaveUpOnDeafCapture = false

    /// Whether this listener's microphone is open while Grux's own voice plays.
    /// It is NOT, and the wiring below this line is what makes it false:
    /// `.gruxSpeechDidStart` calls `suspendForSpeech()`, which calls
    /// `tearDownCapture()`, which stops the engine AND resets the rolling
    /// buffer, and `resumeIfReady()` then waits 400ms after the reply ends
    /// before opening the mic again. Grux's reply cannot reach this engine,
    /// so Apple's echo canceller has nothing here to cancel.
    ///
    /// That matters because the cost is not free: measured 2026-09-23, another
    /// process capturing from the same microphone STOPS receiving audio the
    /// moment VPIO starts here, and `wake.log` carries 12 starts where voice
    /// processing came up and delivered nothing, each costing a 2.1s deaf
    /// window and a restart. `VoiceProcessingListenerTests` holds this whole
    /// chain: if ambient is ever changed to keep listening while Grux speaks,
    /// this constant is wrong and that test fails rather than silently
    /// shipping a listener that hears itself.
    nonisolated static let holdsMicWhileGruxSpeaks = false
    // Installed while running (start() to stop()), so AirPods connecting or
    // headphones unplugging mid-listen re-makes the voice processing call.
    private var outputRouteListening = false
    private var outputRouteDebounce: Task<Void, Never>?

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

    /// THE GAP THAT ENDS A SHORT UTTERANCE, which is how fast a spoken command
    /// can possibly be.
    ///
    /// Measured 2026-09-22 by saying "open my calendar" into the microphone
    /// nine times: 3.1 seconds from the end of the sentence to the decision
    /// being written, of which the decision itself was 450ms. The rest was
    /// this wait plus transcribing a buffer that had 1.6 seconds of silence
    /// on the end of it. Nobody is served by holding a finished command for a
    /// second and a half to see whether more words arrive.
    ///
    /// A conversational pause mid-sentence runs about 0.2 to 0.3 seconds, so
    /// 0.6 clears it comfortably while still being a gap a person can feel the
    /// end of. Long buffers keep the old threshold, because sustained speech
    /// is somebody talking rather than somebody instructing, and splitting
    /// that produces short chunks Whisper transcribes worse.
    ///
    /// Meeting capture is unaffected: `MeetingCaptureService` calls
    /// `pauseForMeeting()` and runs its own buffer, sharing only the model.
    private let commandSilenceFlushSeconds: TimeInterval = 0.6
    /// Speech this short is a command, not a conversation. NOT the buffer
    /// length: the buffer carries room silence from before anyone spoke.
    private let commandWindowSeconds: Double = 3.5

    /// Which silence gap ends this chunk. Pure, so the numbers are held by a
    /// test instead of living only in a condition.
    nonisolated static func flushSilenceThreshold(spokenSeconds: Double,
                                                  commandWindow: Double,
                                                  commandGap: TimeInterval,
                                                  conversationGap: TimeInterval) -> TimeInterval {
        spokenSeconds <= commandWindow ? commandGap : conversationGap
    }

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
        installOutputRouteListener()
        WakeLog.shared.log("ambient: STARTED")
    }

    func stop() {
        running = false
        // Stopped is not deaf: muted and off have their own words.
        MicHealth.shared.set(notHearing: false)
        removeOutputRouteListener()
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
        ListeningMicGuard.shared.release("ambient")
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
        // Not a release: this is a blip inside one listening session, and
        // handing the input back and forth per utterance would switch the
        // person's device twice every time Grux speaks.
        tearDownCapture(reason: "Grux is speaking", releaseMic: false)
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
    private func tearDownCapture(reason: String, releaseMic: Bool = true) {
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
        if releaseMic { ListeningMicGuard.shared.release("ambient") }
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
        if await whisper.get() != nil {
            AmbientState.shared.whisperReady = true
            WakeLog.shared.log("ambient: whisper READY")
        } else if let error = whisper.lastFailure {
            AmbientState.shared.error = "Whisper init failed: \(error.localizedDescription)"
            WakeLog.shared.log("ambient: whisper init FAILED \(error)")
        }
    }

    /// Why the last model load failed, or nil after a success or before any load.
    var whisperLoadFailure: String? { whisper.lastFailure?.localizedDescription }

    // MARK: - Engine

    /// What to do two seconds after a start, from how much audio arrived.
    ///
    /// A start that hears nothing restarts, later each time, and gives up only
    /// after `maxDeafRestarts`, about a minute and a half of trying. Measured
    /// 2026-09-21: the restarts after Grux spoke came up deaf at 11:42 AM and
    /// 1:08 PM and stayed deaf until relaunch, because the check only logged;
    /// and at 2:24 PM three starts running were deaf and the first version of
    /// this gave up after two restarts, while the fault was transient (a fresh
    /// process ten minutes later heard fine). Every one of those deaf starts
    /// had voice processing on, and Core Audio logged why: the voice
    /// processing IO would not start. So a deaf start with it on also marks
    /// `VoiceProcessingRefusal`, and the restarts run without it.
    enum DeafStartAction: Equatable {
        case hearing
        case restart(afterSeconds: Double)
        case giveUp
    }

    static let maxDeafRestarts = 5
    nonisolated static let deafRestartDelays: [Double] = [1, 2, 10, 30, 60]

    /// How long the tap may deliver NOTHING, while the engine is up and
    /// capturing, before the capture is treated as dead.
    ///
    /// MEASURED 2026-09-23, and this is the incident that put it here. Grux
    /// ran for 1h40m reporting `ambientCapturing = true` with every surface
    /// saying it was listening, while `wake.log` showed the same line every
    /// five seconds:
    ///
    ///     ambient vad: buf=1.8s spoken=0.0s rms=0.0000 peak=0.000 voiced=N
    ///
    /// A frozen buffer and an rms of exactly zero. A separate process
    /// capturing from the same microphone in the same moment got 120,000
    /// frames of real audio, so the device was fine and only Grux was deaf.
    ///
    /// Nothing caught it. `deafStartAction` runs ONCE, about two seconds
    /// after `startEngine`, so it only ever sees a start that was born deaf,
    /// never one that died later. `deadAirResetSeconds` could not catch it
    /// either: it fires when the buffer passes 12s with no voice, and a
    /// buffer frozen at 1.8s never gets there.
    ///
    /// Eight seconds is well past any legitimate gap. The tap fires on every
    /// hardware buffer regardless of whether anyone is speaking, so silence
    /// still arrives as samples; zero NEW SAMPLES for eight seconds is not a
    /// quiet room, it is a dead tap.
    static let captureStallSeconds: Double = 8.0

    /// Whether a capture that has delivered no new samples for `stalledFor`
    /// should be treated as dead. Pure so the threshold is testable without
    /// an audio device.
    nonisolated static func captureIsStalled(noNewAudioFor stalledFor: TimeInterval,
                                             threshold: Double = captureStallSeconds) -> Bool {
        stalledFor >= threshold
    }

    nonisolated static func deafStartAction(heardSeconds: Double, attempt: Int) -> DeafStartAction {
        guard heardSeconds <= 0 else { return .hearing }
        guard attempt < maxDeafRestarts else { return .giveUp }
        return .restart(afterSeconds: deafRestartDelays[min(attempt, deafRestartDelays.count - 1)])
    }

    /// Whether the tell should read NOT HEARING after a deaf start: not on the
    /// first, which a restart one second later usually cures, so the orb does
    /// not flicker; from the second deaf start in a row on.
    nonisolated static func tellsNotHearing(afterDeafAttempt attempt: Int) -> Bool { attempt >= 1 }

    /// The orb, tapped while not hearing: start over now, with a fresh count.
    func retryNow() {
        guard running else { return }
        restartAfterDeafStart(attempt: 0, afterSeconds: 0.2)
    }

    /// `deafAttempt` counts restarts made because the previous start heard
    /// nothing. Every other caller starts a fresh count at zero.
    private func startEngine(deafAttempt: Int = 0) throws {
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
        // FaceTime / Phone use kAudioUnitSubType_VoiceProcessingIO under the
        // hood - Apple's hardware-level AEC + noise suppression + AGC. Great
        // for laptop built-in mics (cancels Music/YouTube out of the mic so
        // we never transcribe lyrics as user utterances).
        //
        // WHAT ENABLING IT COSTS, corrected 2026-09-23. This comment used to
        // say it forced the whole system output chain into a narrow-band
        // "communications" codec and made Music, Safari and YouTube go
        // tinny-mono until the engine stopped. That was never measured and it
        // is false: a 12 kHz tone survived 73 dB above the noise floor while
        // VPIO ran, the output device stayed 48000 Hz 2ch 32bit lpcm, and a
        // playback-only app saw no disruption. The real cost lands on any
        // OTHER app that is RECORDING, whose microphone capture stops dead.
        // Ambient does not enable VPIO at all any more (see
        // holdsMicWhileGruxSpeaks above); this block is kept because the
        // policy, not the call site, is what decides.
        //
        // External mics like the DJI Mic Mini have strong on-device DSP and
        // don't need our VPIO; the whitelist lets the user mark specific mics
        // "skip VPIO - preserve full-fidelity output".
        MicWhitelist.applyPreferredInputIfPossible()
        // Off a borrowed device (headset, phone, AirPlay) before the engine
        // opens anything: holding one costs the person audio quality on it
        // for as long as Grux listens. Released in tearDownCapture.
        ListeningMicGuard.shared.claim("ambient")
        let activeInputUID = MicDevices.systemDefaultInputUID() ?? ""
        // THE ENGINE IS BUILT AFTER THE MIC IS CHOSEN, never before. It used to
        // be built first, so its input was taken while the default input was
        // still the headset the guard was about to move off. Voice processing
        // rebuilt the pairing and hid it; without voice processing the engine
        // kept the headset's microphone (see MicDevices.bindInput).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The global switch is read here as well as in VoiceInput. Until
        // 2026-08-22 this path consulted only the per-mic whitelist, so turning
        // voice processing off in Settings quieted dictation and left ambient
        // still forcing VPIO: the same narrow-band output, coming from the half
        // nobody thought to check. The output route is read too: with
        // headphones the mic cannot hear the output, so VPIO buys nothing and
        // costs the music its quality (see VoiceProcessingPolicy). A route
        // change while capturing re-makes this call via
        // reconsiderVoiceProcessing().
        let vpio = VoiceProcessingPolicy.shouldEnable(
            settingOn: AppState.shared.config.premiumNoiseCancellation,
            micWhitelisted: MicWhitelist.isWhitelisted(uid: activeInputUID),
            output: MicDevices.defaultOutputRoute(),
            refusedRecently: VoiceProcessingRefusal.isRecent(),
            holdsMicWhileGruxSpeaks: Self.holdsMicWhileGruxSpeaks)
        voiceProcessingDecision = vpio.enable
        var boundToChosenMic = false
        if !vpio.enable {
            WakeLog.shared.log("ambient: VPIO BYPASSED (\(vpio.reason)) input \(activeInputUID) - output stays full-fidelity")
            boundToChosenMic = MicDevices.bindInput(input, toUID: activeInputUID)
            if !boundToChosenMic {
                WakeLog.shared.log("ambient: could not bind the input to \(activeInputUID), the engine picks its own")
            }
        } else {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Without this macOS applies its default ducking and lowers
                // every other app for as long as ambient listens.
                input.voiceProcessingOtherAudioDuckingConfiguration = VoiceProcessingPolicy.otherAudioDucking
                WakeLog.shared.log("ambient: VoiceProcessingIO ENABLED (AEC/NS/AGC) for \(activeInputUID) (\(vpio.reason))")
            } catch {
                WakeLog.shared.log("ambient: VoiceProcessingIO enable FAILED \(error.localizedDescription)")
            }
        }

        // After an explicit bind the node's OUTPUT format is stale: it still
        // describes the device the engine was created on. Measured with a
        // probe: bound to the MacBook Pro Microphone (48 kHz), outputFormat
        // still read 24 kHz from the AirPods, and a tap in that format got 0
        // frames in 2 seconds. A tap in the device's own INPUT format got
        // 96000. So a bound input is tapped in its hardware format.
        // A fresh engine starts the watchdog's clock over. Without this the
        // new engine inherits the dead one's timestamp and trips instantly.
        lastAppendedEver = buffer.stats().appendedEver
        lastAudioGrowthUptime = ProcessInfo.processInfo.systemUptime

        let nativeFormat = MicDevices.tapFormat(for: input, bound: boundToChosenMic)
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
        WakeLog.shared.log("ambient: engine up  native=\(Int(nativeRate))Hz ch=\(channelCount) on \(MicDevices.boundInputName(input))")
        // A listener that reports capturing while nothing arrives is the worst
        // kind of broken: the orb says ARMED and Grux is deaf. Measured
        // 2026-09-21, every VAD tick read buf=0.0s for as long as it ran and
        // nothing said so. Two seconds in, check that audio is flowing.
        let started = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.audioEngine === engine else { return }
            let heard = self.buffer.stats().totalSeconds
            let action = Self.deafStartAction(heardSeconds: heard, attempt: deafAttempt)
            if action != .hearing && vpio.enable {
                VoiceProcessingRefusal.markRefused()
                WakeLog.shared.log("ambient: voice processing started and delivered nothing; listening without it for \(Int(VoiceProcessingRefusal.window / 60)) minutes")
            }
            switch action {
            case .hearing:
                MicHealth.shared.set(notHearing: false)
                WakeLog.shared.log("ambient: hearing \(String(format: "%.1f", heard))s of audio from \(MicDevices.boundInputName(input))")
            case .restart(let delay):
                if Self.tellsNotHearing(afterDeafAttempt: deafAttempt) { MicHealth.shared.set(notHearing: true) }
                WakeLog.shared.log("ambient: DEAF, no audio from \(MicDevices.boundInputName(input)) \(String(format: "%.1f", Date().timeIntervalSince(started)))s after start, restarting in \(Int(delay))s (restart \(deafAttempt + 1) of \(Self.maxDeafRestarts))")
                self.restartAfterDeafStart(attempt: deafAttempt + 1, afterSeconds: delay)
            case .giveUp:
                self.gaveUpOnDeafCapture = true
                MicHealth.shared.set(notHearing: true)
                WakeLog.shared.log("ambient: DEAF after \(deafAttempt) restarts, no audio from \(MicDevices.boundInputName(input)); stopped retrying")
                AmbientState.shared.isCapturing = false
                AmbientState.shared.status = "Error"
                AmbientState.shared.error = "The microphone is not sending any sound. Tap the orb to try again."
            }
        }
    }

    // MARK: - Output route

    // THE C FUNCTION-POINTER API, NOT THE BLOCK ONE, AND THAT IS LOAD-BEARING.
    // AudioObjectPropertyListenerBlock imports as a plain Swift closure type,
    // so every call re-wraps it in a NEW block, and removal matches on block
    // identity. Measured 2026-09-21 with a per-process property as the
    // trigger: after AudioObjectRemovePropertyListenerBlock with the stored
    // closure the listener still fired, while the proc below stopped firing
    // once removed. With the block API every stop() leaked a listener and
    // every mute and unmute stacked another one. The block remove also
    // returned 0 for a block never added, so its status proves nothing.
    // Called on a CoreAudio thread; hops to the main actor.
    private static let outputRouteProc: AudioObjectPropertyListenerProc = { _, _, _, _ in
        Task { @MainActor in AmbientListener.shared.outputRouteDidChange() }
        return noErr
    }

    private func installOutputRouteListener() {
        guard !outputRouteListening else { return }
        var addr = MicDevices.defaultOutputDeviceAddress
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &addr, Self.outputRouteProc, nil)
        if status == noErr {
            outputRouteListening = true
        } else {
            WakeLog.shared.log("ambient: could not watch the output device (\(status)), voice processing is decided at each start only")
        }
    }

    private func removeOutputRouteListener() {
        outputRouteDebounce?.cancel()
        outputRouteDebounce = nil
        guard outputRouteListening else { return }
        var addr = MicDevices.defaultOutputDeviceAddress
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &addr, Self.outputRouteProc, nil)
        outputRouteListening = false
    }

    // Debounced: connecting AirPods can move the default output more than once
    // inside a second, and every restart drops the audio buffered so far.
    private func outputRouteDidChange() {
        outputRouteDebounce?.cancel()
        outputRouteDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.reconsiderVoiceProcessing()
        }
    }

    /// Tears down a start that heard nothing and starts again after `seconds`,
    /// unless something else took over meanwhile (a pause, a stop, or another
    /// start that already built an engine).
    private func restartAfterDeafStart(attempt: Int, afterSeconds seconds: Double) {
        guard running, !pausedForExplicit, !pausedForSpeech, !pausedForMeeting else { return }
        tearDownCapture(reason: "no audio arrived", releaseMic: false)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard running, audioEngine == nil,
                  !self.pausedForExplicit, !self.pausedForSpeech, !self.pausedForMeeting else { return }
            do {
                try startEngine(deafAttempt: attempt)
                AmbientState.shared.isCapturing = true
                AmbientState.shared.status = Date() < self.wakeArmedUntil
                    ? "Listening · conversation open"
                    : "Listening"
                startChunkTimer()
                startLevelTimer()
                WakeLog.shared.log("ambient: restarted after a deaf start (restart \(attempt) of \(Self.maxDeafRestarts))")
            } catch {
                AmbientState.shared.error = "Restart failed: \(error.localizedDescription)"
                AmbientState.shared.status = "Error"
                WakeLog.shared.log("ambient: deaf restart failed \(error)")
            }
        }
    }

    // Re-make the voice processing call for the new output, and restart
    // capture ONLY when it flips. While paused there is no engine to fix: the
    // resume path calls startEngine(), which decides afresh.
    private func reconsiderVoiceProcessing() {
        guard running, audioEngine != nil, let current = voiceProcessingDecision,
              !pausedForExplicit, !pausedForSpeech, !pausedForMeeting else { return }
        let activeInputUID = MicDevices.systemDefaultInputUID() ?? ""
        let next = VoiceProcessingPolicy.shouldEnable(
            settingOn: AppState.shared.config.premiumNoiseCancellation,
            micWhitelisted: MicWhitelist.isWhitelisted(uid: activeInputUID),
            output: MicDevices.defaultOutputRoute(),
            holdsMicWhileGruxSpeaks: Self.holdsMicWhileGruxSpeaks)
        guard next.enable != current else {
            WakeLog.shared.log("ambient: output changed, voice processing unchanged (\(next.reason))")
            return
        }
        // tearDownCapture stops the live engine and drops it before
        // startEngine builds the next one, so nothing is left orphaned.
        tearDownCapture(reason: "output changed", releaseMic: false)
        do {
            try startEngine()
            AmbientState.shared.isCapturing = true
            AmbientState.shared.status = Date() < wakeArmedUntil
                ? "Listening · conversation open"
                : "Listening"
            startChunkTimer()
            startLevelTimer()
            WakeLog.shared.log("ambient: restarted for output change (\(next.reason))")
        } catch {
            AmbientState.shared.error = "Restart after output change failed: \(error.localizedDescription)"
            AmbientState.shared.status = "Error"
            WakeLog.shared.log("ambient: restart after output change failed \(error)")
        }
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
                let snap = self.buffer.stats()
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
        let snap = buffer.stats()
        let now = Date()
        let silentFor = now.timeIntervalSince(snap.lastVoiceAt)

        // THE RUNNING DEAF WATCHDOG. Everything above this line assumes audio
        // is still arriving; on 2026-09-23 it stopped arriving and nothing
        // noticed for 1h40m. See captureStallSeconds for the measurement.
        // Checked only while an engine is actually up and no pause is in
        // effect, so a torn-down engine is never mistaken for a dead one.
        if audioEngine != nil, !pausedForSpeech, !pausedForMeeting {
            let uptime = ProcessInfo.processInfo.systemUptime
            if snap.appendedEver != lastAppendedEver {
                lastAppendedEver = snap.appendedEver
                lastAudioGrowthUptime = uptime
                // Audio arriving is the ONLY honest evidence that a give-up was
                // wrong, so it is the only thing that lifts one. A device that
                // comes back (replugged, released by the app that held it)
                // otherwise stays stuck showing an error while it works.
                if gaveUpOnDeafCapture {
                    gaveUpOnDeafCapture = false
                    MicHealth.shared.set(notHearing: false)
                    AmbientState.shared.error = nil
                    AmbientState.shared.isCapturing = true
                    AmbientState.shared.status = Date() < wakeArmedUntil ? "Listening · conversation open" : "Listening"
                    WakeLog.shared.log("ambient: audio came back after giving up; listening again")
                }
            } else if !gaveUpOnDeafCapture,
                      Self.captureIsStalled(noNewAudioFor: uptime - lastAudioGrowthUptime) {
                let stalled = uptime - lastAudioGrowthUptime
                WakeLog.shared.log(String(format:
                    "ambient: CAPTURE STALLED, no new audio for %.1fs while capturing; restarting the engine", stalled))
                MicHealth.shared.set(notHearing: true)
                // Attempt 0 is right for a NEW failure: this engine was working
                // and stopped, which is not a continuation of a failed start.
                // The give-up flag above is what stops that from restarting a
                // ladder that has already run to its end.
                restartAfterDeafStart(attempt: 0, afterSeconds: 1)
                return
            }
        }

        // Diagnostic heartbeat: log VAD/peak every 5s so we can see why audio isn't chunking.
        if now.timeIntervalSince(lastVadStatLogAt) > 5 {
            lastVadStatLogAt = now
            // Until the first voiced frame, lastVoiceAt sits at .distantPast, so
            // silentFor is a ~64-billion-second epoch sentinel (silentFor=63920114471s),
            // not a real gap. Log "never" in that case instead of the garbage delta.
            let silentForStr = snap.voicedEver ? String(format: "%.1fs", silentFor) : "never"
            WakeLog.shared.log(String(format: "ambient vad: buf=%.1fs spoken=%.1fs rms=%.4f peak=%.3f voiced=%@ silentFor=%@",
                                      snap.totalSeconds, snap.voicedSeconds, Double(snap.rms), Double(snap.peak),
                                      snap.voicedEver ? "Y" : "N", silentForStr))
        }

        let flushAfter = Self.flushSilenceThreshold(spokenSeconds: snap.voicedSeconds,
                                                    commandWindow: commandWindowSeconds,
                                                    commandGap: commandSilenceFlushSeconds,
                                                    conversationGap: silenceFlushSeconds)
        if snap.voicedEver && snap.totalSeconds >= minChunkSeconds && silentFor >= flushAfter {
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
        // Timed because it is the largest remaining term in the spoken-command
        // budget and nothing measured it. The decision is 1ms on the fast path
        // and execution is about 10ms, so whatever this costs IS the latency.
        // Logged per chunk with the audio length beside it, because a
        // transcription time means nothing without knowing how much audio it
        // was given.
        let transcribeStarted = Date()
        do {
            let results = try await WhisperDecode.transcribe(kit, samples, options: options)
            let transcribeMs = Int(Date().timeIntervalSince(transcribeStarted) * 1000)
            let audioSeconds = Double(samples.count) / 16000.0
            WakeLog.shared.log(String(format: "ambient: whisper %dms for %.1fs of audio (voiced %.2fs)",
                                      transcribeMs, audioSeconds, Double(voiced)))
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
                }
            }
            guard !text.isEmpty else { return }
            // Everything after cleaning is ONE function, shared with the
            // inject seam, so a typed chunk and a heard chunk cannot drift.
            Task { @MainActor in _ = await self.routeChunk(text) }
        } catch {
            await MainActor.run {
                AmbientState.shared.isTranscribing = false
                AmbientState.shared.status = "Listening"
            }
            WakeLog.shared.log("ambient transcribe FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - One chunk, start to finish

    /// What became of one chunk. Every exit carries a reason, so no chunk is
    /// dropped without a trace: the inject seam writes this to a file.
    struct ChunkRoute {
        let heard: String
        let stage: String
        var event: VoiceDecisionEvent? = nil
        /// For a chunk that took no router decision: true when a dry run held
        /// back what it would have done. Nil when nothing was held.
        var dryRun: Bool? = nil
    }

    /// Everything that happens to a transcript once it is clean text: the
    /// echo, music, dismissal and advice gates, then the listening mode's
    /// dispatch. Transcription and `debugInjectChunk` both come through here,
    /// so a typed chunk takes exactly the path a heard one does, with or
    /// without a microphone.
    @discardableResult
    func routeChunk(_ text: String, dryRun: VoiceCommandRouter.DryRun = .none) async -> ChunkRoute {
        // Self-echo guard: Whisper sometimes catches the tail of
        // Grux's own speech within ~2s of the speech ending. If a
        // new chunk arrives that fast AND contains a wake phrase,
        // it's almost always Grux hearing itself, not the user.
        let sinceSpeech = Date().timeIntervalSince(lastSpeechEndAt)
        if sinceSpeech < postSpeechEchoGuardSeconds,
           Self.startsWithWake(text) {
            WakeLog.shared.log("ambient: dropped self-echo (\(String(format: "%.1f", sinceSpeech))s post-speech): \(text.prefix(80))")
            return ChunkRoute(heard: text, stage: "dropped: self-echo within \(Int(postSpeechEchoGuardSeconds))s of Grux speaking")
        }
        AmbientState.shared.appendChunk(text)
        WakeLog.shared.log("ambient chunk: \(text.prefix(120))")
        // A full dry run records the decision and nothing else, so the side
        // listeners that can draft, offer or spend a call stay out of it.
        let sideListeners = dryRun != .everything
        if sideListeners { Task { await AmbientMemoryExtractor.shared.onNewChunk(text) } }
        // Watch for verbal frustration ("this is broken", "always
        // fails", "TODO ...") next to a clear subject, and offer to
        // draft a GitHub issue. Heuristic-gated so it only spends an
        // LLM call on a hit; nothing files without confirmation.
        if sideListeners { Task { await IssueExtractor.shared.onNewChunk(text) } }
        // Voice-to-cold-email: "Grux, draft outreach to <person> at
        // <company>". Regex-gated, debounced, and never sends on its
        // own (drafts open a confirm dialog). See Outreach/ColdEmail.
        if sideListeners { Task { await ColdEmailEngine.shared.onTranscriptChunk(text) } }

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
            return ChunkRoute(heard: text, stage: "dropped: singing or music is playing")
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
            return ChunkRoute(heard: text, stage: "dismissal: conversation ended")
        }
        // Mentor trigger: if the user explicitly asked for advice
        // ("what do you think?", "any advice?"), fire a mentor
        // reminder + speak the answer. Don't also run wake dispatch.
        if MentorTriggerDetector.shared.evaluate(chunk: text) {
            WakeLog.shared.log("mentor-trigger handled chunk, skipping wake dispatch")
            return ChunkRoute(heard: text, stage: "mentor: asked for advice")
        }
        return await handleInlineWakeOrCommand(text: text, dryRun: dryRun)
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
        // The name is GruxName's, not "gr plus a vowel": see GruxName for the
        // meeting where "great" and "grab" were taken as Grux's name.
        let pattern = #"\b"# + GruxName.greeting + #"[\s,.!?:;-]+"# + GruxName.loose + #"\b[\s,.!?:;-]*(.*)$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Bare brand call: "Grux, what's next" / "grux!" / "grux". ANCHORED to the
    // start of the chunk and limited to spellings that are not English words
    // (GruxName.strong). It used to match any "gr" word anywhere, so "we could
    // grab a minute" was Grux being called by name.
    private static let bareBrandWakeRegex: NSRegularExpression = {
        let pattern = #"^[\s,.!?:;"'-]*"# + GruxName.strong + #"\b[\s,.!?:;-]*(.*)$"#
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

    /// Why the always-on gate drops a chunk before the router sees it, or nil
    /// when it goes on. Muted is a reason like any other: it used to be a bare
    /// `return`, so a muted chunk vanished without a line anywhere.
    static func alwaysOnDropReason(_ command: String, micMuted: Bool) -> String? {
        guard command.count >= 4, !isFillerChunk(command), passesCommandGate(command) else {
            return "dropped: short, filler or incoherent"
        }
        return micMuted ? "dropped: microphone is muted" : nil
    }

    private func handleInlineWakeOrCommand(text: String, dryRun: VoiceCommandRouter.DryRun) async -> ChunkRoute {
        // ALWAYS ON: every chunk that clears the cheap gates is judged by the
        // decision engine, which decides between a command, words said to
        // Grux (those go to Chat), and chatter. Nothing is forwarded to Chat
        // wholesale: measured 2026-09-20, a television advert in the room
        // reached Chat as a user message and Grux answered it out loud.
        if AppState.shared.config.listeningMode == .alwaysOn {
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = Self.alwaysOnDropReason(command, micMuted: AppState.shared.micMuted) {
                WakeLog.shared.log("ambient (always on): \(reason): '\(text.prefix(60))'")
                return ChunkRoute(heard: text, stage: reason)
            }
            guard let e = await VoiceCommandRouter.shared.consider(chunk: command, dryRun: dryRun) else {
                WakeLog.shared.log("ambient (always on): router made no decision: '\(command.prefix(80))'")
                return ChunkRoute(heard: text, stage: "router: no decision")
            }
            WakeLog.shared.log("ambient (always on): \(e.commandId) \(e.outcome) conf=\(String(format: "%.2f", e.confidence)) \(e.latencyMs)ms \(e.provider.rawValue)\(e.dryRun ? " (dry run)" : ""): '\(command.prefix(80))'")
            return ChunkRoute(heard: text, stage: "routed", event: e)
        }

        // FOCUS MODE (legacy, only reachable when the Listening control is not
        // Always on): every meaningful utterance is a command - no wake gate.
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
                return ChunkRoute(heard: text, stage: "dropped: focus mode requires the wake word")
            }
            let stripped = Self.stripWakePrefix(text)
            let command = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.count >= 4, !Self.isFillerChunk(command), Self.passesCommandGate(command) else {
                WakeLog.shared.log("ambient (focus): skipped short/filler/incoherent: '\(text.prefix(60))'")
                return ChunkRoute(heard: text, stage: "dropped: short, filler or incoherent")
            }
            WakeLog.shared.log("ambient (focus): → chat: \(command)")
            return sendToChat(command, heard: text, stage: "focus mode", dryRun: dryRun)
        }

        // WAKE MODE below. (Default.)
        // Case A: we're wake-armed from a prior "hey grux" - treat this chunk
        // as the follow-up command (unless it's ANOTHER wake phrase).
        if Date() < wakeArmedUntil, !Self.startsWithWake(text) {
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.count >= 4, !Self.isFillerChunk(command), Self.passesCommandGate(command) else {
                WakeLog.shared.log("ambient: armed-wake skipped short/filler/incoherent: '\(command.prefix(60))'")
                return ChunkRoute(heard: text, stage: "dropped: short, filler or incoherent")
            }
            // A dry run leaves the person's armed window as it found it (RV10).
            if dryRun == .none { wakeArmedUntil = .distantPast }
            WakeLog.shared.log("ambient: armed-wake \(dryRun == .none ? "consumed" : "left armed (dry run)") → command: \(command)")
            return sendToChat(command, heard: text, stage: "wake mode, armed", dryRun: dryRun)
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let match = Self.inlineWakeRegex.firstMatch(in: text, options: [], range: range)
            ?? Self.bareBrandWakeRegex.firstMatch(in: text, options: [], range: range)
        guard let m = match,
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else {
            return ChunkRoute(heard: text, stage: "ignored: wake mode and no wake phrase")
        }
        let command = String(text[r]).trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?:;-"))
        )

        WakeLog.shared.log("ambient: wake matched  text='\(text)'  cmd='\(command)'")
        let answersCommand = command.count >= 3 && Self.passesCommandGate(command)
        // A dry run never chimes, greets or arms the window (review RV10):
        // those answer a person in the room, and an injected line is not one.
        if dryRun != .none, !answersCommand {
            return ChunkRoute(heard: text, stage: "wake: dry run, would arm for the next chunk", dryRun: true)
        }
        if dryRun == .none {
            AudioOutput.chime([.tink, .glass], source: "AmbientListener.wake")
            NotificationCenter.default.post(name: .gruxWakeDetected, object: nil)
        }

        if answersCommand {
            // Single-breath command: fire immediately.
            return sendToChat(command, heard: text, stage: "wake phrase with a command", dryRun: dryRun)
        } else if command.count >= 3 {
            // Wake matched but the trailing command is incoherent (garbled /
            // roster echo). Arm for the next chunk instead of acting on noise.
            wakeArmedUntil = Date().addingTimeInterval(wakeArmWindow)
            AmbientState.shared.status = "Armed - say your command"
            SpeechEngine.shared.speak("Yeah, boss?")
            return ChunkRoute(heard: text, stage: "wake: armed, the command after it was incoherent")
        } else {
            // Bare wake - acknowledge and arm for the next chunk.
            wakeArmedUntil = Date().addingTimeInterval(wakeArmWindow)
            AmbientState.shared.status = "Armed - say your command"
            SpeechEngine.shared.speak("Yeah, boss?")
            return ChunkRoute(heard: text, stage: "wake: armed for the next chunk")
        }
    }

    /// The focus and wake modes hand words to Chat without the router. A full
    /// dry run holds that back like any other effect; an outside-Grux one
    /// sends them as a dry-run turn, where every tool that acts outside Grux
    /// only records (review RV4).
    private func sendToChat(_ command: String, heard: String, stage: String,
                            dryRun: VoiceCommandRouter.DryRun) -> ChunkRoute {
        guard dryRun != .everything else {
            return ChunkRoute(heard: heard, stage: "\(stage): dry run, would send to chat", dryRun: true)
        }
        let rehearsal = dryRun != .none
        Task { @MainActor in
            await JaxToolGate.$dryRun.withValue(rehearsal) { await ChatService.shared.send(userText: command) }
        }
        return ChunkRoute(heard: heard, stage: "\(stage): sent to chat\(rehearsal ? " as a dry run" : "")",
                          dryRun: rehearsal ? true : nil)
    }

    // If the chunk leads with a wake phrase, strip it so the model sees the
    // actual ask. If there's no wake phrase, return the chunk as-is. Shared
    // with VoiceCommandRouter, which strips before dictating into Chat.
    static func stripWakePrefix(_ text: String) -> String {
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
    // consuming a back-to-back second wake as the command of the first, and
    // by VoiceCommandRouter to tell an address from chatter.
    static func startsWithWake(_ text: String) -> Bool {
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
    // actual mic pipeline. Runs cleanTranscript and then routeChunk, the same
    // path a transcribed chunk takes, and needs no capture hardware at all.
    func debugInjectChunk(_ text: String, dryRun: VoiceCommandRouter.DryRun) async -> ChunkRoute {
        let cleaned = Self.cleanTranscript(text)
        guard !cleaned.isEmpty else {
            WakeLog.shared.log("debug inject: dropped empty-after-clean '\(text)'")
            return ChunkRoute(heard: "", stage: "dropped: nothing left after cleaning")
        }
        WakeLog.shared.log("debug inject: '\(cleaned)' (dry run: \(dryRun.rawValue))")
        return await routeChunk(cleaned, dryRun: dryRun)
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
        let snap = buffer.stats()
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
    /// When speech STARTED in this chunk. The buffer is not one
    /// utterance: it accumulates from the last flush, so it carries
    /// however much room silence preceded somebody speaking, and its
    /// total length says nothing about how long they talked. Measured
    /// 2026-09-22, buffers at flush ran 1.5s to 8.0s for the same
    /// one-second command. The span between this and `lastVoiceAt` is
    /// what separates a command from a conversation.
    private var firstVoiceAt: Date = .distantPast
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
    /// Every sample this buffer has EVER been handed, across drains and
    /// resets. `samples.count` cannot answer "is audio still arriving",
    /// because a drain takes it to zero and a reset does too, so a stalled
    /// tap and a freshly flushed buffer look identical. This only ever goes
    /// up, so no growth means no audio, with no other reading available.
    private var appendedEver: UInt64 = 0

    func appendSamples(_ ptr: UnsafePointer<Float>, count: Int, rms: Float) {
        lock.lock(); defer { lock.unlock() }
        appendedEver &+= UInt64(count)
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        let cap = sampleRate * maxSeconds
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
        liveRms = rms
        for i in 0..<count { peak = max(peak, abs(ptr[i])) }
        if noiseGate.classify(rms: rms) {
            lastVoiceAt = Date()
            if !voicedEver { firstVoiceAt = lastVoiceAt }
            voicedEver = true
        }
    }

    /// EVERYTHING ABOUT THE BUFFER EXCEPT THE BUFFER.
    ///
    /// There used to be only `snapshot()`, which returned the sample array
    /// alongside the numbers. Swift arrays are copy on write, so handing that
    /// reference to a caller keeps the storage alive, and the audio thread's
    /// next `append` sees a refcount above one and deep copies the whole
    /// thing. Thirty seconds at 16 kHz is 1.92 MB.
    ///
    /// Both hot callers asked for it twelve times a second, to read one float.
    /// Neither ever touched a sample: the level meter wants `rms`, and
    /// `considerFlush` wants the timings. The only caller that needs audio is
    /// `flush()`, which takes it with `drain()` once per utterance.
    ///
    /// Measured 2026-09-22 with listening on and no window open: 8.9% of a
    /// core before, and the level timer alone was asking for 1.92 MB ten times
    /// a second.
    func stats() -> (lastVoiceAt: Date, voicedEver: Bool, totalSeconds: Double, peak: Float, rms: Float, voicedSeconds: Double, appendedEver: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let spoken = voicedEver ? lastVoiceAt.timeIntervalSince(firstVoiceAt) : 0
        return (lastVoiceAt, voicedEver, Double(samples.count) / Double(sampleRate), peak, liveRms, spoken, appendedEver)
    }

    func drain() -> (samples: [Float], peak: Float) {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        let p = peak
        samples.removeAll(keepingCapacity: false)
        lastVoiceAt = .distantPast
        firstVoiceAt = .distantPast
        voicedEver = false
        peak = 0
        liveRms = 0
        return (out, p)
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lastVoiceAt = .distantPast
        firstVoiceAt = .distantPast
        voicedEver = false
        peak = 0
        liveRms = 0
        lock.unlock()
    }
}
