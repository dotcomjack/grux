import XCTest
@testable import Grux

/// D72 (sense pass 5, `meetings-1.png`, `focus-1.png`): "Confirm you will tell
/// people" and "Confirm what stays private" carried "Run setup again", read by
/// people who never walked those steps. Wave 26 round 1 (P2): "Open setup"
/// still landed on a Settings pane to hunt for the choice. The button now does
/// what Settings' "Restart onboarding" does, behind the same question, and says
/// so; it never claims to confirm anything itself.
@MainActor
final class SetupCardStepButtonTests: XCTestCase {
    private let firstRunSteps: [SetupRequirement] = [.stepRecordingConsentAcknowledged,
                                                     .stepCaptureExclusionsConfirmed,
                                                     .stepCorpusSourcesConfirmed]

    /// D138 item 1: these three are now asked on the card itself
    /// (`SetupCardAnswersConsentTests`); none lands on a pane to hunt for the choice.
    func test_aStepAnsweredInTheSetupWalkIsAskedOnTheCard() {
        for step in firstRunSteps {
            XCTAssertTrue(SettingsTabAliases.stepNeedsFirstRun(step), "\(step) moved out of the setup walk")
            XCTAssertEqual(CapabilitySetupCard.actionTitle(for: step), "Review", "\(step)")
            XCTAssertEqual(CapabilitySetupCard.stepRoute(for: step), .answerHere,
                           "\(step) still lands on a pane to hunt for the choice")
        }
        XCTAssertEqual(CapabilitySetupCard.stepRoute(for: .stepTerminalSessionsExplained), .settings("sessions"))
        XCTAssertNil(CapabilitySetupCard.stepRoute(for: .stepSpeechModelDownloaded))
    }

    /// The card asks the same question Settings asks, in the same words.
    func test_theCardAndSettingsAskTheSameQuestion() throws {
        XCTAssertEqual(OnboardingModel.restartTitle, "Restart onboarding")
        XCTAssertEqual(OnboardingModel.restartQuestion, "Restart onboarding?")
        XCTAssertTrue(OnboardingModel.restartDetail.hasPrefix("The main window switches to the first-run screens immediately."))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Grux/SettingsView.swift", "Sources/Grux/Onboarding/CapabilitySetupCard.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(src.contains("OnboardingModel.restartQuestion") && src.contains("OnboardingModel.restartDetail"),
                          "\(file) words the restart question itself")
        }
    }

    func test_noStepButtonSaysAgainOrClaimsToConfirm() {
        for step in SetupRequirement.allCases where step.kind == .step {
            guard let title = CapabilitySetupCard.actionTitle(for: step) else { continue }
            XCTAssertFalse(title.lowercased().contains("again"), "\(step): \(title)")
            XCTAssertFalse(title.lowercased().hasPrefix("confirm"), "\(step): \(title) does not confirm anything")
        }
    }

    func test_otherButtonsAreUnchanged() {
        XCTAssertEqual(CapabilitySetupCard.actionTitle(for: .stepTerminalSessionsExplained), "Open Settings")
        XCTAssertNil(CapabilitySetupCard.actionTitle(for: .stepSpeechModelDownloaded))
    }
}
