import XCTest
@testable import Grux

/// Grux going deaf while it is running, and never noticing.
///
/// THE INCIDENT, 2026-09-23. Grux ran for 1 hour 40 minutes reporting
/// `ambientCapturing = true`, with `mic-status.json` and every UI surface
/// saying it was listening, while `wake.log` repeated one line every five
/// seconds:
///
///     ambient vad: buf=1.8s spoken=0.0s rms=0.0000 peak=0.000 voiced=N
///
/// A buffer frozen at 1.8s and an rms of exactly zero. In the same minute a
/// separate process capturing from the SAME microphone got 120,000 frames of
/// real audio, so the device was healthy and only Grux was deaf.
///
/// Why nothing caught it, and why both existing guards were the wrong shape:
///
/// - `deafStartAction` runs ONCE, about two seconds after `startEngine`. It
///   can only ever see a start that was born deaf. This one lived, served
///   commands for six minutes, and then died.
/// - `deadAirResetSeconds` fires when the buffer passes 12s with no voice.
///   A buffer frozen at 1.8s never reaches 12s, so it was unreachable by
///   construction.
///
/// For a voice product this is the worst failure available: broken, with
/// every surface reporting healthy.
@MainActor
final class CaptureStallTests: XCTestCase {

    // MARK: - The threshold

    func testAStalledCaptureIsCalledDeadAfterTheThreshold() {
        XCTAssertTrue(AmbientListener.captureIsStalled(noNewAudioFor: AmbientListener.captureStallSeconds))
        XCTAssertTrue(AmbientListener.captureIsStalled(noNewAudioFor: 100))
    }

    func testAudioArrivingNormallyIsNotCalledDead() {
        XCTAssertFalse(AmbientListener.captureIsStalled(noNewAudioFor: 0))
        XCTAssertFalse(AmbientListener.captureIsStalled(noNewAudioFor: 1.0))
        XCTAssertFalse(AmbientListener.captureIsStalled(noNewAudioFor: AmbientListener.captureStallSeconds - 0.1))
    }

    /// The threshold has to sit above any legitimate gap and below anything a
    /// person would call "it stopped working". The tap fires on every hardware
    /// buffer whether or not anyone is speaking, so silence still arrives as
    /// samples: this measures NO SAMPLES, not no speech.
    func testTheThresholdIsInASaneRange() {
        XCTAssertGreaterThanOrEqual(AmbientListener.captureStallSeconds, 4,
            "too eager: a brief hiccup would tear down a working engine")
        XCTAssertLessThanOrEqual(AmbientListener.captureStallSeconds, 20,
            "too patient: this is the guard against silent deafness, and 1h40m of it already shipped")
    }

    // MARK: - The signal the watchdog reads

    /// `samples.count` cannot answer "is audio still arriving", because a
    /// drain takes it to zero. The monotonic counter is what makes a stalled
    /// tap distinguishable from a freshly flushed buffer.
    func testTheCounterOnlyEverGoesUp() {
        let b = AmbientAudioBuffer()
        var chunk = [Float](repeating: 0.1, count: 1600)
        XCTAssertEqual(b.stats().appendedEver, 0)

        chunk.withUnsafeBufferPointer { b.appendSamples($0.baseAddress!, count: $0.count, rms: 0.1) }
        let afterFirst = b.stats().appendedEver
        XCTAssertEqual(afterFirst, 1600)

        _ = b.drain()
        XCTAssertEqual(b.stats().totalSeconds, 0, accuracy: 0.001, "drain should empty the buffer")
        XCTAssertEqual(b.stats().appendedEver, afterFirst,
            "the drain reset the ever-counter, so a flushed buffer is indistinguishable from a dead tap")

        chunk.withUnsafeBufferPointer { b.appendSamples($0.baseAddress!, count: $0.count, rms: 0.1) }
        XCTAssertEqual(b.stats().appendedEver, 3200, "the counter stopped accumulating across a drain")
    }

    /// A reset is the other way the live buffer goes to zero.
    func testTheCounterSurvivesAReset() {
        let b = AmbientAudioBuffer()
        let chunk = [Float](repeating: 0.1, count: 800)
        chunk.withUnsafeBufferPointer { b.appendSamples($0.baseAddress!, count: $0.count, rms: 0.1) }
        b.reset()
        XCTAssertEqual(b.stats().appendedEver, 800,
            "reset cleared the ever-counter; after a speech pause the watchdog would see a fake stall")
    }

    /// The exact shape of the incident: the buffer holds 1.8s and never
    /// changes. Everything that looks at the buffer's SIZE reads it as a
    /// normal small buffer; only the ever-counter shows nothing is arriving.
    func testTheIncidentShape() {
        let b = AmbientAudioBuffer()
        let oneEightSeconds = [Float](repeating: 0.0, count: Int(1.8 * 16000))
        oneEightSeconds.withUnsafeBufferPointer { b.appendSamples($0.baseAddress!, count: $0.count, rms: 0.0) }

        let first = b.stats()
        XCTAssertEqual(first.totalSeconds, 1.8, accuracy: 0.01)
        XCTAssertFalse(first.voicedEver, "silence should not read as voiced")

        // Time passes. No tap callbacks. Nothing changes.
        let later = b.stats()
        XCTAssertEqual(later.appendedEver, first.appendedEver,
            "no audio arrived, so the counter must not move; if it does the watchdog can never fire")
        XCTAssertLessThan(later.totalSeconds, 12.0,
            "a buffer frozen below deadAirResetSeconds is exactly why the existing reset could not catch this")
        XCTAssertTrue(AmbientListener.captureIsStalled(noNewAudioFor: 10),
            "ten seconds with an unmoving counter must read as stalled")
    }

    static func listenerSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Ambient/AmbientListener.swift"), encoding: .utf8)
    }

    // MARK: - The wiring

    /// The watchdog has to be READ somewhere, and it has to act. A pure
    /// function nobody calls is the same bug with more code.
    func testTheWatchdogIsWiredIntoTheFlushLoop() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Ambient/AmbientListener.swift"), encoding: .utf8)
        let body = try XCTUnwrap(src.components(separatedBy: "private func considerFlush() {").dropFirst().first,
                                 "considerFlush disappeared")
        let head = String(body.prefix(2_800))
        XCTAssertTrue(head.contains("captureIsStalled"),
            "considerFlush no longer checks for a stalled capture, so Grux can go deaf silently again")
        XCTAssertTrue(head.contains("restartAfterDeafStart"),
            "the stall is detected but nothing restarts the engine, so it would log the problem forever")
        XCTAssertTrue(head.contains("audioEngine != nil"),
            "the watchdog no longer checks an engine is actually up, so a torn-down engine reads as a dead one")
        XCTAssertTrue(head.contains("!pausedForSpeech"),
            "the watchdog runs while Grux is speaking, when capture is deliberately down; it will restart on every reply")
    }

    /// THE DEFECT TWO REVIEWERS FOUND INDEPENDENTLY, 2026-09-24.
    ///
    /// `.giveUp` tears nothing down. It sets MicHealth, writes the error and
    /// returns, leaving `running` true, `audioEngine` non-nil and the chunk
    /// timer alive. So eight seconds later this watchdog saw a live engine
    /// with no audio and called `restartAfterDeafStart(attempt: 0)`, starting
    /// the five step ladder over with a fresh count. Forever.
    ///
    /// Measured shape on a genuinely dead input: a ~122 second cycle, six
    /// CoreAudio teardown/rebuilds and six mic-guard claims per cycle, with
    /// the orb flickering between Listening and Error rather than settling on
    /// "Tap the orb to try again". `maxDeafRestarts` stopped bounding anything.
    func testTheWatchdogDoesNotRestartAfterTheLadderGaveUp() throws {
        let src = try Self.listenerSource()
        let body = try XCTUnwrap(src.components(separatedBy: "private func considerFlush() {").dropFirst().first)
        let head = String(body.prefix(2_600))
        XCTAssertTrue(head.contains("!gaveUpOnDeafCapture"), """
            the stall branch no longer checks gaveUpOnDeafCapture, so once the deaf ladder \
            has given up this watchdog restarts it at attempt 0 every 8 seconds forever and \
            maxDeafRestarts bounds nothing.
            """)
        // And the flag must actually be set where the ladder gives up.
        XCTAssertTrue(src.contains("case .giveUp:\n                self.gaveUpOnDeafCapture = true"), """
            .giveUp no longer sets gaveUpOnDeafCapture, so the guard above can never be true \
            and the infinite restart cycle is back.
            """)
    }

    /// The other half: a give-up must be liftable, or a device that comes back
    /// (replugged, released by whatever held it) stays showing an error while
    /// it is actually working. Audio arriving is the only honest evidence.
    func testAGiveUpIsLiftedWhenAudioComesBack() throws {
        let src = try Self.listenerSource()
        let body = try XCTUnwrap(src.components(separatedBy: "private func considerFlush() {").dropFirst().first)
        let head = String(body.prefix(2_600))
        // The growth branch, not the stall branch, is where it must be cleared.
        let growth = try XCTUnwrap(head.components(separatedBy: "if snap.appendedEver != lastAppendedEver {").dropFirst().first)
        XCTAssertTrue(String(growth.prefix(900)).contains("gaveUpOnDeafCapture = false"), """
            audio arriving no longer lifts a give-up, so a microphone that recovers leaves \
            Grux stuck on "The microphone is not sending any sound" while it transcribes fine.
            """)
    }

    /// Elapsed time must come from a clock that does NOT advance while the Mac
    /// is asleep. With `Date`, the first tick after an eight hour lid close
    /// reads "no new audio for 28800.0s" and reports a dead microphone on
    /// every single wake; a forward NTP step does the same with no fault.
    func testTheStallClockDoesNotCountSleep() throws {
        let src = try Self.listenerSource()
        let body = try XCTUnwrap(src.components(separatedBy: "private func considerFlush() {").dropFirst().first)
        let head = String(body.prefix(2_600))
        XCTAssertTrue(head.contains("ProcessInfo.processInfo.systemUptime"),
            "the watchdog is back on a wall clock, so every wake from sleep is a false CAPTURE STALLED")
        XCTAssertFalse(head.contains("lastAudioGrowthAt"),
            "a Date-based growth timestamp is back in the stall path")
    }

    /// A fresh engine must start the clock over, or it inherits the dead
    /// engine's timestamp and trips immediately on its first tick.
    func testAFreshEngineResetsTheWatchdogClock() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Ambient/AmbientListener.swift"), encoding: .utf8)
        let body = try XCTUnwrap(src.components(separatedBy: "private func startEngine(deafAttempt: Int = 0) throws {").dropFirst().first)
        XCTAssertTrue(String(body.prefix(6_000)).contains("lastAudioGrowthUptime = ProcessInfo.processInfo.systemUptime"),
            "startEngine does not reset the watchdog clock, so every new engine trips the stall check on its first tick and restarts forever")
    }
}
