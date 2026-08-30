import XCTest
@testable import Grux

/// MUTED MUST MEAN THE MICROPHONE IS FREE.
///
/// Reported 2026-08-24 with a screenshot: Grux showing MUTED and "Paused", the
/// macOS orange microphone indicator lit in the menu bar, and Voice Memos
/// unable to record. Muting an assistant that runs in the background is a
/// promise that the machine is the user's again. Holding the device anyway is
/// worse than not offering mute at all, because the UI says one thing and the
/// hardware does another.
///
/// `MicController.mute()` stopped `AmbientListener` and `WakeWordListener`.
/// There are FOUR input taps in the app. It stopped two.
///
/// THE RULE THIS FILE ENFORCES, and why it is written as a source sweep rather
/// than a behavioural assertion: the failure mode is a NEW tap being added by
/// somebody who does not know `mute()` exists. No runtime test can see a tap
/// that nobody started. The sweep finds every `installTap(onBus:` in the tree
/// and demands its owner be named in `MicController.mute()`, so adding a fifth
/// microphone consumer without releasing it on mute fails the build.
final class MicMuteReleasesDeviceTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
    }

    private func swiftFiles() -> [URL] {
        (FileManager.default.enumerator(at: sourcesRoot(), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }) ?? []
    }

    /// Every type that installs an input tap.
    ///
    /// Tracks the most recent type declaration BEFORE each `installTap`, rather
    /// than taking the first type in the file. The naive version reported
    /// `WhisperAudioBuffer` for VoiceInput.swift, a helper declared above the
    /// class that actually owns the microphone, and missed WakeWordListener
    /// entirely. A sweep that names the wrong owner is worse than no sweep: it
    /// looks thorough while checking the wrong thing.
    private func microphoneOwners() -> [String] {
        var owners: Set<String> = []
        for f in swiftFiles() {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            var current: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                for kw in ["final class ", "class ", "actor ", "struct "] where t.hasPrefix(kw) {
                    let name = t.dropFirst(kw.count).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                    if !name.isEmpty { current = String(name) }
                    break
                }
                if t.contains("installTap(onBus:"), let c = current { owners.insert(c) }
            }
        }
        return owners.sorted()
    }

    /// The body of `mute()`, to its real end rather than a fixed character
    /// window. The first version took `prefix(1400)` and started failing the
    /// moment the function grew a comment, which is a test that breaks on
    /// documentation. Scoped to the next `static func` instead.
    private func muteBody() throws -> String {
        let mic = try String(contentsOf: sourcesRoot().appendingPathComponent("MicController.swift"),
                             encoding: .utf8)
        guard let r = mic.range(of: "static func mute()") else {
            throw XCTSkip("MicController.mute() was renamed")
        }
        let rest = mic[r.upperBound...]
        let end = rest.range(of: "\n    static func ")?.lowerBound ?? rest.endIndex
        return Self.stripComments(String(rest[rest.startIndex..<end]))
    }

    /// THE SWEEP WAS MATCHING ITS OWN DOCUMENTATION.
    ///
    /// `mute()`'s comment explains the bug it fixes and, in doing so, NAMES
    /// AmbientListener and WakeWordListener. So the owner check found those two
    /// strings in prose and passed whether or not the stop calls were still
    /// there: deleting `AmbientListener.shared.stop()` left the suite green,
    /// which is precisely the defect this test exists to catch.
    ///
    /// A test that reads a comment is not reading the code. Strip them first.
    static func stripComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Control for the stripper. If it removed too much, every assertion that
    /// reads a stripped body would pass for the wrong reason.
    func testStrippingCommentsKeepsTheCodeAndDropsTheProse() throws {
        let sample = [
            "// AmbientListener is named here in prose only.",
            "let x = 1",
            "WakeWordListener.shared.stop()"
        ].joined(separator: "\n")
        let stripped = Self.stripComments(sample)
        XCTAssertFalse(stripped.contains("prose only"), "comments survived the stripper")
        XCTAssertTrue(stripped.contains("WakeWordListener.shared.stop()"), "the stripper ate real code")
        XCTAssertTrue(stripped.contains("let x = 1"))

        // And on the real body: the owner names must come from CALLS, not prose.
        let body = try muteBody()
        XCTAssertTrue(body.contains("AmbientListener.shared.stop()"),
                      "mute() does not actually call AmbientListener.shared.stop()")
        XCTAssertFalse(body.contains("easiest to remember"),
                       "a comment line survived stripComments, so the sweep can still self-match")
    }

    /// Control. If the sweep finds nothing, every assertion below is vacuous.
    func testTheSweepFindsTheKnownMicrophoneOwners() {
        let owners = microphoneOwners()
        XCTAssertGreaterThanOrEqual(owners.count, 4,
                                    "found only \(owners), so the sweep is broken and proves nothing")
        for expected in ["AmbientListener", "WakeWordListener", "VoiceInput", "MeetingMicCapture"] {
            XCTAssertTrue(owners.contains(expected),
                          "the sweep missed \(expected), which is a known microphone owner")
        }
    }

    /// THE BUG. Mute must release every one of them.
    func testMuteStopsEveryMicrophoneOwner() throws {
        let body = try muteBody()

        // Some owners are correctly released through the type that OWNS them
        // rather than by reaching past it. MeetingMicCapture is a private let
        // inside MeetingCaptureService, and stopping the service is what
        // summarises and saves the transcript instead of dropping it. Declared
        // explicitly, one line per delegation, so the sweep stays strict: a new
        // tap with no entry here and no direct stop still fails.
        let releasedVia: [String: String] = [
            "MeetingMicCapture": "MeetingCaptureService"
        ]
        var unreleased: [String] = []
        for owner in microphoneOwners() {
            if body.contains(owner) { continue }
            if let via = releasedVia[owner], body.contains(via) { continue }
            unreleased.append(owner)
        }
        XCTAssertTrue(unreleased.isEmpty,
                      """
                      mute() does not stop \(unreleased). The user sees MUTED, the macOS \
                      microphone indicator stays lit, and other apps cannot record.
                      """)
    }

    /// And the state it advertises must match. A mute that stops the hardware
    /// but leaves a surface claiming it is listening is the same lie inverted.
    @MainActor
    func testMuteAdvertisesTheStateItActuallyReached() throws {
        let body = try muteBody()
        XCTAssertTrue(body.contains("micMuted = true"), "mute() does not set the flag every surface reads")
        XCTAssertTrue(body.contains("isEnabled = false"),
                      "the ambient pill would keep claiming capture is on while muted")
    }
}

/// MUTE MUST PREVENT, NOT ONLY STOP.
///
/// Stopping every listener at the moment of muting is half the contract. The
/// other half is that nothing re-acquires the device afterwards, and that half
/// was missing: `AmbientListener.start()` and `WakeWordListener.start()` both
/// check `micMuted` and refuse, while `VoiceInput.start()` and
/// `MeetingMicCapture.start()` had ZERO mute checks between them.
///
/// So a muted Grux would take the microphone back the moment dictation was
/// triggered or a meeting auto-capture fired, with every surface still showing
/// MUTED. That is the reported symptom, "grux is still utilizing the mic",
/// surviving the stop-side fix entirely.
final class MicMuteIsRespectedOnStartTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
    }

    /// Every file that installs an input tap must consult the mute flag before
    /// starting. Derived from the same sweep as the stop-side test, so a fifth
    /// microphone owner is covered by both halves automatically.
    func testEveryMicrophoneOwnerRefusesToStartWhileMuted() throws {
        let files = (FileManager.default.enumerator(at: sourcesRoot(), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }) ?? []

        var tapOwners: [URL] = []
        for f in files {
            guard let t = try? String(contentsOf: f, encoding: .utf8), t.contains("installTap(onBus:") else { continue }
            tapOwners.append(f)
        }
        XCTAssertGreaterThanOrEqual(tapOwners.count, 4,
                                    "control: found \(tapOwners.count) tap owners, sweep is broken")

        var unchecked: [String] = []
        for f in tapOwners {
            let t = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            if !t.contains("micMuted") { unchecked.append(f.lastPathComponent) }
        }
        XCTAssertTrue(unchecked.isEmpty,
                      """
                      \(unchecked) install a microphone tap and never consult micMuted, so a \
                      muted Grux takes the device back as soon as one of them starts.
                      """)
    }
}

/// A BEHAVIOURAL TEST, BECAUSE EVERY OTHER TEST HERE IS A SUBSTRING SWEEP.
///
/// Review's closing line was the sharpest thing in it: not one test in either
/// mic file starts, stops or observes an audio engine, so "the suite would go
/// green with the microphone held". A sweep proves a line of code exists. It
/// cannot prove the device was released, and three of the four defects review
/// found lived precisely in that gap.
///
/// This drives the real `MicController.mute()` against the real singletons and
/// asserts the observable state they expose.
@MainActor
final class MicMuteBehaviourTests: XCTestCase {

    private var savedMuted = false

    override func setUp() async throws {
        try await super.setUp()
        savedMuted = AppState.shared.micMuted
    }

    override func tearDown() async throws {
        AppState.shared.micMuted = savedMuted
        try await super.tearDown()
    }

    /// Mute must leave every observable capture flag down, not merely set a
    /// boolean that the UI reads.
    func testMuteLeavesNothingCapturing() async {
        AppState.shared.micMuted = false
        // ESTABLISH THE STATE FIRST. The first version of this test asserted
        // flags that were ALREADY false in a fresh test process, so deleting
        // `AmbientListener.shared.stop()` from mute() left it green. A test that
        // asserts a value it never made true proves nothing, which is exactly
        // the criticism that produced this file.
        AmbientState.shared.isEnabled = true
        AmbientState.shared.isCapturing = true

        MicController.mute()

        XCTAssertTrue(AppState.shared.micMuted, "the flag every surface reads did not move")
        XCTAssertFalse(AmbientState.shared.isCapturing,
                       "ambient still reports capturing after mute")
        XCTAssertFalse(AmbientState.shared.isEnabled,
                       "the ambient pill still claims enabled after mute")

        // Give the fire-and-forget meeting stop a moment to land.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(MeetingCaptureService.shared.isCapturing,
                       "a meeting is still capturing after mute")
    }

    /// AND THE GUARD IS NOT ENTRY-ONLY. A listener asked to start while muted
    /// must not be capturing when it returns. This is the half review called
    /// "MUTE MUST PREVENT" and it is asserted here rather than grepped.
    func testAListenerAskedToStartWhileMutedDoesNotCapture() async {
        AppState.shared.micMuted = true
        await AmbientListener.shared.start()
        XCTAssertFalse(AmbientState.shared.isCapturing,
                       "ambient started capturing despite the mute")

        await VoiceInput.shared.start()
        XCTAssertFalse(VoiceInput.shared.isRecording,
                       "dictation started recording despite the mute")
    }

    /// Mute must be idempotent. It is reachable from the orb, the menu bar, a
    /// hotkey and a CLI trigger, so a double fire has to be harmless.
    func testMuteTwiceIsHarmless() async {
        AppState.shared.micMuted = false
        MicController.mute()
        MicController.mute()
        XCTAssertTrue(AppState.shared.micMuted)
        XCTAssertFalse(AmbientState.shared.isCapturing)
    }
}
