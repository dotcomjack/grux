import AppKit
import SwiftUI

// Floating, non-activating NSPanel that hosts a small OrbAnywhereView. The
// orb lives here as a persistent desktop artifact - always-on-top on every
// Space, draggable, click-to-mute. Same panel style as AmbientPanelController
// and FocusOverlayController: .borderless + .nonactivatingPanel + canBecomeKey
// so SwiftUI buttons still receive clicks without stealing main-window focus.
@MainActor
final class OrbAnywhereController {
    static let shared = OrbAnywhereController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    private let defaultsKey = "grux.orbAnywhereFrame"
    // The hosted SwiftUI view is sized by `fixedSize`; we only need a seed.
    private let panelSize = NSSize(width: 88, height: 124)

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    func show() {
        if let existing = panel {
            existing.orderFrontRegardless()
            OrbAnywhereState.shared.isVisible = true
            return
        }
        build()
    }

    func hide() {
        panel?.orderOut(nil)
        OrbAnywhereState.shared.isVisible = false
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    private func build() {
        let frame = restoredFrame(defaultSize: panelSize)

        // Reuse InteractiveHUDPanel (declared in AmbientPanelController.swift)
        // so the orb tap-to-mute button receives clicks.
        let p = InteractiveHUDPanel(
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

        // ThemeRevisionHost: hosted roots never re-key on theme commits, so
        // a reduceMotion toggle would leave the orb's repeatForever
        // animations running (or frozen) until the next orb state change.
        let root = AnyView(
            ThemeRevisionHost {
                OrbAnywhereView()
                    .environmentObject(AppState.shared)
                    .padding(8) // breathing room for soft outer halo
            }
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
        OrbAnywhereState.shared.isVisible = true
    }

    private func restoredFrame(defaultSize: NSSize) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let r = NSRectFromString(saved)
            if r.width > 40 && r.height > 40 { return r }
        }
        // Default: top-right of the main screen, inset 24pt. Sits to the LEFT
        // of the FocusOverlay default so both can coexist without overlap
        // (coexistence confirmed).
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: defaultSize)
        }
        let vf = screen.visibleFrame
        let x = vf.maxX - defaultSize.width - 24 - 320 - 16
        let y = vf.maxY - defaultSize.height - 24
        return NSRect(origin: NSPoint(x: x, y: y), size: defaultSize)
    }

    private func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: defaultsKey)
    }
}
