import AppKit
import Foundation

// One unread message as read out of the open webmail tab (or a fixture).
struct InboxMessage: Codable {
    var fromName: String
    var fromEmail: String
    var subject: String
    var preview: String          // list-row preview text (not the full body)
    var messageId: String        // usually "" from webmail scraping
    // Full message body INCLUDING the quoted thread history, when available
    // (Graph supplies it; tab scraping does not). Optional so old fixtures still
    // decode. The drafter uses this to stay thread-aware instead of re-asking.
    var body: String? = nil
    // Bulk / automated signals parsed from the message's internet headers
    // (Graph supplies them; tab scraping leaves both false and the reply-policy
    // gate degrades to sender-address detection). Defaulted so old fixtures and
    // persisted JSON decode unchanged.
    var isBulk: Bool = false          // List-Unsubscribe present or Precedence: bulk
    var isAutoSubmitted: Bool = false // Auto-Submitted header other than "no"
}

// Reads unread support mail out of an Outlook web tab left open in
// Chrome. This is the realistic in-app substitute for the spec's
// "claude-in-chrome MCP": Grux is a Swift app and has no MCP client, but it
// already drives Chrome via NSAppleScript (see ChromeTabWatcher + BrowserTool).
// We extend that pattern with Chrome's `execute ... javascript` to pull the
// visible message list out of OWA's DOM.
//
// QUIRKS (documented in the catalog too):
//  1. Chrome blocks Apple-Events JavaScript by default. The user must enable
//     "Allow JavaScript from Apple Events" once under Chrome > View >
//     Developer. Until then execute-javascript returns an error and we fall
//     back to the fixture (or empty).
//  2. OWA is a heavy SPA with obfuscated, churning class names. We read
//     role="option" rows and their aria-labels, which are the most stable
//     handles, but Microsoft can change them. We only get the LIST PREVIEW,
//     not the full message body. The classifier + drafter work off the
//     preview, which is enough for a first-pass reply the user edits before send.
//  3. Every configured inbox lives on outlook.office.com, indistinguishable
//     by host; the caller picks which inbox/brand a run targets.
//
// Fixture path: pass a JSON file ([InboxMessage]) to read deterministically.
// Used by the smoke test so end-to-end verification never depends on a live
// logged-in Outlook tab.
@MainActor
enum OutlookReader {
    private static let chromeBundleID = "com.google.Chrome"

    // Reads up to `limit` unread messages for the given inbox. Tries the live
    // Chrome tab first; if `fixturePath` is non-nil it is used instead (and
    // takes precedence, for deterministic tests).
    static func readUnread(inbox: SupportInbox, fixturePath: String?, limit: Int = 12) -> [InboxMessage] {
        if let fixturePath, !fixturePath.isEmpty {
            return readFixture(fixturePath)
        }
        return readLiveTab(inbox: inbox, limit: limit)
    }

    // MARK: - Fixture

    static func readFixture(_ path: String) -> [InboxMessage] {
        guard let data = FileManager.default.contents(atPath: path) else {
            WakeLog.shared.log("outlookReader: fixture not found at \(path)")
            return []
        }
        if let msgs = try? JSONDecoder().decode([InboxMessage].self, from: data) {
            return msgs
        }
        WakeLog.shared.log("outlookReader: fixture at \(path) did not decode as [InboxMessage]")
        return []
    }

    // MARK: - Live Chrome tab

    private static func readLiveTab(inbox: SupportInbox, limit: Int) -> [InboxMessage] {
        guard let tabRef = findWebmailTab(hints: inbox.webmailHostHints) else {
            WakeLog.shared.log("outlookReader: no open Outlook tab found for \(inbox.rawValue)")
            return []
        }
        // OWA list extraction. role="option" rows carry the sender/subject/
        // preview in their aria-label or innerText. We return a JSON string the
        // Swift side decodes. Capped to `limit` rows.
        let js = """
        (function(){
          try {
            var rows = document.querySelectorAll('div[role="option"], div[role="listbox"] div[role="option"]');
            var out = [];
            for (var i = 0; i < rows.length && out.length < \(limit); i++) {
              var el = rows[i];
              var aria = el.getAttribute('aria-label') || '';
              var text = (el.innerText || '').replace(/\\s+/g, ' ').trim();
              var unread = !!(el.querySelector('[aria-label*="Unread"]')) || /unread/i.test(aria);
              var senderEl = el.querySelector('span[title*="@"]');
              var email = senderEl ? (senderEl.getAttribute('title') || '') : '';
              var sender = senderEl ? (senderEl.innerText || '').trim() : '';
              out.push({ aria: aria, text: text, unread: unread, email: email, sender: sender });
            }
            return JSON.stringify(out);
          } catch (e) { return 'ERR:' + e.message; }
        })();
        """
        let raw = executeJavaScript(js, inTabIndex: tabRef.tabIndex, windowIndex: tabRef.windowIndex)
        guard let raw, !raw.isEmpty else {
            WakeLog.shared.log("outlookReader: execute-javascript returned empty (is 'Allow JavaScript from Apple Events' enabled in Chrome?)")
            return []
        }
        if raw.hasPrefix("ERR:") {
            WakeLog.shared.log("outlookReader: page JS error \(raw.prefix(120))")
            return []
        }
        return parseRows(raw)
    }

    private struct TabRef { let windowIndex: Int; let tabIndex: Int }

    // Walks every Chrome window/tab and returns the first whose URL matches a
    // webmail host hint. 1-based indices (AppleScript convention).
    private static func findWebmailTab(hints: [String]) -> TabRef? {
        guard let urls = allTabURLs() else { return nil }
        for (wi, tabs) in urls.enumerated() {
            for (ti, url) in tabs.enumerated() {
                let lower = url.lowercased()
                if hints.contains(where: { lower.contains($0) }) {
                    return TabRef(windowIndex: wi + 1, tabIndex: ti + 1)
                }
            }
        }
        return nil
    }

    // Returns URLs as [window][tab]. Uses unlikely multi-char delimiters so we
    // can split reliably even when URLs contain commas or newlines (and so the
    // AppleScript source stays free of literal control characters).
    private static let winSep = "<<GRUXWIN>>"
    private static let tabSep = "<<GRUXTAB>>"
    private static func allTabURLs() -> [[String]]? {
        let source = """
        tell application id "com.google.Chrome"
            set output to ""
            set winCount to count of windows
            repeat with w from 1 to winCount
                if w > 1 then set output to output & "\(winSep)"
                set tabUrls to URL of every tab of window w
                set AppleScript's text item delimiters to "\(tabSep)"
                set output to output & (tabUrls as text)
                set AppleScript's text item delimiters to ""
            end repeat
            return output
        end tell
        """
        guard let raw = runAppleScript(source) else { return nil }
        if raw.isEmpty { return [] }
        let windows = raw.components(separatedBy: winSep)
        // Filter empties so a zero-tab window yields [] (not [""]) and the
        // enumerated (window, tab) indices stay aligned with AppleScript's
        // 1-based addressing.
        return windows.map { $0.components(separatedBy: tabSep).filter { !$0.isEmpty } }
    }

    private static func executeJavaScript(_ js: String, inTabIndex tab: Int, windowIndex win: Int) -> String? {
        // Backslash MUST be escaped first. Then quotes. Then collapse every line
        // ending (\r\n, \r, \n) to a space so no raw control char lands inside
        // the AppleScript string literal. (The JS here is statement-terminated,
        // so collapsing newlines is safe; avoid // line comments in this JS.)
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let source = """
        tell application id "com.google.Chrome"
            return (execute tab \(tab) of window \(win) javascript "\(escaped)") as text
        end tell
        """
        return runAppleScript(source)
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
            WakeLog.shared.log("outlookReader: AppleScript error \(msg)")
            return nil
        }
        return result.stringValue
    }

    // Parses the OWA aria/text rows into InboxMessage. aria-labels in OWA tend
    // to read like "From Jane Doe, subject Where is my order, preview ...,
    // received ...". We split heuristically and keep the preview generous.
    private static func parseRows(_ json: String) -> [InboxMessage] {
        guard
            let data = json.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var out: [InboxMessage] = []
        for row in arr {
            let unread = (row["unread"] as? Bool) ?? false
            guard unread else { continue }
            let aria = (row["aria"] as? String) ?? ""
            let text = (row["text"] as? String) ?? ""
            let basis = aria.isEmpty ? text : aria
            // The sender email + display name now come straight from the row's
            // span[title="..@.."] (OWA puts the address there even when the
            // aria-label does not). This is what unblocks the unattended sweep:
            // without a sender address the triage skipped every live message.
            let domEmail = (row["email"] as? String) ?? ""
            let domSender = (row["sender"] as? String) ?? ""

            let email = extractEmail(from: domEmail) ?? extractEmail(from: basis) ?? ""
            let fallback = splitSenderSubject(basis)
            let name = domSender.isEmpty ? fallback.name : domSender
            let subject = subjectFromAria(basis, sender: name, fallback: fallback.subject)
            out.append(InboxMessage(
                fromName: name,
                fromEmail: email,
                subject: subject,
                preview: text.isEmpty ? aria : text,
                messageId: ""
            ))
        }
        return out
    }

    // OWA list aria reads "[Unread] <sender> <subject> <h:mm AM/PM> <preview...>".
    // With the DOM sender name in hand we strip the read-state + sender, then cut
    // at the first time token, which leaves the subject. Falls back to the older
    // comma-heuristic result when the shape does not match.
    nonisolated static func subjectFromAria(_ aria: String, sender: String, fallback: String) -> String {
        var s = aria
        for p in ["Unread ", "Read ", "Flagged "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if !sender.isEmpty, let r = s.range(of: sender) { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: .whitespaces)
        // Cut at the received-time token, including an optional leading weekday
        // ("Mon 4:31 PM") or date ("6/17/2026 9:32 AM") that OWA prepends.
        if let tr = s.range(of: #"\b((Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+)?(\d{1,2}/\d{1,2}/\d{2,4}\s+)?\d{1,2}:\d{2}\s?(AM|PM)"#, options: .regularExpression) {
            s = String(s[..<tr.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.count < 2 { return fallback }
        return String(s.prefix(120))
    }

    private static func splitSenderSubject(_ s: String) -> (name: String, subject: String) {
        // Very forgiving: first comma-delimited token is usually the sender,
        // the chunk after "subject" (if present) is the subject. Falls back to
        // the leading line.
        let lower = s.lowercased()
        var name = ""
        var subject = ""
        let parts = s.components(separatedBy: ",")
        if let first = parts.first { name = first.replacingOccurrences(of: "From ", with: "").trimmingCharacters(in: .whitespaces) }
        if let r = lower.range(of: "subject ") {
            let after = String(s[r.upperBound...])
            subject = after.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? after
        } else if parts.count > 1 {
            subject = parts[1].trimmingCharacters(in: .whitespaces)
        }
        if subject.isEmpty { subject = "(no subject)" }
        return (name.isEmpty ? "Customer" : name, subject)
    }

    private static func extractEmail(from s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
}
