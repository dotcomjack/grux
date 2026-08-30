import AppKit
import SwiftUI

// Centered floating panel for the Daily Recap. Larger than a toast, lives
// until dismissed by the user. Uses InteractiveHUDPanel so the action chips
// are clickable without stealing system focus.
@MainActor
final class DailyRecapPanelController {
    static let shared = DailyRecapPanelController()

    private var panel: InteractiveHUDPanel?
    private var hostingController: NSHostingController<AnyView>?

    private init() {}

    func present(_ data: DailyRecapData) {
        tearDown()
        build(with: data)
    }

    func dismiss() {
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.tearDown() }
        }
    }

    private func build(with data: DailyRecapData) {
        // Generous height so the three sections never clip on realistic content.
        let initial = NSSize(width: 600, height: 640)
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(
            x: (vf.midX - initial.width / 2).rounded(),
            y: (vf.midY - initial.height / 2).rounded()
        )

        let p = InteractiveHUDPanel(
            contentRect: NSRect(origin: origin, size: initial),
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
            DailyRecapView(
                data: data,
                onGoodNight: { [weak self] in
                    Task { @MainActor [weak self] in
                        SpeechEngine.shared.stop(reason: "recap good night")
                        self?.dismiss()
                    }
                },
                onPlanTomorrow: { [weak self] in
                    Task { @MainActor [weak self] in
                        SpeechEngine.shared.stop(reason: "plan tomorrow")
                        // Open the menu-bar chat UI so the user can talk through tomorrow.
                        WindowOpener.openChat()
                        self?.dismiss()
                    }
                }
            )
            .padding(10)
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: initial)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        p.contentView = hc.view
        self.panel = p
        self.hostingController = hc

        p.orderFrontRegardless()
        // Snap to visible immediately, then fade up. Prevents the panel from
        // sitting invisible if the animation is pre-empted.
        p.alphaValue = 1.0
        WakeLog.shared.log("dailyRecap: panel presented at \(origin)")
    }

    private func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }
}
