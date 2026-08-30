import Foundation

// MARK: - ProjectsIndex
//
// Unified view of the user's projects. Merges two sources:
//   1. Registry-managed projects (authoritative remote registry, HTTP)
//   2. Grux-scaffolded local projects (via `.grux/project.json` markers
//      written by IOSProjectGen, found by scanning a small set of roots)
//
// The same repo can exist in both sources - in that case the registry record
// wins for status/health, and the local marker adds a "last built / last
// screenshot / scheme" enrichment so the Projects tab can still show
// Grux-specific quick actions.

public struct ProjectEntry: Identifiable, Sendable, Hashable {
    public let id: String              // stable: registry slug OR "local:<absPath>"
    public let name: String
    public let rootPath: String
    public let origin: Origin
    public let remote: RemoteProject?        // nil for local-only
    public let local: LocalProjectMarker?

    public enum Origin: String, Sendable { case registryManaged, gruxScaffolded, both }

    public var displayTier: String {
        // The registry is the only source of a tier. There is deliberately no
        // built-in slug-to-tier table: which projects matter most is the
        // user's call, declared in their registry, not compiled in here.
        if let raw = remote?.tier, !raw.isEmpty { return raw }
        return origin == .gruxScaffolded ? "Grux" : "Tier 3"
    }

    public var healthPill: HealthPill {
        guard let h = remote?.lastHealth else {
            // Local-only Grux projects: we don't ping them, but they're
            // "OK" in the sense that the last scaffold/build succeeded.
            return origin == .gruxScaffolded ? .scaffolded : .unknown
        }
        if h.healthy == true { return .healthy(ms: h.responseTimeMs ?? 0) }
        if h.healthy == false { return .down(statusCode: h.statusCode ?? 0) }
        return .unknown
    }

    public enum HealthPill: Sendable, Hashable {
        case healthy(ms: Int)
        case down(statusCode: Int)
        case scaffolded
        case unknown
    }
}

// MARK: - Grux marker file
//
// Dropped at `<projectDir>/.grux/project.json` by IOSProjectGen.scaffold.
// Lightweight so multiple scaffolds/builds can update it without heavy
// serialization cost.

public struct LocalProjectMarker: Codable, Sendable, Hashable {
    public var projectName: String
    public var rootDir: String
    public var bundleId: String
    public var scheme: String
    public var xcodeprojPath: String
    public var kind: String                // "ios-app" for now
    public var features: [String]
    public var scaffoldedAt: Date
    public var lastBuildAt: Date?
    public var lastAppPath: String?
    public var lastScreenshotPath: String?

    public init(projectName: String, rootDir: String, bundleId: String,
                scheme: String, xcodeprojPath: String, kind: String = "ios-app",
                features: [String], scaffoldedAt: Date = Date(),
                lastBuildAt: Date? = nil, lastAppPath: String? = nil,
                lastScreenshotPath: String? = nil) {
        self.projectName = projectName
        self.rootDir = rootDir
        self.bundleId = bundleId
        self.scheme = scheme
        self.xcodeprojPath = xcodeprojPath
        self.kind = kind
        self.features = features
        self.scaffoldedAt = scaffoldedAt
        self.lastBuildAt = lastBuildAt
        self.lastAppPath = lastAppPath
        self.lastScreenshotPath = lastScreenshotPath
    }

    public static func path(for projectDir: String) -> String {
        (projectDir as NSString).appendingPathComponent(".grux/project.json")
    }

    public static func read(projectDir: String) -> LocalProjectMarker? {
        let p = path(for: projectDir)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LocalProjectMarker.self, from: data)
    }

    public func write() throws {
        let dir = (rootDir as NSString).appendingPathComponent(projectName)
        let gruxDir = (dir as NSString).appendingPathComponent(".grux")
        try FileManager.default.createDirectory(atPath: gruxDir, withIntermediateDirectories: true)
        let p = (gruxDir as NSString).appendingPathComponent("project.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    // Atomic update helper: read, mutate, write. Used by IOSSimulator to
    // record `lastScreenshotPath`, by IOSBuildVerify to record `lastBuildAt`
    // and `lastAppPath`, etc., without forcing callers to juggle JSON.
    public static func update(projectDir: String, _ mutate: (inout LocalProjectMarker) -> Void) {
        guard var m = read(projectDir: projectDir) else { return }
        mutate(&m)
        try? m.write()
    }
}

// MARK: - Index

public enum ProjectsIndex {

    public struct Snapshot: Sendable {
        public let entries: [ProjectEntry]
        public let registrySource: RegistryFetchResult.Source
        public let registryFetchedAt: Date
        public let fetchDurationMs: Int
    }

    // Scan targets for Grux-local projects. We keep this tight - deep
    // scans of iCloud Drive or node_modules would be a disaster - and bail
    // early on any dir that doesn't have a `.grux/project.json`.
    public static var scanRoots: [String] {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent("Projects"),
            (home as NSString).appendingPathComponent("Developer"),
            (home as NSString).appendingPathComponent("Sites"),
        ]
    }

    public static func snapshot() async -> Snapshot {
        let start = Date()
        // Kick off both sources in parallel - network fetch and disk scan
        // don't depend on each other.
        async let remote = ProjectRegistryClient.fetchProjects()
        let locals = scanLocal()
        let remoteResult = await remote

        // Index registry projects by rootPath for fast merge with locals.
        var byRoot: [String: RemoteProject] = [:]
        for p in remoteResult.projects {
            byRoot[normalize(p.rootPath)] = p
        }

        var entries: [ProjectEntry] = []

        // 1. Registry-managed projects (base set, always present).
        for p in remoteResult.projects {
            // If a local marker lives at this rootPath, mark origin=.both.
            let localMarker = LocalProjectMarker.read(projectDir: p.rootPath)
            entries.append(ProjectEntry(
                id: p.slug,
                name: p.name,
                rootPath: p.rootPath,
                origin: localMarker == nil ? .registryManaged : .both,
                remote: p,
                local: localMarker
            ))
        }

        // 2. Grux-scaffolded locals that aren't in the registry (yet).
        for m in locals where byRoot[normalize((m.rootDir as NSString).appendingPathComponent(m.projectName))] == nil {
            let dir = (m.rootDir as NSString).appendingPathComponent(m.projectName)
            entries.append(ProjectEntry(
                id: "local:\(dir)",
                name: m.projectName,
                rootPath: dir,
                origin: .gruxScaffolded,
                remote: nil,
                local: m
            ))
        }

        // Stable sort: Tier 1 → 2 → 3 → Grux; within tier, alphabetical.
        entries.sort { a, b in
            let ra = tierRank(a.displayTier), rb = tierRank(b.displayTier)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return Snapshot(
            entries: entries,
            registrySource: remoteResult.source,
            registryFetchedAt: remoteResult.fetchedAt,
            fetchDurationMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    // MARK: - Local disk scan

    // Find a marker by bundle id, scanning the same roots we use for the
    // Projects tab. Used by the simulator dispatcher - which only knows the
    // bundle_id, not the source tree - to record the latest screenshot on
    // the right project.
    public static func findByBundleId(_ bundleId: String) -> (dir: String, marker: LocalProjectMarker)? {
        let fm = FileManager.default
        for root in scanRoots {
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for child in children where !child.hasPrefix(".") {
                let dir = (root as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
                if let m = LocalProjectMarker.read(projectDir: dir), m.bundleId == bundleId {
                    return (dir, m)
                }
            }
        }
        return nil
    }

    private static func scanLocal() -> [LocalProjectMarker] {
        let fm = FileManager.default
        var out: [LocalProjectMarker] = []
        for root in scanRoots {
            guard fm.fileExists(atPath: root) else { continue }
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for child in children where !child.hasPrefix(".") {
                let dir = (root as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
                if let m = LocalProjectMarker.read(projectDir: dir) {
                    out.append(m)
                }
            }
        }
        return out
    }

    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func tierRank(_ t: String) -> Int {
        switch t {
        case "Tier 1": return 1
        case "Tier 2": return 2
        case "Tier 3": return 3
        case "Grux":   return 4
        default:       return 5
        }
    }
}
