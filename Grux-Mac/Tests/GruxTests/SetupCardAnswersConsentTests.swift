import XCTest
@testable import Grux

/// D138 item 1 (sense pass 15, `focus-1.png`, `meetings-1.png`, `jaxCommand-1.png`):
/// a setup card whose item is a consent ("Confirm what stays private", "Confirm you
/// will tell people", "Choose what gets indexed") carried "Restart onboarding", which
/// threw a person back through every first-run screen to answer one question. The
/// card now asks that one question itself: Review shows what is being agreed to, and
/// its confirm button runs the same writer first run uses.
@MainActor
final class SetupCardAnswersConsentTests: XCTestCase {
    private let consentSteps: [SetupRequirement] = [.stepRecordingConsentAcknowledged,
                                                    .stepCaptureExclusionsConfirmed,
                                                    .stepCorpusSourcesConfirmed]

    func test_aConsentIsAnsweredOnTheCardNotByRestartingSetup() {
        for step in consentSteps {
            XCTAssertEqual(CapabilitySetupCard.stepRoute(for: step), .answerHere, "\(step)")
            XCTAssertEqual(CapabilitySetupCard.actionTitle(for: step), "Review", "\(step)")
            XCTAssertNotNil(CapabilitySetupCard.consent(for: step, config: .default), "\(step) has nothing to ask")
        }
        // Nothing else moved.
        XCTAssertEqual(CapabilitySetupCard.stepRoute(for: .stepTerminalSessionsExplained), .settings("sessions"))
        XCTAssertNil(CapabilitySetupCard.stepRoute(for: .stepSpeechModelDownloaded))
        XCTAssertNil(CapabilitySetupCard.consent(for: .stepTerminalSessionsExplained, config: .default))
        XCTAssertNil(CapabilitySetupCard.consent(for: .permMicrophone, config: .default))
    }

    /// The recording consent on the card is the one Meetings asks, word for word.
    func test_theRecordingConsentIsTheMeetingsQuestion() throws {
        let c = try XCTUnwrap(CapabilitySetupCard.consent(for: .stepRecordingConsentAcknowledged, config: .default))
        XCTAssertEqual(c.title, RecordingConsent.title)
        XCTAssertEqual(c.message, RecordingConsent.body)
        XCTAssertEqual(c.confirm, RecordingConsent.confirmTitle)
        XCTAssertNil(c.settingsTag)
    }

    /// The exclusions question names the list this Mac really has, and where to change it.
    func test_theExclusionsQuestionCountsTheListThisMacHas() throws {
        var config = GruxConfig.default
        config.captureExcludedBundleIds = CapturePrivacy.defaultExcludedBundleIds
        config.captureExcludedTitlePatterns = CapturePrivacy.defaultExcludedTitlePatterns
        let defaults = try XCTUnwrap(CapabilitySetupCard.consent(for: .stepCaptureExclusionsConfirmed, config: config))
        let n = CapturePrivacy.defaultExcludedBundleIds.count
        XCTAssertTrue(defaults.message.hasPrefix("Grux never captures \(n) apps: password managers, Keychain Access, Passwords and authenticator apps."),
                      defaults.message)
        XCTAssertTrue(defaults.message.contains("any window whose title names a password, a bank, a card number or a recovery phrase"),
                      defaults.message)
        XCTAssertTrue(defaults.message.contains("Settings, Data & Security, Data & Capabilities, Privacy and capture"), defaults.message)
        XCTAssertEqual(defaults.confirm, "Keep this list")
        XCTAssertEqual(defaults.settingsTag, "capture-privacy")
        XCTAssertEqual(SettingsTabAliases.resolve("capture-privacy"),
                       SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.capturePrivacy"))

        // An edited list is not described as the defaults.
        config.captureExcludedBundleIds = ["com.example.one"]
        config.captureExcludedTitlePatterns = ["salary"]
        let edited = try XCTUnwrap(CapabilitySetupCard.consent(for: .stepCaptureExclusionsConfirmed, config: config))
        XCTAssertTrue(edited.message.hasPrefix("Grux never captures 1 app you listed."), edited.message)
        XCTAssertTrue(edited.message.contains("1 title word you listed"), edited.message)
        XCTAssertFalse(edited.message.contains("password managers"), edited.message)

        // An emptied list says so instead of promising protection.
        config.captureExcludedBundleIds = []
        config.captureExcludedTitlePatterns = []
        let empty = try XCTUnwrap(CapabilitySetupCard.consent(for: .stepCaptureExclusionsConfirmed, config: config))
        XCTAssertTrue(empty.message.hasPrefix("Your list is empty, so Grux leaves out no app and no window."), empty.message)
    }

    /// Confirming the corpus step indexes nothing, and the question says so.
    func test_theCorpusQuestionSaysConfirmingIndexesNothing() throws {
        let c = try XCTUnwrap(CapabilitySetupCard.consent(for: .stepCorpusSourcesConfirmed, config: .default))
        XCTAssertTrue(c.message.contains("Nothing is indexed by confirming"), c.message)
        XCTAssertFalse(c.confirm.lowercased().contains("index"), c.confirm)
    }

    /// Answering on the card writes where the readers read, clears a skip, and tells
    /// every gate to redraw (nothing watches UserDefaults, so before this a card
    /// answered in place would have stayed up until something else redrew it).
    func test_answeringOnTheCardSatisfiesTheStepAndRedraws() {
        for step in consentSteps {
            let original = CapabilityResolver.isSatisfied(step)
            let wasSkipped = OnboardingModel.shared.wasSkipped(step)
            defer {
                CapabilityResolver.markStepCompleted(step, original)
                if wasSkipped { OnboardingModel.shared.markSkipped(step) }
            }
            CapabilityResolver.markStepCompleted(step, false)
            OnboardingModel.shared.markSkipped(step)
            let before = SetupRevision.shared.count

            CapabilitySetupCard.answer(step)

            XCTAssertTrue(CapabilityResolver.isSatisfied(step), "\(step)")
            XCTAssertFalse(OnboardingModel.shared.wasSkipped(step), "\(step) still reads skipped")
            XCTAssertGreaterThan(SetupRevision.shared.count, before, "\(step): nothing told the card to redraw")
        }
    }

    /// The gate and the card both watch the revision, so any step writer redraws them.
    func test_theGateAndTheCardWatchTheRevision() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Grux/Onboarding/CapabilityGate.swift", "Sources/Grux/Onboarding/CapabilitySetupCard.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(src.contains("@ObservedObject private var setupRevision = SetupRevision.shared"), file)
        }
        let before = SetupRevision.shared.count
        let original = CapabilityResolver.isSatisfied(.stepCorpusSourcesConfirmed)
        CapabilityResolver.markStepCompleted(.stepCorpusSourcesConfirmed, original)
        XCTAssertGreaterThan(SetupRevision.shared.count, before, "markStepCompleted does not bump the revision")
    }
}
