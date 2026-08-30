import AppKit
import SwiftUI

// Floating, non-activating NSPanel that hosts the meeting-capture HUD. Mirrors
// AmbientPanelController - same InteractiveHUDPanel style mask, same Spaces
// behavior, same UserDefaults-backed frame persistence.
@MainActor
final class MeetingPanelController {
    static let shared = MeetingPanelController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    private let defaultsKey = "grux.meetingHUDFrame"

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
        let initialSize = NSSize(width: 420, height: 520)
        let frame = restoredFrame(defaultSize: initialSize)

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

        let rootView = AnyView(
            MeetingPanelView()
                .environmentObject(MeetingCaptureService.shared)
                .padding(6)
        )
        let hc = NSHostingController(rootView: rootView)
        hc.view.frame = CGRect(origin: .zero, size: frame.size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        panel.contentView = hc.view

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
    }

    private func restoredFrame(defaultSize: NSSize) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let r = NSRectFromString(saved)
            if r.width > 100 && r.height > 100 { return r }
        }
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
