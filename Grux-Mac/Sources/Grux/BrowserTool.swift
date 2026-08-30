import AppKit
import Foundation

// Chrome automation for Grux's voice/chat tools.
//
// Design: reuse the frontmost Chrome window. NEVER spawn a fresh window
// unless there's literally zero Chrome windows open, so the user's session,
// tabs, and logged-in state stay intact.
//
// Transport: NSAppleScript. The entitlement
// `com.apple.security.automation.apple-events` + Info.plist's
// NSAppleEventsUsageDescription are already present; macOS prompts once
// for cross-app AppleEvents, then remembers the grant.

@MainActor
enum BrowserTool {
    private static let chromeBundleId = "com.google.Chrome"

    static func openURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "error: empty url" }
        guard let normalized = normalizeURL(trimmed) else {
            return "error: doesn't look like a URL: \(trimmed)"
        }
        // Item 31: URL guard, block credential URLs and private-network
        // targets before any Chrome open.
        if case .denied(let reason) = URLGuard.check(normalized, purpose: "open_url") {
            return "error: URL blocked by Grux URL guard (\(reason)). You can add the host under Settings, Security if intended."
        }
        return runChromeScript(openTab: normalized)
    }

    static func searchWeb(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "error: empty query" }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let url = "https://www.google.com/search?q=\(encoded)"
        return runChromeScript(openTab: url, successMessage: "ok: searched Google for '\(q)'")
    }

    static func playOnYouTube(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "error: empty query" }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        // sp=EgIQAQ filters to videos only - gets you to a clickable video
        // list without Shorts/playlists clutter.
        let url = "https://www.youtube.com/results?search_query=\(encoded)&sp=EgIQAQ"
        return runChromeScript(openTab: url, successMessage: "ok: YouTube search loaded for '\(q)' - click the top result to play")
    }

    // MARK: - AppleScript transport

    private static func runChromeScript(openTab url: String, successMessage: String? = nil) -> String {
        // AppleScript-safe URL escape: replace " and \ with \" and \\.
        let escaped = url
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Google Chrome"
            activate
            if (count of windows) = 0 then
                make new window
                set URL of active tab of front window to "\(escaped)"
            else
                tell front window
                    make new tab with properties {URL:"\(escaped)"}
                end tell
            end if
            return "ok"
        end tell
        """
        var err: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&err)
        if let err = err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
            let num = (err[NSAppleScript.errorNumber] as? Int).map { String($0) } ?? "?"
            // errAEEventNotPermitted (-1743) → user denied Automation permission
            if num == "-1743" {
                return "error: macOS blocked Grux from controlling Chrome. Grant it in System Settings → Privacy & Security → Automation → Grux → Google Chrome."
            }
            return "error: Chrome scripting failed (\(num)): \(msg)"
        }
        guard result != nil else { return "error: Chrome returned no result" }
        return successMessage ?? "ok: opened \(url) in Chrome"
    }

    // Accepts "google.com", "https://x.com/foo", "example.com/path", and
    // prepends https:// if missing. Rejects obvious non-URLs.
    private static func normalizeURL(_ raw: String) -> String? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        // Heuristic: something containing a dot with no spaces, plausibly a host.
        guard raw.contains("."), !raw.contains(" ") else { return nil }
        return "https://\(raw)"
    }
}
