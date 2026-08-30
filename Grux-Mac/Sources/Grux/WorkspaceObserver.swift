import AppKit
import Foundation

// Live workspace awareness for chat context.
//
// Why this exists: the focus watcher only updates `state.lastActiveApp` once
// per tick (≥10s), overwrites to "Grux" while the user is looking at Grux, and
// stops updating entirely when the watcher is disabled/snoozed/idle. That
// made "what am I looking at?" return stale or self-referential answers.
//
// This observer subscribes to NSWorkspace activation notifications (zero
// polling) and exposes two snapshots on demand:
//   - current:       the frontmost app right NOW (live re-query of
//                    NSWorkspace.frontmostApplication + AX focused window).
//   - lastNonGrux:   the most recent frontmost app that ISN'T Grux itself.
//                    When the user brings Grux forward to ask a question, the
//                    thing they were "looking at" is this, not Grux.
@MainActor
final class WorkspaceObserver {
    static let shared = WorkspaceObserver()

    struct Snapshot {
        let currentName: String
        let currentBundleId: String
        let currentWindowTitle: String
        let isGruxFrontmost: Bool
        // Most recent frontmost app that wasn't Grux. Matches `current` when
        // Grux isn't frontmost. Empty strings if no activation seen yet.
        let lastNonGruxName: String
        let lastNonGruxBundleId: String
        let lastNonGruxWindowTitle: String
        let lastNonGruxSeenAt: Date?
    }

    private let gruxBundleId: String
    private var lastNonGruxName: String = ""
    private var lastNonGruxBundleId: String = ""
    private var lastNonGruxWindowTitle: String = ""
    private var lastNonGruxSeenAt: Date?
    private var started = false

    private init() {
        self.gruxBundleId = Bundle.main.bundleIdentifier ?? "com.gruxai.grux"
    }

    func start() {
        guard !started else { return }
        started = true

        // Seed from current frontmost so lastNonGrux is populated immediately
        // if Grux launches while another app is already in front (rare -
        // Grux activates on launch - but cheap and correct).
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != gruxBundleId {
            captureLastNonGrux(from: app)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != gruxBundleId else { return }
        captureLastNonGrux(from: app)
    }

    /// A window title the app is allowed to remember, or "" when it is not.
    ///
    /// THE SAME LIST THE SCREEN CAPTURER OBEYS. `CapturePrivacy` exists to keep a password
    /// manager out of what Grux looks at, and its two readers were both in `ScreenCapture`.
    /// This file read the focused window TITLE and never consulted it, so Grux composited
    /// 1Password out of a screenshot and then sent `1Password - Personal vault` verbatim in
    /// the system prompt of the very next chat turn. The default patterns are "password",
    /// "api key", "recovery phrase", "bank", "credit card": every one of them describes a
    /// title, not a frame.
    ///
    /// THE APP NAME SURVIVES AND THE TITLE DOES NOT, which is the whole distinction. Knowing
    /// somebody is in a password manager is context. Knowing which vault entry they have
    /// open is the thing the list exists to stop.
    /// SPLIT SO THE DECISION IS TESTABLE. The first test for this asserted only that the
    /// gate was CALLED, and it stayed green against a version whose body was `return title`.
    /// A guard whose presence is checked and whose answer is not is not a guard.
    /// NONISOLATED, because it touches nothing shared: two strings and two lists in, one
    /// string out. The isolation was inherited from the enclosing @MainActor type and the
    /// only thing it bought was making the decision untestable.
    nonisolated static func allowedTitle(bundleId: String, title: String,
                                         bundleIds: [String], titlePatterns: [String]) -> String {
        guard !title.isEmpty else { return "" }
        let blocked = CapturePrivacy.frontmostBlockReason(
            bundleId: bundleId,
            windowTitle: title,
            bundleIds: bundleIds,
            titlePatterns: titlePatterns) != nil
        return blocked ? "" : title
    }

    /// The same decision, against the lists this Mac is actually configured with.
    private static func allowedTitle(bundleId: String, title: String) -> String {
        let cfg = AppState.shared.config
        return allowedTitle(bundleId: bundleId, title: title,
                            bundleIds: cfg.captureExcludedBundleIds,
                            titlePatterns: cfg.captureExcludedTitlePatterns)
    }

    private func captureLastNonGrux(from app: NSRunningApplication) {
        lastNonGruxName = app.localizedName ?? "Unknown"
        lastNonGruxBundleId = app.bundleIdentifier ?? ""
        // Window title can be empty right at activation (the app may not have
        // set its focused window yet). Try once now; snapshot() re-queries live.
        lastNonGruxWindowTitle = Self.allowedTitle(
            bundleId: lastNonGruxBundleId,
            title: Self.focusedWindowTitle(pid: app.processIdentifier) ?? "")
        lastNonGruxSeenAt = Date()

        // Mirror into AppState so any UI that was reading the old tick-cached
        // fields also sees fresh data immediately (not just at the next tick).
        let state = AppState.shared
        state.lastActiveApp = lastNonGruxName
        state.lastWindowTitle = lastNonGruxWindowTitle
    }

    // Read-once snapshot. Re-queries NSWorkspace LIVE so stale-cache bugs
    // can't sneak back in. Also refreshes lastNonGrux's window title if the
    // last-seen app is still running - titles change when users switch tabs
    // or navigate pages without triggering a didActivateApplication event.
    func snapshot() -> Snapshot {
        let currentInfo = ActiveApp.current()
        let isGrux = currentInfo.bundleId == gruxBundleId

        // If the last-non-Grux app is still running, refresh its window title
        // - Chrome/Safari tab switches happen silently.
        if !lastNonGruxBundleId.isEmpty,
           let running = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == lastNonGruxBundleId
           }),
           let fresh = Self.focusedWindowTitle(pid: running.processIdentifier) {
            // Re-checked on every refresh, not once at activation: a browser tab switch
            // changes the title without changing the app, and that is exactly how a
            // banking page arrives under an already-approved bundle id.
            lastNonGruxWindowTitle = Self.allowedTitle(bundleId: lastNonGruxBundleId,
                                                       title: fresh)
        }

        // If current frontmost isn't Grux, current IS the last-non-Grux.
        if !isGrux {
            lastNonGruxName = currentInfo.name
            lastNonGruxBundleId = currentInfo.bundleId
            lastNonGruxWindowTitle = Self.allowedTitle(bundleId: currentInfo.bundleId,
                                                       title: currentInfo.windowTitle)
            lastNonGruxSeenAt = Date()
        }

        return Snapshot(
            currentName: currentInfo.name,
            currentBundleId: currentInfo.bundleId,
            // The FRONTMOST title goes through the same gate. It is the one the chat turn
            // labels ACTIVE_APP_RIGHT_NOW, so it is the likeliest of the two to be a
            // password manager somebody just switched away from to ask Grux a question.
            currentWindowTitle: Self.allowedTitle(bundleId: currentInfo.bundleId,
                                                  title: currentInfo.windowTitle),
            isGruxFrontmost: isGrux,
            lastNonGruxName: lastNonGruxName,
            lastNonGruxBundleId: lastNonGruxBundleId,
            lastNonGruxWindowTitle: lastNonGruxWindowTitle,
            lastNonGruxSeenAt: lastNonGruxSeenAt
        )
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        let axWindow = window as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
    }
}
