import XCTest
@testable import Grux

/// The permissions card told somebody a button had not worked and then stopped talking.
///
/// Measured on the Mac Mini during a first-run walkthrough, at the Notifications card: the
/// person pressed Allow, nothing visible happened, and the screen said "Still not granted.
/// That is a fine answer, and you can carry on without it." True, and useless. It is fine to
/// decline; it is not fine to be unable to find the control.
///
/// Two defects sat under that one screen and only one of them was about copy.
@MainActor
final class PermissionDeadEndTests: XCTestCase {

    /// EVERY permission onboarding offers can say where its switch lives. A card that can
    /// reach the not-granted state without a path is the dead end again with a different
    /// capability's name on it.
    func testEveryOfferedPermissionCanSayWhereToGo() {
        for req in CapabilityRequest.onboardingOrder {
            let path = CapabilityRequest.settingsPath(for: req)
            XCTAssertTrue(path.hasPrefix("System Settings > "),
                          "\(req.rawValue) path does not start where the person starts: \(path)")
            XCTAssertGreaterThanOrEqual(path.components(separatedBy: " > ").count, 2,
                                        "\(req.rawValue) names no pane inside System Settings")
            let how = CapabilityRequest.howToGrant(req)
            XCTAssertTrue(how.contains(path), "\(req.rawValue) instruction omits its own path")
            XCTAssertTrue(how.contains("checks again when you come back"),
                          "\(req.rawValue) does not promise the re-check the card performs")
        }
    }

    /// THE PATHS MUST MATCH WHAT macOS ACTUALLY SHOWS. A path with the right idea and the
    /// wrong words is worse than none: the person hunts for a pane that is not there and
    /// concludes Grux is out of date. These are the pane names macOS 26 uses.
    func testThePanesAreTheOnesMacOSActuallyHas() {
        let expected: [SetupRequirement: String] = [
            .permNotifications:   "System Settings > Notifications > Grux OS",
            .permMicrophone:      "System Settings > Privacy & Security > Microphone",
            .permCalendar:        "System Settings > Privacy & Security > Calendars",
            .permContacts:        "System Settings > Privacy & Security > Contacts",
            .permScreenRecording: "System Settings > Privacy & Security > Screen & System Audio Recording",
            .permAccessibility:   "System Settings > Privacy & Security > Accessibility",
            .permAutomation:      "System Settings > Privacy & Security > Automation",
            .permFullDiskAccess:  "System Settings > Privacy & Security > Full Disk Access",
        ]
        for (req, path) in expected {
            XCTAssertEqual(CapabilityRequest.settingsPath(for: req), path, req.rawValue)
        }
        // And the table above covers the whole offered set, so a new permission cannot be
        // added to onboarding without landing here.
        XCTAssertEqual(Set(CapabilityRequest.onboardingOrder), Set(expected.keys),
                       "onboarding offers a permission this test does not pin a path for")
    }

    /// Notifications gets the switch it actually has; the Privacy panes get the list they
    /// actually have. "Turn it on" for a list you must find yourself is the almost-right
    /// instruction that costs more than silence.
    func testTheInstructionNamesTheControlThatIsThere() {
        XCTAssertTrue(CapabilityRequest.howToGrant(.permNotifications)
            .contains("switch on Allow Notifications"))
        for req in [SetupRequirement.permAccessibility, .permFullDiskAccess, .permMicrophone] {
            XCTAssertTrue(CapabilityRequest.howToGrant(req).contains("tick Grux OS in the list"),
                          "\(req.rawValue) does not name the control")
        }
    }

    /// THE SECOND DEFECT, and the one that made the button genuinely dead.
    ///
    /// Notifications is the only CACHED capability: the resolver runs from view bodies that
    /// cannot await, so it reads a UserDefaults key filled in by a callback. `request` used
    /// to return `isSatisfied` immediately after awaiting the system prompt, which reads that
    /// cache microseconds before the callback lands, so it always returned the value from
    /// BEFORE the request.
    ///
    /// On the Mini it was worse than stale. `grux.capability.notifications_granted` did not
    /// exist in the defaults domain at all, so it was `UserDefaults.bool` on a missing key,
    /// which is false forever. The card could not have reported granted whatever was pressed.
    func testTheNotificationAnswerIsAwaitedRatherThanReadFromTheCache() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Onboarding/CapabilityRequest.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "static func request", in: src))
        let awaited = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "refreshedNotificationAuthorization", in: src)
                .first { body.contains($0) },
            "request() does not await the live notification status, so it returns whatever "
            + "the cache held before the prompt")
        let requested = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "requestAuthorization", in: src)
                .first { body.contains($0) })
        XCTAssertLessThan(requested, awaited, "it reads the answer before asking the question")
    }

    /// And the awaited read writes the cache, so every other surface agrees a moment later
    /// rather than disagreeing until some later callback happens to fire.
    func testTheAwaitedReadUpdatesTheCacheTheResolverUses() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Onboarding/CapabilityRequest.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "static func refreshedNotificationAuthorization", in: src))
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "setNotificationAuthorizationCache", in: src)
                .filter { body.contains($0) }.isEmpty,
            "the awaited answer is not written back, so the resolver keeps its old opinion")
    }

    /// After a prompt comes back empty, pressing the same button again does nothing, because
    /// macOS shows most of these once. The control has to become the one that still works.
    func testTheButtonStopsOfferingAPromptThatWillNotAppearAgain() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let line = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "? \"Allow\" : \"Open System Settings\"", in: src)
                .first,
            "the permissions button no longer chooses between the two labels")
        let condition = src[max(0, line - 1)...line].joined(separator: "\n")
        XCTAssertTrue(condition.contains("!declined"),
                      "the button still offers Allow after a decline, which is a prompt macOS "
                      + "will not show a second time")
    }

    /// And the screen re-checks when the person comes back from System Settings, or sending
    /// them there is the same dead end one step later.
    ///
    /// `recheckOnReturn` was renamed to `recheck` when the card stopped waiting to be
    /// returned to and started polling as well. Coming back is still one of the two
    /// triggers, so this assertion still holds; PermissionRefreshTests covers the other.
    func testTheCardRechecksWhenTheAppComesBack() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("didBecomeActiveNotification"),
                      "nothing re-checks when the app regains focus")
        let src = raw.components(separatedBy: "\n")
        let body = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "private func recheck() async", in: src))
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "refreshedNotificationAuthorization", in: src)
                .filter { body.contains($0) }.isEmpty,
            "the re-check re-reads the notification cache instead of the live status, so "
            + "coming back from System Settings cannot change its mind")
    }
}
