import Foundation
import AppKit

// Auto-detect when the user is in a meeting app so Grux can offer / auto-start
// capture. Watches NSWorkspace.didActivateApplicationNotification; consumers
// subscribe via `onMeetingAppEntered` / `onMeetingAppExited` closures.
//
// "Entered" fires whenever a whitelisted meeting-app bundle becomes frontmost
// and we weren't already in a capture session. "Exited" fires once the user
// switches AWAY from every meeting app. We don't stop capture automatically
// on exit - they can tab to Notes mid-call; a stop gesture stays deliberate.
@MainActor
final class MeetingAppDetector {
    static let shared = MeetingAppDetector()

    // Bundle IDs for supported meeting apps. Ordered by rough popularity -
    // keep this list tight; false positives would auto-offer captures
    // on random apps.
    static let meetingBundleIds: Set<String> = [
        "us.zoom.xos",                       // Zoom
        "com.microsoft.teams2",              // Teams (new)
        "com.microsoft.teams",               // Teams (classic)
        "com.apple.FaceTime",                // FaceTime
        "com.cisco.webexmeetingsapp",        // Webex
        "com.webex.meetingmanager",          // Webex (older)
        "com.hnc.Discord",                   // Discord
        "com.tinyspeck.slackmacgap",         // Slack (huddles)
        "com.google.Chrome",                 // Google Meet typically runs here
        "com.apple.Safari",                  // Meet / other web meetings
        "company.thebrowser.Browser",        // Arc
        "com.brave.Browser",                 // Brave
        "com.loom.desktop",                  // Loom
        "com.tinyspeck.slackcallbrain",      // Slack calls
        "com.apple.Chess"                    // (placeholder, harmless)
    ]

    // We only auto-offer for these. Browsers ARE in the supersearch list for
    // user-initiated "capture this tab" but we don't auto-fire on them - way
    // too many false positives.
    static let autoTriggerBundleIds: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager"
    ]

    var onMeetingAppEntered: ((_ bundleId: String, _ appName: String) -> Void)?
    var onMeetingAppExited: (() -> Void)?

    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var currentMeetingApp: String?

    private init() {}

    func start() {
        stop()
        let ws = NSWorkspace.shared.notificationCenter
        activationObserver = ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.handleActivation(app) }
        }
    }

    func stop() {
        if let o = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            activationObserver = nil
        }
        if let o = deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            deactivationObserver = nil
        }
        currentMeetingApp = nil
    }

    // Lookup helpers - used by menubar + tool dispatch to resolve display names.

    static func displayName(for bundleId: String) -> String? {
        switch bundleId {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams": return "Microsoft Teams"
        case "com.apple.FaceTime": return "FaceTime"
        case "com.cisco.webexmeetingsapp", "com.webex.meetingmanager": return "Webex"
        case "com.hnc.Discord": return "Discord"
        case "com.tinyspeck.slackmacgap", "com.tinyspeck.slackcallbrain": return "Slack"
        case "com.google.Chrome": return "Google Chrome"
        case "com.apple.Safari": return "Safari"
        case "company.thebrowser.Browser": return "Arc"
        case "com.brave.Browser": return "Brave"
        case "com.loom.desktop": return "Loom"
        default: return nil
        }
    }

    static func currentFrontmostMeetingApp() -> (bundleId: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier,
              meetingBundleIds.contains(bundleId) else { return nil }
        let name = displayName(for: bundleId) ?? app.localizedName ?? bundleId
        return (bundleId, name)
    }

    private func handleActivation(_ app: NSRunningApplication) {
        let bundleId = app.bundleIdentifier ?? ""
        if Self.autoTriggerBundleIds.contains(bundleId) {
            if currentMeetingApp != bundleId {
                currentMeetingApp = bundleId
                let name = Self.displayName(for: bundleId) ?? app.localizedName ?? bundleId
                WakeLog.shared.log("meeting-detector: entered \(name) (\(bundleId))")
                onMeetingAppEntered?(bundleId, name)
            }
        } else if currentMeetingApp != nil && !Self.meetingBundleIds.contains(bundleId) {
            // Switched to a non-meeting, non-peripheral app. Exit.
            let prev = currentMeetingApp ?? ""
            WakeLog.shared.log("meeting-detector: exited \(prev)")
            currentMeetingApp = nil
            onMeetingAppExited?()
        }
    }
}
