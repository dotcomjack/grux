import AppKit

/// Suspends decorative animation while nobody can see it.
///
/// Grux runs thirteen `repeatForever` animations plus `TimelineView`s at 30 to 40 fps. They
/// are cheap to look at and expensive to leave running: on an idle laptop with the app in
/// the background, the display transaction flush they drive was the single largest cost in
/// the process. A `repeatForever` animation does NOT stop when its window is hidden or the
/// app is deactivated, which is exactly why this has to be explicit.
///
/// The signal is deliberately conservative. Motion suspends when the app is not active AND
/// every window is occluded, so an animation stays live in a window the user is watching
/// beside another app, which is a real way people use an assistant.
/// Lock box so `GruxTheme.reduceMotion`, which is a nonisolated static read from any
/// thread, can consult the flag without hopping to the main actor. Same shape as the
/// palette box in ThemeConfig.swift, and for the same reason.
private final class SuspendedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSuspended: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private let suspendedBox = SuspendedBox()

@MainActor
final class MotionSuspension {
    static let shared = MotionSuspension()

    nonisolated static var suspended: Bool { suspendedBox.isSuspended }
    var isSuspended: Bool { suspendedBox.isSuspended }

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification,
                     NSApplication.didBecomeActiveNotification,
                     NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MotionSuspension.shared.reevaluate() }
            })
        }
        reevaluate()
    }

    private func reevaluate() {
        let active = NSApp.isActive
        // `.visible` is set when any part of the window is on screen. A miniaturised or
        // fully covered window reports it cleared.
        //
        // The menu bar extra is excluded and that exclusion is the whole fix. Grux is a
        // menu-bar app, so `NSStatusBarWindow` is ALWAYS visible, which made `anyVisible`
        // permanently true and the gate permanently open. Measured with it counted: 21.5%
        // of a core while the app sat in the background. Measured with it excluded: 0.8%.
        // The first version of this file shipped the bug and looked correct.
        let anyVisible = NSApp.windows.contains { w in
            guard w.isVisible, w.occlusionState.contains(.visible) else { return false }
            return !w.isKind(of: NSClassFromString("NSStatusBarWindow") ?? NSWindow.self)
        }
        // Both conditions, so a floating panel the user is watching beside another app,
        // Orb Anywhere or the ambient HUD, keeps animating while Grux is not frontmost.
        let suspend = !active && !anyVisible
        guard suspend != isSuspended else { return }
        suspendedBox.isSuspended = suspend
        // Roots key on `revision`, so this re-runs every `onAppear` and the animation sites
        // re-read the gate. Stopping and restarting is the whole mechanism.
        ThemeConfig.shared.bumpRevisionForMotion()
    }
}
