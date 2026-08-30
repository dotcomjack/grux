import Foundation

// Canonical workday log persistence:
//   * JSON at ~/Library/Application Support/Grux/workday-logs/<dayKey>.json
//   * Index at ~/Library/Application Support/Grux/workday-logs/index.json
//   * Markdown mirror at ~/…/Mobile Documents/…/GruxAI/workday-logs/<dayKey>.md
//
// Idempotent: saving the same dayKey twice overwrites + upserts the index.
// Never lossy: a failed iCloud write does NOT block the local save.

enum WorkdayLogStore {

    // MARK: - The two switches

    /// Whether the 6 AM rollup runs at all. Default ON, because the log is the surface, but
    /// it had NO off switch of any kind: `stop()` had zero call sites, there was no toggle
    /// anywhere in Settings, and `start()` ran on every launch, so somebody who deleted the
    /// files got them back on the next 6 AM tick with nothing they could do about it short
    /// of quitting Grux.
    static let enabledKey = "grux.workdayLog.enabled"

    /// Whether the markdown copy goes to iCloud Drive. DEFAULT OFF, and this one is not a
    /// convenience switch.
    ///
    /// The log is a rollup of the person's project names, git branches and commit messages.
    /// It was written to ~/Library/Mobile Documents/com~apple~CloudDocs/GruxAI/workday-logs/,
    /// a folder whose getter CREATES it, so a `GruxAI` folder appeared in their iCloud Drive
    /// in Finder and on their iPhone, and Apple's sync uploaded the contents to every device
    /// on their Apple ID. On a first launch in the morning, before they had configured or
    /// agreed to anything.
    ///
    /// The rest of the app already takes the opposite position and says so out loud:
    /// Persistence.swift calls meetingsDir "Deliberately NOT mirrored to iCloud (meetings are
    /// sensitive)" and gives chatThreadsDir the "same sensitivity posture". The workday log
    /// aggregates both and was the one that mirrored. Nothing in onboarding or Settings
    /// mentioned iCloud at all: grep across Sources/Grux/Onboarding and SettingsView returned
    /// zero hits.
    static let iCloudMirrorKey = "grux.workdayLog.iCloudMirror"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// No `?? true` here on purpose. An absent key is somebody who has never been asked.
    static var mirrorsToICloud: Bool {
        UserDefaults.standard.bool(forKey: iCloudMirrorKey)
    }

    // MARK: - Save / load

    @discardableResult
    static func save(_ log: WorkdayLog) -> URL {
        let dir = Persistence.workdayLogsDir
        let jsonURL = dir.appendingPathComponent("\(log.dayKey).json")
        Persistence.save(log, to: jsonURL)

        upsertIndexEntry(for: log)
        writeMarkdownMirror(log)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .gruxWorkdayLogSaved, object: log.dayKey)
        }
        WakeLog.shared.log("workdayLog saved: \(log.dayKey) → \(jsonURL.path)")
        return jsonURL
    }

    static func load(dayKey: String) -> WorkdayLog? {
        let url = Persistence.workdayLogsDir.appendingPathComponent("\(dayKey).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WorkdayLog.self, from: data)
    }

    static func list() -> [WorkdayLogIndexEntry] {
        let url = Persistence.workdayLogsDir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let entries = (try? dec.decode([WorkdayLogIndexEntry].self, from: data)) ?? []
        return entries.sorted { $0.dayKey > $1.dayKey }
    }

    // MARK: - Index

    private static func upsertIndexEntry(for log: WorkdayLog) {
        let snippet = String(log.narrative.prefix(140))
        let entry = WorkdayLogIndexEntry(
            dayKey: log.dayKey,
            generatedAt: log.generatedAt,
            tags: log.tags,
            narrativeSnippet: snippet,
            totalProductiveMinutes: log.totalProductiveMinutes
        )
        var current = list()
        current.removeAll { $0.dayKey == log.dayKey }
        current.append(entry)
        current.sort { $0.dayKey > $1.dayKey }
        let url = Persistence.workdayLogsDir.appendingPathComponent("index.json")
        Persistence.save(current, to: url)
    }

    // MARK: - Markdown mirror (iCloud)

    private static func writeMarkdownMirror(_ log: WorkdayLog) {
        // BEFORE Persistence.iCloudMirrorDir is touched, because reading that property is
        // itself the side effect: its getter calls createDirectory, so merely asking where
        // the mirror would go creates the folder in the person's iCloud Drive.
        guard mirrorsToICloud else { return }
        guard let iCloud = Persistence.iCloudMirrorDir else {
            WakeLog.shared.log("workdayLog: iCloud unavailable, skipping MD mirror")
            return
        }
        let url = iCloud.appendingPathComponent("\(log.dayKey).md")
        let md = WorkdayLogRenderer.renderMarkdown(log)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            WakeLog.shared.log("workdayLog MD mirror → \(url.path)")
        } catch {
            WakeLog.shared.log("workdayLog MD mirror FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Convenience

    /// Pure, and pure for a specific reason rather than for tidiness.
    ///
    /// A test that drove `markdownMirrorURL` directly PASSED with the preference guard
    /// deleted, so it was not a test. `xctest` has no TCC grant for
    /// ~/Library/Mobile Documents, so `Persistence.iCloudMirrorDir` returns nil inside the
    /// suite whatever the switch says, and asserting nil could not fail. Handing the
    /// directory in is what makes the decision observable on any machine.
    static func mirrorURL(in directory: URL?, dayKey: String, mirrorOn: Bool) -> URL? {
        guard mirrorOn, let directory else { return nil }
        return directory.appendingPathComponent("\(dayKey).md")
    }

    static func markdownMirrorURL(for dayKey: String) -> URL? {
        // Same reason as above: this is a "where is it" question and answering it used to
        // create the folder. With the mirror off there is no file, so the honest answer is
        // nil and the Reveal in Finder button that calls this hides itself.
        guard mirrorsToICloud else { return nil }
        guard let iCloud = Persistence.iCloudMirrorDir else { return nil }
        guard let url = Self.mirrorURL(in: iCloud, dayKey: dayKey, mirrorOn: mirrorsToICloud)
        else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
