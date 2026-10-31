import AppKit
import Foundation

// Chrome automation for Grux's voice/chat tools.
//
// Design: reuse the frontmost Chrome window. NEVER spawn a fresh window
// unless there's literally zero Chrome windows open, so the user's session,
// tabs, and logged-in state stay intact.
//
// Transport: ForeignAppScript.run, off the main actor and bounded, so a
// pending Automation prompt never freezes Grux (D13). The entitlement
// `com.apple.security.automation.apple-events` + Info.plist's
// NSAppleEventsUsageDescription are already present; macOS prompts once
// for cross-app AppleEvents, then remembers the grant.

@MainActor
enum BrowserTool {
    private static let chromeBundleId = "com.google.Chrome"

    static func openURL(_ url: String) async -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "error: empty url" }
        guard let normalized = normalizeURL(trimmed) else {
            return "error: doesn't look like a URL: \(trimmed)"
        }
        // Item 31: URL guard, block credential URLs and private-network
        // targets before any Chrome open.
        if case .denied(let reason) = URLGuard.check(normalized, purpose: "open_url") {
            return "error: URL blocked by Grux URL guard (\(reason)). You can add the host in Settings, Data & Security, Security if you meant to open it."
        }
        return await runChromeScript(openTab: normalized, purpose: "openURL")
    }

    static func searchWeb(_ query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "error: empty query" }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let url = "https://www.google.com/search?q=\(encoded)"
        return await runChromeScript(openTab: url, purpose: "searchWeb", successMessage: "ok: searched Google for '\(q)'")
    }

    static func playOnYouTube(_ query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "error: empty query" }
        // Asking for a video is asking for sound, so silent mode refuses it like music.
        guard AudioOutput.permit(.video, source: "BrowserTool.playOnYouTube", text: q) else {
            return "error: silent mode is on (~/.grux/SILENT), so Grux will not play '\(q)'"
        }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        // sp=EgIQAQ filters to videos only - gets you to a clickable video
        // list without Shorts/playlists clutter.
        let url = "https://www.youtube.com/results?search_query=\(encoded)&sp=EgIQAQ"
        return await runChromeScript(openTab: url, purpose: "playOnYouTube", successMessage: "ok: YouTube search loaded for '\(q)' - click the top result to play")
    }

    // MARK: - AppleScript transport

    private static func runChromeScript(openTab url: String, purpose: String, successMessage: String? = nil) async -> String {
        if let why = ForeignAppScript.refuse("BrowserTool.\(purpose)") { return "error: \(why)" }
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
        let outcome = await ForeignAppScript.run(source, purpose: "BrowserTool.\(purpose)")
        switch outcome {
        case .ok:
            break
        case .failed(let code, _) where code == -1743:
            // errAEEventNotPermitted: the person denied Automation permission.
            return "error: macOS blocked Grux from controlling Chrome. Grant it in System Settings → Privacy & Security → Automation → Grux → Google Chrome."
        case .failed(let code, let message):
            return "error: Chrome scripting failed (\(code.map(String.init) ?? "?")): \(message)"
        case .refused, .timedOut, .busy, .stopped, .behindLongerScript:
            return "error: Chrome: \(outcome.problem ?? "no answer")"
        }
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
