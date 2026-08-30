import AppKit
import SwiftUI

// Floating NSPanel that hosts FocusOverlayView. Anchored top-right of the
// main screen on first launch; frame persisted between launches so the user can
// drag it wherever they want. Same non-activating pattern as AmbientPanelController.
@MainActor
final class FocusOverlayController {
    static let shared = FocusOverlayController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private let defaultsKey = "grux.focusOverlayFrame"

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    func show() {
        if let existing = panel {
            existing.orderFrontRegardless()
            FocusOverlayState.shared.isVisible = true
            return
        }
        build()
    }

    func hide() {
        panel?.orderOut(nil)
        FocusOverlayState.shared.isVisible = false
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    private func build() {
        // The hosting view is sized by SwiftUI (fixedSize), but the panel
        // needs an initial frame. Overlay card is ~320 wide, orb is ~52 -
        // use a roomy initial box and let autoresizing hostingView track.
        let initialSize = NSSize(width: 320, height: 220)
        let frame = restoredFrame(defaultSize: initialSize)

        let p = FocusOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let root = AnyView(
            FocusOverlayView()
                .padding(6) // shadow breathing room
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: frame.size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        p.contentView = hc.view

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let pp = self.panel else { return }
                self.saveFrame(pp.frame)
            }
        }

        self.panel = p
        self.hostingController = hc
        p.orderFrontRegardless()
        FocusOverlayState.shared.isVisible = true
    }

    private func restoredFrame(defaultSize: NSSize) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let r = NSRectFromString(saved)
            if r.width > 40 && r.height > 40 { return r }
        }
        // Default: top-right of the main screen with a 24pt inset, aligned to
        // the top right of the live workspace.
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: defaultSize)
        }
        let vf = screen.visibleFrame
        let x = vf.maxX - defaultSize.width - 24
        let y = vf.maxY - defaultSize.height - 24
        return NSRect(origin: NSPoint(x: x, y: y), size: defaultSize)
    }

    private func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: defaultsKey)
    }
}

// NSPanel subclass matching InteractiveHUDPanel's pattern - `canBecomeKey`
// true so SwiftUI Buttons inside receive clicks, but `canBecomeMain` stays
// false so the overlay never steals the main-window identity.
private final class FocusOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
