import AppKit
import SwiftUI

@MainActor
final class TerminalFocusOverlayController {
    static let shared = TerminalFocusOverlayController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var trackingView: HoverTrackingView?

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    func show() {
        if let existing = panel {
            updateFrame(panel: existing)
            if !existing.isVisible { existing.orderFront(nil) }
            return
        }
        buildPanel()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    func bringToFront() {
        panel?.orderFront(nil)
    }

    /// Used by the resync picker in `TerminalFocusState` to force pass-through
    /// regardless of hover state. Hover-driven updates will override this the
    /// next time the mouse enters/exits the panel.
    func setClickThrough(_ passThrough: Bool) {
        panel?.ignoresMouseEvents = passThrough
    }

    private func buildPanel() {
        let focusState = TerminalFocusState.shared
        let frame = focusState.overlayFrame()

        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.isReleasedWhenClosed = false
        newPanel.ignoresMouseEvents = true // start unfocused / click-through
        newPanel.alphaValue = 0.7
        newPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle
        ]

        let rootView = AnyView(
            TerminalFocusClaudeView()
                .environmentObject(focusState)
        )
        let hc = NSHostingController(rootView: rootView)
        hc.view.frame = CGRect(origin: .zero, size: frame.size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear

        let tracker = HoverTrackingView(frame: CGRect(origin: .zero, size: frame.size))
        tracker.autoresizingMask = [.width, .height]
        tracker.wantsLayer = true
        tracker.layer?.backgroundColor = CGColor.clear
        tracker.onHoverChange = { [weak self, weak newPanel] isHovered in
            guard let panel = newPanel else { return }
            self?.applyHoverState(panel: panel, hovered: isHovered)
        }
        tracker.addSubview(hc.view)

        newPanel.contentView = tracker

        self.panel = newPanel
        self.hostingController = hc
        self.trackingView = tracker

        newPanel.orderFront(nil)
    }

    private func applyHoverState(panel: NSPanel, hovered: Bool) {
        panel.ignoresMouseEvents = !hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = hovered ? 1.0 : 0.7
        }
    }

    private func updateFrame(panel: NSPanel) {
        let frame = TerminalFocusState.shared.overlayFrame()
        panel.setFrame(frame, display: true, animate: false)
        let localSize = CGRect(origin: .zero, size: frame.size)
        trackingView?.frame = localSize
        hostingController?.view.frame = localSize
    }
}

/// NSView subclass that reports hover enter/exit via an NSTrackingArea
/// covering its full visible rect. Used to drive opacity + click-through on
/// the parent NSPanel.
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}
