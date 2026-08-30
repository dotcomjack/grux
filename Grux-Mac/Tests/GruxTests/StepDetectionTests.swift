import XCTest
@testable import Grux

/// A SETUP STEP THAT ONLY A CHECKBOX CAN SATISFY IS A LOOP NOBODY CAN CLOSE.
///
/// Every `step.*` capability used to resolve to a `UserDefaults` boolean whose only writers
/// were in-app controls. So somebody could install the agent CLI, fetch the speech model
/// and write the focus hook, and Grux would still report `needs-setup`, the counts would
/// not move, and regenerating the agent handoff produced identical text. `AgentHandoff`
/// shipped a paragraph warning the reader about exactly that, because the alternative was
/// pretending it had noticed.
///
/// Four steps are now DETECTED from the machine and six remain self-attested on purpose.
/// The split is the point: a probe for "you confirmed you will tell people you are
/// recording" does not exist and should not, so those stay somebody's word and `grux status`
/// says so rather than implying a check it never ran.
@MainActor
final class StepDetectionTests: XCTestCase {

    private var allSteps: [SetupRequirement] {
        SetupRequirement.allCases.filter { $0.kind == .step }
    }

    /// The two sets must cover every step exactly once. A step in neither is a step whose
    /// honesty nobody decided, and it would silently fall through to the flag.
    func testTheTwoSetsPartitionEveryStep() {
        let detected = CapabilityResolver.detectedSteps
        let attested = CapabilityResolver.selfAttestedSteps

        XCTAssertTrue(detected.isDisjoint(with: attested),
            "these steps are in both sets: \(detected.intersection(attested).map(\.rawValue).sorted())")

        let covered = detected.union(attested)
        let missing = Set(allSteps).subtracting(covered).map(\.rawValue).sorted()
        XCTAssertTrue(missing.isEmpty,
            "\(missing) is a step in neither detectedSteps nor selfAttestedSteps, so nobody "
            + "decided whether Grux can check it and it quietly falls through to a checkbox")

        let stray = covered.subtracting(Set(allSteps)).map(\.rawValue).sorted()
        XCTAssertTrue(stray.isEmpty, "\(stray) is classified as a step but is not one")

        XCTAssertEqual(allSteps.count, 10, "the step count changed, so revisit the split")
        XCTAssertEqual(detected.count, 4)
        XCTAssertEqual(attested.count, 6)
    }

    /// THE ONE THAT MATTERS. For a detected step the stored flag must not be able to change
    /// the answer, in either direction: a tick cannot survive an uninstall, and an install
    /// needs no tick. Asserted by flipping the flag both ways and requiring the answer to be
    /// identical, which holds whether or not the artifact happens to exist on this machine.
    func testTheStoredFlagCannotMoveADetectedStep() {
        for step in CapabilityResolver.detectedSteps {
            guard let key = CapabilityResolver.stepDefaultsKey(for: step) else {
                XCTFail("\(step.rawValue) has no defaults key, so this proves nothing")
                continue
            }
            let original = UserDefaults.standard.object(forKey: key)
            defer {
                if let original { UserDefaults.standard.set(original, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }

            UserDefaults.standard.set(false, forKey: key)
            let withFlagOff = CapabilityResolver.isSatisfied(step)
            UserDefaults.standard.set(true, forKey: key)
            let withFlagOn = CapabilityResolver.isSatisfied(step)

            XCTAssertEqual(withFlagOff, withFlagOn, """
                \(step.rawValue) changed answer when the stored flag flipped, so it is still
                a checkbox rather than a detection. Off said \(withFlagOff), on said \(withFlagOn).
                """)
        }
    }

    /// The mirror of the above: a self-attested step MUST follow the answer somebody gave,
    /// or the person's answer is being ignored.
    ///
    /// DRIVEN THROUGH `markStepCompleted`, WHICH IS THE ONLY WRITER, rather than by poking
    /// the UserDefaults key. That distinction is the whole point: a step's truth does not
    /// always live in its own key. `step.first_frame_reviewed` reads onboarding state, and
    /// `step.recording_consent_acknowledged` reads `config.recordingConsentAcknowledged`,
    /// because that is where the consent modal with legal weight actually writes its answer.
    ///
    /// The first version set the key directly, which meant it could only ever have tested
    /// the steps whose truth happens to live in a key, and it PASSED while the consent step
    /// was split across two stores: the flag it set was one nothing consulted, so somebody
    /// who had answered the modal still had the step reported outstanding and
    /// `grux meeting start` refused with exit 2 naming a dialog they had already answered.
    /// Writing where a reader does not read is exactly what this now catches.
    func testASelfAttestedStepFollowsTheAnswerSomebodyGave() {
        let steps = CapabilityResolver.selfAttestedSteps.subtracting([.stepFirstFrameReviewed])
        XCTAssertFalse(steps.isEmpty, "control: nothing left to check")

        for step in steps {
            // RESTORED FROM THE READ, not from a key, so a step whose truth lives elsewhere
            // is put back correctly too. These are the operator's own answers to consent
            // questions and a test has no business changing them.
            let original = CapabilityResolver.isSatisfied(step)
            defer { CapabilityResolver.markStepCompleted(step, original) }

            CapabilityResolver.markStepCompleted(step, false)
            XCTAssertFalse(CapabilityResolver.isSatisfied(step),
                           "\(step.rawValue) reports satisfied after being set to false, so "
                           + "a person taking their answer back does not take")
            CapabilityResolver.markStepCompleted(step, true)
            XCTAssertTrue(CapabilityResolver.isSatisfied(step),
                          "\(step.rawValue) reports unsatisfied after being answered, so "
                          + "the writer and the reader are looking at different places")
        }
    }

    /// The four consent decisions must never leave the self-attested set. If one is ever
    /// "detected", something is inferring consent from a side effect, which is not consent.
    func testConsentIsNeverDetected() {
        for consent: SetupRequirement in [.stepRecordingConsentAcknowledged,
                                          .stepCaptureExclusionsConfirmed,
                                          .stepCorpusSourcesConfirmed,
                                          .stepFirstFrameReviewed] {
            XCTAssertTrue(CapabilityResolver.selfAttestedSteps.contains(consent),
                "\(consent.rawValue) left the self-attested set. A consent decision inferred "
                + "from a side effect is not consent.")
            XCTAssertFalse(CapabilityResolver.detectedSteps.contains(consent))
        }
    }

    // MARK: - The probes themselves

    /// `resolveClaudeBinary` ends `?? "claude"`, a bare name for a shell to resolve on PATH.
    /// That is right for spawning and wrong for asking, and two call sites were asking:
    /// `resolvedBinary.isEmpty` could never be true, so a Mac with no agent CLI showed
    /// `claude` in the Terminal Sessions pane and hid the sentence explaining it was missing.
    func testTheLocatorCanSayNoAndTheSpawnerStillFallsBack() {
        XCTAssertEqual(AccountSwitcher.resolveClaudeBinary(),
                       AccountSwitcher.locateClaudeBinary() ?? "claude",
                       "the spawner must be exactly the locator plus its PATH fallback")
        XCTAssertFalse(AccountSwitcher.resolveClaudeBinary().isEmpty,
                       "the old emptiness test is unreachable, which is why it was a bug")
        if let found = AccountSwitcher.locateClaudeBinary() {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: found),
                          "the locator returned \(found), which is not executable")
        }
    }

    /// A directory left behind by an interrupted download is not a model. WhisperKit writes
    /// three compiled bundles and the model is unusable without all three.
    func testTheSpeechModelNeedsAllThreeBundles() {
        XCTAssertTrue(CapabilityResolver.speechModelPath.hasSuffix("openai_whisper-small.en"),
                      "the model path stopped naming the model AmbientListener actually loads")
        let present = CapabilityResolver.speechModelIsDownloaded()
        let dirExists = FileManager.default.fileExists(atPath: CapabilityResolver.speechModelPath)
        if present {
            XCTAssertTrue(dirExists, "reported downloaded with no directory at all")
            for bundle in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: CapabilityResolver.speechModelPath + "/" + bundle),
                    "reported downloaded without \(bundle)")
            }
        }
    }

    /// THE POSITIVE AND NEGATIVE CONTROLS. Every assertion above runs on a Mac where all
    /// three artifacts happen to exist, so "the flag cannot change the answer" passes with
    /// both answers true and proves very little on its own. These drive the probes against
    /// a temporary directory and require them to say NO, then YES, then NO again when one
    /// piece is taken away. A probe nobody has watched fail is not evidence.
    func testTheProbesCanActuallySayNo() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("grux-probe-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let model = dir.appendingPathComponent("openai_whisper-small.en")
        XCTAssertFalse(CapabilityResolver.speechModelIsDownloaded(at: model.path),
                       "control: reported a model in a directory that does not exist")

        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        XCTAssertFalse(CapabilityResolver.speechModelIsDownloaded(at: model.path),
                       "an empty directory is what an interrupted download leaves behind, "
                       + "and it was reported as a downloaded model")

        for bundle in CapabilityResolver.speechModelBundles {
            try fm.createDirectory(at: model.appendingPathComponent(bundle),
                                   withIntermediateDirectories: true)
        }
        XCTAssertTrue(CapabilityResolver.speechModelIsDownloaded(at: model.path),
                      "all three bundles present and it still says no")

        try fm.removeItem(at: model.appendingPathComponent(CapabilityResolver.speechModelBundles[1]))
        XCTAssertFalse(CapabilityResolver.speechModelIsDownloaded(at: model.path),
                       "two of three bundles is an unusable model and must not report ready")

        let hook = dir.appendingPathComponent("terminal-focus.sh")
        XCTAssertFalse(CapabilityResolver.terminalFocusHookIsInstalled(at: hook.path),
                       "control: reported a hook that is not there")
        try "#!/bin/sh\n".write(to: hook, atomically: true, encoding: .utf8)
        XCTAssertTrue(CapabilityResolver.terminalFocusHookIsInstalled(at: hook.path),
                      "hook written and it still says no")
    }

    /// One path, named once. `TerminalFocusState` writes the hook and the resolver reads it,
    /// and if those two ever disagree the pane and the setup card say different things about
    /// the same file.
    func testTheHookPathIsTheOneTerminalFocusWrites() {
        XCTAssertEqual(CapabilityResolver.terminalFocusHookPath,
                       NSHomeDirectory() + "/.claude/hooks/terminal-focus.sh")
        XCTAssertEqual(CapabilityResolver.isSatisfied(.stepTerminalFocusHookInstalled),
                       FileManager.default.fileExists(
                        atPath: CapabilityResolver.terminalFocusHookPath),
                       "the hook step disagrees with the file it is about")
    }
}
