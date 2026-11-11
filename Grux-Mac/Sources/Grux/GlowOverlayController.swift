import AppKit
import SwiftUI
import ApplicationServices

// Shows an animated glow around the currently-focused window of the frontmost
// app. Red when the user drifts off-task, green when they lock back in.
@MainActor
final class GlowOverlayController {
    static let shared = GlowOverlayController()

    private var edgeWindows: [GlowEdge: GlowEdgeWindow] = [:]
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// The red and green edges follow "Animate window edges red/green", the cyan
    /// pulse follows "Pulse window edges in cyan" alone, so greying the drift
    /// switch while screen analysis is off cannot hide the pulse (wave 68).
    static func allows(_ mode: GlowColorMode, driftEdges: Bool, speakingPulse: Bool) -> Bool {
        switch mode {
        case .focused, .distracted: return driftEdges
        case .speaking: return speakingPulse
        }
    }

    private static func allows(_ mode: GlowColorMode) -> Bool {
        let config = AppState.shared.config
        return allows(mode, driftEdges: config.glowOverlayEnabled, speakingPulse: config.audioReactiveGlow)
    }

    // Showtime. Returns immediately; glow auto-dismisses after ~3.5s.
    func showGlowAroundActiveWindow(colorMode: GlowColorMode) {
        guard Self.allows(colorMode) else { return }
        guard let windowFrame = getActiveWindowFrame() else {
            NSLog("[Grux] glow: could not resolve active window frame")
            return
        }
        showGlow(around: windowFrame, colorMode: colorMode)
    }

    func showGlow(around frame: NSRect, colorMode: GlowColorMode) {
        guard Self.allows(colorMode) else { return }
        dismissOverlay()

        for edge in [GlowEdge.top, .bottom, .left, .right] {
            let edgeWindow = GlowEdgeWindow(edge: edge)
            let glowView = GlowEdgeView(edge: edge, colorMode: colorMode)
            let hosting = NSHostingView(rootView: glowView)
            hosting.frame = edgeWindow.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]
            edgeWindow.contentView?.addSubview(hosting)
            edgeWindow.updateFrame(for: frame)
            WindowFacade.orderFrontRegardless(edgeWindow)
            edgeWindows[edge] = edgeWindow
        }

        // GlowEdgeView's internal startAnimation schedules fade-out at 2.5s +
        // 0.5s, so a 3.5s teardown gives the fade a clean finish before the
        // windows go away.
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled {
                self?.dismissOverlay()
            }
        }
    }

    func dismissOverlay() {
        dismissTask?.cancel()
        dismissTask = nil
        for (_, window) in edgeWindows {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.animationBehavior = .none
            window.orderOut(nil)
        }
        edgeWindows.removeAll()
    }

    // MARK: - Active window frame

    private func getActiveWindowFrame() -> NSRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        // Don't draw a glow around Grux itself.
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        if let frame = frameViaAccessibility(pid: pid) {
            return frame
        }
        return frameViaWindowList(pid: pid)
    }

    private func frameViaAccessibility(pid: pid_t) -> NSRect? {
        guard AccessibilityTrust.isGranted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowRef = focused else { return nil }
        let window = windowRef as! AXUIElement

        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              let posRef = positionValue else { return nil }
        var position = CGPoint.zero
        if !AXValueGetValue(posRef as! AXValue, .cgPoint, &position) { return nil }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let sizeRef = sizeValue else { return nil }
        var size = CGSize.zero
        if !AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) { return nil }

        guard size.width > 100, size.height > 100 else { return nil }

        // AX uses top-left origin; NSWindow uses bottom-left. Use the screen
        // that contains the window's top-left corner so multi-monitor
        // positioning stays correct (NSScreen.main is the *key* screen, not
        // the one the window lives on).
        let topLeft = position
        let screen = NSScreen.screens.first(where: { $0.frame.contains(topLeft) })
            ?? NSScreen.main
        let screenFrame = screen?.frame ?? .zero
        let flippedY = (screenFrame.maxY) - position.y - size.height

        return NSRect(x: position.x, y: flippedY, width: size.width, height: size.height)
    }

    private func frameViaWindowList(pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var rects: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 100, height > 100 else { continue }
            rects.append((x, y, width, height))
        }
        guard let largest = rects.max(by: { $0.w * $0.h < $1.w * $1.h }) else { return nil }
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        let flippedY = screenHeight - largest.y - largest.h
        return NSRect(x: largest.x, y: flippedY, width: largest.w, height: largest.h)
    }
}
