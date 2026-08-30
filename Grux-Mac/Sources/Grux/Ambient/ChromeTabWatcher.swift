import AppKit
import Foundation

private let kChromeTabSampleInterval: TimeInterval = ChromeTabWatcher.kSampleIntervalSeconds
private let kChromeBundleID = "com.google.Chrome"

// Polls Chrome's frontmost-window active tab every 15s, but ONLY while Chrome
// is the frontmost app. Writes one NDJSON line per tick to
// ~/.grux/ambient/chrome-tabs-YYYY-MM-DD.ndjson with {ts, url, title, domain}.
//
// Pairs with ScreenTimeWatcher: that one tells you Chrome was foregrounded
// for N seconds, this one tells you WHICH tab. BrandAttribution maps the
// domain back to one of the user's brands later.
//
// Permissions: NSAppleScript dispatch to Chrome triggers the OS Apple Events
// (Automation) TCC prompt the first time. NSAppleEventsUsageDescription is
// set in Info.plist; the entitlement is enabled in Grux.entitlements. Until
// The user grants Automation > Google Chrome to Grux in System Settings, every
// tick will fail silently (we log once and keep going).
//
// Frontmost gate: we query NSWorkspace.shared.frontmostApplication directly
// per tick (same pattern ScreenTimeWatcher uses internally) instead of
// reading cached state from ScreenTimeWatcher - avoids cross-actor reads and
// keeps each watcher independent.
@MainActor
final class ChromeTabWatcher {
    static let shared = ChromeTabWatcher()

    static var sampleIntervalSeconds: TimeInterval { kChromeTabSampleInterval }
    // Nonisolated mirror so off-main callers (e.g. BrandAttribution running on
    // a detached utility task) can read the poll interval without crossing
    // actors. Update both if the poll rate changes.
    nonisolated static let kSampleIntervalSeconds: TimeInterval = 15

    private let queue = DispatchQueue(label: "grux.chrometabs", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(
            at: Self.chromeTabsDir, withIntermediateDirectories: true)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + 1.0,
            repeating: kChromeTabSampleInterval,
            leeway: .seconds(2))
        t.setEventHandler { Self.tickSync() }
        t.resume()
        timer = t
        WakeLog.shared.log("chromeTabWatcher: started (15s tick)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func fireTickNow() {
        queue.async { Self.tickSync() }
    }

    // MARK: - Tick (utility queue)

    nonisolated private static func tickSync() {
        guard chromeIsFrontmost() else { return }
        guard let snapshot = readActiveTab() else { return }
        guard !snapshot.url.isEmpty else { return }

        let now = Date()
        let iso = ISO8601DateFormatter()
        let event: [String: Any] = [
            "ts": iso.string(from: now),
            "url": snapshot.url,
            "title": snapshot.title,
            "domain": domain(from: snapshot.url)
        ]
        appendEvent(event, at: now)
    }

    nonisolated private static func chromeIsFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return front.bundleIdentifier == kChromeBundleID
    }

    // MARK: - AppleScript bridge

    private struct TabSnapshot {
        let url: String
        let title: String
    }

    nonisolated private static func readActiveTab() -> TabSnapshot? {
        let source = """
        tell application id "com.google.Chrome"
            if (count of windows) is 0 then return ""
            set theTab to active tab of front window
            return ((URL of theTab) as text) & "\n" & ((title of theTab) as text)
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            logScriptErrorOnce(error)
            return nil
        }
        guard let raw = result.stringValue, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let url = parts.indices.contains(0) ? String(parts[0]) : ""
        let title = parts.indices.contains(1) ? String(parts[1]) : ""
        return TabSnapshot(
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // Apple Events errors repeat on every tick under steady-state failures
    // (TCC denial -1743, Chrome unresponsive -1712, etc). Log each error code
    // once so a permission denial doesn't drown the log, but a different
    // failure later in the day still surfaces. Per-code rather than global
    // one-shot so granting permission after a denial logs the recovery, and
    // a new failure mode isn't silently swallowed.
    nonisolated private static let scriptErrorFlag = NSLock()
    nonisolated(unsafe) private static var loggedScriptErrorCodes: Set<Int> = []
    nonisolated private static func logScriptErrorOnce(_ error: NSDictionary) {
        let code = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
        scriptErrorFlag.lock()
        defer { scriptErrorFlag.unlock() }
        guard loggedScriptErrorCodes.insert(code).inserted else { return }
        let msg = (error["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
        WakeLog.shared.log(
            "chromeTabWatcher: AppleScript error code=\(code) msg=\(msg)")
    }

    // MARK: - Domain extraction

    nonisolated static func domain(from url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host
        else { return "" }
        // Strip a leading "www." so example.com and www.example.com group.
        if host.hasPrefix("www.") { return String(host.dropFirst(4)) }
        return host
    }

    // MARK: - NDJSON layout

    nonisolated static var chromeTabsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
    }

    nonisolated static func chromeTabsURL(forDate date: Date) -> URL {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return chromeTabsDir.appendingPathComponent(
            "chrome-tabs-\(f.string(from: date)).ndjson")
    }

    nonisolated private static func appendEvent(
        _ obj: [String: Any], at date: Date
    ) {
        let url = chromeTabsURL(forDate: date)
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: json, encoding: .utf8)
        else { return }
        let payload = (str + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                do {
                    try h.seekToEnd()
                    try h.write(contentsOf: payload)
                } catch {
                    WakeLog.shared.log(
                        "chromeTabWatcher: append failed \(error)")
                }
            }
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Replay + analysis

struct ChromeTabEvent: Codable, Equatable {
    let ts: Date
    let url: String
    let title: String
    let domain: String
}

extension ChromeTabWatcher {
    // Every event in [start, end). Walks daily NDJSON files that overlap the
    // range (capped at 7 days).
    nonisolated static func loadEvents(
        between start: Date, and end: Date
    ) -> [ChromeTabEvent] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var urls: [URL] = []
        var d = startDay
        var safety = 0
        while d <= endDay && safety < 7 {
            urls.append(chromeTabsURL(forDate: d))
            d = cal.date(byAdding: .day, value: 1, to: d)
                ?? endDay.addingTimeInterval(86400)
            safety += 1
        }
        let iso = ISO8601DateFormatter()
        var out: [ChromeTabEvent] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            for raw in text.split(separator: "\n") {
                guard let lineData = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let tsStr = obj["ts"] as? String,
                      let ts = iso.date(from: tsStr)
                else { continue }
                guard ts >= start && ts < end else { continue }
                out.append(ChromeTabEvent(
                    ts: ts,
                    url: (obj["url"] as? String) ?? "",
                    title: (obj["title"] as? String) ?? "",
                    domain: (obj["domain"] as? String) ?? ""
                ))
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }

    // Per-domain dwell in [start, end). Each event counts for
    // sampleIntervalSeconds (15s default). Returns domains sorted by seconds
    // desc. Mirrors ScreenTimeWatcher.perAppDwell for the brand-attribution
    // layer.
    nonisolated static func perDomainDwell(
        between start: Date, and end: Date
    ) -> [(domain: String, seconds: Int)] {
        let events = loadEvents(between: start, and: end)
        var totals: [String: Double] = [:]
        for ev in events {
            let key = ev.domain
            guard !key.isEmpty else { continue }
            totals[key, default: 0] += kChromeTabSampleInterval
        }
        return totals
            .map { (domain: $0.key, seconds: Int($0.value.rounded())) }
            .sorted { $0.seconds > $1.seconds }
    }
}
