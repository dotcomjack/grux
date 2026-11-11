import Foundation
import UserNotifications

/// Settings, General's "Send reminder notifications" read on while macOS had
/// not allowed Grux's notifications, so a person expected reminders that could
/// never show (D116). Like screen analysis above it: off while macOS says no,
/// the choice kept for when it says yes.
@MainActor
enum ReminderToggleTruth {
    /// `allowed` is nil until macOS has been asked, and then the choice shows.
    static func shown(choice: Bool, allowed: Bool?) -> Bool {
        choice && allowed != false
    }

    /// macOS's answer as the toggle reads it. Never asked is nil, not a
    /// refusal: macOS asks the first time Grux does (W32-P3 item 1).
    static func allowed(_ status: UNAuthorizationStatus) -> Bool? {
        switch status {
        case .notDetermined: return nil
        case .denied: return false
        default: return true
        }
    }

    static func line(allowed: Bool?) -> String? {
        guard allowed == false else { return nil }
        return "macOS has not allowed Grux's notifications, so no reminder shows. "
             + CapabilityRequest.howToGrant(.permNotifications)
    }
}
