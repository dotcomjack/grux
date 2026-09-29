import ApplicationServices
import Foundation

/// The one door to the Accessibility trust state.
///
/// Asking macOS anything about Accessibility from a process it has not seen
/// before can raise the system "would like to control this computer" dialog,
/// even through the non-prompting `AXIsProcessTrusted()` (measured 2026-09-27:
/// a test whose only Accessibility call was that one brought the dialog up on
/// every run). The XCTest host is such a process, so under test this door never
/// reaches the system: it answers `testAnswer`, and a prompt request is only
/// counted. `AccessibilityTrustGuardTests` fails if any other file asks directly
/// or reads another app's elements without asking here first.
enum AccessibilityTrust {

    /// The trust state a test run sees. Tests that need the granted path set it
    /// and restore it.
    nonisolated(unsafe) static var testAnswer = false

    /// The last trust state read from the system, if any. What a headless
    /// prompt request answers, since headless it asks the system nothing.
    nonisolated(unsafe) static var lastKnownAnswer: Bool?

    /// Prompt requests a test run made; the system dialog itself never comes up.
    nonisolated(unsafe) static var testPromptRequests = 0

    /// The opt-in for the live Accessibility tests (they read Finder's real AX tree
    /// and post real events). Off by default: on this macOS even the non-prompting
    /// trust check from an untrusted test host raises the system dialog.
    static let liveTestsEnv = "GRUX_LIVE_AX_TESTS"

    static var liveTestsOptedIn: Bool {
        Persistence.isUnderTest && ProcessInfo.processInfo.environment[liveTestsEnv] == "1"
    }

    /// The real trust state, for an opted-in live test only. Anything else gets false
    /// without the system being asked.
    static func liveTrustForOptedInTest() -> Bool {
        guard liveTestsOptedIn else { return false }
        return AXIsProcessTrusted()
    }

    /// Non-prompting trust check.
    static func isGranted() -> Bool {
        if Persistence.isUnderTest { return testAnswer }
        let trusted = AXIsProcessTrusted()
        lastKnownAnswer = trusted
        return trusted
    }

    /// Prompting variant: macOS surfaces its Accessibility dialog the first
    /// time. Only for a person's explicit enable or grant action.
    /// Headless (`WindowFacade`): the system is not asked at all, not even the
    /// non-prompting way, which on this macOS can raise the dialog from an
    /// untrusted process. The request is recorded and the last trust state
    /// Grux read is returned, or false when it has read none.
    @discardableResult
    static func requestWithPrompt() -> Bool {
        if WindowFacade.isHeadless {
            WindowFacade.withhold("Accessibility prompt")
            return lastKnownAnswer ?? false
        }
        if Persistence.isUnderTest {
            testPromptRequests += 1
            return testAnswer
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        lastKnownAnswer = trusted
        return trusted
    }
}
