import AppKit
import Foundation

// Mac sleep/wake log. Subscribes to NSWorkspace willSleep + didWake and
// appends one NDJSON line per event to:
//   ~/.grux/ambient/system-events-YYYY-MM-DD.ndjson
//
// Schema: {"ts": "<ISO8601>", "kind": "sleep" | "wake"}
//
// The Workday Log assembler reads these so multi-hour gaps the Mac was
// actually asleep get labeled "system slept" instead of inflating
// drifting/off-task minutes via the 20-minute interval cap.
//
// Path mirrors ScreenTimeWatcher (~/.grux/ambient/) so tail -F works for
// quick verification and the file lives next to its sibling ambient logs.
@MainActor
final class SleepWatcher {
    static let shared = SleepWatcher()

    private var willSleepObs: NSObjectProtocol?
    private var didWakeObs: NSObjectProtocol?
    private var running = false

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        try? FileManager.default.createDirectory(
            at: Self.systemEventsDir, withIntermediateDirectories: true)

        let nc = NSWorkspace.shared.notificationCenter
        // queue: nil → handler runs synchronously on the posting thread.
        // willSleep is dispatched while the system is preparing to suspend,
        // so we want the write to land before the disk goes idle.
        willSleepObs = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: nil
        ) { _ in
            Self.appendSync(kind: "sleep", at: Date())
        }
        didWakeObs = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: nil
        ) { _ in
            Self.appendSync(kind: "wake", at: Date())
        }

        WakeLog.shared.log("sleepWatcher: started")
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let o = willSleepObs { nc.removeObserver(o); willSleepObs = nil }
        if let o = didWakeObs   { nc.removeObserver(o); didWakeObs = nil }
        running = false
    }

    // Synthesize a paired sleep+wake event for the fire-sleep-log-test
    // trigger. Bypasses NSWorkspace so verification works on an awake Mac.
    func fireSyntheticTestEvents() {
        let now = Date()
        Self.appendSync(kind: "sleep", at: now.addingTimeInterval(-1))
        Self.appendSync(kind: "wake", at: now)
        WakeLog.shared.log("sleepWatcher: synthetic test pair written")
    }

    // MARK: - NDJSON layout

    nonisolated static var systemEventsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
    }

    nonisolated static func systemEventsURL(forDate date: Date) -> URL {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return systemEventsDir.appendingPathComponent(
            "system-events-\(f.string(from: date)).ndjson")
    }

    nonisolated static func appendSync(kind: String, at date: Date) {
        let iso = ISO8601DateFormatter()
        let obj: [String: Any] = ["ts": iso.string(from: date), "kind": kind]
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: json, encoding: .utf8)
        else { return }
        let payload = (str + "\n").data(using: .utf8) ?? Data()
        let url = systemEventsURL(forDate: date)
        try? FileManager.default.createDirectory(
            at: systemEventsDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                do {
                    try h.seekToEnd()
                    try h.write(contentsOf: payload)
                } catch {
                    WakeLog.shared.log("sleepWatcher: append failed \(error)")
                }
            }
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Replay

struct SleepInterval: Equatable {
    let start: Date
    let end: Date
}

extension SleepWatcher {
    // Pair sleep/wake events into closed intervals clipped to [start, end).
    // Loads a 24h cushion before `start` so a sleep that began earlier still
    // pairs with its wake event inside the window.
    nonisolated static func sleepIntervals(
        in range: Range<Date>
    ) -> [SleepInterval] {
        let cal = Calendar.current
        let loadFrom = range.lowerBound.addingTimeInterval(-86400)
        let loadTo = range.upperBound
        var d = cal.startOfDay(for: loadFrom)
        let endDay = cal.startOfDay(for: loadTo)
        var urls: [URL] = []
        var safety = 0
        while d <= endDay && safety < 8 {
            urls.append(systemEventsURL(forDate: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? endDay.addingTimeInterval(86400)
            safety += 1
        }
        let iso = ISO8601DateFormatter()
        var events: [(ts: Date, kind: String)] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            for raw in text.split(separator: "\n") {
                guard let lineData = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let tsStr = obj["ts"] as? String,
                      let ts = iso.date(from: tsStr),
                      let kind = obj["kind"] as? String
                else { continue }
                events.append((ts, kind))
            }
        }
        events.sort { $0.ts < $1.ts }

        var intervals: [SleepInterval] = []
        var pendingSleep: Date?
        for ev in events {
            if ev.kind == "sleep" {
                // Two sleeps in a row (missed wake): close the prior with
                // this sleep's ts so we don't span across waking work.
                if let prior = pendingSleep {
                    intervals.append(SleepInterval(start: prior, end: ev.ts))
                }
                pendingSleep = ev.ts
            } else if ev.kind == "wake" {
                if let prior = pendingSleep {
                    intervals.append(SleepInterval(start: prior, end: ev.ts))
                    pendingSleep = nil
                }
            }
        }
        // Unterminated sleep (system still asleep or app died): clip to now.
        if let prior = pendingSleep {
            intervals.append(SleepInterval(start: prior, end: Date()))
        }

        // Clip to range.
        var out: [SleepInterval] = []
        for iv in intervals {
            let lo = max(iv.start, range.lowerBound)
            let hi = min(iv.end, range.upperBound)
            if hi > lo { out.append(SleepInterval(start: lo, end: hi)) }
        }
        return out
    }
}
