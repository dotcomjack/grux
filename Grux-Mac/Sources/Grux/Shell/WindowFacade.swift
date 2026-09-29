import AppKit

/// The one door through which Grux puts a window in front of a person, or makes
/// an app (itself or another) the active one.
///
/// WHY. Grux ordered windows front and activated itself from about 60 places, so
/// there was no way to run it on a Mac whose screen belongs to someone else (a
/// test rig in the same room as a movie, a shared display) and be sure nothing
/// appears, takes focus or floats. `WindowFacadeArchitectureTests` fails if any
/// file outside this one calls those APIs, so a new call site cannot bypass it.
///
/// HEADLESS MODE. The presence of `~/.grux/HEADLESS` (checked live, like
/// `~/.grux/SILENT`, so it survives `open` and `build.sh` relaunches) means:
/// activation policy `.accessory` (no Dock icon), Grux never activates itself or
/// another app, never hides another app, and every Grux window is ordered to the
/// back at alpha 0, ignoring the mouse, at the normal level. The windows stay
/// ordered in, so layout and drawing stay live and `HeadlessWorkspace` can render
/// them to PNG. Removing the file restores what each window and the policy were.
/// A test run is always headless unless a test asks otherwise.
@MainActor
enum WindowFacade {
    nonisolated static var sentinelURL: URL { Persistence.gruxDir.appendingPathComponent("HEADLESS") }

    /// Tests that check the visible path set this to false. Nil: a test run is headless.
    nonisolated(unsafe) static var headlessUnderTest: Bool?

    nonisolated static var isHeadless: Bool {
        if Persistence.isUnderTest { return headlessUnderTest ?? true }
        return FileManager.default.fileExists(atPath: sentinelURL.path)
    }

    /// What a concealed window was before, so leaving headless mode puts it back.
    /// It lives ON the window (an associated object), never in a table keyed by the
    /// window's address: a window that closes and deallocates takes its record with
    /// it, and a new window that lands at the same address starts with none.
    private final class Saved {
        var alpha: CGFloat
        var ignoresMouse: Bool
        var level: NSWindow.Level
        var hasShadow: Bool
        init(_ w: NSWindow) {
            alpha = w.alphaValue; ignoresMouse = w.ignoresMouseEvents; level = w.level; hasShadow = w.hasShadow
        }
    }
    private static var savedKey: UInt8 = 0
    private static func saved(_ w: NSWindow) -> Saved? {
        objc_getAssociatedObject(w, &savedKey) as? Saved
    }
    private static func setSaved(_ s: Saved?, on w: NSWindow) {
        objc_setAssociatedObject(w, &savedKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    /// Every window concealed and not yet closed, held weakly so none piles up.
    private static let concealed = NSHashTable<NSWindow>.weakObjects()
    private static var closeObserver: NSObjectProtocol?
    /// The policy Grux asked for, applied again when headless mode ends.
    private(set) static var intendedPolicy: NSApplication.ActivationPolicy = .regular
    /// The sentinel as last read by `enforce`, for the per-loop observer.
    private(set) static var headlessCached = false
    private static var guardTimer: Timer?
    private static var observers: [NSObjectProtocol] = []

    // MARK: Grux itself

    static func activateGrux() {
        guard !isHeadless else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        intendedPolicy = policy
        NSApp.setActivationPolicy(isHeadless ? .accessory : policy)
    }

    /// Unhides Grux. Plain `unhide` also activates it, so headless uses the variant that does not.
    static func unhideGrux() {
        guard NSApp.isHidden else { return }
        if isHeadless { NSApp.unhideWithoutActivation() } else { NSApp.unhide(nil) }
    }

    // MARK: Windows

    static func makeKeyAndOrderFront(_ window: NSWindow) {
        if isHeadless { orderInConcealed(window) } else { restore(window); window.makeKeyAndOrderFront(nil) }
    }

    static func orderFront(_ window: NSWindow) {
        if isHeadless { orderInConcealed(window) } else { restore(window); window.orderFront(nil) }
    }

    static func orderFrontRegardless(_ window: NSWindow) {
        if isHeadless { orderInConcealed(window) } else { restore(window); window.orderFrontRegardless() }
    }

    /// Sets a window's level. Headless keeps every window at `.normal` and remembers
    /// the asked level for when headless mode ends.
    static func setLevel(_ level: NSWindow.Level, of window: NSWindow) {
        if isHeadless {
            conceal(window)
            saved(window)?.level = level
        } else {
            restore(window)
            window.level = level
        }
    }

    private static func orderInConcealed(_ window: NSWindow) {
        conceal(window)
        window.orderBack(nil)
    }

    /// Alpha 0, click-through, normal level, no shadow. Idempotent.
    static func conceal(_ window: NSWindow) {
        if saved(window) == nil { setSaved(Saved(window), on: window) }
        concealed.add(window)
        watchCloses()
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        if window.level != .normal { window.level = .normal }
        if window.hasShadow { window.hasShadow = false }
    }

    static func isConcealed(_ window: NSWindow) -> Bool {
        window.alphaValue == 0 && window.ignoresMouseEvents && window.level == .normal
    }

    // MARK: Other apps

    /// Activates another app. Refused headless: the screen is not Grux's to change.
    @discardableResult
    nonisolated static func activate(_ app: NSRunningApplication, options: NSApplication.ActivationOptions = []) -> Bool {
        guard !isHeadless else { return false }
        return app.activate(options: options)
    }

    /// Hides another app. Refused headless for the same reason.
    @discardableResult
    nonisolated static func hide(_ app: NSRunningApplication) -> Bool {
        guard !isHeadless else { return false }
        return app.hide()
    }

    // MARK: What headless mode held back

    nonisolated private static let withheldLock = NSLock()
    nonisolated(unsafe) private static var withheldLines: [String] = []

    /// What headless mode stopped Grux doing to the screen (a system dialog, System
    /// Settings brought forward), newest last, at most 50.
    nonisolated static var withheld: [String] {
        withheldLock.lock(); defer { withheldLock.unlock() }
        return withheldLines
    }

    nonisolated static var withheldLogURL: URL {
        Persistence.gruxDir.appendingPathComponent("headless-workspace").appendingPathComponent("withheld.log")
    }

    /// Records, instead of doing, something that would have put a dialog or another
    /// app in front of the person: in memory, and one line in `withheld.log`.
    nonisolated static func withhold(_ what: String) {
        withheldLock.lock()
        withheldLines.append(what)
        if withheldLines.count > 50 { withheldLines.removeFirst(withheldLines.count - 50) }
        withheldLock.unlock()
        let url = withheldLogURL
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(what)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: The guard

    /// Windows SwiftUI orders in by itself (scenes, the menu bar item) never pass
    /// through the calls above, so under headless mode every event loop pass and a
    /// one second timer conceal whatever is not concealed, keep the policy
    /// `.accessory` and give activation straight back. Call once, first thing at launch.
    static func startGuard() {
        guard guardTimer == nil else { return }
        enforce()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { if headlessCached { concealAll() } }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { enforce() }
        })
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { enforce() } }
        RunLoop.main.add(t, forMode: .common)
        guardTimer = t
    }

    /// Reads the sentinel and applies it to the whole app.
    static func enforce() {
        let headless = isHeadless
        defer { headlessCached = headless }
        if headless {
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
            concealAll()
            if NSApp.isActive { NSApp.deactivate() }
            HeadlessWorkspace.refresh()
        } else if headlessCached {
            restoreAll()
            NSApp.setActivationPolicy(intendedPolicy)
        }
    }

    private static func concealAll() {
        for w in NSApp.windows where !isConcealed(w) { conceal(w) }
    }

    /// Puts back every window headless mode concealed: the ones still open, and any
    /// the app still holds after they closed.
    static func restoreAll() {
        for w in concealed.allObjects + NSApplication.shared.windows { restore(w) }
        concealed.removeAllObjects()
    }

    /// Puts one window back as it was before it was concealed, if it was. Every
    /// visible show path calls this, so a window closed while headless and shown
    /// again after the sentinel is gone never comes back invisible.
    static func restore(_ w: NSWindow) {
        guard let s = saved(w) else { return }
        w.alphaValue = s.alpha
        w.ignoresMouseEvents = s.ignoresMouse
        w.level = s.level
        w.hasShadow = s.hasShadow
        setSaved(nil, on: w)
        concealed.remove(w)
    }

    /// A closed window leaves the table. Its record stays on the window, so showing
    /// it again later still restores it.
    private static func watchCloses() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                               queue: .main) { note in
            MainActor.assumeIsolated {
                if let w = note.object as? NSWindow { concealed.remove(w) }
            }
        }
    }

    /// For tests: how many windows the facade is tracking as concealed.
    static var concealedCount: Int { concealed.allObjects.count }
}
