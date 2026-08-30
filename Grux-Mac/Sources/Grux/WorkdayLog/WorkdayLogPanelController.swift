import AppKit
import SwiftUI

// Floating panel wrapper for the Workday Log browser. Matches
// DailyRecapPanelController's style (InteractiveHUDPanel + centered geometry).

@MainActor
final class WorkdayLogPanelController {
    static let shared = WorkdayLogPanelController()

    private var panel: InteractiveHUDPanel?
    private var hostingController: NSHostingController<AnyView>?

    private init() {}

    func present() {
        if panel != nil { panel?.orderFrontRegardless(); return }
        build()
    }

    func toggle() {
        if panel != nil { dismiss() } else { present() }
    }

    func dismiss() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.tearDown() }
        }
    }

    private func build() {
        let size = NSSize(width: 980, height: 720)
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(
            x: (vf.midX - size.width / 2).rounded(),
            y: (vf.midY - size.height / 2).rounded()
        )

        let p = InteractiveHUDPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let root = AnyView(
            WorkdayLogView(onClose: { [weak self] in
                Task { @MainActor in self?.dismiss() }
            })
            .padding(8)
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        p.contentView = hc.view
        self.panel = p
        self.hostingController = hc

        p.orderFrontRegardless()
        p.alphaValue = 1.0
        WakeLog.shared.log("workdayLog: panel presented")
    }

    private func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }
}
