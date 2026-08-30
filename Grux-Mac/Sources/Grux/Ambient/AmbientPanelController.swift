import AppKit
import SwiftUI

// NSPanel with .nonactivatingPanel style defaults `canBecomeKey` to false,
// which means SwiftUI buttons/text fields inside never receive mouse clicks.
// Overriding `canBecomeKey` to true (while keeping `canBecomeMain` false to
// preserve the floating HUD behavior) makes interactive controls clickable
// without activating the whole app.
final class InteractiveHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Floating, non-activating NSPanel that hosts the AmbientHUD. Lives at .floating
// level, joins all Spaces, and ignores the app's regular window cycle. Position
// persisted to UserDefaults between launches.
@MainActor
final class AmbientPanelController {
    static let shared = AmbientPanelController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    private let defaultsKey = "grux.ambientHUDFrame"

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    func show() {
        if let existing = panel {
            existing.orderFrontRegardless()
            return
        }
        build()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    private func build() {
        let initialSize = NSSize(width: 380, height: 520)
        let frame = restoredFrame(defaultSize: initialSize)

        // Minimal style mask - matches TerminalFocusOverlayController's working
        // setup. Adding .titled / .fullSizeContentView / .resizable breaks
        // SwiftUI button click delivery on .nonactivatingPanel.
        let panel = InteractiveHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        // ThemeRevisionHost: hosted roots never re-key on theme commits, so
        // a reduceMotion toggle would leave the orb's repeatForever
        // animations running (or frozen) until the next orb state change.
        let rootView = AnyView(
            ThemeRevisionHost {
                AmbientHUDRoot()
                    .environmentObject(AppState.shared)
                    .padding(6) // tiny outer padding so shadow isn't clipped by panel bounds
            }
        )
        let hc = NSHostingController(rootView: rootView)
        hc.view.frame = CGRect(origin: .zero, size: frame.size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        panel.contentView = hc.view

        // Observe frame changes to persist position
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.panel else { return }
                self.saveFrame(p.frame)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.panel else { return }
                self.saveFrame(p.frame)
            }
        }

        self.panel = panel
        self.hostingController = hc
        panel.orderFrontRegardless()
        AmbientState.shared.hudVisible = true
    }

    // MARK: - Frame persistence

    private func restoredFrame(defaultSize: NSSize) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let r = NSRectFromString(saved)
            if r.width > 100 && r.height > 100 { return r }
        }
        // Default: bottom-right of main screen
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: defaultSize)
        }
        let vf = screen.visibleFrame
        let x = vf.maxX - defaultSize.width - 24
        let y = vf.minY + 24
        return NSRect(origin: NSPoint(x: x, y: y), size: defaultSize)
    }

    private func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: defaultsKey)
    }
}
