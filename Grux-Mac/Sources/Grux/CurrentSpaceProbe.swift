import AppKit
import CoreGraphics
import Foundation

// CGWindowList-backed probe for "what windows are on the macOS Space I'm on
// RIGHT NOW". macOS has no public API to enumerate Spaces by ID, but
// `.optionOnScreenOnly` (+ filtering layer == 0 to drop menu bar / Dock
// helpers) yields exactly the windows currently visible on the active
// Space, which is what a workspace-arranging macro needs to stay scoped to.

struct CurrentSpaceWindow {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String        // e.g. "Terminal", "Google Chrome"
    let title: String
    let bounds: CGRect
}

@MainActor
enum CurrentSpaceProbe {
    static func windows() -> [CurrentSpaceWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { d -> CurrentSpaceWindow? in
            guard (d[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            guard let id = d[kCGWindowNumber as String] as? CGWindowID else { return nil }
            guard let pid = d[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            let title = d[kCGWindowName as String] as? String ?? ""
            let boundsDict = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            // Ignore zero-size ghost windows (popovers, etc).
            guard bounds.width > 10, bounds.height > 10 else { return nil }
            return CurrentSpaceWindow(id: id, pid: pid, ownerName: owner, title: title, bounds: bounds)
        }
    }

    static func terminalWindows() -> [CurrentSpaceWindow] {
        windows().filter { $0.ownerName == "Terminal" }
    }

    // PIDs of apps that have at least one regular window on the current Space.
    // Used so `prepareCleanWorkspace` only hides apps the user can actually see
    // - apps parked on other Spaces stay visible when they switch back to them.
    static func pidsOnCurrentSpace() -> Set<pid_t> {
        Set(windows().map(\.pid))
    }
}
