import AppKit
import SwiftUI

// Floating, non-activating NSPanel that hosts a Reminder Toast at the
// bottom-right of the main screen. Stacks below the Ambient HUD if both
// are visible. Auto-dismisses after 6 seconds unless the user is hovering
// or has interacted. Clicks on action chips route back to GruxReminderState.
@MainActor
final class GruxReminderPanelController {
    static let shared = GruxReminderPanelController()

    private var panel: InteractiveHUDPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var autoDismissTimer: Timer?
    private var currentReminderId: UUID?
    private let autoDismissSeconds: TimeInterval = 6.5

    private init() {}

    func present(_ reminder: GruxReminder) {
        currentReminderId = reminder.id
        // Rebuild every time - the toast content differs per reminder and
        // the panel is small + cheap to construct.
        tearDownPanel()
        buildPanel(for: reminder)
        scheduleAutoDismiss()
    }

    func dismiss(animated: Bool) {
        autoDismissTimer?.invalidate(); autoDismissTimer = nil
        guard let panel = panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.tearDownPanel() }
            }
        } else {
            tearDownPanel()
        }
    }

    private func buildPanel(for reminder: GruxReminder) {
        let panelSize = NSSize(width: 360, height: 200)
        let origin = bottomRightOrigin(for: panelSize)

        let p = InteractiveHUDPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
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
        p.alphaValue = 0

        let root = AnyView(
            ReminderToastView(
                reminder: reminder,
                onAccept: { [weak self] in self?.handleAccept(reminder.id) },
                onDismiss: { [weak self] in self?.handleDismiss(reminder.id) },
                onSnooze: { [weak self] mins in self?.handleSnooze(reminder.id, minutes: mins) }
            )
            .padding(6)
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: panelSize)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        p.contentView = hc.view
        self.panel = p
        self.hostingController = hc

        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            p.animator().alphaValue = 1
        }
    }

    private func tearDownPanel() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        currentReminderId = nil
    }

    private func scheduleAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss(animated: true) }
        }
    }

    private func handleAccept(_ id: UUID) {
        GruxReminderState.shared.accept(id)
    }

    private func handleDismiss(_ id: UUID) {
        GruxReminderState.shared.dismiss(id)
    }

    private func handleSnooze(_ id: UUID, minutes: Int) {
        GruxReminderState.shared.snooze(id, minutes: minutes)
    }

    // Position in the bottom-right of the main screen, above the Dock.
    // Stacks roughly 20pt below the Ambient HUD if both are up - we don't
    // track the HUD's exact frame here; the ambient panel is top-aligned
    // and the toast is bottom-aligned, so they don't overlap at default
    // positions.
    private func bottomRightOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let x = vf.maxX - size.width - 20
        let y = vf.minY + 20
        return NSPoint(x: x, y: y)
    }
}
