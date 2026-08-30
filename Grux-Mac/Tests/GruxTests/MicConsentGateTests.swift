import XCTest
@testable import Grux

/// THE DIALOG COVERED ONE OF THREE DOORS, AND THE TEST REPORTED FULL COVERAGE.
///
/// The consent alert shipped on `SettingsView` and was fired from that view's
/// two toggles. Ambient can also be switched on from the menu bar row
/// (`MenuBarView.swift`) and from the capture pill in the ambient HUD
/// (`AmbientHUD.swift`), and neither asked anything at all: flipping the menu
/// bar switch took the microphone with no disclosure.
///
/// The test that was supposed to guard this swept `SettingsView.swift` only. It
/// found the copy it was looking for, passed, and said nothing about the two
/// open side doors. That is the failure mode worth naming: a test scoped to the
/// file where the fix was written can only ever confirm the fix was written.
///
/// The gate now lives at the choke point, and these tests DRIVE it rather than
/// reading it. `MicConsent.presenter` is injectable precisely so the answer can
/// be stubbed and the consequence asserted.
@MainActor
final class MicConsentGateTests: XCTestCase {

    private var savedConfig: GruxConfig!
    private var savedMuted = false
    private var savedEnabled = false

    override func setUp() async throws {
        try await super.setUp()
        savedConfig = AppState.shared.config
        savedMuted = AppState.shared.micMuted
        savedEnabled = AmbientState.shared.isEnabled
        // Nothing in this file should be able to take the device. Muted means
        // every listener refuses to start, so `enable()` can be exercised for
        // its DECISION without any of these tests touching audio hardware.
        AppState.shared.micMuted = true
        AppState.shared.config.ambientHUDVisible = false
    }

    override func tearDown() async throws {
        MicConsent.presenter = { MicConsent.presentPrompt(for: $0) }
        AppState.shared.config = savedConfig
        AppState.shared.saveConfig()
        AppState.shared.micMuted = savedMuted
        AmbientState.shared.isEnabled = savedEnabled
        try await super.tearDown()
    }

    /// Stubs the answer and counts how many times it was asked.
    private func stubConsent(_ answer: Bool) -> () -> Int {
        var asked = 0
        MicConsent.presenter = { _ in asked += 1; return answer }
        return { asked }
    }

    // MARK: - Ambient

    /// THE ONE THAT WOULD HAVE CAUGHT IT. A declined answer must leave the
    /// microphone alone AND leave nothing persisted.
    func testDecliningConsentLeavesAmbientOff() async {
        let asked = stubConsent(false)
        AppState.shared.config.ambientConsentAcknowledged = false
        AppState.shared.config.ambientEnabled = false
        AmbientState.shared.isEnabled = false

        await AmbientState.shared.enable()

        XCTAssertEqual(asked(), 1, "the user was never asked before ambient took the microphone")
        XCTAssertFalse(AmbientState.shared.isEnabled,
                       "ambient turned itself on after the user declined")
        XCTAssertFalse(AppState.shared.config.ambientEnabled,
                       "a declined answer was written to disk as if it were a yes")
        XCTAssertFalse(AppState.shared.config.ambientConsentAcknowledged,
                       "declining recorded consent, so the user is never asked again")
    }

    /// And the gate must not be a permanent refusal. Accepting proceeds.
    func testAcceptingConsentTurnsAmbientOn() async {
        let asked = stubConsent(true)
        AppState.shared.config.ambientConsentAcknowledged = false
        AppState.shared.config.ambientEnabled = false

        await AmbientState.shared.enable()

        XCTAssertEqual(asked(), 1)
        XCTAssertTrue(AppState.shared.config.ambientEnabled,
                      "the user said yes and ambient stayed off, so the gate refuses everything")
        XCTAssertTrue(AppState.shared.config.ambientConsentAcknowledged,
                      "the answer was not remembered")
    }

    /// Asked once, then never again. A gate that re-prompts on every enable is
    /// a gate people learn to click through without reading.
    func testTheQuestionIsAskedOnceAndRemembered() async {
        let asked = stubConsent(true)
        AppState.shared.config.ambientConsentAcknowledged = false

        XCTAssertTrue(MicConsent.ensureAcknowledged(for: .ambient))
        XCTAssertTrue(MicConsent.ensureAcknowledged(for: .ambient))
        XCTAssertTrue(MicConsent.ensureAcknowledged(for: .ambient))

        XCTAssertEqual(asked(), 1, "asked \(asked()) times, so the answer is not being remembered")
    }

    /// REMEMBERED ACROSS LAUNCHES, WHICH IS A DIFFERENT CLAIM FROM REMEMBERED
    /// IN MEMORY, and the first version of this file only proved the second.
    ///
    /// Mutation testing caught it: deleting the `saveConfig()` from the gate
    /// left every consent test green, because they all read the in-memory
    /// config that the gate had just written. The answer would have been
    /// forgotten on the next launch and the dialog would have returned forever,
    /// with a full green suite. So this one reads the FILE.
    func testTheAnswerIsWrittenToDiskNotJustHeldInMemory() throws {
        _ = stubConsent(true)
        AppState.shared.config.ambientConsentAcknowledged = false
        AppState.shared.saveConfig()

        // Control: absent on disk before the gate runs, or the assertion after
        // it could be reading an answer from some earlier run.
        let before = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: Persistence.configURL)) as? [String: Any]
        XCTAssertEqual(before?["ambientConsentAcknowledged"] as? Bool, false,
                       "control: the flag was already true on disk, so this test proves nothing")

        _ = MicConsent.ensureAcknowledged(for: .ambient)

        let after = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: Persistence.configURL)) as? [String: Any]
        XCTAssertEqual(after?["ambientConsentAcknowledged"] as? Bool, true,
                       "the answer was never persisted, so the dialog comes back on every launch")
    }

    /// THE TWO ANSWERS ARE NOT INTERCHANGEABLE. Ambient transcribes on this Mac;
    /// the wake word can send audio to Apple. One shared flag would have a user
    /// agree to the second by answering the first.
    func testConsentingToAmbientDoesNotConsentToTheWakeWord() async {
        let asked = stubConsent(true)
        AppState.shared.config.ambientConsentAcknowledged = false
        AppState.shared.config.wakeWordConsentAcknowledged = false

        _ = MicConsent.ensureAcknowledged(for: .ambient)
        XCTAssertFalse(AppState.shared.config.wakeWordConsentAcknowledged,
                       "answering the ambient dialog consented to sending audio to Apple")

        _ = MicConsent.ensureAcknowledged(for: .wakeWord)
        XCTAssertEqual(asked(), 2, "the wake word reused the ambient answer")
    }

    // MARK: - Wake word

    func testDecliningConsentLeavesTheWakeWordOff() async {
        let asked = stubConsent(false)
        AppState.shared.config.wakeWordConsentAcknowledged = false
        AppState.shared.config.wakeWordEnabled = false

        await WakeWordListener.shared.enable()

        XCTAssertEqual(asked(), 1, "the wake word turned on without asking")
        XCTAssertFalse(AppState.shared.config.wakeWordEnabled,
                       "the preference was written despite a declined answer")
    }

    func testAcceptingConsentTurnsTheWakeWordOn() async {
        _ = stubConsent(true)
        AppState.shared.config.wakeWordConsentAcknowledged = false
        AppState.shared.config.wakeWordEnabled = false

        await WakeWordListener.shared.enable()

        XCTAssertTrue(AppState.shared.config.wakeWordEnabled,
                      "the user said yes and the preference never moved")
    }

    // MARK: - The doors

    /// EVERY DOOR, NOT THE ONES THAT WERE EASY TO REMEMBER.
    ///
    /// The behavioural tests above prove the gate works at the choke point.
    /// This proves nothing ROUTES AROUND it, which is the half a runtime test
    /// cannot see: a new view that sets `config.ambientEnabled = true` directly
    /// would take the microphone with every test above still green.
    func testTheListeningPreferencesAreOnlyTurnedOnBehindTheGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }) ?? []
        XCTAssertGreaterThan(files.count, 50, "control: the sweep found \(files.count) files and is broken")

        // The one file allowed to flip each preference on: the gated door.
        let allowed = [
            "ambientEnabled": "AmbientState.swift",
            "wakeWordEnabled": "WakeWord.swift"
        ]
        var offenders: [String] = []
        var foundAtAll = 0
        for f in files {
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { continue }
            // Comments discuss these preferences all over the tree, and a sweep
            // that reads prose is the exact defect this wave also fixed in
            // MicMuteReleasesDeviceTests.
            let text = MicMuteReleasesDeviceTests.stripComments(raw)
            for (pref, home) in allowed {
                for pattern in ["config.\(pref) = true", "\(pref) = true"] where text.contains(pattern) {
                    foundAtAll += 1
                    if f.lastPathComponent != home {
                        offenders.append("\(f.lastPathComponent) sets \(pref) outside \(home)")
                    }
                    break
                }
            }
        }
        XCTAssertGreaterThanOrEqual(foundAtAll, 2,
                                    "control: found \(foundAtAll) enable sites, so the pattern no longer matches anything")
        XCTAssertTrue(offenders.isEmpty,
                      """
                      \(offenders) turn a listening feature on without going through the \
                      consent gate. That is how the menu bar row and the ambient HUD pill \
                      shipped taking the microphone with no disclosure.
                      """)
    }
}

/// MUTE MUST NOT LEAVE AN ENGINE BEHIND, AND A GUARD MUST SURVIVE ITS AWAIT.
///
/// Three defects with one shape: the code checked the right thing at the wrong
/// moment, and the microphone stayed live while every surface read MUTED.
@MainActor
final class MicListenerLifecycleTests: XCTestCase {

    private var savedMuted = false

    override func setUp() async throws {
        try await super.setUp()
        savedMuted = AppState.shared.micMuted
    }

    override func tearDown() async throws {
        AmbientListener.shared.stop()
        AppState.shared.micMuted = savedMuted
        try await super.tearDown()
    }

    /// THE ORPHANED ENGINE, AT ITS ROOT CAUSE.
    ///
    /// Muting during a meeting fires a summariser that takes seconds. Unmuting
    /// inside that window called `start()`, which built engine A. The summariser
    /// then finished and called `resumeFromMeeting()`, which found
    /// `pausedForMeeting` STILL TRUE because `stop()` never cleared it, so
    /// `resumeIfReady` built engine B and assigned it over A without stopping A.
    /// A later mute stopped only B. Engine A kept its tap on the input node for
    /// the life of the process, which is the reported symptom exactly: MUTED on
    /// screen, orange dot lit, other apps unable to record.
    ///
    /// `stop()` is a full reset, so the reasons it was paused stop being true.
    func testStopClearsEveryPauseReason() {
        AmbientListener.shared.pauseForMeeting()
        // Control. Without this the assertions below pass on a flag that was
        // never set, which is how the first version of MicMuteBehaviourTests
        // managed to stay green with the feature deleted.
        XCTAssertTrue(AmbientListener.shared.pausedForMeeting,
                      "control: pauseForMeeting did not set the flag, so this test proves nothing")

        AmbientListener.shared.stop()

        XCTAssertFalse(AmbientListener.shared.pausedForMeeting,
                       "stop() left pausedForMeeting set, so a late resumeFromMeeting builds a second engine over the first")
        XCTAssertFalse(AmbientListener.shared.pausedForSpeech,
                       "stop() left pausedForSpeech set")
        XCTAssertFalse(AmbientListener.shared.pausedForExplicit,
                       "stop() left pausedForExplicit set")
    }

    /// And a resume that arrives after the stop must do nothing at all, which is
    /// the property the cleared flags buy.
    func testAResumeThatArrivesAfterAStopIsIgnored() async {
        AmbientListener.shared.pauseForMeeting()
        AmbientListener.shared.stop()

        AmbientListener.shared.resumeFromMeeting()
        // resumeIfReady sleeps 400ms before it touches the engine.
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertFalse(AmbientState.shared.isCapturing,
                       "a resume from before the stop restarted capture after it")
    }

    /// ENTRY-ONLY GUARDS, ASSERTED STRUCTURALLY BECAUSE THE RACE HAS NO SEAM.
    ///
    /// Each of these three functions checks `micMuted` and THEN awaits an
    /// authorization prompt or a model download before touching hardware. A
    /// mute landing in that window was overtaken by the listener it was trying
    /// to stop. Reproducing that at runtime means winning a race against a TCC
    /// prompt, so what is asserted instead is the structural property that
    /// makes the race impossible: a mute check AFTER the last suspension point.
    ///
    /// Comments are stripped first. Every one of these functions now carries a
    /// comment containing the word `micMuted`, and a sweep that reads its own
    /// documentation is the defect this wave fixed twice elsewhere.
    func testEveryListenerRechecksTheMuteAfterItsLastAwait() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")

        // file, function signature, and the line that takes the device.
        let cases: [(String, String, String)] = [
            ("Ambient/AmbientListener.swift", "func start() async {", "try startEngine()"),
            ("VoiceInput.swift", "func start(autoSendOnSilence: Bool = false", "audioEngine = AVAudioEngine()"),
            ("WakeWord.swift", "func start() async {", "try startEngineAndTask()")
        ]

        for (file, signature, hardware) in cases {
            let raw = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let text = MicMuteReleasesDeviceTests.stripComments(raw)
            let sig = try XCTUnwrap(text.range(of: signature), "\(file): \(signature) moved")
            let body = String(text[sig.upperBound...])
            let hw = try XCTUnwrap(body.range(of: hardware), "\(file): \(hardware) moved")
            let beforeHardware = String(body[body.startIndex..<hw.lowerBound])

            let lastAwait = try XCTUnwrap(beforeHardware.range(of: "await ", options: .backwards),
                                          "\(file): no await before it takes the device, so this case is stale")
            let afterAwait = String(beforeHardware[lastAwait.upperBound...])
            XCTAssertTrue(afterAwait.contains("micMuted"),
                          """
                          \(file) checks micMuted only before its last await, so a mute that \
                          lands during authorization or a model load is overtaken and the \
                          listener takes the microphone with the UI reading MUTED.
                          """)
        }
    }

    /// `VoiceInput.stop()` MUST NOT BUILD THE INPUT NODE WHEN NOTHING RAN.
    ///
    /// `AVAudioEngine.inputNode` is lazy: reading it instantiates the node and
    /// queries the current input hardware. `MicController.mute()` calls
    /// `VoiceInput.shared.stop()` unconditionally, so on an install where
    /// dictation had never once run, muting reached into the microphone stack
    /// to stop something that did not exist.
    ///
    /// Asserted structurally and deliberately so: AVAudioEngine exposes no way
    /// to ask whether its input node has been realised, so there is no
    /// observable seam to assert against. The honest version of this test says
    /// which kind it is rather than dressing a source read up as a behavioural
    /// one.
    func testVoiceInputStopGuardsBeforeItTouchesTheEngine() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/VoiceInput.swift"), encoding: .utf8)
        let text = MicMuteReleasesDeviceTests.stripComments(src)
        let sig = try XCTUnwrap(text.range(of: "\n    func stop() {"), "VoiceInput.stop() was renamed")
        let body = String(text[sig.upperBound...])
        let guardSite = try XCTUnwrap(body.range(of: "guard isRecording else { return }"),
                                      "VoiceInput.stop() has no isRecording guard")
        let engineSite = try XCTUnwrap(body.range(of: "audioEngine.inputNode"),
                                       "VoiceInput.stop() no longer touches inputNode, so this case is stale")
        XCTAssertTrue(guardSite.lowerBound < engineSite.lowerBound,
                      "stop() reads audioEngine.inputNode before the guard, which builds the node on every defensive stop")
    }

    /// And it must be harmless to call on an install that never dictated.
    func testStoppingDictationThatNeverStartedIsHarmless() {
        XCTAssertFalse(VoiceInput.shared.isRecording, "control: dictation is running, so this proves nothing")
        VoiceInput.shared.stop()
        VoiceInput.shared.stop()
        XCTAssertFalse(VoiceInput.shared.isRecording)
    }
}
