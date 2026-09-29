import XCTest
@testable import Grux

/// The gate every live Accessibility test passes first (RV22).
///
/// OFF BY DEFAULT UNDER XCTEST. The live tests read Finder's real accessibility tree
/// and post real events, which needs the test host itself to be trusted. On this
/// macOS even the non-prompting trust check (`AXIsProcessTrusted`) from an untrusted
/// test host raises the system "would like to control this computer" dialog
/// (D-axprompt), so a plain run never asks: `AccessibilityTrust.isGranted()` answers
/// `testAnswer` there, and these tests skip with `offReason`.
///
/// TO RUN THEM: on a Mac where the test host (xctest, or Xcode's runner) is already
/// in System Settings, Privacy and Security, Accessibility, set
/// `GRUX_LIVE_AX_TESTS=1` in the test process's environment. The gate then reads the
/// real trust state once and, when trusted, opens the door (`testAnswer = true`) for
/// the rest of that test, restoring it after.
enum LiveAccessibility {
    static let offReason = "Live Accessibility tests are off by default under XCTest, because asking an "
        + "untrusted test host raises the system dialog. Set \(AccessibilityTrust.liveTestsEnv)=1 on a Mac "
        + "where the test host is trusted to run this."
    static let untrustedReason = "\(AccessibilityTrust.liveTestsEnv)=1 is set, but the test host is not "
        + "trusted for Accessibility on this Mac."

    static func require(_ test: XCTestCase) throws {
        try XCTSkipUnless(AccessibilityTrust.liveTestsOptedIn, offReason)
        try XCTSkipUnless(AccessibilityTrust.liveTrustForOptedInTest(), untrustedReason)
        let saved = AccessibilityTrust.testAnswer
        AccessibilityTrust.testAnswer = true
        test.addTeardownBlock { AccessibilityTrust.testAnswer = saved }
    }
}
