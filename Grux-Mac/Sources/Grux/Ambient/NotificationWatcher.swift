import AppKit
import Foundation

// Polls macOS NotificationCenter's SQLite store for the delivered-notification
// stream so the daily recap can answer "how many times did you get yanked out
// of flow today, and by which apps?" One NDJSON line per delivered notification
// at ~/.grux/ambient/notifications-YYYY-MM-DD.ndjson, mirroring the layout used
// by ScreenTimeWatcher / ChromeTabWatcher so `tail -F` works for diagnostics.
//
// Data source. The real path is `~/Library/Group Containers/group.com.apple.usernoted/db2/db`,
// NOT the `~/Library/Application Support/NotificationCenter/...` path the
// original spec listed (that location does not exist on Sonoma / Sequoia). The
// db is owned by `notificationd`; we read it as the user. Sandbox is OFF for
// Grux (see Grux.entitlements + SECURITY.md), so reads succeed without a Full
// Disk Access prompt as long as the app runs as the logged-in user.
//
// Liveness markers. We persist the last `delivered_date` we forwarded to
// `~/Library/Application Support/Grux/notif-watcher-state.json`. On first ever
// launch we initialize the marker to "now" so we do not flood the user with the
// historical backlog the OS has been retaining.
//
// Concurrency. notificationd writes the db on its own queue, so reads can race
// with a checkpoint. We open the db in read-only mode and accept the rare
// SQLITE_BUSY by treating the tick as a no-op (next tick will catch up).
//
// Pure helpers. `loadEvents`, `interruptCount`, and `perAppInterrupts` are all
// nonisolated so WorkdayLogAssembler (off-main pool) and AmbientHourlySummarizer
// (main actor) can both call them without bouncing actors.
@MainActor
final class NotificationWatcher {
    static let shared = NotificationWatcher()

    nonisolated static let kPollIntervalSeconds: TimeInterval = 60
    // Mac Absolute Time epoch: 2001-01-01 00:00:00 UTC. Foundation's
    // timeIntervalSinceReferenceDate is identical, so the two convert 1:1.
    nonisolated static let macAbsoluteEpoch = Date(timeIntervalSinceReferenceDate: 0)

    private let queue = DispatchQueue(label: "grux.notifwatcher", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    // Read access to the notificationd db requires Full Disk Access. Without
    // FDA the subprocess returns "authorization denied" every tick; we keep
    // a single in-process flag so we log + write the instructions file ONCE
    // per launch instead of spamming wake.log every minute. Reset on next
    // launch in case the user has granted FDA in between.
    nonisolated(unsafe) private static var didReportFDADenied = false
    nonisolated private static let fdaDeniedLock = NSLock()

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(
            at: Self.notifDir, withIntermediateDirectories: true)
        // Initialize the marker file the first time so the first tick after
        // install does not dump a week of old notifications into today's NDJSON.
        Self.ensureStateInitialized()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + 5.0,
            repeating: Self.kPollIntervalSeconds,
            leeway: .seconds(5))
        t.setEventHandler { Self.tickSync() }
        t.resume()
        timer = t
        WakeLog.shared.log("notificationWatcher: started (60s tick)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // Force one immediate poll. Used by fire-notif-storm-test for E2E
    // verification without waiting up to a minute for the next natural tick.
    func fireTickNow() {
        queue.async { Self.tickSync() }
    }

    // MARK: - Tick (off-main, no shared actor state)

    nonisolated private static func tickSync() {
        let dbURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            // notificationd db gone (TCC reset, fresh user, OS upgrade in
            // progress). Skip quietly.
            return
        }
        let marker = loadMarker()
        let rows = querySinceMarker(dbPath: dbURL.path, markerMacAbs: marker)
        guard !rows.isEmpty else { return }
        let nameCache = AppNameCache()
        for row in rows {
            let appName = nameCache.displayName(forBundleID: row.bundleID)
            let event: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: row.deliveredAt),
                "app_bundle": row.bundleID,
                "app_name": appName
            ]
            appendEvent(event, at: row.deliveredAt)
        }
        // Advance the marker to the newest row we saw. querySinceMarker
        // returns rows sorted asc by delivered_date, so .last is the max.
        if let newest = rows.last?.deliveredMacAbs {
            saveMarker(newest)
        }
        WakeLog.shared.log("notificationWatcher: wrote \(rows.count) notification(s)")
    }

    // MARK: - SQLite via /usr/bin/sqlite3 (no third-party dep needed)
    //
    // The notification db is small and we poll once a minute, so the
    // subprocess overhead is negligible. Avoids pulling SQLite3 module
    // bindings into the build just for this one read path.

    private struct NotifRow {
        let bundleID: String
        let deliveredMacAbs: Double
        let deliveredAt: Date
    }

    nonisolated private static func querySinceMarker(
        dbPath: String, markerMacAbs: Double
    ) -> [NotifRow] {
        // Read-only URI form so we never lock the db against notificationd.
        let uri = "file:\(dbPath)?mode=ro&immutable=0"
        // Pipe-separated for trivial parsing. NULL delivered_date rows
        // (still-pending requests) are filtered by the WHERE clause.
        let sql = """
        SELECT a.identifier, r.delivered_date
        FROM record r JOIN app a USING(app_id)
        WHERE r.delivered_date IS NOT NULL AND r.delivered_date > \(markerMacAbs)
        ORDER BY r.delivered_date ASC;
        """
        let proc = Process()
        proc.launchPath = "/usr/bin/sqlite3"
        proc.arguments = ["-readonly", "-batch", uri, sql]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            WakeLog.shared.log("notificationWatcher: sqlite3 launch failed \(error)")
            return []
        }
        // Drain stdout (and immediately after, stderr) BEFORE waitUntilExit.
        // sqlite3 can stall on a full kernel pipe buffer (~64 KB) if neither
        // side is read until the child exits, deadlocking the watcher tick.
        // A large historical backlog after a long marker gap is the realistic
        // trigger; reading both ends drained first defuses that.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            // TCC's "authorization denied" means Grux hasn't been added to
            // Full Disk Access. Surface the fix path once per launch, then
            // stay quiet so we don't spam wake.log every 60s.
            if err.contains("authorization denied") {
                reportFDADenied()
            } else {
                // SQLITE_BUSY (5) etc. is rare; log it and keep ticking.
                WakeLog.shared.log("notificationWatcher: sqlite3 exit=\(proc.terminationStatus) err=\(err.prefix(200))")
            }
            return []
        }
        guard let text = String(data: outData, encoding: .utf8) else { return [] }
        var rows: [NotifRow] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let bundleID = String(parts[0])
            guard let macAbs = Double(parts[1]) else { continue }
            let date = Date(timeIntervalSinceReferenceDate: macAbs)
            rows.append(NotifRow(
                bundleID: bundleID,
                deliveredMacAbs: macAbs,
                deliveredAt: date))
        }
        return rows
    }

    // True when the most recent poll attempt was denied by TCC. The smoke-test
    // trigger reads this so the result file can call out the missing FDA grant
    // instead of silently reporting zero interrupts.
    nonisolated static func isFDADenied() -> Bool {
        fdaDeniedLock.lock()
        defer { fdaDeniedLock.unlock() }
        return didReportFDADenied
    }

    nonisolated private static func reportFDADenied() {
        fdaDeniedLock.lock()
        let first = !didReportFDADenied
        didReportFDADenied = true
        fdaDeniedLock.unlock()
        guard first else { return }
        let path = NSHomeDirectory() + "/.grux/notif-storm-fda-required.txt"
        let body = """
        NotificationWatcher needs Full Disk Access.

        macOS protects ~/Library/Group Containers/group.com.apple.usernoted/db2/db
        behind TCC's Full Disk Access. Until Grux.app is added there the watcher
        returns 0 interrupts on every poll.

        One-time grant:
          1. System Settings > Privacy & Security > Full Disk Access
          2. Toggle Grux on (or click + and pick /Applications/Grux.app)
          3. Relaunch Grux

        Once granted, ~/.grux/ambient/notifications-YYYY-MM-DD.ndjson will start
        filling and the daily recap will quote interrupt counts.
        """
        try? body.write(
            toFile: path, atomically: true, encoding: .utf8)
        WakeLog.shared.log("notificationWatcher: FDA denied - see \(path)")
    }

    // MARK: - Bundle ID → display name
    //
    // Resolved on the polling queue, cached for the lifetime of the tick.
    // Touches LaunchServices via NSWorkspace, which is thread-safe.

    nonisolated private final class AppNameCache {
        private var map: [String: String] = [:]
        func displayName(forBundleID id: String) -> String {
            if let cached = map[id] { return cached }
            let resolved = Self.resolve(bundleID: id)
            map[id] = resolved
            return resolved
        }
        private static func resolve(bundleID: String) -> String {
            // Hard-coded fast path for high-volume system apps so we never
            // depend on LaunchServices for the common cases. Also tidier
            // strings ("Messages" beats "MobileSMS").
            switch bundleID {
            case "com.apple.mobilesms": return "Messages"
            case "com.apple.mobilephone", "com.apple.facetime": return "Phone"
            case "com.apple.mail": return "Mail"
            case "com.apple.passbook": return "Wallet"
            case "com.apple.softwareupdatenotification": return "Software Update"
            case "com.apple.scripteditor2": return "Script Editor"
            case "com.apple.ical", "com.apple.iCal": return "Calendar"
            case "com.apple.appstore": return "App Store"
            case "com.apple.reminders": return "Reminders"
            case "com.apple.finder": return "Finder"
            case "com.tinyspeck.slackmacgap": return "Slack"
            case "com.hnc.discord": return "Discord"
            case "com.electron.linear-linear": return "Linear"
            case "com.google.Chrome": return "Chrome"
            default: break
            }
            // Strip the _system_center_: prefix Apple uses on some alerts.
            let cleaned = bundleID.hasPrefix("_system_center_:")
                ? String(bundleID.dropFirst("_system_center_:".count))
                : bundleID
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cleaned) {
                let plistURL = url.appendingPathComponent("Contents/Info.plist")
                let info = (try? Data(contentsOf: plistURL))
                    .flatMap {
                        try? PropertyListSerialization.propertyList(
                            from: $0, format: nil) as? [String: Any]
                    } ?? [:]
                if let display = info["CFBundleDisplayName"] as? String, !display.isEmpty {
                    return display
                }
                if let name = info["CFBundleName"] as? String, !name.isEmpty {
                    return name
                }
            }
            // Fall back to the trailing component of the bundle ID,
            // titlecased. "com.foo.bar-baz" -> "Bar Baz".
            let tail = cleaned.split(separator: ".").last.map(String.init) ?? cleaned
            return tail.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    // MARK: - Marker persistence

    nonisolated static var stateURL: URL {
        Persistence.supportDir.appendingPathComponent("notif-watcher-state.json")
    }

    nonisolated private static func ensureStateInitialized() {
        guard !FileManager.default.fileExists(atPath: stateURL.path) else { return }
        let nowMacAbs = Date().timeIntervalSinceReferenceDate
        saveMarker(nowMacAbs)
    }

    nonisolated private static func loadMarker() -> Double {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = obj["lastDeliveredMacAbs"] as? Double else {
            return 0
        }
        return val
    }

    nonisolated private static func saveMarker(_ macAbs: Double) {
        let obj: [String: Any] = ["lastDeliveredMacAbs": macAbs]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - NDJSON layout (mirrors ScreenTimeWatcher)

    nonisolated static var notifDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
    }

    nonisolated static func notifURL(forDate date: Date) -> URL {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return notifDir.appendingPathComponent(
            "notifications-\(f.string(from: date)).ndjson")
    }

    nonisolated private static func appendEvent(
        _ obj: [String: Any], at date: Date
    ) {
        let url = notifURL(forDate: date)
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
                        "notificationWatcher: append failed \(error)")
                }
            }
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Replay + analysis

struct NotificationEvent: Codable, Equatable {
    let ts: Date
    let appBundle: String
    let appName: String

    enum CodingKeys: String, CodingKey {
        case ts
        case appBundle = "app_bundle"
        case appName = "app_name"
    }
}

extension NotificationWatcher {
    nonisolated static func loadEvents(
        between start: Date, and end: Date
    ) -> [NotificationEvent] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var urls: [URL] = []
        var d = startDay
        var safety = 0
        while d <= endDay && safety < 7 {
            urls.append(notifURL(forDate: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? endDay.addingTimeInterval(86400)
            safety += 1
        }
        let iso = ISO8601DateFormatter()
        var out: [NotificationEvent] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                guard let lineData = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let tsStr = obj["ts"] as? String,
                      let ts = iso.date(from: tsStr) else { continue }
                guard ts >= start && ts < end else { continue }
                out.append(NotificationEvent(
                    ts: ts,
                    appBundle: (obj["app_bundle"] as? String) ?? "",
                    appName: (obj["app_name"] as? String) ?? ""
                ))
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }

    nonisolated static func interruptCount(
        between start: Date, and end: Date
    ) -> Int {
        loadEvents(between: start, and: end).count
    }

    nonisolated static func perAppInterrupts(
        between start: Date, and end: Date
    ) -> [(app: String, count: Int)] {
        var totals: [String: Int] = [:]
        for ev in loadEvents(between: start, and: end) {
            let key = ev.appName.isEmpty ? ev.appBundle : ev.appName
            guard !key.isEmpty else { continue }
            totals[key, default: 0] += 1
        }
        return totals
            .map { (app: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
}
