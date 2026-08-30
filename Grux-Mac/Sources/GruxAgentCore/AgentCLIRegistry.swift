import Foundation

// MARK: - AgentCLIRegistry
//
// Discovers which agent CLIs are installed on this machine and caches the
// result. Replaces the three duplicated resolveClaudeBinary()s scattered across
// the app (SwarmWorker, AccountSwitcher, TerminalFocusState) with one
// Foundation-only detector that every target can share.
//
// Detection is DATA, never an instruction to run: probing a CLI runs ONLY its
// version args (short, bounded) to confirm the binary exists and is the tool we
// expect. It never invokes the agent loop. Whether to then delegate work to a
// detected CLI is a separate, explicit decision made by the caller.
//
// Caching: an in-memory table with a TTL (default 24h) backed by a persisted
// JSON snapshot (default ~/.grux/agent-cli-cache.json) so a cold app launch
// does not re-probe every CLI. The snapshot + TTL math live in pure value types
// (AgentCLIProbe / AgentCLICacheSnapshot) so the expiry logic is unit-testable
// with no processes involved.

// One probe result for one adapter. Codable so it round-trips through the
// on-disk snapshot.
public struct AgentCLIProbe: Codable, Sendable, Equatable {
    public let adapterId: String
    // Resolved absolute path (or bare tool name) when found; nil = not present.
    public let executablePath: String?
    // First line of the version-probe output, for diagnostics. nil when the
    // CLI was not found or the probe produced nothing.
    public let version: String?
    public let probedAt: Date

    public init(adapterId: String, executablePath: String?, version: String?, probedAt: Date) {
        self.adapterId = adapterId
        self.executablePath = executablePath
        self.version = version
        self.probedAt = probedAt
    }

    public var isAvailable: Bool { executablePath != nil }

    // Pure TTL check: is this probe still trustworthy at `now`?
    public func isFresh(now: Date, ttl: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(probedAt)
        return age >= 0 && age < ttl
    }
}

// The persisted table: adapterId -> most recent probe.
public struct AgentCLICacheSnapshot: Codable, Sendable, Equatable {
    public var probes: [String: AgentCLIProbe]

    public init(probes: [String: AgentCLIProbe] = [:]) {
        self.probes = probes
    }

    // Fold a fresh probe in, replacing any prior entry for the same adapter.
    public mutating func record(_ probe: AgentCLIProbe) {
        probes[probe.adapterId] = probe
    }

    // The subset of adapter ids whose cached probe is still fresh at `now`.
    public func freshAdapterIDs(now: Date, ttl: TimeInterval) -> Set<String> {
        var out: Set<String> = []
        for (id, probe) in probes where probe.isFresh(now: now, ttl: ttl) {
            out.insert(id)
        }
        return out
    }
}

public actor AgentCLIRegistry {

    // The adapters this registry knows how to detect and drive.
    private let adapters: [any AgentAdapter]
    private let adaptersByID: [String: any AgentAdapter]

    // Where the snapshot persists. nil disables persistence (pure in-memory).
    private let cacheFileURL: URL?
    private let ttl: TimeInterval
    private let probeTimeout: TimeInterval
    private let environment: [String: String]
    // Injected clock so TTL expiry is testable without waiting real time.
    private let now: @Sendable () -> Date

    private var snapshot: AgentCLICacheSnapshot
    private var loadedFromDisk = false

    public static let defaultCacheFileURL: URL = {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("agent-cli-cache.json")
    }()

    // The full set of first-party adapters. This is the canonical roster the
    // app boots with.
    public static func defaultAdapters() -> [any AgentAdapter] {
        [
            ClaudeCodeAdapter(),
            CodexAdapter(),
            GeminiAdapter(),
            AiderAdapter()
        ]
    }

    public init(
        adapters: [any AgentAdapter] = AgentCLIRegistry.defaultAdapters(),
        cacheFileURL: URL? = AgentCLIRegistry.defaultCacheFileURL,
        ttl: TimeInterval = 24 * 60 * 60,
        probeTimeout: TimeInterval = 2,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapters = adapters
        var byID: [String: any AgentAdapter] = [:]
        for a in adapters { byID[a.id] = a }
        self.adaptersByID = byID
        self.cacheFileURL = cacheFileURL
        self.ttl = ttl
        self.probeTimeout = probeTimeout
        self.environment = environment
        self.now = now
        self.snapshot = AgentCLICacheSnapshot()
    }

    // MARK: - Public API

    public func adapter(id: String) -> (any AgentAdapter)? {
        adaptersByID[id]
    }

    public var knownAdapters: [any AgentAdapter] { adapters }

    // Detect every adapter, honoring the cache. Returns a probe per adapter
    // (present or absent). forceRefresh re-probes even fresh entries.
    @discardableResult
    public func detectAll(forceRefresh: Bool = false) async -> [AgentCLIProbe] {
        loadSnapshotIfNeeded()
        var results: [AgentCLIProbe] = []
        for adapter in adapters {
            results.append(await detect(adapter: adapter, forceRefresh: forceRefresh))
        }
        persistSnapshot()
        return results
    }

    // Detect one adapter by id. nil when the id is unknown to this registry.
    public func detect(adapterId: String, forceRefresh: Bool = false) async -> AgentCLIProbe? {
        guard let adapter = adaptersByID[adapterId] else { return nil }
        loadSnapshotIfNeeded()
        let probe = await detect(adapter: adapter, forceRefresh: forceRefresh)
        persistSnapshot()
        return probe
    }

    // The adapters that resolved to an installed binary (cache-honoring).
    public func availableAdapters(forceRefresh: Bool = false) async -> [any AgentAdapter] {
        let probes = await detectAll(forceRefresh: forceRefresh)
        let availableIDs = Set(probes.filter { $0.isAvailable }.map { $0.adapterId })
        return adapters.filter { availableIDs.contains($0.id) }
    }

    // MARK: - Detection core

    private func detect(adapter: any AgentAdapter, forceRefresh: Bool) async -> AgentCLIProbe {
        let clock = now()
        if !forceRefresh,
           let cached = snapshot.probes[adapter.id],
           cached.isFresh(now: clock, ttl: ttl) {
            return cached
        }
        let probe = await Self.probe(
            adapter: adapter,
            environment: environment,
            timeout: probeTimeout,
            now: clock
        )
        snapshot.record(probe)
        return probe
    }

    // Resolve the executable path for an adapter WITHOUT verifying it runs.
    // Used both by detection (as the path to verify) and by adapters at
    // buildInvocation time (best-effort, falls back to the bare tool name).
    public static func resolveExecutablePath(
        for detection: AdapterDetectionCandidates,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let fm = FileManager.default
        // 1. $<TOOL>_BIN override wins outright when it points at a real binary.
        if let override = environment[detection.envVar],
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return override
        }
        // 2. Fixed candidate paths in priority order.
        for raw in detection.candidatePaths {
            let expanded = (raw as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return expanded }
        }
        // 3. `which <tool>` on the (augmented) PATH.
        if let viaWhich = whichPath(for: detection.toolName, environment: environment) {
            return viaWhich
        }
        // 4. Give up on resolving; let /usr/bin/env sort it out at spawn time.
        return detection.toolName
    }

    // Run the version probe against a resolved path to confirm it is real.
    // Detection NEVER runs the agent loop: only `<path> <versionArgs>`.
    private static func probe(
        adapter: any AgentAdapter,
        environment: [String: String],
        timeout: TimeInterval,
        now: Date
    ) async -> AgentCLIProbe {
        let detection = adapter.detectionCandidates
        let fm = FileManager.default

        // Resolve a candidate path. Only a "/"-containing path can be probed by
        // Process directly; a bare tool name means unresolved -> not available.
        let resolved = resolveExecutablePath(for: detection, environment: environment)
        let hasConcretePath = resolved.contains("/") && fm.isExecutableFile(atPath: resolved)
        guard hasConcretePath else {
            return AgentCLIProbe(adapterId: adapter.id, executablePath: nil, version: nil, probedAt: now)
        }

        let version = runVersionProbe(
            executablePath: resolved,
            versionArgs: detection.versionArgs,
            environment: environment,
            timeout: timeout
        )
        // A binary that exists but whose probe produced nothing is still
        // considered present (some CLIs print version to stderr or exit non-0);
        // we record it as available with a nil version rather than hiding it.
        return AgentCLIProbe(adapterId: adapter.id, executablePath: resolved, version: version, probedAt: now)
    }

    // MARK: - OAuth-safe environment
    //
    // The single source of truth for the env-strip table that keeps a spawned
    // Claude CLI on the user's Claude.ai subscription (OAuth) instead of metered
    // API billing. Consolidates the identical list previously copy-pasted in
    // SwarmWorker, AccountSwitcher, and TerminalFocusState. Those three
    // resolvers can migrate to call this.
    public static func oauthSafeEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let stripKeys: Set<String> = [
            // Direct API key auth - top priority to remove.
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_API_TOKEN",
            "CLAUDE_API_KEY",
            "CLAUDE_AUTH_TOKEN",
            // Custom auth header / base URL overrides.
            "ANTHROPIC_AUTH_HEADER",
            "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_API_URL",
            // Cloud-provider auth alternatives that also bypass OAuth.
            "ANTHROPIC_BEDROCK_API_KEY",
            "ANTHROPIC_VERTEX_PROJECT_ID",
            "ANTHROPIC_VERTEX_REGION",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            // Claude Code parent-session detection: if set, the spawned claude
            // adopts the parent's auth/API mode. We want a fresh OAuth session.
            "CLAUDECODE",
            "CLAUDE_CODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_API_KEY",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
            "CLAUDE_CODE_SIMPLE",
            "CLAUDE_CODE_OAUTH_TOKEN"
        ]
        for k in stripKeys { env.removeValue(forKey: k) }
        env["NODE_NO_WARNINGS"] = "1"
        return env
    }

    // GUI apps inherit a bare launchd PATH; augment it so bare-name resolution
    // (via /usr/bin/env and `which`) finds Homebrew and user-local bins. Shared
    // by resolution and by AgentBridgeRunner's spawn.
    public static func augmentedPATH(base: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.bun/bin"
        ]
        let basePath = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (extraPaths + [basePath]).joined(separator: ":")
    }

    // MARK: - Persistence

    private func loadSnapshotIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let url = cacheFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.gruxCache.decode(AgentCLICacheSnapshot.self, from: data)
        else { return }
        snapshot = decoded
    }

    private func persistSnapshot() {
        guard let url = cacheFileURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.gruxCache.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Process helpers

    // Locate a tool via `which` using an augmented PATH. Bounded: `which` is a
    // trivial builtin/binary that returns immediately.
    private static func whichPath(for tool: String, environment: [String: String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", tool]
        var env = environment
        env["PATH"] = augmentedPATH(base: environment)
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? nil
        guard let data,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // Run `<path> <versionArgs>` with a hard timeout. Returns the first line of
    // output, or nil if the probe timed out or produced nothing usable. A
    // watchdog terminates the process if versionArgs unexpectedly hangs.
    private static func runVersionProbe(
        executablePath: String,
        versionArgs: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = versionArgs
        var env = environment
        env["PATH"] = augmentedPATH(base: environment)
        env["NODE_NO_WARNINGS"] = "1"
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Watchdog: version probes should finish in well under the timeout.
        // Terminate (then SIGKILL) if a misbehaving CLI wanders off. A
        // cancellable work item avoids a shared mutable flag: we cancel it once
        // the process exits; a terminate() that races an already-exited process
        // is a harmless no-op.
        let killer = DispatchQueue(label: "grux.cli-probe.watchdog")
        let watchdog = DispatchWorkItem {
            if proc.isRunning {
                proc.terminate()
                killer.asyncAfter(deadline: .now() + 1) {
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
            }
        }
        killer.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        let data = (try? out.fileHandleForReading.readToEnd()) ?? nil
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if let firstLine, !firstLine.isEmpty { return firstLine }
        return nil
    }
}

// Shared coders that keep the on-disk snapshot dates stable and readable.
private extension JSONEncoder {
    static let gruxCache: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let gruxCache: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
