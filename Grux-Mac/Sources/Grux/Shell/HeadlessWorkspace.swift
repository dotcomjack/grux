import AppKit

/// What Grux's windows hold, readable without the screen and without Screen
/// Recording permission, for a Mac running headless (`WindowFacade`).
///
/// `~/.grux/headless-workspace/workspace.json` is rewritten whenever it changes while
/// headless: every window's id, title, frame, alpha, level, the rendered tab and
/// each window's focused control. `snapshot` renders each window's own view
/// hierarchy to PNG with `cacheDisplay(in:to:)` into
/// `~/.grux/headless-workspace/shots/<time>-<key>-<window>.png`, on `fire-headless-snapshot` and
/// shortly after every tab change or pane open. The folder keeps the newest 200.
@MainActor
enum HeadlessWorkspace {
    /// Not `headless`: on a case-insensitive disk that is the sentinel `HEADLESS` itself.
    static var dir: URL { Persistence.gruxDir.appendingPathComponent("headless-workspace") }
    static var workspaceURL: URL { dir.appendingPathComponent("workspace.json") }
    static var shotsDir: URL { dir.appendingPathComponent("shots") }
    /// The last snapshot's files, for a script waiting on `fire-headless-snapshot`.
    static var resultURL: URL { dir.appendingPathComponent("snapshot-result.json") }
    static let shotCap = 200

    private static var lastWritten: Data?

    /// The windows worth describing: not the menu bar's own status item window.
    static var windows: [NSWindow] {
        NSApp.windows.filter { !String(describing: type(of: $0)).contains("StatusBar") }
    }

    static func state() -> [String: Any] {
        let wins: [[String: Any]] = windows.map { w in
            let f = w.frame
            var d: [String: Any] = [
                "id": w.windowNumber,
                "title": w.title,
                "class": String(describing: type(of: w)),
                "frame": [f.origin.x, f.origin.y, f.size.width, f.size.height].map { Double($0) },
                "alpha": Double(w.alphaValue),
                "ignoresMouseEvents": w.ignoresMouseEvents,
                "level": w.level.rawValue,
                "visible": w.isVisible,
                "key": w.isKeyWindow,
            ]
            if let r = w.firstResponder, r !== w { d["focused"] = String(describing: type(of: r)) }
            return d
        }
        return [
            "headless": WindowFacade.isHeadless,
            "appActive": NSApp.isActive,
            "activationPolicy": NSApp.activationPolicy() == .accessory ? "accessory"
                : NSApp.activationPolicy() == .regular ? "regular" : "prohibited",
            "renderedTab": (try? String(contentsOf: RenderedTab.fileURL, encoding: .utf8)) ?? "",
            "requestedTab": AppState.shared.requestedTab,
            "windows": wins,
        ]
    }

    /// Rewrites workspace.json when what it says changed.
    static func refresh() {
        guard let data = try? JSONSerialization.data(withJSONObject: state(), options: [.prettyPrinted, .sortedKeys]),
              data != lastWritten else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: workspaceURL, options: .atomic)
        lastWritten = data
    }

    /// A tab rendered or a pane opened: headless, snapshot it once it has drawn.
    /// One shot per render, never coalesced, so a fast sweep still leaves one PNG
    /// per tab; the file name carries the key that was on screen when it was taken.
    static func noteRendered(_ key: String) {
        guard WindowFacade.isHeadless else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let onScreen = (try? String(contentsOf: RenderedTab.fileURL, encoding: .utf8)) ?? key
            snapshot(reason: onScreen)
        }
    }

    /// Renders every visible Grux window to PNG. Returns the files written.
    @discardableResult
    static func snapshot(reason: String) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        let stamp = stampFormatter.string(from: Date())
        var written: [String] = []
        for w in windows where w.isVisible {
            guard let view = w.contentView, view.bounds.width > 1, view.bounds.height > 1,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = slug(w.title.isEmpty ? String(describing: type(of: w)) : w.title)
            let url = shotsDir.appendingPathComponent("\(stamp)-\(slug(reason))-\(name)-\(w.windowNumber).png")
            if (try? png.write(to: url, options: .atomic)) != nil { written.append(url.path) }
        }
        prune()
        refresh()
        let result: [String: Any] = ["reason": reason, "renderedTab": state()["renderedTab"] ?? "", "files": written]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: resultURL, options: .atomic)
        }
        return written
    }

    /// Keeps the newest `shotCap` files; names start with the time, so name order is age order.
    static func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: shotsDir.path) else { return }
        let pngs = names.filter { $0.hasSuffix(".png") }.sorted()
        for name in pngs.dropLast(shotCap) {
            try? fm.removeItem(at: shotsDir.appendingPathComponent(name))
        }
    }

    static func slug(_ s: String) -> String {
        let kept = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(kept).split(separator: "-").joined(separator: "-").prefix(40))
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()
}
