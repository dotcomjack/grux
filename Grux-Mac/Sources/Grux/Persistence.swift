import Foundation

enum Persistence {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where user-facing HTML exports land. Portable, inside the user's own
    /// Documents, created on demand.
    ///
    /// Four export paths used to be hardcoded under one contributor's own
    /// person's directory layout. Two consequences, and the second is the one
    /// that mattered: it shipped that layout inside a public binary, and the
    /// Feature Review "Export to Chrome" button wrote with `try?` into a folder
    /// that does not exist on anybody else's Mac, then opened the file it had
    /// just failed to write. Silent no-op for every user but one.
    /// NAMING A PLACE IS NOT MAKING ONE. This getter used to call createDirectory, which
    /// meant that merely asking where an export WOULD go put a `Grux` folder in the person's
    /// Documents. Measured on a Mac that had never run Grux: `~/Documents/Grux` appeared on
    /// the first launch, empty, for features nobody had used.
    ///
    /// Three getters in this codebase had that shape (`iCloudMirrorDir`, `defaultBackupsDir`
    /// and this one) and a fourth, `designDir`, is corrected in DesignProjectStore.swift.
    /// Use `makeExportsDir()` at the point of writing.
    static var exportsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Grux", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
    }

    /// The same place, created, for the moment something is actually about to be written
    /// there. The comment above this pair records why that matters in the other direction
    /// too: an earlier version wrote with `try?` into a folder that did not exist on anybody
    /// else's Mac and then opened the file it had just failed to write, which was a silent
    /// no-op for every user but one.
    @discardableResult
    static func makeExportsDir() -> URL {
        let dir = exportsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The live build worktree Grux is built and installed from, read from
    /// `~/.grux/live-worktree.txt`. There is deliberately NO default.
    ///
    /// The path to somebody's build tree is theirs. Hardcoding one person's
    /// layout put it inside a public binary and left the Foundry tripwire
    /// sweeping a path that will never exist on any other machine, every five
    /// minutes, forever. Absent file means the feature is simply off, which is
    /// the correct posture for machinery only its author uses.
    static var liveWorktreeRoot: URL? {
        let cfg = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("live-worktree.txt")
        guard let raw = try? String(contentsOf: cfg, encoding: .utf8) else { return nil }
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        let expanded = p.hasPrefix("~") ? NSHomeDirectory() + p.dropFirst() : p
        return URL(fileURLWithPath: String(expanded), isDirectory: true)
    }

    /// Where the app parks things it must not lose and must not trust: the
    /// tripwire's strays, and the byte-for-byte copy of any state file that
    /// failed to decode (see `load(_:from:fallback:)`). App-owned and neutral.
    static var quarantineDir: URL {
        if let quarantineDirOverride { return quarantineDirOverride }
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("quarantine", isDirectory: true)
        return dir
    }

    /// Test seam, nil on every shipping path. The quarantine tests plant corrupt
    /// files and assert on the copies that land here, and a test that writes
    /// into a real home directory is a test that changes the machine it runs on.
    /// Set once in setUp, before anything reads it.
    static nonisolated(unsafe) var quarantineDirOverride: URL?

    static var tasksURL: URL { supportDir.appendingPathComponent("tasks.json") }
    static var eventsURL: URL { supportDir.appendingPathComponent("events.json") }
    static var chatURL: URL { supportDir.appendingPathComponent("chat.json") }
    static var configURL: URL { supportDir.appendingPathComponent("config.json") }
    static var terminalFocusConfigURL: URL { supportDir.appendingPathComponent("terminal-focus.json") }
    static var screenshotsDir: URL {
        let dir = supportDir.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Agent framework jobs. One subdirectory per AgentJob; per-worker step
    // streams nested under workers/<workerId>/. Owned by AgentService and
    // GruxAgentCore.AgentStore.
    static var agentsDir: URL {
        let dir = supportDir.appendingPathComponent("agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Workday Log subsystem: canonical per-day JSON + index lives here.
    static var workdayLogsDir: URL {
        let dir = supportDir.appendingPathComponent("workday-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Ambient hourly summaries (NDJSON per day). Fills the retention gap
    // left by the 200-chunk ring buffer in AmbientState.
    static var ambientSummariesDir: URL {
        let dir = supportDir.appendingPathComponent("ambient-summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Persistent chat threads. One JSON file per thread + an index.json.
    // Replaces the legacy single-file chat.json - ChatThreadStore migrates
    // any pre-existing chat.json into a "Previous chat" thread on first
    // launch. Same sensitivity posture as meetingsDir (not iCloud-mirrored).
    static var chatThreadsDir: URL {
        let dir = supportDir.appendingPathComponent("chat-threads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Meeting captures - one JSON file per meeting plus an index.json.
    // Deliberately NOT mirrored to iCloud by default (meetings are sensitive).
    static var meetingsDir: URL {
        let dir = supportDir.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Crash-safe audio write-ahead log. One subdirectory per in-flight
    // meeting; `AudioWAL` writes raw Float32 16 kHz mono PCM chunks here
    // and `AudioWALRecovery` replays them on launch if the previous
    // process died mid-capture. Same sensitivity posture as meetingsDir.
    static var audioWALDir: URL {
        let dir = supportDir.appendingPathComponent("audio-wal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // iCloud Drive mirror location for human-readable markdown logs.
    // Returns nil when ubiquity container is unavailable (iCloud off).
    // Callers MUST gracefully skip the MD mirror step when this is nil.
    static var iCloudMirrorDir: URL? {
        // Standard system iCloud Drive path - reachable without entitlements
        // since we're sandbox-off. Bypasses `url(forUbiquityContainerIdentifier:)`
        // which requires a container identifier in the entitlements.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let dir = root
            .appendingPathComponent("GruxAI", isDirectory: true)
            .appendingPathComponent("workday-logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    /// Load a Codable from disk, distinguishing "nothing there yet" from
    /// "something there and it is broken".
    ///
    /// This function used to treat those two as one event: a `try?` on the read
    /// and a `try?` on the decode, both collapsing into the fallback. There are
    /// 81 load sites and 104 save sites in this app, and the stores behind them
    /// debounce a save shortly after they load. That combination is what turned
    /// a decode failure into permanent loss: one corrupt or schema-drifted file
    /// decodes to nothing, the store comes up empty, and seconds later the
    /// debounce writes that empty default back over the only copy the user had.
    /// Nothing was logged and nothing reached the screen, so the first anyone
    /// knew of it was the data being gone.
    ///
    /// So the two cases are split, and they are treated in opposite ways. A
    /// MISSING file is NORMAL, it is exactly what every fresh install looks
    /// like, and it stays completely silent. A file that EXISTS and does not
    /// decode is a DEFECT: its bytes are copied into `quarantineDir` before
    /// anything else touches them, the failure is logged and recorded for the
    /// UI, and the path is armed against overwrite until someone acknowledges
    /// it. The fallback is still returned either way, so not one of those 81
    /// call sites changes behaviour.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, fallback: T) -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        guard let data = try? Data(contentsOf: url) else {
            // Present but unreadable is a permissions or hardware problem rather
            // than a decode failure, and there are no bytes for quarantine to
            // preserve. Still worth a line: it is not a fresh install.
            log("load: \(url.path) exists but could not be read. Using the fallback.")
            return fallback
        }
        // A zero-byte file decodes to nothing, but it also contains nothing to
        // preserve, and arming the overwrite guard on it would strand the store
        // with no recoverable data and no way forward. Say so and carry on.
        guard !data.isEmpty else {
            log("load: \(url.path) is empty. Using the fallback.")
            return fallback
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode(T.self, from: data)
        } catch {
            recordDecodeFailure(url: url, byteCount: data.count, error: error)
            return fallback
        }
    }

    // MARK: - Corrupt-file quarantine

    /// One recorded load failure: a file that existed, held bytes, and did not
    /// decode. `quarantined` is the path of the copy taken before anything else
    /// touched the original, or empty if even the copy failed.
    struct DecodeFailure: Equatable {
        let path: String
        let quarantined: String
        let error: String
    }

    // Same NSLock pattern as the restore kill switch below: loads happen off the
    // main thread in several stores, so both the record and the refusal set have
    // to be safe to touch from anywhere. A separate lock from `suspendLock`
    // because the two have nothing to say to each other.
    private static let failureLock = NSLock()
    private static nonisolated(unsafe) var decodeFailureStorage: [DecodeFailure] = []
    private static nonisolated(unsafe) var refusedPathStorage: Set<String> = []

    /// Every load failure recorded this launch, oldest first. The UI reads this
    /// to tell the user which file broke and where the preserved copy is.
    static var decodeFailures: [DecodeFailure] {
        failureLock.lock(); defer { failureLock.unlock() }; return decodeFailureStorage
    }

    /// True when this path is armed against overwrite because its last load did
    /// not decode.
    static func isWriteRefused(_ url: URL) -> Bool {
        failureLock.lock(); defer { failureLock.unlock() }
        return refusedPathStorage.contains(url.path)
    }

    /// Lift the write refusal on a path and drop its record.
    ///
    /// Acknowledging is the user, or the UI acting for them, saying they have
    /// seen the failure and accept that the next save replaces the file. The
    /// record goes with the refusal on purpose: a banner that outlives the state
    /// it describes is how the next reader learns to ignore banners. The
    /// quarantined copy is never touched, so acknowledging costs nothing.
    static func acknowledgeDecodeFailure(_ url: URL) {
        let path = url.path
        failureLock.lock()
        refusedPathStorage.remove(path)
        decodeFailureStorage.removeAll { $0.path == path }
        failureLock.unlock()
        log("acknowledged \(path). Writes to it are allowed again; the quarantined copy is untouched.")
    }

    /// Clear every recorded failure and lift every refusal.
    ///
    /// Dismiss-all is acknowledge-all deliberately. Leaving a path refused after
    /// the only record of WHY has been cleared strands the store in a state
    /// nothing on screen can explain, which is the exact failure mode this guard
    /// exists to remove.
    static func clearDecodeFailures() {
        failureLock.lock()
        decodeFailureStorage.removeAll()
        refusedPathStorage.removeAll()
        failureLock.unlock()
    }

    private static func recordDecodeFailure(url: URL, byteCount: Int, error: Error) {
        // Already armed means the first failing load already took a copy.
        // Several stores read the same file, and without this the same corrupt
        // bytes land in quarantine once per reader.
        if isWriteRefused(url) {
            log("DECODE FAILURE (repeat): \(url.path) still does not decode. Writes stay refused.")
            return
        }
        let dest = quarantineCopy(of: url)
        let described = String(describing: error)
        log("DECODE FAILURE: \(url.path) exists (\(byteCount) bytes) and did not decode: \(described). "
            + "Copy preserved at \(dest ?? "<quarantine copy FAILED>"). "
            + "Writes to this path are REFUSED until Persistence.acknowledgeDecodeFailure(_:) is called.")
        failureLock.lock()
        decodeFailureStorage.append(DecodeFailure(path: url.path, quarantined: dest ?? "", error: described))
        refusedPathStorage.insert(url.path)
        failureLock.unlock()
    }

    /// Byte-for-byte copy of a file that failed to decode, parked under
    /// `quarantineDir` with its original basename and a UTC stamp.
    ///
    /// COPY, never move. The user's own file stays exactly where it lives, so
    /// anyone able to hand-repair it still finds it at the path the app names,
    /// and the copy exists purely so the repair has an original to work from.
    ///
    /// ONE COPY PER DISTINCT CONTENT, and the FIRST one wins. The repeat guard
    /// in `recordDecodeFailure` reads `refusedPathStorage`, which is in-memory
    /// and dies with the process, so without this rule every launch took
    /// another full copy of a file that `refuseWrite` guarantees cannot have
    /// changed since the last one: one duplicate of a multi-megabyte
    /// chat.json per app start, forever, in a directory nothing in the app
    /// enumerates, prunes, or reports the size of. Matching on CONTENT is the
    /// only thing that can work, because the destination name carries a fresh
    /// timestamp by construction and so can never match its own earlier copy.
    /// The first match is returned rather than the last because it is the copy
    /// taken nearest the original failure.
    ///
    /// Nothing here deletes, prunes, or caps. Deleting a quarantined copy is
    /// the exact loss this whole mechanism exists to prevent, and once content
    /// decides the question the directory can only grow when the bytes really
    /// do differ from every version already preserved, which means someone
    /// acknowledged the failure, a store wrote the file again, and the result
    /// broke again. That is a second corruption event, and it is worth keeping.
    private static func quarantineCopy(of url: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        } catch {
            log("quarantine: could not create \(quarantineDir.path): \(error)")
            return nil
        }

        // Copies of THIS basename, oldest first. The stamp below is fixed
        // width, zero padded and UTC, so sorting the names sorts them by the
        // moment they were taken. The one exception is the collision suffix two
        // copies inside the same second get, and inside one second "first" has
        // no meaning anyway.
        let prefix = "\(url.lastPathComponent)."
        let existing = ((try? fm.contentsOfDirectory(at: quarantineDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Size settles almost every candidate without reading a large file
        // twice, so the byte compare only runs on a real suspect. Equal sizes
        // are never treated as equal content: a schema drift usually leaves the
        // length alone and changes what is inside it.
        if let sourceBytes = try? Data(contentsOf: url) {
            for candidate in existing {
                guard (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == sourceBytes.count,
                      (try? Data(contentsOf: candidate)) == sourceBytes else { continue }
                log("quarantine: \(url.path) is byte-for-byte identical to \(candidate.path), which is "
                    + "already preserved. Kept that copy and took no new one.")
                return candidate.path
            }
        }

        // Built per call rather than held in a static: DateFormatter is not
        // Sendable, this runs at most once per broken file, and a shared mutable
        // formatter is not worth a nanosecond nobody will ever measure.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        let stamp = fmt.string(from: Date())

        // Everything that reaches this path was being decoded as JSON, so the
        // suffix is honest, and keeping the original basename in the middle is
        // what makes the copy identifiable a week later.
        var dest = quarantineDir.appendingPathComponent("\(url.lastPathComponent).\(stamp).json")
        // Two readers failing inside the same second would otherwise collide,
        // and copyItem refuses to overwrite. Never clobber a quarantined copy:
        // it can be the only surviving version of somebody's data.
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = quarantineDir.appendingPathComponent("\(url.lastPathComponent).\(stamp)-\(n).json")
            n += 1
        }
        do {
            try fm.copyItem(at: url, to: dest)
            return dest.path
        } catch {
            log("quarantine: copying \(url.path) failed: \(error)")
            return nil
        }
    }

    /// True when the write must not happen, having logged why.
    ///
    /// This is the half that turns silent permanent loss into a recoverable
    /// state. The quarantine copy preserves the bytes; this stops the debounced
    /// save that would otherwise replace the original with an empty default
    /// seconds after the failed load.
    private static func refuseWrite(to url: URL, verb: String) -> Bool {
        guard isWriteRefused(url) else { return false }
        log("REFUSED \(verb) to \(url.path): its last load did not decode and nobody has acknowledged it. "
            + "Call Persistence.acknowledgeDecodeFailure(_:) to allow writes again.")
        return true
    }

    /// Interpolate first, then hand NSLog a single `%@`. A path or a decode
    /// error containing a `%` would otherwise be read as a format specifier and
    /// take the process down with it.
    private static func log(_ message: String) {
        NSLog("[Persistence] %@", message)
    }

    // Restore-in-progress kill switch. Once a restore has swapped the data
    // trees on disk, every in-memory store is stale: any debounced save,
    // scheduler tick, or termination flush would overwrite the just-restored
    // files with pre-restore state. BackupView flips this before the swap
    // and the app relaunches before it is ever cleared.
    private static let suspendLock = NSLock()
    private static nonisolated(unsafe) var suspendedStorage = false
    static var writesSuspended: Bool {
        get { suspendLock.lock(); defer { suspendLock.unlock() }; return suspendedStorage }
        set { suspendLock.lock(); defer { suspendLock.unlock() }; suspendedStorage = newValue }
    }

    /// Encode and write, non-throwing, because 104 call sites depend on that.
    ///
    /// Non-throwing is not the same as silent, which is what the two `try?`s
    /// here used to make it: an encode that threw and a write that failed both
    /// returned as if they had worked, and the store above kept serving state
    /// that no longer matched the disk. Both failures now say so by path.
    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard !writesSuspended else { return }
        guard !refuseWrite(to: url, verb: "save") else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try enc.encode(value)
        } catch {
            log("save: encoding \(T.self) for \(url.path) failed: \(error)")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log("save: writing \(url.path) failed: \(error)")
        }
    }

    // Guarded raw write for stores that persist non-Codable payloads
    // (markdown mirrors, NDJSON appends, raw report bytes). Honors the
    // restore kill switch exactly like save(_:to:); direct data.write
    // calls in tree-writing stores bypass the switch and can overwrite a
    // just-restored tree with stale in-memory state.
    @discardableResult
    static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) -> Bool {
        guard !writesSuspended else { return false }
        guard !refuseWrite(to: url, verb: "write") else { return false }
        do {
            try data.write(to: url, options: options)
            return true
        } catch {
            log("write: \(url.path) failed: \(error)")
            return false
        }
    }
}
