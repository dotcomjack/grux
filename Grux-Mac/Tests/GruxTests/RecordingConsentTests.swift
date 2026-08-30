import XCTest
@testable import Grux

/// Recording a call captures every person on it and only one of them is holding the mouse.
/// These guard the gate that asks the owner, once, to confirm they will say so.
final class RecordingConsentTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux").appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The whole design rests on this: ONE gate, at the function every path goes through.
    /// There are five entry points today, the menu bar pill, the Meetings tab, the panel,
    /// the keyboard shortcut and the model-callable tool, and the sixth written next month
    /// must be covered without anyone remembering to cover it.
    func testTheGateIsAtTheChokePointNotAtTheCallSites() throws {
        let service = try source("Meeting/MeetingCaptureService.swift")
        XCTAssertTrue(service.contains("RecordingConsent.ensureAcknowledged()"),
                      "the consent gate must live in MeetingCaptureService.start()")

        // And nowhere else, because a second gate is a second thing to keep in sync.
        for caller in ["MenuBarView.swift", "Meeting/MeetingsView.swift",
                       "Meeting/MeetingPanelView.swift", "Meeting/MeetingTool.swift"] {
            let src = try source(caller)
            XCTAssertFalse(src.contains("RecordingConsent.ensureAcknowledged"),
                           "\(caller) must not gate separately, the choke point covers it")
        }
    }

    /// Ordering matters and is easy to get wrong: prompting before the cheap guards would
    /// put a dialog in front of someone whose Mac cannot record at all, or who pressed the
    /// shortcut twice during a capture that is already running.
    func testTheCheapGuardsRunBeforeThePrompt() throws {
        let src = try source("Meeting/MeetingCaptureService.swift")
        let alreadyCapturing = try XCTUnwrap(src.range(of: "guard !isCapturing, !isInitializing"))
        let supported = try XCTUnwrap(src.range(of: "guard isSystemAudioSupported"))
        let consent = try XCTUnwrap(src.range(of: "RecordingConsent.ensureAcknowledged()"))
        XCTAssertLessThan(alreadyCapturing.lowerBound, consent.lowerBound,
                          "a repeat start during a live capture must not prompt")
        XCTAssertLessThan(supported.lowerBound, consent.lowerBound,
                          "an unsupported OS must not prompt")
    }

    /// Declining is an answer, not a crash. The model must report it and stop, not retry.
    func testDecliningIsReportedAsAnAnswerNotAnError() throws {
        let tool = try source("Meeting/MeetingTool.swift")
        XCTAssertTrue(tool.contains("ok: not recording"),
                      "a declined prompt must come back as ok:, so the model states it "
                      + "plainly instead of apologising for a bug that did not happen")
        XCTAssertTrue(tool.contains("Do not retry"),
                      "the model must be told not to retry a refusal")
        // And the model should know the gate exists before it calls, not after.
        XCTAssertTrue(tool.contains("confirm they will tell the other"),
                      "the tool description must disclose the consent step")
    }

    /// A one-time question you can never see again is a trap. Settings has to show the
    /// state and be able to put it back.
    func testTheAnswerIsVisibleAndReversibleInSettings() throws {
        let settings = try source("SettingsView.swift")
        XCTAssertTrue(settings.contains("RecordingConsent.reset()"),
                      "the user must be able to ask for the prompt again")
        XCTAssertTrue(settings.contains("recordingConsentAcknowledged"),
                      "Settings must show the current answer")

        // And it must be findable. An unregistered anchor still renders, so this would
        // pass unnoticed while nobody could search for the one setting they came for.
        let registry = try source("Settings/SettingsSearchRegistry.swift")
        XCTAssertTrue(registry.contains("id: \"meeting.consent\""),
                      "the section must be registered or search cannot find it")
        for term in ["recording", "consent", "privacy"] {
            XCTAssertTrue(SettingsSearchRegistry.sectionVisible(anchor: "meeting.consent",
                                                                query: term),
                          "searching \(term) must surface the consent section")
        }
    }

    /// Defaults false for an EXISTING install too. Nobody already running Grux has been
    /// asked, so assuming an answer they never gave is the one thing this must not do.
    func testAnExistingInstallIsStillAsked() throws {
        let models = try source("Models.swift")
        XCTAssertTrue(models.contains("recordingConsentAcknowledged: Bool = false"),
                      "must ship unacknowledged")
        XCTAssertTrue(models.contains("forKey: .recordingConsentAcknowledged) ?? false"),
                      "a config written before this shipped must decode to false, not true")
    }

    /// The copy is the feature. It has to name what happens, who it affects, and what the
    /// reader is agreeing to do.
    func testThePromptSaysWhatItActuallyDoes() {
        let text = RecordingConsent.title + " " + RecordingConsent.body
        for required in ["everyone", "recorded too", "required"] {
            XCTAssertTrue(text.lowercased().contains(required),
                          "the prompt must mention \(required)")
        }
        XCTAssertFalse(RecordingConsent.confirmTitle.lowercased().contains("ok"),
                       "the confirm button must state the commitment, not just dismiss")
        XCTAssertLessThan(RecordingConsent.body.count, 400, "keep it readable")
    }
}

/// AND THE GATE ITSELF, DRIVEN RATHER THAN READ.
///
/// Every test above this line is a source-text sweep. They prove the gate is
/// CALLED from the choke point, that no call site gates separately, that the
/// cheap guards run first and that the copy reads well. Not one of them ever
/// established that DECLINING STOPS A RECORDING, because until `presenter` was
/// injectable there was no way to answer the question without a modal.
///
/// For the one gate in this app with legal weight, "the call site looks right"
/// is the weaker half. This is the other half.
@MainActor
final class RecordingConsentBehaviourTests: XCTestCase {

    private var savedConfig: GruxConfig!

    override func setUp() async throws {
        try await super.setUp()
        savedConfig = AppState.shared.config
    }

    override func tearDown() async throws {
        RecordingConsent.presenter = { RecordingConsent.presentPrompt() }
        AppState.shared.config = savedConfig
        AppState.shared.saveAll()
        try await super.tearDown()
    }

    private func stub(_ answer: Bool) -> () -> Int {
        var asked = 0
        RecordingConsent.presenter = { asked += 1; return answer }
        return { asked }
    }

    /// A decline must stop the recording AND record nothing, so the next attempt
    /// asks again. A decline is about this moment, not a permanent preference.
    func testDecliningRefusesAndIsNotRemembered() async {
        let asked = stub(false)
        AppState.shared.config.recordingConsentAcknowledged = false

        let first = await RecordingConsent.ensureAcknowledged()
        XCTAssertFalse(first, "a declined prompt let the recording proceed")
        XCTAssertFalse(AppState.shared.config.recordingConsentAcknowledged,
                       "declining was written down as consent")

        let second = await RecordingConsent.ensureAcknowledged()
        XCTAssertFalse(second)
        XCTAssertEqual(asked(), 2, "a decline silenced the question for next time")
    }

    /// And it must not be a permanent refusal, or the feature is dead.
    func testAcceptingProceedsAndIsRememberedAcrossLaunches() async throws {
        let asked = stub(true)
        AppState.shared.config.recordingConsentAcknowledged = false
        AppState.shared.saveAll()

        // Control: not already true on disk from an earlier run, or the
        // assertion below could be reading somebody else's answer.
        let before = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: Persistence.configURL)) as? [String: Any]
        XCTAssertEqual(before?["recordingConsentAcknowledged"] as? Bool, false,
                       "control: already acknowledged on disk, so this test proves nothing")

        let accepted = await RecordingConsent.ensureAcknowledged()
        XCTAssertTrue(accepted)

        // READ THE FILE, not the in-memory config. Mutation testing on the
        // sibling gate showed that asserting the in-memory value passes even
        // when the save is deleted, which would forget the answer on the next
        // launch and re-prompt forever with a green suite.
        let after = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: Persistence.configURL)) as? [String: Any]
        XCTAssertEqual(after?["recordingConsentAcknowledged"] as? Bool, true,
                       "the answer was never persisted, so it is asked again every launch")

        // Asked ONCE. A gate that re-prompts is one people click through unread.
        let again = await RecordingConsent.ensureAcknowledged()
        let onceMore = await RecordingConsent.ensureAcknowledged()
        XCTAssertTrue(again)
        XCTAssertTrue(onceMore)
        XCTAssertEqual(asked(), 1, "asked \(asked()) times, so the answer is not remembered")
    }

    /// `reset()` must genuinely put the question back, or the Settings button
    /// that offers to ask again is a lie.
    func testResetPutsTheQuestionBack() async {
        let asked = stub(true)
        AppState.shared.config.recordingConsentAcknowledged = true

        RecordingConsent.reset()
        XCTAssertFalse(AppState.shared.config.recordingConsentAcknowledged,
                       "reset did not clear the answer")

        let reasked = await RecordingConsent.ensureAcknowledged()
        XCTAssertTrue(reasked)
        XCTAssertEqual(asked(), 1, "after a reset the user was never asked again")
    }

    /// An already-acknowledged install must never see the dialog. This is what
    /// makes the gate one-time rather than a nag on every recording.
    func testAnAcknowledgedInstallIsNeverPrompted() async {
        let asked = stub(false)   // would refuse if it were ever consulted
        AppState.shared.config.recordingConsentAcknowledged = true

        let proceeded = await RecordingConsent.ensureAcknowledged()
        XCTAssertTrue(proceeded, "an install that already answered was refused")
        XCTAssertEqual(asked(), 0, "an already-acknowledged install was prompted again")
    }

    /// The dialog can be raised by a model-callable tool while the user is in
    /// another app, so it has to be dismissable from the keyboard.
    func testTheDeclineButtonAnswersToEscape() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Meeting/RecordingConsent.swift"), encoding: .utf8)
        let text = MicMuteReleasesDeviceTests.stripComments(src)
        XCTAssertTrue(text.contains("keyEquivalent"),
                      "the decline button has no key equivalent, so Escape does nothing: "
                    + "AppKit only wires Escape to a button titled exactly Cancel")
    }
}
