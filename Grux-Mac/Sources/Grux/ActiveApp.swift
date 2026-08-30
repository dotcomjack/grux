import AppKit
import ApplicationServices

struct ActiveAppInfo {
    let name: String
    let bundleId: String
    let windowTitle: String
}

enum ActiveApp {
    static func current() -> ActiveAppInfo {
        let ws = NSWorkspace.shared
        let app = ws.frontmostApplication
        let name = app?.localizedName ?? "Unknown"
        let bundle = app?.bundleIdentifier ?? ""
        let title = frontWindowTitle(pid: app?.processIdentifier) ?? ""
        return ActiveAppInfo(name: name, bundleId: bundle, windowTitle: title)
    }

    private static func frontWindowTitle(pid: pid_t?) -> String? {
        guard let pid else { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        let axWindow = window as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
    }
}
