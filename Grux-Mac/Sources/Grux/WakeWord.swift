import Foundation
import AVFoundation
import Speech
import AppKit

extension Notification.Name {
    static let gruxWakeDetected = Notification.Name("gruxWakeDetected")
    static let gruxVoiceInputDidStop = Notification.Name("gruxVoiceInputDidStop")
}

/// Appends timestamped lines to ~/Library/Application Support/Grux/wake.log
/// so we can `tail -f` it while testing.
///
/// Rooted at `Persistence.supportDir`, so the suite logs into its own scratch
/// directory. It used to hardcode the real Application Support path, and every
/// `swift test` run wrote hundreds of lines of test noise (consent churn,
/// meta-ads failures against a test port, "auto-revert (crash loop: test)")
/// into the operator's real log. The lines carry a time and no date, so a day
/// later that noise reads as something the running app did. Measured
/// 2026-09-21: it sent a live audio diagnosis down a wrong path for a while.
final class WakeLog: @unchecked Sendable {
    static let shared = WakeLog()
    private let url: URL
    private let fmt: DateFormatter
    private let q = DispatchQueue(label: "grux.wake.log")

    /// Where the lines go, for tests.
    var fileURL: URL { url }

    private init() {
        let base = Persistence.supportDir
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("wake.log")
        self.fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
    }
    func log(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        q.async {
            LogRotation.appendRotating(line, to: self.url)
        }
        NSLog("[Grux/wake] %@", s)
    }
}

@MainActor
final class WakeWordListener: ObservableObject {
    static let shared = WakeWordListener()

    @Published var isListening = false
    @Published var error: String?

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var restartTimer: Timer?
    private var lastTriggerAt: Date = .distantPast
    private var shouldResumeAfterDictation = false
    private var lastProcessedLength: Int = 0
    private var lastLoggedTranscript: String = ""

    // Very loose matcher: anything sounding like "hey gr[ou][ckfsgpt]?s?" -
    // "hey grux / grooks / groks / gruff / groose / grubs / grugs / groot /
    // grocks / grucks / gruks / gruhks / gruz / groo / grew" all fire.
    // Also matches "ok grux" / "okay grux" / "yo grux" / bare "grux".
    /// THE PHRASE THE INTERFACE IS ALLOWED TO TELL PEOPLE TO SAY.
    ///
    /// It is tied to the APP's name, not the assistant's, and permanently: the
    /// regex below matches "gr" plus vowels, so it can never fire on a renamed
    /// assistant. This is the same rule the tab names follow, and Settings
    /// already states it: renaming the assistant does not rename the app.
    ///
    /// It exists because copy drifted from it. Two screens were changed to read
    /// `UserIdentity.assistantName`, which defaults to "Jax", so they told EVERY
    /// user out of the box to say "Hey Jax" at a listener that only answers to
    /// "grux". Wrong for everyone, not just for somebody who renamed.
    static let spokenPhrase = "hey grux"

    /// Whether a transcript would really fire the wake word.
    ///
    /// Exposed so the copy can be TESTED against the actual matcher instead of
    /// agreeing with it by hand. A sentence and a regex that are supposed to
    /// describe the same thing should be checked against each other, not both
    /// checked against somebody's memory.
    static func wouldTrigger(_ transcript: String) -> Bool {
        let s = transcript as NSString
        return sharedWakeRegex.firstMatch(
            in: transcript, options: [],
            range: NSRange(location: 0, length: s.length)) != nil
    }

    fileprivate static let sharedWakeRegex: NSRegularExpression = {
        // A greeting and any known mishearing, or a bare name that is not an
        // English word (GruxName). "gr plus a vowel" fired on "great".
        let pattern = #"\b"# + GruxName.greeting + #"\s+"# + GruxName.loose + #"\b|\b"# + GruxName.strong + #"\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private let wakeRegex: NSRegularExpression = WakeWordListener.sharedWakeRegex

    private init() {
        NotificationCenter.default.addObserver(forName: .gruxVoiceInputDidStop, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Always clear the flag - keeping it set while wake-word is disabled
                // causes an inappropriate auto-resume the next time wake-word is re-enabled.
                let should = self.shouldResumeAfterDictation
                self.shouldResumeAfterDictation = false
                if should && AppState.shared.config.wakeWordEnabled {
                    await self.start()
                }
            }
        }
    }

    /// THE ONE WAY TO TURN THE WAKE WORD ON.
    ///
    /// `start()` is called on launch and from half a dozen resume paths, so it
    /// is the wrong place to ask: a user who already said yes would be asked
    /// again every restart. The act that needs consent is flipping the
    /// PREFERENCE, and this is the only function allowed to do it.
    /// `MicConsentGateTests` sweeps the tree and fails if `wakeWordEnabled` is
    /// set to true anywhere else.
    func enable() async {
        guard MicConsent.ensureAcknowledged(for: .wakeWord) else { return }
        AppState.shared.config.wakeWordEnabled = true
        AppState.shared.saveConfig()
        await start()
    }

    /// The matching door out. Turning a listener OFF is never gated.
    func disable() {
        AppState.shared.config.wakeWordEnabled = false
        AppState.shared.saveConfig()
        stop()
    }

    func start() async {
        guard !isListening else { return }
        // Hard mute - the user tapped the orb to silence the mic. Respect it.
        if AppState.shared.micMuted {
            WakeLog.shared.log("wake: skipping start - micMuted")
            return
        }
        // Ambient mode handles wake detection via its own continuous transcription.
        // Don't start SFSpeechRecognizer - the two engines fight for the mic.
        if AmbientState.shared.isEnabled {
            WakeLog.shared.log("wake: skipping start - ambient is enabled")
            return
        }
        error = nil

        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        if speechAuth != .authorized {
            let ok = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { s in cont.resume(returning: s == .authorized) }
            }
            guard ok else { self.error = "Speech recognition not authorized."; return }
        }
        guard await MicController.ensureAuthorized() else {
            self.error = "Microphone not authorized."; return
        }

        // RE-CHECK AFTER THE SUSPENSIONS. Two authorization prompts sit between
        // the mute guard at the top of this function and the line below that
        // takes the device, and a first-run user can leave both sitting on
        // screen for a long time. A mute that arrives during them has to win.
        if AppState.shared.micMuted {
            WakeLog.shared.log("wake: aborting start - muted during authorization")
            return
        }

        do {
            try startEngineAndTask()
            isListening = true
            scheduleRestart()
            WakeLog.shared.log("LISTENER STARTED (speech auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))")
        } catch {
            self.error = "Wake start failed: \(error.localizedDescription)"
            WakeLog.shared.log("start FAILED: \(error.localizedDescription)")
        }
    }

    func stop() {
        ListeningMicGuard.shared.release("wake")
        restartTimer?.invalidate(); restartTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        isListening = false
        lastProcessedLength = 0
    }

    /// Called by Speaker while Grux speaks so the wake listener doesn't hear
    /// its own voice and retrigger.
    func suspendForSpeaking() {
        WakeLog.shared.log("suspend for speaking")
        stop()
    }

    func resumeAfterSpeaking() {
        WakeLog.shared.log("resume after speaking")
        guard AppState.shared.config.wakeWordEnabled else { return }
        Task { @MainActor in
            // Small grace window so the speaker's tail audio drains.
            try? await Task.sleep(nanoseconds: 600_000_000)
            await self.start()
        }
    }

    private func startEngineAndTask() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Grux.WakeWord", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recognizer unavailable"])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Prefer on-device but fall through to server if unavailable - better
        // accuracy for novel words like "grux" since on-device has a smaller LM.
        req.requiresOnDeviceRecognition = false
        request = req

        // Same rule as ambient: the wake word listens on the Mac's own
        // microphone, never a borrowed one. Released in stop().
        ListeningMicGuard.shared.claim("wake")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        WakeLog.shared.log("start engine  format=\(format) sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine

        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.handle(transcript: result.bestTranscription.formattedString)
                    if result.isFinal { self.restartSoon() }
                }
                if let err {
                    let ns = err as NSError
                    if ns.domain != "kAFAssistantErrorDomain" || ![203, 216, 1110].contains(ns.code) {
                        WakeLog.shared.log("recog error: \(ns.domain) / \(ns.code) - \(ns.localizedDescription)")
                    }
                    self.restartSoon()
                }
            }
        }
        lastProcessedLength = 0
    }

    private func handle(transcript: String) {
        // No published copy of the transcript. There used to be one, read by
        // nothing, and every partial result the recognizer produced (a steady
        // stream while music plays) fired objectWillChange on this listener,
        // which the main window's root observed and re-rendered for.
        // Log every transcript change so we can see what the recognizer hears.
        if transcript != lastLoggedTranscript {
            WakeLog.shared.log("heard: \(transcript)")
            lastLoggedTranscript = transcript
        }
        // Only scan the newly-added tail to avoid re-matching stale buffer content.
        let len = transcript.count
        guard len > lastProcessedLength else { return }
        let tailStart = max(lastProcessedLength - 20, 0)
        let tail = String(transcript.suffix(len - tailStart)).lowercased()
        lastProcessedLength = len

        let range = NSRange(tail.startIndex..<tail.endIndex, in: tail)
        if let match = wakeRegex.firstMatch(in: tail, options: [], range: range),
           let r = Range(match.range, in: tail) {
            trigger(matched: String(tail[r]))
        }
    }

    private func trigger(matched: String) {
        let now = Date()
        guard now.timeIntervalSince(lastTriggerAt) >= 2.5 else { return }
        lastTriggerAt = now
        WakeLog.shared.log(">>> MATCHED: \(matched)")

        // Fallback to Glass if Tink isn't available - a named system sound can
        // be missing on some installs.
        AudioOutput.chime([.tink, .glass, .pop], source: "WakeWordListener.matched")
        shouldResumeAfterDictation = true
        stop()

        // Intentionally do NOT activate Grux or steal focus - the user keeps
        // working in whatever app they are in while Grux listens. The wake
        // notification + voice input start in the background; Grux only
        // becomes visible if they open it themselves.
        NotificationCenter.default.post(name: .gruxWakeDetected, object: nil)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let config = AppState.shared.config
            // If ambient listening is enabled in WAKE mode, the wake phrase
            // kicks off a FULL conversation (ambient pipeline + VP + Whisper)
            // instead of the one-shot VoiceInput dictation. Ambient keeps
            // listening until the user taps DONE TALKING, stays silent for 30s
            // post-reply, or says a dismissal phrase.
            if config.ambientEnabled && config.ambientMode == .wake {
                await AmbientState.shared.enterConversation(reason: "wake phrase")
                return
            }
            await VoiceInput.shared.start(autoSendOnSilence: config.autoSendOnWake)
        }
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        // SFSpeechRecognizer tasks are capped around 60s; recycle at 50.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restartSoon() }
        }
    }

    private func restartSoon() {
        guard isListening else { return }
        stop()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if AppState.shared.config.wakeWordEnabled {
                await self.start()
            }
        }
    }
}
