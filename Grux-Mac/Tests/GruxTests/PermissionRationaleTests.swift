import XCTest
@testable import Grux

/// "Permissions JUST IN TIME with the contract's rationale shown BEFORE the
/// macOS prompt."
///
/// The rationale is DERIVED from the contract remediation rather than written a
/// second time. That is the load-bearing decision and these tests hold it: two
/// sets of sentences describing one capability to one person is exactly the pair
/// that drifted before, when two remediations diverged behind a claim that they
/// were transcribed verbatim.
@MainActor
final class PermissionRationaleTests: XCTestCase {

    private var permissions: [SetupRequirement] {
        SetupRequirement.allCases.filter { $0.kind == .perm }
    }

    /// Nine, from the contract. A count so a capability cannot quietly leave.
    func testEveryPermissionHasARationale() {
        XCTAssertEqual(permissions.count, 9)
        for req in permissions {
            XCTAssertFalse(req.rationale.isEmpty, "\(req.rawValue) has no rationale")
            XCTAssertTrue(req.remediation.hasPrefix(req.rationale),
                          "\(req.rawValue): the rationale must be the contract's own opening "
                          + "sentence, not a paraphrase. got '\(req.rationale)'")
        }
    }

    /// Splitting must be lossless. If rationale plus instructions do not
    /// reconstruct the remediation then the split is dropping words the contract
    /// put there on purpose.
    func testRationalePlusInstructionsReconstructTheRemediation() {
        for req in SetupRequirement.allCases {
            let rejoined = req.instructions.isEmpty
                ? req.rationale
                : req.rationale + " " + req.instructions
            XCTAssertEqual(rejoined, req.remediation, "\(req.rawValue) lost text in the split")
        }
    }

    /// The rationale answers WHY and must not smuggle in the how. A permission
    /// screen that opens with "Open System Settings" is telling somebody what to
    /// do before telling them what for, which is the exact failure the just in
    /// time ordering exists to fix.
    func testTheRationaleDoesNotStartWithInstructions() {
        for req in permissions {
            XCTAssertFalse(req.rationale.contains("Open System Settings"),
                           "\(req.rawValue): the reason must come before the instructions; "
                           + "got '\(req.rationale)'")
            XCTAssertFalse(req.rationale.isEmpty)
        }
    }

    /// Every permission Grux offers in onboarding still has to have a real
    /// remediation. A capability with an empty instruction half and no prompt
    /// would be a screen with a button that cannot do anything.
    func testEveryOfferedPermissionIsEitherPromptableOrExplained() {
        for req in CapabilityRequest.onboardingOrder {
            switch CapabilityRequest.style(for: req) {
            case .prompt:
                continue
            case .systemSettingsOnly:
                XCTAssertFalse(req.instructions.isEmpty,
                               "\(req.rawValue) cannot raise a prompt, so the screen has "
                               + "nothing to tell the user to do")
            }
        }
    }

    /// Screen Recording, Accessibility, Full Disk Access and Automation CANNOT
    /// be granted by a dialog an app raises. Labelling one of them promptable
    /// puts an "Allow" button on screen that does nothing at all, which reads as
    /// a broken app rather than a macOS limitation.
    func testUnpromptablePermissionsAreNotLabelledPromptable() {
        for req in [SetupRequirement.permScreenRecording, .permSystemAudio,
                    .permAccessibility, .permFullDiskAccess, .permAutomation] {
            XCTAssertEqual(CapabilityRequest.style(for: req), .systemSettingsOnly,
                           "\(req.rawValue) has no prompt macOS will show on demand")
        }
    }

    /// The ones macOS genuinely does prompt for should ask directly. Sending
    /// somebody to System Settings for the microphone when a one-tap dialog
    /// exists is a worse experience for no reason.
    func testPromptablePermissionsAreAsked() {
        for req in [SetupRequirement.permMicrophone, .permCalendar,
                    .permContacts, .permNotifications] {
            XCTAssertEqual(CapabilityRequest.style(for: req), .prompt, "\(req.rawValue)")
        }
    }

    /// system_audio resolves to the same Screen Recording grant, so offering
    /// both would walk the user through the same System Settings pane twice and
    /// look like the first one had failed.
    func testOnboardingDoesNotOfferTheSameGrantTwice() {
        let order = CapabilityRequest.onboardingOrder
        XCTAssertTrue(order.contains(.permScreenRecording))
        XCTAssertFalse(order.contains(.permSystemAudio),
                       "system_audio is the same macOS grant as screen_recording")
        XCTAssertEqual(Set(order).count, order.count, "a permission is offered twice")
    }

    /// Full Disk Access reads as the most alarming ask in the list, so it goes
    /// last. Leading with it colours every permission that follows.
    func testTheHeaviestAskIsOfferedLast() {
        XCTAssertEqual(CapabilityRequest.onboardingOrder.last, .permFullDiskAccess)
    }

    /// The contract caps remediations at 140 characters, and the rationale is a
    /// substring, so this is really a guard on the split staying sane rather
    /// than returning the whole string when there is no full stop.
    func testRationaleIsASentenceNotTheWholeParagraph() {
        for req in permissions {
            XCTAssertLessThanOrEqual(req.rationale.count, req.remediation.count)
            XCTAssertTrue(req.rationale.hasSuffix("."),
                          "\(req.rawValue): '\(req.rationale)'")
        }
    }
}
