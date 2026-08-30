import AppKit
import SwiftUI
import Combine

// Cinematic full-screen "Stage" for tool-call-driven hero moments. Claude
// can call `grux_orb_stage` to bloom a gradient backdrop with a giant orb
// and a short message for a few seconds. Opt-in per-response - the LLM
// decides when a beat deserves the cinematic treatment. Not auto-triggered.
//
// Implementation: a single transparent click-through NSWindow at the
// .screenSaver level, spanning the visible frame of the screen that hosts
// the mouse cursor. Dismisses automatically after `duration`, or when the
// user clicks anywhere on the stage.
@MainActor
final class StageController {
    static let shared = StageController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    var isShowing: Bool { window?.isVisible == true }

    func show(message: String, state: GruxOrbState = .speaking, duration: TimeInterval = 3.5) {
        // Clamp to [1.0s, 8.0s]. A zero-duration stage would flash-and-disappear;
        // anything > 8s is a nag, not a beat.
        let clamped = max(1.0, min(8.0, duration))
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // 180 chars is more than any one-line hero message should need. Past
        // that, display text wraps to two lines; past three, it ellipsizes.
        let clampedMsg = String(trimmed.prefix(180))
        guard !clampedMsg.isEmpty else { return }

        dismiss(animated: false)

        guard let screen = screenUnderMouse() ?? NSScreen.main else { return }
        let frame = screen.visibleFrame

        let w = StagePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false // allow click-to-dismiss
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false

        let root = AnyView(
            StageView(
                message: clampedMsg,
                state: state,
                onTap: { [weak self] in
                    Task { @MainActor [weak self] in self?.dismiss() }
                }
            )
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: frame.size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        w.contentView = hc.view

        self.window = w
        self.hostingController = hc
        w.orderFrontRegardless()

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss(animated: Bool = true) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let w = window else { return }
        // Appearance: decorative-motion opt-out makes dismissal instant.
        if animated && !GruxTheme.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                // Matches StageView's entrance (MotionTokens.easeOutSlow) so
                // the stage leaves at the same pace it arrived.
                ctx.duration = MotionTokens.slow
                w.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.window?.orderOut(nil)
                    self?.window = nil
                    self?.hostingController = nil
                }
            })
        } else {
            w.orderOut(nil)
            self.window = nil
            self.hostingController = nil
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
    }
}

// NSPanel subclass that can become key so SwiftUI can receive the click-to-dismiss
// gesture even without activating the whole app.
private final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
