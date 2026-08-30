import AVFoundation
import AppKit
import Contacts
import CoreGraphics
import EventKit
import UserNotifications

/// Asks macOS for a permission, for the capabilities where asking is possible.
///
/// The split this encodes is the one that matters for onboarding copy, and
/// getting it wrong produces a button that lies. macOS will show a prompt on
/// demand for some permissions and flatly will not for others: Accessibility,
/// Full Disk Access and Screen Recording are granted by the user in System
/// Settings, and an app cannot raise a dialog for them. (Screen Recording is a
/// half exception, `CGRequestScreenCaptureAccess` raises a one-time dialog that
/// then sends the user to System Settings anyway, and never appears again once
/// answered.)
///
/// So a "Grant" button on an Accessibility screen cannot grant anything. The
/// honest control there opens the right pane and says so, which is what
/// `style(for:)` is for.
@MainActor
enum CapabilityRequest {

    /// What Grux can actually do about a given permission.
    enum Style {
        /// macOS will show a prompt. Grux can ask directly.
        case prompt
        /// No prompt exists. The only honest action is to open System Settings.
        case systemSettingsOnly
    }

    static func style(for requirement: SetupRequirement) -> Style {
        switch requirement {
        case .permMicrophone, .permCalendar, .permContacts, .permNotifications:
            return .prompt
        case .permScreenRecording, .permSystemAudio:
            // The one-shot dialog only appears the FIRST time, so treating this
            // as a prompt would leave a returning user pressing a button that
            // does nothing at all.
            return .systemSettingsOnly
        case .permAccessibility, .permFullDiskAccess, .permAutomation:
            return .systemSettingsOnly
        default:
            return .systemSettingsOnly
        }
    }

    /// Ask macOS. Returns whether the permission is granted AFTER asking.
    ///
    /// Always re-reads the live state rather than trusting the callback's own
    /// verdict, because the answer that matters to every other surface in the
    /// app is the one `CapabilityResolver` will read a moment later.
    static func request(_ requirement: SetupRequirement) async -> Bool {
        switch requirement {
        case .permMicrophone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .permCalendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .permContacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .permNotifications:
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            // AND THEN READ THE LIVE ANSWER, because `isSatisfied` cannot.
            //
            // Notifications is the one CACHED capability: the resolver is called from view
            // bodies that cannot await, so it reads a UserDefaults key that
            // `refreshNotificationStatus()` fills in from a callback. Returning
            // `isSatisfied` here read that cache microseconds after requesting, which is
            // always the value from BEFORE the request, and on a machine where the key had
            // never been written it is `UserDefaults.bool` on a missing key, which is false
            // forever.
            //
            // Measured on the Mac Mini during a first-run walkthrough: the key
            // `grux.capability.notifications_granted` did not exist in the defaults domain
            // at all, so the card could not have reported granted no matter what the person
            // pressed. What they saw was "Allow" doing nothing, twice.
            return await refreshedNotificationAuthorization()
        case .permScreenRecording, .permSystemAudio:
            CGRequestScreenCaptureAccess()
        default:
            break
        }
        return CapabilityResolver.isSatisfied(requirement)
    }

    /// The live notification authorization, awaited, with the resolver's cache brought up to
    /// date on the way past so every other surface agrees a moment later.
    ///
    /// `getNotificationSettings` is callback-based and never prompts, so this is safe to call
    /// whenever the answer matters and cheap enough to call on every return from System
    /// Settings.
    static func refreshedNotificationAuthorization() async -> Bool {
        // `UNUserNotificationCenter.current()` RAISES an NSException in a process
        // with no bundle identifier, and an xctest host is exactly that. This
        // used to be unreachable from a test because the only caller ran on
        // `didBecomeActive`, which never fires there. The permissions card polls
        // now, so OnboardingRenderTests simply rendering the step was enough to
        // abort the whole run with an uncaught exception after 1451 cases.
        //
        // Guarded here rather than at the call site because this is where the
        // API's own precondition lives, and the app path is unchanged.
        //
        // The test is the BUNDLE, not the identifier. An xctest host does have a
        // bundle identifier, so checking for one let the exception straight
        // through; what it does not have is an application bundle, and the
        // exception says so exactly: "bundleProxyForCurrentProcess is nil:
        // mainBundle.bundleURL file:///Applications/Xcode.app/.../usr/bin/".
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return CapabilityResolver.isSatisfied(.permNotifications)
        }
        let granted: Bool = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let ok = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                continuation.resume(returning: ok)
            }
        }
        CapabilityResolver.setNotificationAuthorizationCache(granted)
        return granted
    }

    /// Open the exact Privacy pane for this permission.
    ///
    /// Duplicated deliberately from nowhere: `CapabilitySetupCard` had this
    /// switch first, and it now lives here so both surfaces share one mapping
    /// rather than two that agree until somebody edits one.
    static func openSystemSettings(for requirement: SetupRequirement) {
        let anchor: String
        switch requirement {
        case .permScreenRecording, .permSystemAudio: anchor = "Privacy_ScreenCapture"
        case .permMicrophone:                        anchor = "Privacy_Microphone"
        case .permAccessibility:                     anchor = "Privacy_Accessibility"
        case .permCalendar:                          anchor = "Privacy_Calendars"
        case .permContacts:                          anchor = "Privacy_Contacts"
        case .permAutomation:                        anchor = "Privacy_Automation"
        case .permFullDiskAccess:                    anchor = "Privacy_AllFiles"
        case .permNotifications:                     anchor = "Notifications"
        default:                                     anchor = "Privacy"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// WHERE TO GO, in the words macOS uses on its own screens.
    ///
    /// A card that says "still not granted" and stops is a dead end. Measured during a
    /// first-run walkthrough: the person pressed Allow on Notifications, nothing visible
    /// happened, and the screen told them it was fine to carry on without saying where the
    /// switch actually lives. macOS has a house style for this and Grux should use it rather
    /// than invent one.
    ///
    /// Rendered as "System Settings > Notifications > Grux OS". The arrow separator, the
    /// pane names and the capitalisation all match what the person will see when they get
    /// there, because a path that does not match what is on screen is worse than no path:
    /// they will look for the wrong words and conclude Grux is out of date.
    static func settingsPath(for requirement: SetupRequirement) -> String {
        let trail: [String]
        switch requirement {
        case .permNotifications:
            trail = ["Notifications", "Grux OS"]
        case .permMicrophone:
            trail = ["Privacy & Security", "Microphone"]
        case .permCalendar:
            trail = ["Privacy & Security", "Calendars"]
        case .permContacts:
            trail = ["Privacy & Security", "Contacts"]
        case .permScreenRecording, .permSystemAudio:
            trail = ["Privacy & Security", "Screen & System Audio Recording"]
        case .permAccessibility:
            trail = ["Privacy & Security", "Accessibility"]
        case .permAutomation:
            trail = ["Privacy & Security", "Automation"]
        case .permFullDiskAccess:
            trail = ["Privacy & Security", "Full Disk Access"]
        default:
            trail = ["Privacy & Security"]
        }
        return (["System Settings"] + trail).joined(separator: " > ")
    }

    /// One sentence telling somebody what to do, naming the path and the control.
    ///
    /// Two shapes, because the two cases genuinely differ. Notifications has a per-app row
    /// with a switch; the Privacy panes have a list you tick Grux OS in. Saying "turn it on"
    /// for a list you have to find yourself is the kind of almost-right instruction that
    /// wastes more time than none.
    static func howToGrant(_ requirement: SetupRequirement) -> String {
        let path = settingsPath(for: requirement)
        switch requirement {
        case .permNotifications:
            return "To turn this on, go to \(path) and switch on Allow Notifications. "
                 + "Grux checks again when you come back."
        default:
            return "To turn this on, go to \(path) and tick Grux OS in the list. "
                 + "Grux checks again when you come back."
        }
    }

    /// The permissions onboarding offers, in the order it offers them.
    ///
    /// Ordered cheapest-to-refuse first. Notifications and Microphone are
    /// ordinary asks that any app makes; Full Disk Access is the one that reads
    /// as alarming, and putting it first would colour everything after it.
    /// Nothing here is required, and the screen says so.
    static let onboardingOrder: [SetupRequirement] = [
        .permNotifications,
        .permMicrophone,
        .permCalendar,
        .permContacts,
        .permScreenRecording,
        .permAccessibility,
        .permAutomation,
        .permFullDiskAccess
    ]
}
