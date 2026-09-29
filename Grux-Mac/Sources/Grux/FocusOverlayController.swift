import AppKit
import SwiftUI
import Combine

// Floating NSPanel that hosts FocusOverlayView. Anchored top-right of the
// main screen on first launch; frame persisted between launches so the user can
// drag it wherever they want. Same non-activating pattern as AmbientPanelController.
//
// The panel is always exactly the size of its content. When the card collapses
// to the orb or expands back, FocusOverlayPlacement keeps the corner nearest
// the screen edge fixed, so the orb sits where the card's outer corner was and
// the card grows back out of the orb. A drag that ends near an edge settles
// onto the inset, and the side the card is on is published so the view can
// mirror itself (orb on the outer edge, collapse control on the inner edge).
@MainActor
final class FocusOverlayController {
    static let shared = FocusOverlayController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private let defaultsKey = "grux.focusOverlayFrame"
    private var subscriptions: Set<AnyCancellable> = []
    private var settleWork: DispatchWorkItem?
    private var reframeWork: DispatchWorkItem?
    private var suppressMoveHandling = false
    /// How long the collapse transition runs; the panel shrinks after it.
    static let collapseTransitionSeconds: TimeInterval = 0.36

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    func show() {
        if let existing = panel {
            WindowFacade.orderFrontRegardless(existing)
            FocusOverlayState.shared.isVisible = true
            return
        }
        build()
    }

    func hide() {
        panel?.orderOut(nil)
        FocusOverlayState.shared.isVisible = false
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    // MARK: - Drive (debug trigger and tests)

    /// Moves the card to a corner of its screen. The content size is kept.
    func place(side: FocusOverlaySide, vertical: FocusOverlayVerticalHalf) {
        guard let p = panel, let visible = visibleFrame(for: p) else { return }
        setFrame(FocusOverlayPlacement.frame(for: p.frame.size, side: side, vertical: vertical, in: visible), of: p)
        publishSide(of: p)
        saveFrame(p.frame)
    }

    func moveTo(x: CGFloat, y: CGFloat) {
        guard let p = panel, let visible = visibleFrame(for: p) else { return }
        setFrame(FocusOverlayPlacement.clamped(NSRect(origin: NSPoint(x: x, y: y), size: p.frame.size), in: visible), of: p)
        publishSide(of: p)
        saveFrame(p.frame)
    }

    /// One JSON line an outside tool can assert on.
    func statusJSON() -> String {
        let s = FocusOverlayState.shared
        var d: [String: Any] = ["visible": isShowing, "collapsed": s.isCollapsed,
                                "side": s.side.rawValue, "vertical": s.vertical.rawValue,
                                "contentSize": [s.contentSize.width, s.contentSize.height]]
        if let p = panel {
            d["frame"] = [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height]
            if let v = visibleFrame(for: p) { d["screenVisible"] = [v.minX, v.minY, v.width, v.height] }
        }
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Build

    private func build() {
        let initialSize = NSSize(width: 332, height: 200)
        let frame = restoredFrame(defaultSize: initialSize)

        let p = FocusOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "Grux Focus"
        WindowFacade.setLevel(.floating, of: p)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let root = AnyView(FocusOverlayView())
        let hc = NSHostingController(rootView: root)
        // This controller owns the panel's frame, so the hosting view must NOT
        // be the panel's content view: an NSHostingView that is a window's
        // content view resizes that window itself whenever an animation moves
        // the ideal size (updateAnimatedWindowSize, from windowDidLayout), and
        // on 2026-09-20 that fired inside a layout pass on expand and aborted
        // the app twice, sizingOptions = [] notwithstanding. A plain container
        // holds the panel's frame; the hosting view fills it.
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor.clear
        hc.view.frame = container.bounds
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        container.addSubview(hc.view)
        p.contentView = container

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.panelDidMove() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensChanged() }
        }

        // The content reports its size; the panel follows, keeping the outer
        // corner. Collapsing waits for the transition so the orb animates
        // inside the old bounds before the panel shrinks around it.
        FocusOverlayState.shared.$contentSize
            .removeDuplicates()
            .sink { [weak self] size in
                Task { @MainActor [weak self] in self?.contentSizeChanged(size) }
            }
            .store(in: &subscriptions)

        self.panel = p
        self.hostingController = hc
        publishSide(of: p)
        WindowFacade.orderFrontRegardless(p)
        FocusOverlayState.shared.isVisible = true
    }

    // MARK: - Geometry

    private func visibleFrame(for panel: NSPanel) -> NSRect? {
        (panel.screen ?? NSScreen.main)?.visibleFrame
    }

    private func setFrame(_ frame: NSRect, of panel: NSPanel) {
        suppressMoveHandling = true
        panel.setFrame(frame, display: true, animate: false)
        suppressMoveHandling = false
    }

    private func publishSide(of panel: NSPanel) {
        guard let visible = visibleFrame(for: panel) else { return }
        let s = FocusOverlayPlacement.side(of: panel.frame, in: visible)
        let v = FocusOverlayPlacement.verticalHalf(of: panel.frame, in: visible)
        if FocusOverlayState.shared.side != s { FocusOverlayState.shared.side = s }
        if FocusOverlayState.shared.vertical != v { FocusOverlayState.shared.vertical = v }
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard let p = panel, size.width > 0, size.height > 0, let visible = visibleFrame(for: p) else { return }
        reframeWork?.cancel()
        let target = FocusOverlayPlacement.frame(for: NSSize(width: size.width, height: size.height),
                                                 keepingAnchorOf: p.frame, in: visible)
        let shrinking = size.width < p.frame.width || size.height < p.frame.height
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            self.setFrame(target, of: p)
            self.publishSide(of: p)
            self.saveFrame(p.frame)
        }
        reframeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (shrinking ? Self.collapseTransitionSeconds : 0), execute: work)
    }

    private func panelDidMove() {
        guard !suppressMoveHandling, let p = panel else { return }
        publishSide(of: p)
        // Moves arrive continuously during a drag; settle once they stop.
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel, let visible = self.visibleFrame(for: p) else { return }
            let settled = FocusOverlayPlacement.snapped(p.frame, in: visible)
            if settled != p.frame { self.setFrame(settled, of: p) }
            self.publishSide(of: p)
            self.saveFrame(p.frame)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func screensChanged() {
        guard let p = panel, let visible = visibleFrame(for: p) else { return }
        let inside = FocusOverlayPlacement.clamped(p.frame, in: visible)
        if inside != p.frame { setFrame(inside, of: p) }
        publishSide(of: p)
    }

    private func restoredFrame(defaultSize: NSSize) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let r = NSRectFromString(saved)
            if r.width > 40 && r.height > 40 { return r }
        }
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: defaultSize)
        }
        return FocusOverlayPlacement.frame(for: defaultSize, side: .right, vertical: .top, in: screen.visibleFrame)
    }

    private func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: defaultsKey)
    }
}

// NSPanel subclass matching InteractiveHUDPanel's pattern - `canBecomeKey`
// true so SwiftUI Buttons inside receive clicks, but `canBecomeMain` stays
// false so the overlay never steals the main-window identity.
private final class FocusOverlayPanel: NSPanel, MotionLivesOnTheRenderServer {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
