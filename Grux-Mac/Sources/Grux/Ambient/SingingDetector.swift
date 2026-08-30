import Foundation
import AVFoundation
import SoundAnalysis

// On-device singing / music detector that gates command dispatch in the
// AmbientListener pipeline. Someone sang along at the mic and Grux routed
// the transcription to ChatService as if it were a command.
// All existing guards (confidence gate, junk-set, brand normalizer,
// self-echo) passed because sung lyrics look like legit speech to Whisper.
// The only reliable signal is the audio itself - this detector classifies
// the stream with Apple's built-in SoundAnalysis v1 classifier and trips
// a suppress flag when music/singing confidence is sustained above speech.
//
// Design notes:
//   • Entirely on-device. No network. No bundled models - the v1 classifier
//     ships with macOS, so binary size stays flat.
//   • Runs on a private serial queue. Safe to call `process(buffer:)` from
//     the audio-tap thread; the analyzer is confined to the detector's queue.
//   • Decoupled from AmbientState via an `onStateChange` callback so unit
//     tests can verify the state machine without spinning up MainActor.
//   • State is an EMA over per-buffer classifications plus a sustain timer,
//     not a single-frame threshold. One loud sung note doesn't gate a
//     legit spoken command; 1.5 s of dominant music signal does.
//   • The gate suppresses **command dispatch**, not transcription. The user
//     still sees what was heard in the transcript, just no ChatService call.
final class SingingDetector: @unchecked Sendable {

    // Thresholds are exposed so tests can dial the gate without waiting for
    // wall-clock time. Production defaults tuned against the v1 classifier's
    // reported confidences for sung speech at 16 kHz mono.
    struct Thresholds {
        var activate: Double = 0.50      // musicEMA must cross to arm
        var deactivate: Double = 0.30    // musicEMA must fall below to clear
        var sustainSeconds: TimeInterval = 1.5  // how long arming must persist
        var emaAlpha: Double = 0.35      // smoothing factor per observation
    }

    private let thresholds: Thresholds
    private let clock: () -> Date
    private let onStateChange: ((Bool, Double, Double) -> Void)?

    // All state mutations happen on `queue`. Reads use queue.sync for
    // a consistent snapshot from the main thread without races.
    private let queue = DispatchQueue(label: "grux.singing.analyzer")
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var observer: Observer?
    private var musicLabels: Set<String> = []
    private var speechLabels: Set<String> = []
    private var cumulativeFrame: AVAudioFramePosition = 0

    private var _musicEMA: Double = 0
    private var _speechEMA: Double = 0
    private var _sustainStart: Date?
    private var _active: Bool = false

    init(
        thresholds: Thresholds = Thresholds(),
        clock: @escaping () -> Date = { Date() },
        onStateChange: ((Bool, Double, Double) -> Void)? = nil
    ) {
        self.thresholds = thresholds
        self.clock = clock
        self.onStateChange = onStateChange
    }

    // Singleton used by the ambient pipeline. Tests construct their own
    // instance with a mock clock / callback.
    static let shared: SingingDetector = {
        SingingDetector(onStateChange: { active, music, speech in
            Task { @MainActor in
                AmbientState.shared.isSinging = active
                if active {
                    WakeLog.shared.log(String(
                        format: "singing: ACTIVE music=%.2f speech=%.2f - commands SUPPRESSED",
                        music, speech))
                } else {
                    WakeLog.shared.log(String(
                        format: "singing: cleared music=%.2f speech=%.2f - commands re-enabled",
                        music, speech))
                }
            }
        })
    }()

    // MARK: - Public thread-safe reads

    var isSingingActive: Bool { queue.sync { _active } }
    var musicEMA: Double { queue.sync { _musicEMA } }
    var speechEMA: Double { queue.sync { _speechEMA } }

    // MARK: - Lifecycle

    // Build the stream analyzer for the given input format (16 kHz mono Float32
    // out of the ambient pipeline). Idempotent - calling start again tears
    // down the previous analyzer and rebuilds.
    func start(inputFormat: AVAudioFormat) {
        queue.async {
            self.configureInternal(inputFormat: inputFormat)
        }
    }

    func stop() {
        queue.async {
            self.streamAnalyzer?.removeAllRequests()
            self.streamAnalyzer = nil
            self.request = nil
            self.observer = nil
            self.cumulativeFrame = 0
            self.resetState()
        }
    }

    // Feed a buffer into the analyzer. Safe to call from any thread - we
    // hop onto our serial queue before touching the analyzer.
    func process(buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let analyzer = self.streamAnalyzer else { return }
            let pos = self.cumulativeFrame
            self.cumulativeFrame += AVAudioFramePosition(buffer.frameLength)
            analyzer.analyze(buffer, atAudioFramePosition: pos)
        }
    }

    // Synchronous test hook - feed pre-parsed confidences without spinning
    // up SoundAnalysis or wall-clock waits. Clock is driven by the `clock`
    // closure injected in init.
    func ingestForTest(music: Double, speech: Double) {
        queue.sync {
            self.ingestConfidences(music: music, speech: speech)
        }
    }

    // Synchronous drain hook. `process(buffer:)` hops onto the serial queue with
    // `queue.async`, and `SNAudioStreamAnalyzer.analyze` calls the results
    // observer back on that same thread, so a barrier here means every buffer
    // fed so far has been analyzed AND every confidence it produced has been
    // ingested.
    //
    // This exists because the alternative is a wall-clock sleep, and a sleep is
    // wrong twice over: it does not actually know the classifier finished, and
    // it fails on a loaded machine while passing on an idle one. A test that is
    // green because the CPU was free is not a test.
    func drainForTest() {
        queue.sync { }
    }

    // MARK: - Internal

    private func configureInternal(inputFormat: AVAudioFormat) {
        streamAnalyzer?.removeAllRequests()
        cumulativeFrame = 0

        let req: SNClassifySoundRequest
        do {
            req = try SNClassifySoundRequest(classifierIdentifier: .version1)
        } catch {
            WakeLog.shared.log("singing: classifier init failed \(error.localizedDescription)")
            return
        }

        // 0.975 s windows with 0.5 overlap → ~500 ms hop. Each analyze()
        // call may emit multiple results as buffers accumulate; state
        // update runs on every emission.
        req.windowDuration = CMTime(seconds: 0.975, preferredTimescale: 48000)
        req.overlapFactor = 0.5

        let analyzer = SNAudioStreamAnalyzer(format: inputFormat)
        let obs = Observer(owner: self)
        do {
            try analyzer.add(req, withObserver: obs)
        } catch {
            WakeLog.shared.log("singing: analyzer.add failed \(error.localizedDescription)")
            return
        }

        self.streamAnalyzer = analyzer
        self.request = req
        self.observer = obs
        self.musicLabels = Self.buildMusicLabels(from: req)
        self.speechLabels = Self.buildSpeechLabels(from: req)
        self.resetState()

        WakeLog.shared.log(
            "singing: analyzer ready  music-labels=\(self.musicLabels.count) speech-labels=\(self.speechLabels.count)"
        )
    }

    // Observer callback - runs on our queue because we forward via queue.async.
    fileprivate func ingestClassifications(_ classifications: [SNClassification]) {
        queue.async {
            var maxMusic: Double = 0
            var maxSpeech: Double = 0
            for c in classifications {
                if self.musicLabels.contains(c.identifier) { maxMusic = max(maxMusic, c.confidence) }
                if self.speechLabels.contains(c.identifier) { maxSpeech = max(maxSpeech, c.confidence) }
            }
            self.ingestConfidences(music: maxMusic, speech: maxSpeech)
        }
    }

    // Must be called on `queue`.
    private func ingestConfidences(music: Double, speech: Double) {
        let alpha = thresholds.emaAlpha
        _musicEMA = (1 - alpha) * _musicEMA + alpha * music
        _speechEMA = (1 - alpha) * _speechEMA + alpha * speech

        let now = clock()
        // Arming: musicEMA above activate threshold AND dominating speech.
        // "Dominating" is key - a loud spoken command in a café with faint
        // background music can push musicEMA above the activate floor but
        // speechEMA will be even higher, so the gate stays off.
        if _musicEMA >= thresholds.activate && _musicEMA > _speechEMA {
            if _sustainStart == nil {
                _sustainStart = now
            } else if !_active,
                      now.timeIntervalSince(_sustainStart!) >= thresholds.sustainSeconds {
                _active = true
                onStateChange?(true, _musicEMA, _speechEMA)
            }
        } else {
            _sustainStart = nil
            if _active && _musicEMA <= thresholds.deactivate {
                _active = false
                onStateChange?(false, _musicEMA, _speechEMA)
            }
        }
    }

    private func resetState() {
        _musicEMA = 0
        _speechEMA = 0
        _sustainStart = nil
        if _active {
            _active = false
            onStateChange?(false, 0, 0)
        }
    }

    // MARK: - Label discovery

    // The v1 classifier exposes ~300 labels. Any label whose name contains a
    // music/singing keyword counts toward the music signal; a handful of
    // speech-family labels count toward the speech signal. We compute the
    // sets once at start so every ingest is two constant-time lookups.
    static func buildMusicLabels(from req: SNClassifySoundRequest) -> Set<String> {
        let keywords: [String] = [
            "music", "singing", "song", "sing",
            "humming", "whistling", "chanting", "choir",
            "guitar", "piano", "drum", "drums", "bass",
            "violin", "cello", "flute", "saxophone", "trumpet",
            "organ", "synth", "beat", "vocal",
            "instrument", "orchestra", "string", "wind_instrument",
            "harmonica", "accordion", "banjo", "mandolin",
            "ukulele", "keyboard_musical", "brass", "percussion",
            "xylophone", "marimba", "tambourine", "cymbal"
        ]
        return filterLabels(from: req, keywords: keywords, fallback: ["music", "singing"])
    }

    static func buildSpeechLabels(from req: SNClassifySoundRequest) -> Set<String> {
        let keywords: [String] = [
            "speech", "shout", "yell", "whisper",
            "conversation", "babble", "narration"
        ]
        return filterLabels(from: req, keywords: keywords, fallback: ["speech"])
    }

    private static func filterLabels(
        from req: SNClassifySoundRequest,
        keywords: [String],
        fallback: Set<String>
    ) -> Set<String> {
        var out: Set<String> = []
        let all = req.knownClassifications
        for label in all {
            let lower = label.lowercased()
            for kw in keywords {
                if lower.contains(kw) {
                    out.insert(label)
                    break
                }
            }
        }
        if out.isEmpty { return fallback }
        return out
    }
}

// SoundAnalysis observer. Separated into its own class because
// SNResultsObserving requires NSObject conformance; SingingDetector is a
// plain Swift class. Held weakly so an orphaned observer can't leak the
// detector past stop().
private final class Observer: NSObject, SNResultsObserving {
    weak var owner: SingingDetector?
    init(owner: SingingDetector) { self.owner = owner }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        owner?.ingestClassifications(r.classifications)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        WakeLog.shared.log("singing: request error \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) { }
}
