import Foundation

// Per-brand time accounting.
//
// Combines three signals that already exist on disk:
//   * ScreenTimeWatcher NDJSON  (~/.grux/ambient/screentime-YYYY-MM-DD.ndjson)
//   * ChromeTabWatcher  NDJSON  (~/.grux/ambient/chrome-tabs-YYYY-MM-DD.ndjson)
//   * git log across repos discovered under the search roots in the config
//
// Walks today's screen-time samples chronologically. Each non-idle sample
// counts for ScreenTimeWatcher.kSampleIntervalSeconds (10s). When the frontmost
// app is Chrome, the matching chrome-tabs event at that timestamp (within one
// sample window) is used so attribution can hit a brand URL instead of the
// generic "Chrome" bucket. Everything else attributes by bundle id, app name,
// and window title substrings. Anything that does not match a rule lands in
// the "Other" bucket, never double-counted.
//
// Daily output: ~/.grux/brand-time/YYYY-MM-DD.json
//
// Config is a plain JSON file at ~/.grux/brand-attribution.json. Seeded EMPTY
// on first run: the brands a person works on, and the folders their code sits
// in, are theirs to declare, so nothing is assumed. Editable by hand or from a
// future Settings panel. Schema:
//   {
//     "brands": [
//       {
//         "name": "Example Brand",
//         "bundle_ids":      ["com.example.app"],
//         "app_names":       ["Example"],
//         "title_substrings":["Example Brand"],
//         "url_domains":     ["example.com"],
//         "url_substrings":  ["/admin/example"],
//         "repo_paths":      ["Projects/Example", "example-web"]
//       }, ...
//     ],
//     "repo_search_roots": ["~/Code", "~/Projects"]
//   }
//
// An empty roster is a supported state, not an error: every signal still gets
// read, nothing matches, and the report comes back with zero brand rows and
// all active time in `unattributed_seconds`. Empty `repo_search_roots` is the
// same kind of state: no directory is walked and the git component is zero.
//
// Fallback policy: this feature runs entirely on local files. There is no LLM
// call and no companion service dependency, so there is nothing to fall back from. If a
// signal is missing (e.g. Chrome was never frontmost today) the corresponding
// component is zero and the rest still works.
enum BrandAttribution {
    static let configFilename = "brand-attribution.json"
    static let outputDirName = "brand-time"

    // MARK: - Models

    struct BrandRule: Codable, Hashable {
        var name: String
        var bundleIds: [String]
        var appNames: [String]
        var titleSubstrings: [String]
        var urlDomains: [String]
        var urlSubstrings: [String]
        var repoPaths: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case bundleIds = "bundle_ids"
            case appNames = "app_names"
            case titleSubstrings = "title_substrings"
            case urlDomains = "url_domains"
            case urlSubstrings = "url_substrings"
            case repoPaths = "repo_paths"
        }
    }

    struct Config: Codable {
        var brands: [BrandRule]
        // Directories walked to find git repositories. Empty by default, and a
        // hand-edited file written before this key existed decodes as empty
        // rather than failing.
        var repoSearchRoots: [String]

        enum CodingKeys: String, CodingKey {
            case brands
            case repoSearchRoots = "repo_search_roots"
        }

        init(brands: [BrandRule], repoSearchRoots: [String] = []) {
            self.brands = brands
            self.repoSearchRoots = repoSearchRoots
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            brands = try c.decodeIfPresent([BrandRule].self, forKey: .brands) ?? []
            repoSearchRoots = try c.decodeIfPresent([String].self, forKey: .repoSearchRoots) ?? []
        }
    }

    struct BrandBreakdown: Codable, Hashable {
        var brand: String
        var screenSeconds: Int
        var chromeSeconds: Int
        var gitCommits: Int
        var totalSeconds: Int
        var totalHours: Double

        enum CodingKeys: String, CodingKey {
            case brand
            case screenSeconds = "screen_seconds"
            case chromeSeconds = "chrome_seconds"
            case gitCommits = "git_commits"
            case totalSeconds = "total_seconds"
            case totalHours = "total_hours"
        }
    }

    struct DailyReport: Codable, Equatable {
        var date: String        // YYYY-MM-DD
        var generatedAt: String // ISO-8601
        var brands: [BrandBreakdown]
        var unattributedSeconds: Int
        var totalActiveSeconds: Int

        enum CodingKeys: String, CodingKey {
            case date
            case generatedAt = "generated_at"
            case brands
            case unattributedSeconds = "unattributed_seconds"
            case totalActiveSeconds = "total_active_seconds"
        }
    }

    // MARK: - Paths

    static var gruxDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux", isDirectory: true)
    }

    static var configURL: URL {
        gruxDir.appendingPathComponent(configFilename)
    }

    static var outputDir: URL {
        gruxDir.appendingPathComponent(outputDirName, isDirectory: true)
    }

    static func outputURL(for date: Date) -> URL {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return outputDir.appendingPathComponent("\(f.string(from: date)).json")
    }

    // MARK: - Config load + seed

    static func loadConfig() -> Config {
        ensureConfigSeeded()
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else {
            WakeLog.shared.log("brandAttribution: failed to decode config, using defaults")
            return Config(brands: defaultBrands)
        }
        return cfg
    }

    /// Whether the config on disk can actually be read, as opposed to fallen back from.
    ///
    /// `loadConfig` answers a failed decode with the defaults, which is the right answer for
    /// a reader and a destructive one for a writer: anything that loads, mutates and saves
    /// would replace the operator's ledger with the defaults. A writer asks this first.
    static func addConfigIsReadable() -> Bool {
        guard let data = try? Data(contentsOf: configURL) else { return true }  // absent is fine
        return (try? JSONDecoder().decode(Config.self, from: data)) != nil
    }

    static func ensureConfigSeeded() {
        try? FileManager.default.createDirectory(at: gruxDir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        let cfg = Config(brands: defaultBrands)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cfg) {
            try? data.write(to: configURL, options: .atomic)
            WakeLog.shared.log("brandAttribution: seeded default config at \(configURL.path)")
        }
    }

    // Brand roster. EMPTY by default and deliberately so: which brands a
    // person works on is their own business, and shipping somebody else's
    // portfolio compiled into the binary is not a default. Add entries by hand
    // to ~/.grux/brand-attribution.json (schema at the top of this file) or
    // from a Settings panel. With no rules, attribution simply reports no
    // brands and puts all active time in unattributed.
    static let defaultBrands: [BrandRule] = []

    // MARK: - Repo discovery
    //
    // Walks each configured search root up to depth 5 and records every
    // directory that contains a .git. Reasonably fast on a warm cache
    // (sub-second), and the result is cached for the lifetime of a single
    // attribution pass. No root is assumed: with none configured this finds
    // nothing and the git component of the report is zero.

    static func discoverRepos(roots: [String]) -> [URL] {
        var found: [URL] = []
        for root in roots {
            let path = NSString(string: root.trimmingCharacters(in: .whitespacesAndNewlines))
                .expandingTildeInPath
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
            collectRepos(at: URL(fileURLWithPath: path), depth: 0, max: 5, into: &found)
        }
        return found
    }

    private static func collectRepos(
        at url: URL, depth: Int, max: Int, into out: inout [URL]
    ) {
        guard depth <= max else { return }
        let gitURL = url.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitURL.path) {
            out.append(url)
            return
        }
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return }
        for kid in kids {
            let isDir = (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let name = kid.lastPathComponent
            if name == "node_modules" || name == ".build" || name.hasPrefix(".") { continue }
            collectRepos(at: kid, depth: depth + 1, max: max, into: &out)
        }
    }

    // MARK: - Matching helpers

    static func matchScreenEvent(
        _ ev: ScreenTimeEvent, in brands: [BrandRule]
    ) -> String? {
        for brand in brands {
            if !ev.appBundle.isEmpty,
               brand.bundleIds.contains(where: { $0.caseInsensitiveCompare(ev.appBundle) == .orderedSame }) {
                return brand.name
            }
            if !ev.appName.isEmpty,
               brand.appNames.contains(where: { $0.caseInsensitiveCompare(ev.appName) == .orderedSame }) {
                return brand.name
            }
            let title = ev.windowTitle.lowercased()
            if !title.isEmpty,
               brand.titleSubstrings.contains(where: { title.contains($0.lowercased()) }) {
                return brand.name
            }
        }
        return nil
    }

    static func matchChromeEvent(
        _ ev: ChromeTabEvent, in brands: [BrandRule]
    ) -> String? {
        let domain = ev.domain.lowercased()
        let url = ev.url.lowercased()
        let title = ev.title.lowercased()
        for brand in brands {
            if !domain.isEmpty,
               brand.urlDomains.contains(where: { domain == $0.lowercased() || domain.hasSuffix("." + $0.lowercased()) }) {
                return brand.name
            }
            if !url.isEmpty,
               brand.urlSubstrings.contains(where: { url.contains($0.lowercased()) }) {
                return brand.name
            }
            if !title.isEmpty,
               brand.titleSubstrings.contains(where: { title.contains($0.lowercased()) }) {
                return brand.name
            }
        }
        return nil
    }

    static func matchRepoPath(
        _ repoURL: URL, in brands: [BrandRule]
    ) -> String? {
        // Require the needle to land on a path boundary so a short user-added
        // needle like "Acme" doesn't quietly match every repo with "Acme" in
        // some intermediate component (e.g. "Products-Acme-Archive"). The
        // boundary tests cover both interior segments and trailing repo dirs.
        let path = repoURL.path
        for brand in brands {
            for needle in brand.repoPaths where !needle.isEmpty {
                if path.contains("/" + needle + "/") || path.hasSuffix("/" + needle) {
                    return brand.name
                }
            }
        }
        return nil
    }

    // MARK: - Chrome bundles (used to know when to defer to chrome-tab data)

    static let chromeBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev"
    ]

    static func isChromeEvent(_ ev: ScreenTimeEvent) -> Bool {
        if chromeBundles.contains(ev.appBundle) { return true }
        let name = ev.appName.lowercased()
        return name == "google chrome" || name == "chrome"
    }

    // MARK: - Time math

    // Today as the half-open interval [startOfDay(now), now). Reports always
    // align to the user's current timezone so "today's hours" reads naturally.
    static func todaysWindow(now: Date = Date()) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        return (start, now)
    }

    // MARK: - Public entry point

    @discardableResult
    static func computeAndWriteToday(now: Date = Date()) -> DailyReport {
        let report = compute(for: now)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: outputURL(for: now), options: .atomic)
            WakeLog.shared.log("brandAttribution: wrote \(outputURL(for: now).lastPathComponent) (\(report.brands.count) brands, \(report.totalActiveSeconds / 60)m total)")
        } else {
            WakeLog.shared.log("brandAttribution: failed to encode daily report")
        }
        return report
    }

    static func compute(for now: Date = Date()) -> DailyReport {
        let cfg = loadConfig()
        let brands = cfg.brands
        let (start, end) = todaysWindow(now: now)

        // Pull every signal once.
        let screenEvents = ScreenTimeWatcher.loadEvents(between: start, and: end)
        let chromeEvents = ChromeTabWatcher.loadEvents(between: start, and: end)
        let repos = discoverRepos(roots: cfg.repoSearchRoots)

        // Bucket bookkeeping.
        var screenSeconds: [String: Int] = [:]
        var chromeSeconds: [String: Int] = [:]
        var gitCommits: [String: Int] = [:]
        var unattributed = 0
        var totalActive = 0

        // Index chrome events for fast nearest-in-time lookup. Sorted ascending
        // by ts (already sorted by ChromeTabWatcher.loadEvents). Window must
        // span the chrome poll interval, not the screen one: screen samples
        // tick every 10s but chrome ticks every 15s, so a screen sample can
        // sit up to ~15s away from the closest chrome event. Using the smaller
        // 10s window silently drops URL attribution for ~1 in 3 chrome
        // moments and the brand falls back to the generic "Chrome" bucket.
        let chromeTimes = chromeEvents.map { $0.ts.timeIntervalSince1970 }
        let window = ChromeTabWatcher.kSampleIntervalSeconds

        // Pass 1: screen time. Non-idle samples count for one screen-sample
        // worth of seconds. Chrome samples defer to the matching chrome-tab
        // event when one exists so the URL drives attribution.
        for ev in screenEvents where !ev.idle {
            totalActive += Int(ScreenTimeWatcher.kSampleIntervalSeconds)
            var brand: String?
            if isChromeEvent(ev), let near = nearestChrome(
                chromeEvents, times: chromeTimes,
                target: ev.ts, window: window) {
                brand = matchChromeEvent(near, in: brands)
                    ?? matchScreenEvent(ev, in: brands)
            } else {
                brand = matchScreenEvent(ev, in: brands)
            }
            if let b = brand {
                screenSeconds[b, default: 0] += Int(ScreenTimeWatcher.kSampleIntervalSeconds)
            } else {
                unattributed += Int(ScreenTimeWatcher.kSampleIntervalSeconds)
            }
        }

        // Pass 2: chrome dwell, reported separately so the dashboard can show
        // "of that screen time, X seconds were on brand websites". Does not
        // get added to total_seconds (already counted in screen pass when
        // Chrome was frontmost).
        for ev in chromeEvents {
            if let b = matchChromeEvent(ev, in: brands) {
                chromeSeconds[b, default: 0] += Int(ChromeTabWatcher.kSampleIntervalSeconds)
            }
        }

        // Pass 3: git commits authored today across known repos. Local-only,
        // so the search is bounded by the configured search roots, not a
        // network call.
        for repo in repos {
            guard let brand = matchRepoPath(repo, in: brands) else { continue }
            let count = commitCount(in: repo, since: start, until: end)
            if count > 0 {
                gitCommits[brand, default: 0] += count
            }
        }

        // Assemble final rows. Brands with any signal are included.
        var rows: [BrandBreakdown] = []
        let names = Set(screenSeconds.keys)
            .union(chromeSeconds.keys)
            .union(gitCommits.keys)
        for name in names {
            let scr = screenSeconds[name] ?? 0
            let chr = chromeSeconds[name] ?? 0
            let git = gitCommits[name] ?? 0
            // Total time uses screen seconds (the canonical wall-clock).
            // Chrome seconds are informational and already overlap with screen.
            let total = scr
            rows.append(BrandBreakdown(
                brand: name,
                screenSeconds: scr,
                chromeSeconds: chr,
                gitCommits: git,
                totalSeconds: total,
                totalHours: (Double(total) / 3600.0 * 100).rounded() / 100
            ))
        }
        rows.sort { $0.totalSeconds > $1.totalSeconds }

        let iso = ISO8601DateFormatter()
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"

        return DailyReport(
            date: df.string(from: now),
            generatedAt: iso.string(from: now),
            brands: rows,
            unattributedSeconds: unattributed,
            totalActiveSeconds: totalActive
        )
    }

    // Nearest chrome-tab event by binary search; returns nil if none lies
    // within +/- window seconds of target.
    private static func nearestChrome(
        _ events: [ChromeTabEvent],
        times: [TimeInterval],
        target: Date,
        window: TimeInterval
    ) -> ChromeTabEvent? {
        guard !events.isEmpty else { return nil }
        let t = target.timeIntervalSince1970
        var lo = 0
        var hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo, lo - 1, lo + 1]
            .filter { $0 >= 0 && $0 < events.count }
        var best: (event: ChromeTabEvent, delta: TimeInterval)?
        for i in candidates {
            let delta = abs(times[i] - t)
            if delta <= window {
                if best == nil || delta < best!.delta {
                    best = (events[i], delta)
                }
            }
        }
        return best?.event
    }

    // Commits authored in [since, until) by any author. Filtering by author
    // would only mask co-authored commits on a repo the user works on alone.
    // Uses git's @<unix-epoch> date form (supported since git 2.6) instead of
    // ISO 8601: approxidate parses ISO inconsistently across git versions,
    // particularly with fractional seconds, which can silently ignore --since
    // and return every commit in the repo.
    private static func commitCount(
        in repoURL: URL, since: Date, until: Date
    ) -> Int {
        let sinceStr = "@\(Int(since.timeIntervalSince1970))"
        let untilStr = "@\(Int(until.timeIntervalSince1970))"
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = [
            "git",
            "-C", repoURL.path,
            "log",
            "--since=\(sinceStr)",
            "--until=\(untilStr)",
            "--pretty=format:%H"
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return 0
        }
        proc.waitUntilExit()
        // Drain to avoid the pipe-full deadlock noted in NotificationWatcher.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: outData, encoding: .utf8) else { return 0 }
        return text
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .count
    }
}
