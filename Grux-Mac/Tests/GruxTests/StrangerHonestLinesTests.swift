import XCTest
import UserNotifications
@testable import Grux

/// D116 items 1 and 2 (sense pass 11): two lines a stranger reads that were not
/// true of their Mac.
@MainActor
final class StrangerHonestLinesTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: item 1, How Grux works

    /// "The majority of Grux works the moment it has a model key." on first run,
    /// read by a person whose chat already runs on a local model with no key.
    func test_howGruxWorksSaysALocalModelIsEnoughToo() {
        let line = HowItWorksStep.mostTabsNeedNothing
        XCTAssertFalse(line.contains("model key"), "first run says only a key makes Grux work: \(line)")
        XCTAssertTrue(line.contains("local model"), "first run never says a local model is enough: \(line)")
        XCTAssertTrue(line.contains("Where a tab does need something"), "the rest of the point is kept: \(line)")
    }

    // MARK: item 2, Settings, General, reminders

    /// "Send reminder notifications" read on while macOS had not allowed Grux's
    /// notifications, so a person expected reminders that could never show.
    func test_remindersReadOffWithALineWhileMacOSHasNotAllowedNotifications() {
        XCTAssertFalse(ReminderToggleTruth.shown(choice: true, allowed: false))
        XCTAssertFalse(ReminderToggleTruth.shown(choice: false, allowed: false))
        let line = ReminderToggleTruth.line(allowed: false)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("System Settings > Notifications > Grux AI") == true, line ?? "nil")
        XCTAssertTrue(line?.contains("no reminder shows") == true, line ?? "nil")
    }

    /// Allowed, or not read yet: the toggle shows the person's choice and adds nothing.
    func test_remindersShowTheChoiceWhenAllowedOrNotYetRead() {
        for allowed in [true, nil] as [Bool?] {
            XCTAssertTrue(ReminderToggleTruth.shown(choice: true, allowed: allowed))
            XCTAssertFalse(ReminderToggleTruth.shown(choice: false, allowed: allowed))
            XCTAssertNil(ReminderToggleTruth.line(allowed: allowed))
        }
    }

    /// The toggle on screen goes through the rule, reads the permission fresh,
    /// and offers the pane that grants it.
    func test_theGeneralPaneTogglesThroughTheRule() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        guard let at = settings.range(of: "Toggle(\"Send reminder notifications\"") else {
            return XCTFail("the reminders toggle moved; point this test at it")
        }
        let around = String(settings[at.lowerBound...].prefix(900))
        XCTAssertTrue(around.contains("ReminderToggleTruth.shown("), "the toggle reads the config value alone")
        XCTAssertTrue(around.contains("ReminderToggleTruth.line("), "no line says why reminders cannot show")
        XCTAssertTrue(around.contains("openSystemSettings(for: .permNotifications)"), "no way to the pane that allows them")
        guard let read = settings.range(of: "private func refreshNotificationsAllowed()") else {
            return XCTFail("refreshNotificationsAllowed moved; point this test at it")
        }
        let body = String(settings[read.lowerBound...].prefix(300))
        XCTAssertTrue(body.contains("CapabilityRequest.refreshedNotificationAllowance()"),
                      "the pane reads a stale permission, or one that cannot tell never asked from refused: \(body)")
    }

    // MARK: W32-P3 item 1, never asked is not refused

    /// A Mac where Grux has not yet asked for notifications read "macOS has not
    /// allowed Grux's notifications" above a greyed toggle, though macOS has
    /// refused nothing and asks the first time Grux does.
    func test_aNeverAskedGrantIsNotReadAsRefused() {
        XCTAssertNil(ReminderToggleTruth.allowed(.notDetermined))
        XCTAssertEqual(ReminderToggleTruth.allowed(.denied), false)
        for status in [UNAuthorizationStatus.authorized, .provisional] {
            XCTAssertEqual(ReminderToggleTruth.allowed(status), true, "\(status.rawValue)")
        }
        XCTAssertNil(ReminderToggleTruth.line(allowed: ReminderToggleTruth.allowed(.notDetermined)))
        XCTAssertTrue(ReminderToggleTruth.shown(choice: true, allowed: ReminderToggleTruth.allowed(.notDetermined)))
        XCTAssertNotNil(ReminderToggleTruth.line(allowed: ReminderToggleTruth.allowed(.denied)))
    }

    /// The cached grant every surface reads was written by nothing at launch:
    /// `refreshNotificationStatus()` had no caller, though its comment said it
    /// ran on launch, so a person who allowed notifications read "not allowed".
    func test_askingForNotificationsRecordsTheAnswer() throws {
        let notifications = try source("Sources/Grux/Notifications.swift")
        guard let at = notifications.range(of: "func requestAuthorization()") else {
            return XCTFail("requestAuthorization moved; point this test at it")
        }
        let body = String(notifications[at.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("CapabilityResolver.refreshNotificationStatus()"),
                      "the launch request never records what macOS answered")
    }
}
