import XCTest
import SoundAnalysis
@testable import Grux

// Pure unit tests for the singing/music gate state machine. SoundAnalysis
// itself isn't exercised here (that would require real audio fixtures and
// a macOS 14+ runtime in CI); we inject confidences through the test hook
// and drive the clock forward manually. This covers:
//   1. A single loud music frame doesn't flip the gate (sustain guard works).
//   2. Sustained music for >= sustainSeconds flips the gate on.
//   3. Speech-dominant frames keep the gate off even with non-zero music.
//   4. Music EMA falling below deactivate clears the gate.
//   5. Reset/stop semantics behave (via resetState on reconfigure).
//   6. Label set extraction covers music keywords without false positives.
final class SingingDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Build a detector with an injected monotonic clock and a callback that
    /// captures state transitions so the tests can assert on them directly.
    /// `emaAlpha: 1.0` collapses the smoothing to "last observation wins"
    /// which makes the arithmetic easy to reason about in assertions.
    private func makeDetector(
        activate: Double = 0.5,
        deactivate: Double = 0.3,
        sustainSeconds: TimeInterval = 1.5,
        emaAlpha: Double = 1.0
    ) -> (detector: SingingDetector, clock: ClockBox, events: EventLog) {
        let clock = ClockBox()
        let events = EventLog()
        let t = SingingDetector.Thresholds(
            activate: activate,
            deactivate: deactivate,
            sustainSeconds: sustainSeconds,
            emaAlpha: emaAlpha
        )
        let d = SingingDetector(
            thresholds: t,
            clock: { clock.now },
            onStateChange: { active, music, speech in
                events.append(.init(active: active, music: music, speech: speech))
            }
        )
        return (d, clock, events)
    }

    // MARK: - Tests

    func test_singleMusicFrame_doesNotActivate() {
        let (d, _, events) = makeDetector()
        d.ingestForTest(music: 0.9, speech: 0.1)
        XCTAssertFalse(d.isSingingActive)
        XCTAssertEqual(events.all.count, 0)
    }

    func test_sustainedMusicDominantOverSpeech_activatesAfterSustainWindow() {
        let (d, clock, events) = makeDetector(sustainSeconds: 1.5)
        clock.now = Date(timeIntervalSince1970: 10_000)
        d.ingestForTest(music: 0.8, speech: 0.1) // sustain timer starts
        XCTAssertFalse(d.isSingingActive)

        clock.now = clock.now.addingTimeInterval(0.5)
        d.ingestForTest(music: 0.8, speech: 0.1)
        XCTAssertFalse(d.isSingingActive)

        clock.now = clock.now.addingTimeInterval(1.1) // 1.6 s total, past sustain
        d.ingestForTest(music: 0.8, speech: 0.1)
        XCTAssertTrue(d.isSingingActive)
        XCTAssertEqual(events.all.count, 1)
        XCTAssertEqual(events.all.first?.active, true)
    }

    func test_speechDominant_keepsGateOff_evenWithMusicAboveActivate() {
        // Café scenario: background music is audible (0.55), but the user is
        // talking louder (0.75). Music crosses the activate floor, but
        // speech still dominates, gate must stay off.
        let (d, clock, events) = makeDetector(sustainSeconds: 1.0)
        clock.now = Date(timeIntervalSince1970: 20_000)
        d.ingestForTest(music: 0.55, speech: 0.75)
        clock.now = clock.now.addingTimeInterval(2.0)
        d.ingestForTest(music: 0.55, speech: 0.75)
        XCTAssertFalse(d.isSingingActive)
        XCTAssertEqual(events.all.count, 0)
    }

    func test_activeGate_clearsWhenMusicFallsBelowDeactivate() {
        let (d, clock, events) = makeDetector(
            activate: 0.5, deactivate: 0.3, sustainSeconds: 1.0
        )
        clock.now = Date(timeIntervalSince1970: 30_000)

        // Build up to active.
        d.ingestForTest(music: 0.9, speech: 0.05)
        clock.now = clock.now.addingTimeInterval(1.2)
        d.ingestForTest(music: 0.9, speech: 0.05)
        XCTAssertTrue(d.isSingingActive)
        XCTAssertEqual(events.all.last?.active, true)

        // Music stops, should clear on next ingest below deactivate.
        clock.now = clock.now.addingTimeInterval(1.0)
        d.ingestForTest(music: 0.2, speech: 0.8)
        XCTAssertFalse(d.isSingingActive)
        XCTAssertEqual(events.all.count, 2)
        XCTAssertEqual(events.all.last?.active, false)
    }

    func test_hysteresis_noDeactivateAtMidRange() {
        // Music drops into the hysteresis zone (between deactivate and
        // activate). Gate should stay on until music crosses below deactivate.
        let (d, clock, _) = makeDetector(
            activate: 0.5, deactivate: 0.3, sustainSeconds: 1.0
        )
        clock.now = Date(timeIntervalSince1970: 40_000)
        d.ingestForTest(music: 0.8, speech: 0.05)
        clock.now = clock.now.addingTimeInterval(1.2)
        d.ingestForTest(music: 0.8, speech: 0.05)
        XCTAssertTrue(d.isSingingActive)

        // Now music wobbles in the hysteresis zone (0.4). Still dominant
        // vs speech but below activate AND above deactivate.
        clock.now = clock.now.addingTimeInterval(0.5)
        d.ingestForTest(music: 0.4, speech: 0.05)
        XCTAssertTrue(d.isSingingActive, "gate should stay on in hysteresis zone")

        // Drop below deactivate, gate clears.
        clock.now = clock.now.addingTimeInterval(0.5)
        d.ingestForTest(music: 0.15, speech: 0.05)
        XCTAssertFalse(d.isSingingActive)
    }

    func test_sustainResets_whenSpeechTakesOverMidBuildUp() {
        // Music is climbing toward the sustain threshold, then the user starts
        // talking over it. The sustain timer must reset so a brief lull in
        // the middle of conversation doesn't trip the gate on the back end.
        let (d, clock, _) = makeDetector(sustainSeconds: 1.0)
        clock.now = Date(timeIntervalSince1970: 50_000)
        d.ingestForTest(music: 0.8, speech: 0.1) // sustain starts

        // Halfway through sustain window, speech dominates.
        clock.now = clock.now.addingTimeInterval(0.5)
        d.ingestForTest(music: 0.4, speech: 0.9) // resets sustain

        // Another 0.6 s goes by (cumulative 1.1 s from first music ingest)
        // with music back up, since sustain was reset, should NOT activate.
        clock.now = clock.now.addingTimeInterval(0.6)
        d.ingestForTest(music: 0.8, speech: 0.1)
        XCTAssertFalse(d.isSingingActive)
    }

    // MARK: - SoundAnalysis integration (live classifier)

    // Prove that Apple's bundled v1 classifier actually exposes the label
    // families we depend on ("music", "singing", "speech", plus common
    // instruments). If Apple ever removes one of these in a future macOS
    // release, this test fails loud instead of the gate silently going
    // dark. Runs live against the system classifier, fast (<100 ms).
    func test_v1Classifier_exposesMusicSingingAndSpeechLabels() throws {
        let req: SNClassifySoundRequest
        do {
            req = try SNClassifySoundRequest(classifierIdentifier: .version1)
        } catch {
            throw XCTSkip("SoundAnalysis v1 classifier unavailable on this runner: \(error)")
        }
        let musicLabels = SingingDetector.buildMusicLabels(from: req)
        let speechLabels = SingingDetector.buildSpeechLabels(from: req)

        // These are the two core families that gate behavior. If the v1
        // classifier ships without either, the gate degenerates and we need
        // to pick a new strategy.
        XCTAssertTrue(
            musicLabels.contains(where: { $0.lowercased().contains("music") }),
            "v1 classifier missing any 'music'-family label; got: \(musicLabels.sorted())"
        )
        XCTAssertTrue(
            musicLabels.contains(where: { $0.lowercased().contains("singing") }),
            "v1 classifier missing any 'singing'-family label; got: \(musicLabels.sorted())"
        )
        XCTAssertTrue(
            speechLabels.contains(where: { $0.lowercased().contains("speech") }),
            "v1 classifier missing any 'speech'-family label; got: \(speechLabels.sorted())"
        )
        XCTAssertGreaterThan(
            musicLabels.count, speechLabels.count,
            "Music-family label set should dominate speech-family; something's off in filter logic."
        )
    }

    // Smoke-test that SNAudioStreamAnalyzer wiring works end-to-end on a
    // silent 16 kHz mono buffer. Feeds 10 seconds of silence; we don't
    // assert any specific confidence, we just prove the pipeline doesn't
    // crash and the gate stays OFF on pure silence (music confidence should
    // never reach the activate floor on silence).
    func test_soundAnalysisPipeline_stableOnSilence_andGateStaysOff() throws {
        // Don't touch AmbientState.shared, use a fresh instance.
        let events = EventLog()
        let d = SingingDetector(
            thresholds: SingingDetector.Thresholds(),
            clock: Date.init,
            onStateChange: { active, music, speech in
                events.append(.init(active: active, music: music, speech: speech))
            }
        )
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false
        ) else { return XCTFail("format build failed") }

        d.start(inputFormat: fmt)

        // Feed 10 × 1-second silent buffers.
        for _ in 0..<10 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000) else { continue }
            buf.frameLength = 16000
            // All zeros (already zeroed by allocator).
            d.process(buffer: buf)
        }

        // Drain the analyzer's serial queue. This replaced a 0.5s timer waited
        // on with a 2s timeout, which was flaky and dishonest in the same
        // stroke: the expectation was fulfilled by `DispatchQueue.main
        // .asyncAfter`, so it measured main-queue latency and never observed the
        // classifier at all. It would have passed with the analyzer wired to
        // nothing. Under full-suite load the main queue could not service the
        // timer inside 2s and the whole run went red for no product reason.
        d.drainForTest()

        XCTAssertFalse(d.isSingingActive, "Silence must NEVER flip the singing gate on.")
        // No activation events should have fired.
        XCTAssertFalse(events.all.contains(where: { $0.active }),
                       "Silence produced an active event, classifier or gate is misbehaving.")

        d.stop()
    }

    func test_emaSmoothing_singleSpikeDoesNotInstantlyFlipEven_ifAboveActivate() {
        // With a softer EMA, one big spike shouldn't instantly pin musicEMA
        // above activate. (activate=0.5, alpha=0.3 → after one spike at 1.0,
        // musicEMA = 0 * 0.7 + 1.0 * 0.3 = 0.3, below activate.)
        let (d, clock, events) = makeDetector(
            activate: 0.5, deactivate: 0.3, sustainSeconds: 1.5, emaAlpha: 0.3
        )
        clock.now = Date(timeIntervalSince1970: 60_000)
        d.ingestForTest(music: 1.0, speech: 0.0)
        XCTAssertLessThan(d.musicEMA, 0.5)

        // Multiple consecutive spikes pull the EMA above activate. The first
        // ingest above activate starts the sustain timer.
        d.ingestForTest(music: 1.0, speech: 0.0)
        d.ingestForTest(music: 1.0, speech: 0.0)
        d.ingestForTest(music: 1.0, speech: 0.0)
        XCTAssertGreaterThan(d.musicEMA, 0.5)
        XCTAssertFalse(d.isSingingActive)

        // Hold for sustain window.
        clock.now = clock.now.addingTimeInterval(2.0)
        d.ingestForTest(music: 1.0, speech: 0.0)
        XCTAssertTrue(d.isSingingActive)
        XCTAssertEqual(events.all.last?.active, true)
    }
}

// MARK: - Test-only helpers

// Simple reference-typed clock box so the capturing closure can read
// updates without importing Combine.
private final class ClockBox {
    var now: Date = Date()
}

private final class EventLog {
    struct Event { let active: Bool; let music: Double; let speech: Double }
    private let lock = NSLock()
    private var _all: [Event] = []

    func append(_ e: Event) { lock.lock(); _all.append(e); lock.unlock() }
    var all: [Event] { lock.lock(); defer { lock.unlock() }; return _all }
}
