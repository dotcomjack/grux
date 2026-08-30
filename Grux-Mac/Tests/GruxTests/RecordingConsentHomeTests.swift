import XCTest
@testable import Grux

/// The recording consent has ONE home, and the capability reads it.
///
/// The modal with legal weight writes `config.recordingConsentAcknowledged`. The capability
/// `step.recording_consent_acknowledged` read a separate UserDefaults key that the modal
/// never touches, so somebody who had answered the dialog still had the step reported as
/// outstanding, `grux status` still listed it, and `grux meeting start` refused with exit 2
/// telling them to answer a dialog they had already answered. No number of attempts would
/// have changed it.
@MainActor
final class RecordingConsentHasOneHomeTests: XCTestCase {

    private var before = false

    override func setUp() async throws {
        before = AppState.shared.config.recordingConsentAcknowledged
    }

    override func tearDown() async throws {
        // RESTORED, not reset. This is the operator's own answer to a consent question and
        // a test has no business changing it.
        AppState.shared.config.recordingConsentAcknowledged = before
    }

    func testTheCapabilityFollowsTheAnswerTheModalWrites() {
        AppState.shared.config.recordingConsentAcknowledged = true
        XCTAssertTrue(CapabilityResolver.isSatisfied(.stepRecordingConsentAcknowledged),
            "the consent modal recorded a yes and the capability still reads unsatisfied, "
            + "so grux meeting start refuses forever and names a dialog already answered")

        AppState.shared.config.recordingConsentAcknowledged = false
        XCTAssertFalse(CapabilityResolver.isSatisfied(.stepRecordingConsentAcknowledged),
            "the capability reads satisfied with no consent recorded, which is the worse "
            + "direction: it would let a recording start on an answer nobody gave")
    }

    /// And the onboarding checkbox writes where the capability reads.
    func testTickingTheStepIsVisibleToTheCapability() {
        AppState.shared.config.recordingConsentAcknowledged = false
        CapabilityResolver.markStepCompleted(.stepRecordingConsentAcknowledged, true)
        XCTAssertTrue(AppState.shared.config.recordingConsentAcknowledged,
            "the onboarding control wrote a key nothing consults, so the switch springs "
            + "back the next time the screen is drawn")
        XCTAssertTrue(CapabilityResolver.isSatisfied(.stepRecordingConsentAcknowledged))

        CapabilityResolver.markStepCompleted(.stepRecordingConsentAcknowledged, false)
        XCTAssertFalse(AppState.shared.config.recordingConsentAcknowledged,
            "unticking it left the consent recorded, so it cannot be taken back")
    }
}
