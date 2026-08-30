import AppKit
import ApplicationServices
import Foundation

// File-private so nonisolated static funcs can read them without crossing
// the @MainActor boundary. Exposed via static computed properties below.
private let kScreenTimeSampleInterval: TimeInterval = 10
private let kScreenTimeIdleThreshold: TimeInterval = 60

// Polls frontmost app + active window title every 10s. Writes one NDJSON line
// per tick to ~/.grux/ambient/screentime-YYYY-MM-DD.ndjson. Idle samples
// (no HID activity for >= idleThresholdSeconds) are still written but flagged
// idle=true so per-app dwell can exclude them.
//
// Path: ~/.grux/ambient/ (matches the dev-tailable layout used by ~/.grux/focus
// and the fire-* triggers). Other durable ambient data lives under
// ~/Library/Application Support/Grux/, but screen-time NDJSON is intentionally
// surface-level so `tail -F ~/.grux/ambient/screentime-*.ndjson` works.
//
// Permissions: window title needs Accessibility. On first start() we trigger
// the system AX prompt via AXIsProcessTrustedWithOptions. Until the user toggles
// Grux on in Settings | Privacy | Accessibility, window_title stays empty and
// per-app dwell still works from NSWorkspace alone.
//
// Idle: reuses the CGEventSource.secondsSinceLastEventType pattern from
// StuckDetector. Zero permissions required for that path.
@MainActor
final class ScreenTimeWatcher {
    static let shared = ScreenTimeWatcher()

    static var sampleIntervalSeconds: TimeInterval { kScreenTimeSampleInterval }
    // Nonisolated mirror so off-main callers (e.g. WorkdayLogAssembler
    // running on the cooperative thread pool) can read the poll interval
    // without crossing actors. Update both if the poll rate changes.
    nonisolated static let kSampleIntervalSeconds: TimeInterval = 10
    static var idleThresholdSeconds: TimeInterval { kScreenTimeIdleThreshold }

    private let queue = DispatchQueue(label: "grux.screentime", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var didPromptForAX = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(
            at: Self.screentimeDir, withIntermediateDirectories: true)
        // System AX prompt is non-blocking and idempotent. Returns current
        // trust state, not the user's eventual choice.
        if !didPromptForAX {
            didPromptForAX = true
            _ = Self.requestAccessibilityPermission()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + 0.5,
            repeating: kScreenTimeSampleInterval,
            leeway: .seconds(1))
        t.setEventHandler { Self.tickSync() }
        t.resume()
        timer = t
        WakeLog.shared.log("screenTimeWatcher: started (10s tick)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // Force a single tick + summary dump. Used by the fire-screentime-test
    // trigger for on-demand verification.
    func fireTickNow() {
        queue.async { Self.tickSync() }
    }

    // MARK: - Tick (runs on utility queue, no main-actor state)

    nonisolated private static func tickSync() {
        let now = Date()
        guard let front = NSWorkspace.shared.frontmostApplication else {
            WakeLog.shared.log("screenTimeWatcher: no frontmost app")
            return
        }
        let bundleID = front.bundleIdentifier ?? ""
        let appName = front.localizedName ?? ""
        let windowTitle = activeWindowTitle(pid: front.processIdentifier) ?? ""
        let idleSecs = systemIdleSeconds()
        let isIdle = idleSecs >= kScreenTimeIdleThreshold

        let iso = ISO8601DateFormatter()
        let event: [String: Any] = [
            "ts": iso.string(from: now),
            "app_bundle": bundleID,
            "app_name": appName,
            "window_title": windowTitle,
            "idle": isIdle,
            "idle_seconds": Int(idleSecs.rounded())
        ]
        appendEvent(event, at: now)
    }

    // MARK: - Window title via Accessibility

    nonisolated private static func activeWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focusedRaw: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focusedRaw)
        guard r1 == .success, let focused = focusedRaw else { return nil }
        let window = focused as! AXUIElement
        var titleRaw: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRaw)
        guard r2 == .success, let title = titleRaw as? String, !title.isEmpty
        else { return nil }
        return title
    }

    nonisolated private static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: [String: Any] = [key: true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    // MARK: - Idle (mirrors StuckDetector.systemIdleSeconds)

    nonisolated private static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]
        let values = types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        return values.min() ?? 0
    }

    // MARK: - NDJSON layout

    nonisolated static var screentimeDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
    }

    nonisolated static func screentimeURL(forDate date: Date) -> URL {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return screentimeDir.appendingPathComponent(
            "screentime-\(f.string(from: date)).ndjson")
    }

    nonisolated private static func appendEvent(
        _ obj: [String: Any], at date: Date
    ) {
        let url = screentimeURL(forDate: date)
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
                        "screenTimeWatcher: append failed \(error)")
                }
            }
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Replay + analysis

struct ScreenTimeEvent: Codable, Equatable {
    let ts: Date
    let appBundle: String
    let appName: String
    let windowTitle: String
    let idle: Bool
    let idleSeconds: Int

    enum CodingKeys: String, CodingKey {
        case ts
        case appBundle = "app_bundle"
        case appName = "app_name"
        case windowTitle = "window_title"
        case idle
        case idleSeconds = "idle_seconds"
    }
}

extension ScreenTimeWatcher {
    // Load every event in [start, end). Reads all daily NDJSON files that
    // overlap the range (capped at 7 days for safety).
    nonisolated static func loadEvents(
        between start: Date, and end: Date
    ) -> [ScreenTimeEvent] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var urls: [URL] = []
        var d = startDay
        var safety = 0
        while d <= endDay && safety < 7 {
            urls.append(screentimeURL(forDate: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? endDay.addingTimeInterval(86400)
            safety += 1
        }
        let iso = ISO8601DateFormatter()
        var out: [ScreenTimeEvent] = []
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
                out.append(ScreenTimeEvent(
                    ts: ts,
                    appBundle: (obj["app_bundle"] as? String) ?? "",
                    appName: (obj["app_name"] as? String) ?? "",
                    windowTitle: (obj["window_title"] as? String) ?? "",
                    idle: (obj["idle"] as? Bool) ?? false,
                    idleSeconds: (obj["idle_seconds"] as? Int) ?? 0
                ))
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }

    // Per-app dwell in [start, end). Idle samples excluded. Each event counts
    // for sampleIntervalSeconds (10s default). Returns apps sorted by seconds
    // desc.
    nonisolated static func perAppDwell(
        between start: Date, and end: Date
    ) -> [(app: String, seconds: Int)] {
        let events = loadEvents(between: start, and: end)
        var totals: [String: Double] = [:]
        for ev in events where !ev.idle {
            let key = ev.appName.isEmpty ? ev.appBundle : ev.appName
            guard !key.isEmpty else { continue }
            totals[key, default: 0] += kScreenTimeSampleInterval
        }
        return totals
            .map { (app: $0.key, seconds: Int($0.value.rounded())) }
            .sorted { $0.seconds > $1.seconds }
    }
}
