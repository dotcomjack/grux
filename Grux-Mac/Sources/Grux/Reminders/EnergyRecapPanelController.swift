import AppKit
import SwiftUI

// Centered glass takeover for the 8pm energy + focus recap. Mirrors the
// DailyRecapPanelController pattern (InteractiveHUDPanel, non-activating,
// fade-out on dismiss) but rendered tighter since this is a numbers-first
// surface rather than the warmer 10pm wrap-up.
@MainActor
final class EnergyRecapPanelController {
    static let shared = EnergyRecapPanelController()

    private var panel: InteractiveHUDPanel?
    private var hostingController: NSHostingController<AnyView>?

    private init() {}

    func present(_ data: EnergyRecap) {
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

    private func build(with data: EnergyRecap) {
        let initial = NSSize(width: 580, height: 560)
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
            EnergyRecapView(
                data: data,
                onReplay: { [weak self] in
                    Task { @MainActor [weak self] in
                        SpeechEngine.shared.stop(reason: "energy recap replay")
                        SpeechEngine.shared.speak(data.summaryText)
                        _ = self
                    }
                },
                onClose: { [weak self] in
                    Task { @MainActor [weak self] in
                        SpeechEngine.shared.stop(reason: "energy recap close")
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
        p.alphaValue = 1.0
        WakeLog.shared.log("energyRecap: panel presented at \(origin)")
    }

    private func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }
}
