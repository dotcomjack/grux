import XCTest
@testable import Grux

/// LISTENING SHIPS OFF, AND SAYS WHAT IT COSTS BEFORE IT STARTS.
///
/// Ambient capture and the wake word both hold the microphone continuously
/// while they run. That was true and stated nowhere, so a user could turn one
/// on, forget, and later be surprised by the machine's behaviour. Both defaults
/// were already off; the gap was the explanation.
final class MicConsentTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
    }

    /// BOTH DEFAULTS OFF, on a fresh install AND on a config that predates the
    /// keys. The init default alone is not enough: the decode fallback is what
    /// an existing install actually gets, which is the exact gap that made the
    /// local-model fix a no-op for everyone who already had Grux.
    @MainActor
    func testBothListeningFeaturesShipOff() throws {
        let encoded = try JSONEncoder().encode(AppState.shared.config)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        obj.removeValue(forKey: "ambientEnabled")
        obj.removeValue(forKey: "wakeWordEnabled")
        let cfg = try JSONDecoder().decode(GruxConfig.self,
                                           from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(cfg.ambientEnabled, "ambient capture is on by default")
        XCTAssertFalse(cfg.wakeWordEnabled, "the wake word is on by default")
    }

    /// The copy must state the cost in terms a person can act on, and must not
    /// claim things measurement contradicts.
    func testTheConsentCopyIsAccurateAndActionable() {
        let text = (MicConsent.title + " " + MicConsent.body(for: .ambient)).lowercased()
        XCTAssertTrue(text.contains("microphone"), "never names what it takes")
        XCTAssertTrue(text.contains("mute"), "never says how to stop it")
        // WAS: an assertion that "on this mac" appears, which LOCKED IN a false
        // claim. The wake word sets requiresOnDeviceRecognition = false
        // (WakeWord.swift:179) on purpose, so its audio can reach Apple. The
        // copy is per-feature now and each must be accurate about its own path.
        let ambient = MicConsent.body(for: .ambient).lowercased()
        XCTAssertTrue(ambient.contains("on this mac"),
                      "ambient uses Whisper locally and should say so")
        let wake = MicConsent.body(for: .wakeWord).lowercased()
        XCTAssertTrue(wake.contains("apple"),
                      "the wake word can send audio to Apple and the dialog must say so")
        XCTAssertFalse(wake.contains("does not leave"),
                       "the wake word dialog claims the audio stays local, which is false")
        // THE CONSEQUENCE PEOPLE ACTUALLY NOTICE. Apple's voice processing takes
        // over while anything listens and macOS drops system output to a
        // narrow-band call codec, so music and video go tinny. The Voice pane
        // documented this already; the dialog that turns listening ON did not,
        // which is the wrong way round.
        XCTAssertTrue(text.contains("music") || text.contains("audio"),
                      "never warns that listening degrades system audio output")
        XCTAssertTrue(text.contains("codec") || text.contains("tinny"),
                      "names no concrete effect on playback")

        // An earlier draft claimed other apps could not record while Grux
        // listened. Measured on this machine that is FALSE: macOS shares the
        // input device and a second recorder captured real audio with ambient
        // running. Trading one wrong explanation for another is not a fix.
        for overclaim in ["cannot record", "can't record", "block", "exclusive"] {
            XCTAssertFalse(text.contains(overclaim),
                           "copy claims \"\(overclaim)\", which measurement contradicts")
        }
        XCTAssertFalse(MicConsent.confirmTitle.lowercased().contains("ok"),
                       "a confirm button should name the action, not say OK")
    }

    /// TURNING IT ON ASKS, AND THE ASKING IS NOT IN A VIEW.
    ///
    /// THIS TEST USED TO BE THE PROBLEM. It read `SettingsView.swift`, found
    /// the two lines that set `pendingMicConsent`, and passed. Ambient is also
    /// enabled from `MenuBarView` and from the ambient HUD's capture pill, and
    /// neither asked anything, so a test scoped to the file where the fix was
    /// written reported full coverage of a feature with two open side doors.
    ///
    /// The gate is at the choke point now, so that is what gets asserted. The
    /// behaviour itself is driven in `MicConsentGateTests`; this is the
    /// structural half, that nothing routes around it.
    func testBothDoorsAskBeforeTakingTheMicrophone() throws {
        let ambient = MicMuteReleasesDeviceTests.stripComments(
            try String(contentsOf: sourcesRoot().appendingPathComponent("Ambient/AmbientState.swift"),
                       encoding: .utf8))
        let enable = try XCTUnwrap(ambient.range(of: "func enable() async {"), "AmbientState.enable() moved")
        let body = String(ambient[enable.upperBound...])
        let gate = try XCTUnwrap(body.range(of: "MicConsent.ensureAcknowledged(for: .ambient)"),
                                 "ambient takes the microphone without asking")
        let takes = try XCTUnwrap(body.range(of: "isEnabled = true"), "the enable line moved")
        XCTAssertTrue(gate.lowerBound < takes.lowerBound,
                      "ambient turns itself on BEFORE asking, so declining leaves it running")

        let wake = MicMuteReleasesDeviceTests.stripComments(
            try String(contentsOf: sourcesRoot().appendingPathComponent("WakeWord.swift"), encoding: .utf8))
        let wakeEnable = try XCTUnwrap(wake.range(of: "func enable() async {"), "WakeWordListener.enable() is missing")
        let wakeBody = String(wake[wakeEnable.upperBound...])
        let wakeGate = try XCTUnwrap(wakeBody.range(of: "MicConsent.ensureAcknowledged(for: .wakeWord)"),
                                     "the wake word turns on without asking")
        let wakeWrite = try XCTUnwrap(wakeBody.range(of: "wakeWordEnabled = true"), "the preference write moved")
        XCTAssertTrue(wakeGate.lowerBound < wakeWrite.lowerBound,
                      "the wake word preference is written before the question is asked")

        // And the view must no longer own a gate of its own, or there are two
        // implementations and only one of them covers every door.
        let settings = try String(contentsOf: sourcesRoot().appendingPathComponent("SettingsView.swift"),
                                  encoding: .utf8)
        XCTAssertFalse(settings.contains("pendingMicConsent"),
                       "SettingsView still carries its own consent gate beside the choke point one")
    }

    /// AND TURNING IT OFF NEVER DOES. Nobody needs permission to stop being
    /// listened to, and a confirmation on the way out would be the same defect
    /// as a missing one on the way in, inverted.
    func testTurningItOffIsNeverGated() throws {
        // Asserted where the gate actually lives. `disable()` on either
        // listener must reach the stop without consulting consent: a
        // confirmation on the way out is the same defect as a missing one on
        // the way in, inverted.
        for (file, function) in [("Ambient/AmbientState.swift", "func disable() {"),
                                 ("WakeWord.swift", "func disable() {")] {
            let src = MicMuteReleasesDeviceTests.stripComments(
                try String(contentsOf: sourcesRoot().appendingPathComponent(file), encoding: .utf8))
            let r = try XCTUnwrap(src.range(of: function), "\(file): \(function) moved")
            let rest = String(src[r.upperBound...])
            let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
            let body = String(rest[rest.startIndex..<end])
            XCTAssertFalse(body.contains("MicConsent"),
                           "\(file) asks for consent to STOP listening, which is backwards")
            XCTAssertTrue(body.contains("stop()"),
                          "\(file) disable() no longer stops the listener")
        }
    }

    /// The cost stays visible while it runs, rather than being explained once
    /// and forgotten. First run happens once; the microphone is open for months.
    func testTheCostIsRestatedWhileRunning() throws {
        let src = try String(contentsOf: sourcesRoot().appendingPathComponent("SettingsView.swift"),
                             encoding: .utf8)
        let shown = src.components(separatedBy: "MicConsent.runningNote").count - 1
        XCTAssertGreaterThanOrEqual(shown, 2,
                                    "only \(shown) of the two listening features restate the cost while on")
    }
}
