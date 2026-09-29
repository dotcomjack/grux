import XCTest
@testable import Grux

/// Accessibility cannot be granted from inside an app, only toggled in System
/// Settings, and the toggle only exists once macOS has SEEN the app ask. The
/// Set up card's "Open System Settings for Accessibility" button therefore
/// asks first (the one-shot system dialog, which also lists Grux in the pane)
/// and opens the pane second. Without the ask, a fresh install or a rebuilt
/// app lands on a pane with no Grux row to turn on, and the person is left to
/// find the plus button. Measured on the test Mac on 2026-09-27 after the
/// stale entry was reset.
final class AccessibilityCTARegistersTests: XCTestCase {
    func testAccessibilityAsksTheSystemBeforeOpeningThePane() {
        XCTAssertTrue(CapabilityRequest.registersWithSystemFirst(.permAccessibility))
    }

    func testOtherSettingsOnlyPermissionsDoNotAsk() {
        for req in [SetupRequirement.permFullDiskAccess, .permAutomation, .permScreenRecording, .permMicrophone] {
            XCTAssertFalse(CapabilityRequest.registersWithSystemFirst(req), "\(req)")
        }
    }
}
