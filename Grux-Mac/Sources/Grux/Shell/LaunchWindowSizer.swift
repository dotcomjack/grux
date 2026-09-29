import AppKit

/// The launch window's width and minimum, in one place. The Command Panel
/// grows the window to hold a pane and shrinks it back, and the minimum moves
/// with it, so a user cannot drag the pane off the edge. A struct over the
/// window rather than AppDelegate state, so a test can drive it on a bare
/// window.
@MainActor
struct LaunchWindowSizer {
    let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    /// The launch window's level. Only the Command Panel floats: the classic
    /// sidebar shell stays normal whatever `keepOnTop` says.
    nonisolated static func level(keepOnTop: Bool, legacyShell: Bool) -> NSWindow.Level {
        keepOnTop && !legacyShell ? .floating : .normal
    }

    /// Sets the content minimum, and the frame minimum to match it with the
    /// window's chrome added, so AppKit's drag limit and the content floor agree.
    func setMinimum(_ size: NSSize) {
        let chromeW = window.frame.size.width - window.contentLayoutRect.size.width
        let chromeH = window.frame.size.height - window.contentLayoutRect.size.height
        window.contentMinSize = size
        window.minSize = NSSize(width: size.width + chromeW, height: size.height + chromeH)
    }

    /// Sets the content minimum height, keeping the minimum width, and grows
    /// a shorter window to it from the top edge, so a flow with a taller floor
    /// than the panel (onboarding) is never clipped.
    func setMinimumHeight(_ height: CGFloat) {
        setMinimum(NSSize(width: window.contentMinSize.width, height: height))
        let current = window.contentLayoutRect.size.height
        guard current < height - 0.5 else { return }
        var f = window.frame
        f.origin.y -= height - current
        f.size.height += height - current
        if let screen = window.screen?.visibleFrame, f.minY < screen.minY {
            f.origin.y = screen.minY
        }
        window.setFrame(f, display: true)
    }

    /// Puts the window back on its floor after something other than a drag
    /// (a window tool, a script) set a frame under it. AppKit holds the
    /// minimum for a drag only, and under it the pane clips.
    func restoreFloor() {
        setMinimumWidth(window.contentMinSize.width)
    }

    /// Sets the content minimum width, keeping the minimum height, and grows
    /// a narrower window to it from the trailing edge, pulled back left only
    /// when growing would leave the screen. A wider window keeps its width:
    /// this raises a floor, it does not pick a size.
    func setMinimumWidth(_ width: CGFloat) {
        setMinimum(NSSize(width: width, height: window.contentMinSize.height))
        let current = window.contentLayoutRect.size.width
        guard current < width - 0.5 else { return }
        var f = window.frame
        f.size.width += width - current
        if let screen = window.screen?.visibleFrame, f.maxX > screen.maxX {
            f.origin.x = max(screen.minX, screen.maxX - f.size.width)
        }
        window.setFrame(f, display: true)
    }

    /// Sets the content width to `width` and the content minimum width to
    /// `minWidth`. Anchored at the top-left, so the panel does not walk across
    /// the screen; pulled back left only when growing would leave the screen.
    /// Animates unless `GruxTheme.reduceMotion`.
    ///
    /// `keepingExplicitWidth`: the current width was asked for at launch
    /// (`--win-w`). It is kept unless it is under `minWidth`, and then it is
    /// raised to the minimum, not to `width`.
    func setContentWidth(_ width: CGFloat, minWidth: CGFloat, animated: Bool,
                         keepingExplicitWidth: Bool = false) {
        setMinimum(NSSize(width: minWidth, height: window.contentMinSize.height))
        let current = window.contentLayoutRect.size.width
        let target = keepingExplicitWidth ? max(current, minWidth) : width
        guard abs(current - target) > 0.5 else { return }
        var f = window.frame
        f.size.width += target - current
        if let screen = window.screen?.visibleFrame, f.maxX > screen.maxX {
            f.origin.x = max(screen.minX, screen.maxX - f.size.width)
        }
        window.setFrame(f, display: true, animate: animated && !GruxTheme.reduceMotion)
    }
}
