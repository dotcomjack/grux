import CoreGraphics
import AppKit

struct TerminalWindowInfo {
    let windowID: CGWindowID
    let frame: CGRect   // CGWindowList coords: top-left origin
    let title: String   // kCGWindowName - used to disambiguate same-position windows on different Spaces
}

enum TerminalWindowMapper {

    // AppleScript cache: (windowTitle, tty) pairs for ALL Terminal windows.
    // Matching by title is Space-accurate because every window has a unique title,
    // whereas multiple Spaces can have windows at the same screen position.
    private static var ttyPairCache: [(title: String, tty: String)] = []
    private static var ttyCacheAge: Date = .distantPast
    private static let ttyCacheTTL: TimeInterval = 4

    // Separate cache: TTY → cwd. The foreground process's cwd on each TTY,
    // looked up via `ps` + `lsof`. Reused across poll ticks so the Claude-
    // session auto-detector doesn't re-shell for every refresh.
    private static var cwdCache: [String: String] = [:]
    private static var cwdCacheAge: Date = .distantPast
    private static let cwdCacheTTL: TimeInterval = 6

    // Short-TTL cache on `terminalWindows()` - a single `refresh()` tick hits
    // this enumeration 4+ times (updateVisibility, updateCornerAssignments,
    // currentSpaceTTYsByCorner, onScreenTTYs). The underlying
    // CGWindowListCopyWindowInfo + NSString→String bridging is the hottest
    // path in the main-thread poll; sampling showed ~100% of CPU spent in the
    // `as? String` casts when there are many on-screen windows. Sharing one
    // result across the tick collapses that to a single enumeration.
    private static var windowsCache: [TerminalWindowInfo] = []
    private static var windowsCacheAge: Date = .distantPast
    private static let windowsCacheTTL: TimeInterval = 0.5

    static func terminalWindowCount() -> Int {
        let cgCount = terminalWindows().count
        if cgCount > 0 || CGPreflightScreenCaptureAccess() { return cgCount }
        return NSWorkspace.shared.runningApplications
            .filter { $0.localizedName == "Terminal" && $0.activationPolicy == .regular }
            .isEmpty ? 0 : 1
    }

    static func terminalWindows() -> [TerminalWindowInfo] {
        if Date().timeIntervalSince(windowsCacheAge) < windowsCacheTTL {
            return windowsCache
        }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let fresh: [TerminalWindowInfo] = list.compactMap { dict -> TerminalWindowInfo? in
            guard
                let owner = dict[kCGWindowOwnerName as String] as? String, owner == "Terminal",
                let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
                let wid = dict[kCGWindowNumber as String] as? CGWindowID
            else { return nil }

            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 100,
                height: boundsDict["Height"] ?? 100
            )
            guard frame.width > 50, frame.height > 50 else { return nil }
            let title = dict[kCGWindowName as String] as? String ?? ""
            return TerminalWindowInfo(windowID: wid, frame: frame, title: title)
        }
        windowsCache = fresh
        windowsCacheAge = Date()
        return fresh
    }

    // Returns (tty, windowTitle) for each on-screen Terminal window that has a resolvable TTY.
    // Used to synthesise sessions for windows with no JSON hook data yet.
    static func liveWindowSummaries() -> [(tty: String, title: String)] {
        terminalWindows().compactMap { win in
            guard let tty = resolvedTTY(for: win) else { return nil }
            return (tty: tty, title: win.title)
        }
    }

    // Returns the set of TTYs whose terminal windows are on the current Space.
    static func onScreenTTYs() -> Set<String> {
        let onScreen = terminalWindows()
        var result = Set<String>()
        for win in onScreen {
            if let tty = resolvedTTY(for: win) { result.insert(tty) }
        }
        return result
    }

    // Returns the TTY of the currently-frontmost Terminal window, or nil if Terminal
    // isn't the active app or the window can't be resolved. Used to mark a session
    // as "seen" when the user focuses its window.
    static func frontmostWindowTTY() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.localizedName == "Terminal" else { return nil }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        // CGWindowList returns windows in front-to-back order; first Terminal window at layer 0 is frontmost.
        guard let front = list.first(where: {
            ($0[kCGWindowOwnerName as String] as? String) == "Terminal" &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }) else { return nil }
        let title = (front[kCGWindowName as String] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        if let m = ttyPairCache.first(where: { $0.title == title }) { return m.tty }
        let key = titleKey(title)
        if let m = ttyPairCache.first(where: { !$0.title.isEmpty && titleKey($0.title) == key }) { return m.tty }
        return nil
    }

    // Call from main queue. Spawns a background fetch if the cache is stale.
    static func scheduleRefreshTTYCache() {
        guard Date().timeIntervalSince(ttyCacheAge) >= ttyCacheTTL else { return }
        ttyCacheAge = Date()
        DispatchQueue.global(qos: .utility).async {
            let pairs = fetchWindowTTYPairsViaOsascript()
            DispatchQueue.main.async { ttyPairCache = pairs }
        }
    }

    // MARK: - Per-Space Claude session auto-detection (v1.1)

    // Returns the current-Space Terminal windows mapped to their quadrants
    // around `overlayFrame`. Value is the TTY - caller resolves that to a cwd
    // (via `cachedCwd(forTTY:)`) and matches it to a Claude session.
    static func currentSpaceTTYsByCorner(overlayFrame nsFrame: CGRect) -> [OverlayCorner: String] {
        let onScreen = terminalWindows()
        guard !onScreen.isEmpty else { return [:] }
        let screenH = NSScreen.screens.first?.frame.height ?? 900
        let oCenter = CGPoint(x: nsFrame.midX, y: screenH - nsFrame.midY)
        var result: [OverlayCorner: String] = [:]
        for win in onScreen {
            let corner = quadrant(win.frame.center, oCenter)
            guard result[corner] == nil else { continue }
            guard let tty = resolvedTTY(for: win) else { continue }
            result[corner] = tty
        }
        return result
    }

    // Returns the cached cwd for a TTY if we've looked it up recently. Does
    // not block - if the entry is stale, `scheduleRefreshCwdCache(for:)`
    // fires a background refresh, and the next poll tick picks up the result.
    static func cachedCwd(forTTY tty: String) -> String? { cwdCache[tty] }

    // Call from main queue. Spawns a background `ps` + `lsof` for each TTY
    // whose cwd hasn't been refreshed within the cwd TTL.
    static func scheduleRefreshCwdCache(ttys: Set<String>) {
        guard !ttys.isEmpty,
              Date().timeIntervalSince(cwdCacheAge) >= cwdCacheTTL else { return }
        cwdCacheAge = Date()
        let snapshot = ttys
        DispatchQueue.global(qos: .utility).async {
            var fresh: [String: String] = [:]
            for tty in snapshot {
                if let cwd = lookupCwd(forTTY: tty) { fresh[tty] = cwd }
            }
            DispatchQueue.main.async { cwdCache = fresh }
        }
    }

    // Synchronous - only call from a background thread. Runs `ps` to find the
    // foreground process on the TTY, then `lsof` to read that process's cwd.
    private static func lookupCwd(forTTY tty: String) -> String? {
        // `ps -t <tty> -o pid=,state=,command=` lists all processes on the
        // TTY. We want the foreground process (state contains '+'); fall back
        // to whichever process is running a user binary (not the bracketed
        // idle row).
        let psProc = Process()
        psProc.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProc.arguments = ["-t", tty, "-o", "pid=,state=,command="]
        let psPipe = Pipe()
        psProc.standardOutput = psPipe
        psProc.standardError = Pipe()
        guard (try? psProc.run()) != nil else { return nil }
        psProc.waitUntilExit()
        let raw = String(data: psPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var candidatePid: Int32?
        var fallbackPid: Int32?
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]) else { continue }
            let state = parts[1]
            let command = parts[2]
            if command.hasPrefix("[") { continue }
            if state.contains("+") {
                candidatePid = pid
                break
            }
            if fallbackPid == nil { fallbackPid = pid }
        }
        guard let pid = candidatePid ?? fallbackPid else { return nil }

        let lsProc = Process()
        lsProc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsProc.arguments = ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"]
        let lsPipe = Pipe()
        lsProc.standardOutput = lsPipe
        lsProc.standardError = Pipe()
        guard (try? lsProc.run()) != nil else { return nil }
        lsProc.waitUntilExit()
        let lsRaw = String(data: lsPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in lsRaw.components(separatedBy: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    // Assigns sessions to overlay corners by matching on-screen window titles → TTY → session.
    // Title matching correctly handles Spaces where two windows occupy the same screen position.
    static func assignCorners(sessions: [TerminalSession], overlayFrame nsFrame: CGRect) -> [OverlayCorner: TerminalSession] {
        let onScreen = terminalWindows()
        guard !onScreen.isEmpty, !sessions.isEmpty else { return [:] }

        let screenH = NSScreen.screens.first?.frame.height ?? 900
        let oCenter = CGPoint(x: nsFrame.midX, y: screenH - nsFrame.midY)
        // Duplicate TTYs are possible when two live windows transiently report the
        // same TTY (happens after rapid `do script ""` spawns, because AppleScript
        // returns a TTY before the new tty is fully assigned). Prefer the first
        // (oldest lastUpdated via the caller's sort) to keep assignment stable,
        // and NEVER crash with Dictionary(uniqueKeysWithValues:).
        let byTTY = Dictionary(sessions.map { ($0.tty, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [OverlayCorner: TerminalSession] = [:]

        for win in onScreen {
            let corner = quadrant(win.frame.center, oCenter)
            guard result[corner] == nil else { continue }
            if let tty = resolvedTTY(for: win), let session = byTTY[tty] {
                result[corner] = session
            }
        }

        return result
    }

    // MARK: - Private helpers

    // Resolve TTY for a CG window: title match (preferred, Space-accurate) → bounds fallback.
    private static func resolvedTTY(for win: TerminalWindowInfo) -> String? {
        guard !win.title.isEmpty else { return nil }
        // Exact title match
        if let m = ttyPairCache.first(where: { $0.title == win.title }) { return m.tty }
        // Icon-agnostic match: CGWindowList and AppleScript read the status icon at different
        // moments, so ⠐ vs ✳ mismatch is common. Strip the icon before comparing.
        let winKey = titleKey(win.title)
        if let m = ttyPairCache.first(where: { !$0.title.isEmpty && titleKey($0.title) == winKey }) {
            return m.tty
        }
        // Legacy prefix match (handles minor suffix differences)
        if let m = ttyPairCache.first(where: {
            !$0.title.isEmpty && (win.title.hasPrefix($0.title) || $0.title.hasPrefix(win.title))
        }) { return m.tty }
        return nil
    }

    // Produces a stable comparison key by stripping the Claude Code status icon and process suffix.
    // e.g. "user - ⠐ My Task" and "user - ✳ My Task - node ◂ claude..." both → "user:My Task"
    private static func titleKey(_ title: String) -> String {
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return title }
        var task = parts[1]
        if let first = task.first, !first.isASCII, task.count > 2, task.dropFirst().first == " " {
            task = String(task.dropFirst(2))
        }
        return parts[0] + ":" + task
    }

    private static func quadrant(_ p: CGPoint, _ center: CGPoint) -> OverlayCorner {
        switch (p.x <= center.x, p.y <= center.y) {
        case (true,  true):  return .topLeft
        case (false, true):  return .topRight
        case (true,  false): return .bottomLeft
        default:             return .bottomRight
        }
    }

    // MARK: - Adaptive grid inference

    // Infer the current Terminal grid shape (cols, rows) by clustering window
    // center positions. The overlay uses this to render an N×M task grid that
    // matches the actual Terminal cockpit (1×1 solo, 1×2 dual, 2×2 quad,
    // 2×3 / 3×2 six-pack, etc.) instead of the hardcoded 2×2.
    //
    // Returns (2, 2) when no Terminal windows are visible - preserves the
    // legacy default so the overlay still has a sensible fallback shape when
    // the user has no cockpit open yet.
    static func inferGridShape() -> (cols: Int, rows: Int) {
        let wins = terminalWindows()
        if wins.isEmpty { return (2, 2) }
        if wins.count == 1 { return (1, 1) }

        // Cluster window centers along each axis with a 100pt threshold -
        // looser than typical window snapping (which lands within ~5pt of a
        // tile boundary) but tight enough that a 2×2 doesn't get misread as
        // 1×4 just because two windows are slightly tall.
        let yClusters = clusterCoordinates(wins.map { $0.frame.midY }, threshold: 100)
        let xClusters = clusterCoordinates(wins.map { $0.frame.midX }, threshold: 100)
        let rows = max(1, yClusters.count)
        let cols = max(1, xClusters.count)

        // Sanity: clusters must accommodate every visible window. If they
        // don't (e.g. weird stacking), fall back to nice ratios for common
        // window counts so the overlay still has a usable shape.
        if rows * cols >= wins.count {
            return (cols, rows)
        }
        return fallbackShape(for: wins.count)
    }

    // Map each Terminal window to a row-major grid slot, return the
    // associated TerminalSession (or nil) per slot. Used by the overlay's
    // adaptive renderer when shape != (2, 2).
    //
    // Slot order matches reading order: top-left → top-right → next row →
    // bottom-right. Sessions are matched to windows via the same TTY-by-title
    // lookup as assignCorners(); slots without a resolvable session are nil
    // so the overlay can render an empty cell at that position.
    static func gridSlotsRowMajor(sessions: [TerminalSession], shape: (cols: Int, rows: Int)) -> [TerminalSession?] {
        let total = shape.cols * shape.rows
        guard total > 0 else { return [] }

        let wins = terminalWindows()
        guard !wins.isEmpty, !sessions.isEmpty else {
            return Array(repeating: nil, count: total)
        }

        let byTTY = Dictionary(sessions.map { ($0.tty, $0) }, uniquingKeysWith: { first, _ in first })

        // Sort by row (clustered Y), then by column (X within row). This
        // mirrors row-major reading order for any rectangular grid.
        let yClusters = clusterCoordinates(wins.map { $0.frame.midY }, threshold: 100)
        let yOrder = yClusters.enumerated().reduce(into: [CGFloat: Int]()) { acc, pair in
            for v in pair.element { acc[v] = pair.offset }
        }

        let sortedWins = wins.sorted { a, b in
            let ra = yOrder[a.frame.midY] ?? 0
            let rb = yOrder[b.frame.midY] ?? 0
            if ra != rb { return ra < rb }
            return a.frame.midX < b.frame.midX
        }

        var slots = [TerminalSession?](repeating: nil, count: total)
        for (i, win) in sortedWins.enumerated() where i < total {
            if let tty = resolvedTTY(for: win), let session = byTTY[tty] {
                slots[i] = session
            }
        }
        return slots
    }

    // Returns each grid slot's resolved cwd (or nil) in row-major order.
    // Length always == shape.cols * shape.rows so the adaptive overlay can
    // index directly. Slot N is the cwd of the Nth visible Terminal window
    // in reading order, or nil if no resolvable TTY/cwd is cached for that
    // slot. Falls back to nil entries for slots beyond the visible window
    // count (e.g. inferred 2x3 grid but only 5 windows actually open).
    static func cwdsRowMajor(shape: (cols: Int, rows: Int)) -> [String?] {
        let total = max(1, shape.cols * shape.rows)
        let wins = windowsRowMajor(for: shape)
        var out = [String?](repeating: nil, count: total)
        for (i, win) in wins.enumerated() where i < total {
            guard let tty = resolvedTTY(for: win) else { continue }
            out[i] = cachedCwd(forTTY: tty)
        }
        return out
    }

    // Returns Terminal windows ordered row-major (top-left first, reading
    // order). Used by the adaptive overlay to map grid slots to TTYs without
    // duplicating the position-clustering work each renderer would otherwise
    // need. Capped at the inferred grid total.
    static func windowsRowMajor(for shape: (cols: Int, rows: Int)) -> [TerminalWindowInfo] {
        let wins = terminalWindows()
        guard !wins.isEmpty else { return [] }
        let yClusters = clusterCoordinates(wins.map { $0.frame.midY }, threshold: 100)
        let yOrder = yClusters.enumerated().reduce(into: [CGFloat: Int]()) { acc, pair in
            for v in pair.element { acc[v] = pair.offset }
        }
        let sorted = wins.sorted { a, b in
            let ra = yOrder[a.frame.midY] ?? 0
            let rb = yOrder[b.frame.midY] ?? 0
            if ra != rb { return ra < rb }
            return a.frame.midX < b.frame.midX
        }
        let total = max(1, shape.cols * shape.rows)
        return Array(sorted.prefix(total))
    }

    // Group sorted CGFloat values into clusters where successive members are
    // within `threshold` of each other. Used for both row inference (Y) and
    // column inference (X).
    private static func clusterCoordinates(_ raw: [CGFloat], threshold: CGFloat) -> [[CGFloat]] {
        guard !raw.isEmpty else { return [] }
        let sorted = raw.sorted()
        var clusters: [[CGFloat]] = [[sorted[0]]]
        for v in sorted.dropFirst() {
            // Compare against the last value added to the current cluster - not
            // its mean - so a long string of barely-touching values doesn't
            // wrongly collapse into one cluster.
            if v - clusters[clusters.count - 1].last! < threshold {
                clusters[clusters.count - 1].append(v)
            } else {
                clusters.append([v])
            }
        }
        return clusters
    }

    // Sensible (cols, rows) for common window counts when geometric inference
    // fails (e.g., weird stacking, partial off-screen windows).
    private static func fallbackShape(for n: Int) -> (cols: Int, rows: Int) {
        switch n {
        case 0, 1: return (1, 1)
        case 2:    return (2, 1)
        case 3:    return (3, 1)
        case 4:    return (2, 2)
        case 5, 6: return (3, 2)
        case 7, 8: return (4, 2)
        case 9:    return (3, 3)
        default:
            let cols = Int(ceil(Double(n).squareRoot()))
            let rows = Int(ceil(Double(n) / Double(cols)))
            return (cols, rows)
        }
    }

    /// `tell application "Terminal"` LAUNCHES TERMINAL if it is not already open.
    ///
    /// That is what an Apple event addressed to an app by name does, and reading a property
    /// inside the block is enough to send one. Measured on a Mac where Terminal had never
    /// been opened: approving the Automation consent dialog opened Terminal.app and its
    /// window, from a background poll nobody asked for. The consent dialog itself is now
    /// held behind the feature gate in `TerminalFocusState.start()`, but that gate opens the
    /// moment somebody legitimately turns Terminal Focus on, and from then on every poll
    /// would still be able to start Terminal on a Mac that had it closed.
    ///
    /// So the decision is its own pure function and the query does not run unless Terminal
    /// is already up. Nothing is lost: with Terminal closed there are no windows to map, and
    /// the honest answer to "which Terminal windows exist" is none.
    static func shouldQueryTerminal(runningBundleIds: [String]) -> Bool {
        runningBundleIds.contains("com.apple.Terminal")
    }

    // Synchronous - only call from a background thread.
    // NOTE: "current tab of w" conflicts with the AppleScript "tab" class keyword.
    // Workaround: iterate tabs and check "selected of t".
    private static func fetchWindowTTYPairsViaOsascript() -> [(title: String, tty: String)] {
        guard shouldQueryTerminal(runningBundleIds:
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        else { return [] }
        let script = """
        tell application "Terminal"
            set outputStr to ""
            set NL to ASCII character 10
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if selected of t then
                            set outputStr to outputStr & (tty of t) & "|" & (name of w) & NL
                            exit repeat
                        end if
                    end repeat
                end try
            end repeat
            return outputStr
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        proc.waitUntilExit()

        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var pairs: [(title: String, tty: String)] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pipeRange = trimmed.range(of: "|") else { continue }
            let tty = String(trimmed[trimmed.startIndex..<pipeRange.lowerBound])
                .replacingOccurrences(of: "/dev/", with: "")
                .trimmingCharacters(in: .whitespaces)
            let title = String(trimmed[pipeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !tty.isEmpty else { continue }
            pairs.append((title: title, tty: tty))
        }
        return pairs
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
