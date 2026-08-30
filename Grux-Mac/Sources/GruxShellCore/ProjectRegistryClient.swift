import Foundation

// MARK: - ProjectRegistryClient
//
// HTTP client for the projects orchestrator. Source of truth for the
// managed-projects registry. Tries each configured host in order, falls back to
// localhost:3847 (Grux running on the same box as the orchestrator, or a local
// dev instance), and finally to a JSON cache in Application Support so the
// Projects tab still renders while off-network.
//
// No host is compiled in. The remote list starts EMPTY, because it used to be
// one developer's own machine on his own private tailnet, which a stranger's
// install could never resolve.
//
// THE READER-FACING SENTENCE FOR AN EMPTY REGISTRY DOES NOT LIVE HERE, and it
// cannot: this file is in GruxShellCore, and the app target depends on the core
// rather than the other way round, so nothing here can see the app's copy. The
// one explanation is `PrivateServiceNotice.projectRegistry` in the Grux target,
// which reads `configuredBases` below as its own answer to "has anybody pointed
// this install anywhere". The Projects tab's empty state is
// `ProjectsView.emptyCopy`. Do not add a third sentence in this file: a message
// composed here would be the one string those two could not stay in step with.

public struct RemoteProject: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let slug: String
    public let rootPath: String
    public let healthUrl: String?
    public let repoUrl: String?
    public let dbUrl: String?
    public let status: String          // "active" | "paused" | ...
    public let lastHealth: RemoteHealth?
    public let tier: String?           // enriched server-side in newer builds; optional
}

public struct RemoteHealth: Codable, Sendable, Hashable {
    public let projectSlug: String?
    public let url: String?
    public let statusCode: Int?
    public let responseTimeMs: Int?
    public let healthy: Bool?
    public let checkedAt: String?
}

public struct RemoteHealthPoint: Codable, Sendable, Hashable {
    public let statusCode: Int?
    public let responseTimeMs: Int?
    public let healthy: Bool?
    public let checkedAt: String?
}

public struct RegistryFetchResult: Sendable {
    public let projects: [RemoteProject]
    public let source: Source
    public let fetchedAt: Date

    public enum Source: String, Sendable {
        case macMini, localhost, cache, empty
    }
}

public enum ProjectRegistryClient {

    // Remote orchestrator hosts, highest priority first, from
    // ~/.grux/projects-service.json:  {"bases": ["http://your-host:3847"]}
    // Empty until the user writes that file, which is the honest default: Grux
    // does not know where anybody else's orchestrator lives.
    public static var configuredBases: [String] { ProjectsServiceConfig.bases() }

    // localhost is always tried last, and is the sane fallback for the two
    // named accessors below so a UI line that prints one of them still names a
    // real address rather than an empty string.
    public static let localhostBase = "http://localhost:3847"
    public static var tailnetBase: String { configuredBases.first ?? localhostBase }
    public static var registryBase: String { configuredBases.first ?? localhostBase }

    // Ordered, de-duplicated list of every base worth trying, with the source
    // label to report on a hit. Never empty: localhost is always in it.
    private static func candidateBases() -> [(base: String, source: RegistryFetchResult.Source)] {
        var out: [(base: String, source: RegistryFetchResult.Source)] = []
        var seen = Set<String>()
        for base in configuredBases where seen.insert(base).inserted {
            out.append((base, .macMini))
        }
        if seen.insert(localhostBase).inserted { out.append((localhostBase, .localhost)) }
        return out
    }

    // Short timeouts - we race against a ~30s poll cadence and would rather
    // degrade to cached data than block the UI.
    private static let requestTimeout: TimeInterval = 2.0

    private static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects-cache.json")
    }

    public static func fetchProjects() async -> RegistryFetchResult {
        // Try each base URL in order. A host that refuses immediately loses
        // only the socket-connect RTT; a host that hangs is bounded by
        // requestTimeout so we don't stall the UI.
        for (base, src) in candidateBases() {
            if let projects = try? await getJSON([RemoteProject].self, "\(base)/api/projects") {
                // Persist the most recent successful fetch so offline reads
                // have something to display.
                persistCache(projects)
                return RegistryFetchResult(projects: projects, source: src, fetchedAt: Date())
            }
        }
        // Network failed - load whatever cache we have.
        if let cached = loadCache() {
            return RegistryFetchResult(projects: cached, source: .cache, fetchedAt: cacheMtime())
        }
        return RegistryFetchResult(projects: [], source: .empty, fetchedAt: Date())
    }

    public static func fetchHistory(slug: String) async -> [RemoteHealthPoint] {
        for (base, _) in candidateBases() {
            // History endpoint returns a wrapper: {project, slug, healthUrl, history:[...]}
            struct Wrapper: Codable { let history: [RemoteHealthPoint] }
            if let wrapper = try? await getJSON(Wrapper.self, "\(base)/api/projects/\(slug)/history") {
                return wrapper.history
            }
        }
        return []
    }

    public static func setStatus(id: String, active: Bool) async -> Bool {
        for (base, _) in candidateBases() {
            if await putJSON("\(base)/api/projects/\(id)/status",
                             body: ["status": active ? "active" : "paused"]) {
                return true
            }
        }
        return false
    }

    // MARK: - HTTP helpers

    private static func getJSON<T: Decodable>(_ type: T.Type, _ url: String) async throws -> T {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func putJSON(_ url: String, body: [String: String]) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u)
        req.httpMethod = "PUT"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch { /* fall through */ }
        return false
    }

    // MARK: - Cache

    private static func persistCache(_ projects: [RemoteProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func loadCache() -> [RemoteProject]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([RemoteProject].self, from: data)
    }

    private static func cacheMtime() -> Date {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)
            ?? Date.distantPast
    }
}

// MARK: - ProjectsServiceConfig
//
// Where the orchestrator lives, on disk rather than compiled in:
//
//   ~/.grux/projects-service.json   {"bases": ["http://your-host:3847"]}
//
// Missing file, unreadable JSON, and a blank entry all yield no remote host,
// which leaves localhost as the only candidate. That is the intended
// unconfigured state: the Projects tab reports an empty registry rather than
// failing, and nothing is ever sent to a host this install does not own.
public enum ProjectsServiceConfig {
    public static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("projects-service.json")
    }

    public static func bases() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["bases"] as? [String]
        else { return [] }
        // Trailing slashes stripped HERE because this target cannot import
        // PrivateServiceFetch.join, and the app-side notice probe does go
        // through it. A base written "http://mini:3847/" therefore probed
        // "/api/projects" and answered 200, standing the notice down, while
        // every real fetch concatenated "//api/projects", which a strict
        // router 404s: a permanently empty Projects tab with nothing on
        // screen explaining it. Normalising the list is what makes the two
        // paths ask the same question.
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { base -> String in
                var trimmed = base
                while trimmed.hasSuffix("/") { trimmed.removeLast() }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }
}
