import AppKit
import Foundation

private let kMusicSampleInterval: TimeInterval = 30
private let kSpotifyBundleID = "com.spotify.client"
private let kAppleMusicBundleID = "com.apple.Music"

// Polls Spotify.app and Music.app every 30s for now-playing state. Writes one
// NDJSON line per tick to ~/.grux/ambient/music-YYYY-MM-DD.ndjson with
// {ts, source, state, track, artist, album, genre, durationSec, positionSec}.
// Only writes when at least one client is in a non-stopped state - silence
// hours produce zero lines, keeping the file small.
//
// Pairs with ScreenTimeWatcher + ChromeTabWatcher: gives the daily recap a
// rough idea of what the user was listening to during focus sessions.
//
// BPM is NOT captured. Music.app and Spotify.app AppleScript dictionaries do
// not expose tempo, and Spotify's audio-features Web API is closed to new
// apps as of 2024-11. If a SPOTIFY_TOKEN ever lands in the operator key store
// we can enrich offline in a separate pass, but the live watcher stays simple.
//
// Permissions: NSAppleScript dispatch to each music app triggers the OS Apple
// Events (Automation) TCC prompt on first run. NSAppleEventsUsageDescription
// is in Info.plist. Until granted, every tick fails silently (logged once per
// error code, same pattern as ChromeTabWatcher).
@MainActor
final class MusicWatcher {
    static let shared = MusicWatcher()

    static var sampleIntervalSeconds: TimeInterval { kMusicSampleInterval }

    private let queue = DispatchQueue(label: "grux.music", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(
            at: Self.musicDir, withIntermediateDirectories: true)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + 2.0,
            repeating: kMusicSampleInterval,
            leeway: .seconds(3))
        t.setEventHandler { Self.tickSync() }
        t.resume()
        timer = t
        WakeLog.shared.log("musicWatcher: started (30s tick)")
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
        // Spotify first (faster to respond when paused), then Apple Music.
        // First non-nil snapshot with state != stopped wins. If both are
        // playing we record both as separate lines so dwell totals stay honest.
        var snapshots: [MusicSnapshot] = []
        if appIsRunning(bundleID: kSpotifyBundleID),
           let s = readSpotify(), s.state != "stopped" {
            snapshots.append(s)
        }
        if appIsRunning(bundleID: kAppleMusicBundleID),
           let m = readAppleMusic(), m.state != "stopped" {
            snapshots.append(m)
        }
        guard !snapshots.isEmpty else { return }

        let now = Date()
        let iso = ISO8601DateFormatter()
        for snap in snapshots {
            var event: [String: Any] = [
                "ts": iso.string(from: now),
                "source": snap.source,
                "state": snap.state,
                "track": snap.track,
                "artist": snap.artist,
                "album": snap.album,
                "durationSec": snap.durationSec,
                "positionSec": snap.positionSec
            ]
            if !snap.genre.isEmpty { event["genre"] = snap.genre }
            appendEvent(event, at: now)
        }
    }

    // Don't AppleScript an app that isn't running. Launching Music.app or
    // Spotify.app implicitly via `tell application` is exactly the kind of
    // ambient-watcher overreach that gets a watcher uninstalled.
    nonisolated private static func appIsRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - AppleScript bridges

    private struct MusicSnapshot {
        let source: String       // "spotify" | "apple_music"
        let state: String        // "playing" | "paused" | "stopped"
        let track: String
        let artist: String
        let album: String
        let genre: String        // Apple Music only; "" for Spotify
        let durationSec: Double
        let positionSec: Double
    }

    // Fields are joined with ASCII Unit Separator (U+001F, AppleScript
    // `character id 31`) rather than linefeed. Classical track names and
    // podcast titles can contain newlines, and `linefeed` as a delimiter
    // silently misattributes downstream fields under maxSplits.
    nonisolated private static let fieldSeparator: Character = "\u{001F}"
    nonisolated private static var fieldSeparatorASLiteral: String { "(character id 31)" }

    nonisolated private static func readSpotify() -> MusicSnapshot? {
        let sep = fieldSeparatorASLiteral
        let source = """
        tell application id "com.spotify.client"
            try
                set ps to player state as text
            on error
                return ""
            end try
            set sep to \(sep)
            if ps is "stopped" then return "stopped" & sep & "" & sep & "" & sep & "" & sep & "0" & sep & "0"
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDurMs to duration of current track
            set tPos to player position
            return ps & sep & tName & sep & tArtist & sep & tAlbum & sep & (tDurMs as text) & sep & (tPos as text)
        end tell
        """
        guard let raw = runScript(source: source, tag: "spotify") else { return nil }
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: fieldSeparator, maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6 else { return nil }
        // Spotify reports duration in milliseconds, position in seconds (Float).
        let durMs = Double(parts[4].trimmingCharacters(in: .whitespaces)) ?? 0
        let pos = Double(parts[5].trimmingCharacters(in: .whitespaces)) ?? 0
        return MusicSnapshot(
            source: "spotify",
            state: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            track: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
            artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            album: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
            genre: "",
            durationSec: durMs / 1000.0,
            positionSec: pos
        )
    }

    nonisolated private static func readAppleMusic() -> MusicSnapshot? {
        let sep = fieldSeparatorASLiteral
        // genre fetched in its own try block. Radio streams and some iCloud
        // edge states expose `current track` without a `genre` property; if
        // we wrapped genre in the same try as the other fields, an Apple
        // Music radio session would silently drop the whole snapshot.
        let source = """
        tell application id "com.apple.Music"
            try
                set ps to player state as text
            on error
                return ""
            end try
            set sep to \(sep)
            if ps is "stopped" then return "stopped" & sep & "" & sep & "" & sep & "" & sep & "" & sep & "0" & sep & "0"
            try
                set tName to name of current track
                set tArtist to artist of current track
                set tAlbum to album of current track
                set tDur to duration of current track
                set tPos to player position
            on error
                return ""
            end try
            set tGenre to ""
            try
                set tGenre to genre of current track
            end try
            return ps & sep & tName & sep & tArtist & sep & tAlbum & sep & tGenre & sep & (tDur as text) & sep & (tPos as text)
        end tell
        """
        guard let raw = runScript(source: source, tag: "apple_music") else { return nil }
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: fieldSeparator, maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7 else { return nil }
        let dur = Double(parts[5].trimmingCharacters(in: .whitespaces)) ?? 0
        let pos = Double(parts[6].trimmingCharacters(in: .whitespaces)) ?? 0
        return MusicSnapshot(
            source: "apple_music",
            state: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            track: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
            artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            album: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
            genre: parts[4].trimmingCharacters(in: .whitespacesAndNewlines),
            durationSec: dur,
            positionSec: pos
        )
    }

    nonisolated private static func runScript(source: String, tag: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            logScriptErrorOnce(error, tag: tag)
            return nil
        }
        return result.stringValue
    }

    // Errors repeat every tick under steady-state failures (TCC denial -1743,
    // app unresponsive -1712, missing dictionary -1728). Log each (tag, code)
    // pair once so granting permission later still surfaces recovery and a
    // new failure mode doesn't get swallowed.
    nonisolated private static let scriptErrorFlag = NSLock()
    nonisolated(unsafe) private static var loggedScriptErrorKeys: Set<String> = []
    nonisolated private static func logScriptErrorOnce(_ error: NSDictionary, tag: String) {
        let code = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
        let key = "\(tag):\(code)"
        scriptErrorFlag.lock()
        defer { scriptErrorFlag.unlock() }
        guard loggedScriptErrorKeys.insert(key).inserted else { return }
        let msg = (error["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
        WakeLog.shared.log("musicWatcher[\(tag)]: AppleScript error code=\(code) msg=\(msg)")
    }

    // MARK: - NDJSON layout

    nonisolated static var musicDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
    }

    nonisolated static func musicURL(forDate date: Date) -> URL {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return musicDir.appendingPathComponent("music-\(f.string(from: date)).ndjson")
    }

    nonisolated private static func appendEvent(_ obj: [String: Any], at date: Date) {
        let url = musicURL(forDate: date)
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
                    WakeLog.shared.log("musicWatcher: append failed \(error)")
                }
            }
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Replay + analysis

struct MusicEvent: Codable, Equatable {
    let ts: Date
    let source: String
    let state: String
    let track: String
    let artist: String
    let album: String
    let genre: String
    let durationSec: Double
    let positionSec: Double
}

extension MusicWatcher {
    // Every event in [start, end). Walks daily NDJSON files that overlap the
    // range (capped at 7 days).
    nonisolated static func loadEvents(
        between start: Date, and end: Date
    ) -> [MusicEvent] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var urls: [URL] = []
        var d = startDay
        var safety = 0
        while d <= endDay && safety < 7 {
            urls.append(musicURL(forDate: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? endDay.addingTimeInterval(86400)
            safety += 1
        }
        let iso = ISO8601DateFormatter()
        var out: [MusicEvent] = []
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
                out.append(MusicEvent(
                    ts: ts,
                    source: (obj["source"] as? String) ?? "",
                    state: (obj["state"] as? String) ?? "",
                    track: (obj["track"] as? String) ?? "",
                    artist: (obj["artist"] as? String) ?? "",
                    album: (obj["album"] as? String) ?? "",
                    genre: (obj["genre"] as? String) ?? "",
                    durationSec: (obj["durationSec"] as? Double) ?? 0,
                    positionSec: (obj["positionSec"] as? Double) ?? 0
                ))
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }

    // Per-artist listen-seconds in [start, end). Only "playing" events count
    // (paused snapshots are wall-clock time without listening). Each playing
    // tick credits sampleIntervalSeconds (30s default). Returns artists
    // sorted by seconds desc.
    nonisolated static func perArtistDwell(
        between start: Date, and end: Date
    ) -> [(artist: String, seconds: Int)] {
        let events = loadEvents(between: start, and: end).filter { $0.state == "playing" }
        var totals: [String: Double] = [:]
        for ev in events {
            let key = ev.artist
            guard !key.isEmpty else { continue }
            totals[key, default: 0] += kMusicSampleInterval
        }
        return totals
            .map { (artist: $0.key, seconds: Int($0.value.rounded())) }
            .sorted { $0.seconds > $1.seconds }
    }

    // Per-genre listen-seconds - Apple Music only (Spotify doesn't expose
    // genre via scripting). Useful as a soft signal in the daily recap.
    nonisolated static func perGenreDwell(
        between start: Date, and end: Date
    ) -> [(genre: String, seconds: Int)] {
        let events = loadEvents(between: start, and: end).filter { $0.state == "playing" }
        var totals: [String: Double] = [:]
        for ev in events {
            let key = ev.genre
            guard !key.isEmpty else { continue }
            totals[key, default: 0] += kMusicSampleInterval
        }
        return totals
            .map { (genre: $0.key, seconds: Int($0.value.rounded())) }
            .sorted { $0.seconds > $1.seconds }
    }

    // Total active-listening seconds in [start, end). Sum of "playing" ticks
    // times sampleIntervalSeconds. Used by the daily recap to decide whether
    // to mention music at all.
    nonisolated static func totalListenSeconds(
        between start: Date, and end: Date
    ) -> Int {
        let count = loadEvents(between: start, and: end).filter { $0.state == "playing" }.count
        return Int((Double(count) * kMusicSampleInterval).rounded())
    }
}
