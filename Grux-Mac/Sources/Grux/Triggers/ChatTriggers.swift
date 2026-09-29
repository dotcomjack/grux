import AppKit

/// File-drop triggers that do to the live Chat transcript what only a click or
/// a scroll could (operator rule 0r.4): SWEEP-12 could not check Show earlier,
/// the Latest chip or a scroll on a headless Mac, because nothing but a mouse
/// reached them.
///
/// Each one acts through `ChatView.perform`, which runs the same function the
/// Show earlier row and the Latest chip run (a scroll goes the way a
/// trackpad scroll reaches Chat), waits for the transcript to settle, then
/// writes `chat-status.json` atomically. `fire-chat-status` only writes it.
@MainActor
enum ChatTriggers {
    static let showEarlier = "fire-chat-show-earlier"
    /// Contents: points to scroll, negative is up.
    static let scroll = "fire-chat-scroll"
    static let latest = "fire-chat-latest"
    static let status = "fire-chat-status"
    /// Contents: the open pane's width in points.
    static let paneWidth = "fire-pane-width"
    static let names = [showEarlier, scroll, latest, status, paneWidth]

    static let statusFile = "chat-status.json"

    /// Sets the open pane's width. The app's own: the Command Panel's window
    /// sizer, keeping the window's floor. Tests put their own pane here.
    static var setPaneWidth: (CGFloat) -> Void = { width in
        guard let delegate = AppDelegate.shared, let win = delegate.launchWindow else { return }
        let floor = win.contentMinSize.width
        let chrome = win.frame.width - win.contentLayoutRect.width
        let screen = (win.screen ?? NSScreen.main)?.visibleFrame.width ?? .greatestFiniteMagnitude
        delegate.setLaunchWindowContentWidth(contentWidth(forPane: width, floor: floor, screen: screen, chrome: chrome),
                                             minWidth: floor, animated: false)
    }

    /// The window content width that gives the open pane `pane` points: the
    /// panel, its divider and the pane, never under the window's floor and
    /// never wider than the screen can show.
    static func contentWidth(forPane pane: CGFloat, floor: CGFloat, screen: CGFloat, chrome: CGFloat) -> CGFloat {
        let wanted = GruxLayout.panelWidth + 1 + pane
        return max(floor, min(wanted, screen - chrome))
    }

    /// A number of points a trigger can act on: finite, never NaN or infinity.
    static func points(_ contents: String) -> Double? {
        guard let value = Double(contents), value.isFinite else { return nil }
        return value
    }

    static func register(in dir: URL, on watcher: TriggerWatcher = .shared) {
        for name in names {
            let file = dir.appendingPathComponent(name)
            watcher.register(file) {
                guard FileManager.default.fileExists(atPath: file.path) else { return }
                let contents = (try? String(contentsOf: file, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: file)
                Task { @MainActor in await fire(name, contents: contents, dir: dir) }
            }
        }
    }

    /// Runs one trigger, then writes the status once the transcript settles.
    static func fire(_ name: String, contents: String, dir: URL) async {
        var acted = true
        switch name {
        case showEarlier: acted = ChatView.perform(.showEarlier)
        case latest: acted = ChatView.perform(.latest)
        case scroll:
            if let points = points(contents) { acted = ChatView.perform(.scroll(CGFloat(points))) }
            else { acted = false }
        case paneWidth:
            if let width = points(contents), width > 0 { setPaneWidth(CGFloat(width)) } else { acted = false }
        default: break
        }
        WakeLog.shared.log("\(name): \(acted ? "done" : "nothing to act on") \(contents)")
        if name != status { await settle() }
        writeStatus(to: dir.appendingPathComponent(statusFile))
    }

    /// Waits until the transcript stops moving, at most 3 s. At least 0.35 s,
    /// so a scroll the action queued has started.
    static func settle() async {
        let start = Date()
        try? await Task.sleep(nanoseconds: 350_000_000)
        while Date().timeIntervalSince(start) < 3, !ChatView.isSettled() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func writeStatus(to url: URL) {
        var status = ChatView.status()
        status["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
