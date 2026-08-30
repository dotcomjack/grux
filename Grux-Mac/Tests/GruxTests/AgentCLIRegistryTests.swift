import XCTest
import Foundation
@testable import GruxAgentCore

// Covers AgentCLIRegistry:
//   - pure TTL / freshness math (no processes)
//   - snapshot round-trip through an on-disk fixture cache file
//   - resolution priority ($TOOL_BIN, candidate paths, unresolved fallback)
//   - live detection against a fake candidate dir holding a stub executable
//     (a test fixture, NOT a real agent CLI, and only its version args run)
//   - fresh cache honored without re-probing; stale cache triggers a re-probe
//   - the OAuth-safe env-strip table
final class AgentCLIRegistryTests: XCTestCase {

    // MARK: - Fixtures

    private struct StubAdapter: AgentAdapter {
        let id: String
        let displayName: String
        let detectionCandidates: AdapterDetectionCandidates
        var capabilities: AdapterCapabilities {
            AdapterCapabilities(supportsResume: false, supportsStreamJSON: false, promptViaStdin: false)
        }
        func buildInvocation(prompt: String, cwd: String, model: String?, extraArgs: [String]) -> AdapterInvocation {
            AdapterInvocation(executablePath: "/bin/echo", args: [], env: [:], stdinPayload: nil, cwd: cwd)
        }
        func makeStreamParser() -> any AdapterStreamParsing { NoopParser() }
    }

    private final class NoopParser: AdapterStreamParsing {
        func parseChunk(_ chunk: String) -> (events: [AdapterEvent], remainder: String) { ([], "") }
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-cli-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Write an executable stub script that prints a version string.
    @discardableResult
    private func writeStub(named name: String, in dir: URL, prints version: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let script = "#!/bin/sh\necho '\(version)'\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Pure TTL / freshness

    func testProbeFreshnessTTL() {
        let now = Date()
        let recent = AgentCLIProbe(adapterId: "x", executablePath: "/bin/x", version: "1", probedAt: now.addingTimeInterval(-100))
        XCTAssertTrue(recent.isFresh(now: now, ttl: 200))
        XCTAssertFalse(recent.isFresh(now: now, ttl: 50))
        // A future-dated probe (clock skew) must not be treated as fresh.
        let future = AgentCLIProbe(adapterId: "x", executablePath: "/bin/x", version: "1", probedAt: now.addingTimeInterval(500))
        XCTAssertFalse(future.isFresh(now: now, ttl: 1000))
    }

    func testSnapshotFreshAdapterIDs() {
        let now = Date()
        var snap = AgentCLICacheSnapshot()
        snap.record(AgentCLIProbe(adapterId: "fresh", executablePath: "/x", version: nil, probedAt: now.addingTimeInterval(-10)))
        snap.record(AgentCLIProbe(adapterId: "stale", executablePath: "/y", version: nil, probedAt: now.addingTimeInterval(-1000)))
        let ids = snap.freshAdapterIDs(now: now, ttl: 100)
        XCTAssertEqual(ids, ["fresh"])
    }

    func testSnapshotRecordReplacesPriorEntry() {
        var snap = AgentCLICacheSnapshot()
        snap.record(AgentCLIProbe(adapterId: "a", executablePath: "/old", version: nil, probedAt: Date()))
        snap.record(AgentCLIProbe(adapterId: "a", executablePath: "/new", version: nil, probedAt: Date()))
        XCTAssertEqual(snap.probes.count, 1)
        XCTAssertEqual(snap.probes["a"]?.executablePath, "/new")
    }

    // MARK: - Resolution priority

    func testEnvVarOverrideResolvesFirst() {
        let detection = AdapterDetectionCandidates(
            toolName: "grux-not-a-real-tool-xyz",
            envVar: "MYTOOL_BIN",
            candidatePaths: [],
            versionArgs: ["--version"]
        )
        let resolved = AgentCLIRegistry.resolveExecutablePath(for: detection, environment: ["MYTOOL_BIN": "/bin/echo"])
        XCTAssertEqual(resolved, "/bin/echo")
    }

    func testUnresolvedToolFallsBackToBareName() {
        let detection = AdapterDetectionCandidates(
            toolName: "grux-nonexistent-tool-zzz",
            envVar: "ZZZ_BIN",
            candidatePaths: ["/nonexistent/zzz"],
            versionArgs: ["--version"]
        )
        // Empty env so the `which` fallback cannot find it either.
        let resolved = AgentCLIRegistry.resolveExecutablePath(for: detection, environment: [:])
        XCTAssertEqual(resolved, "grux-nonexistent-tool-zzz")
    }

    // MARK: - Live detection against a stub

    func testDetectFindsStubBinaryAndPersistsSnapshot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = try writeStub(named: "faketool", in: dir, prints: "faketool 9.9.9")
        let cacheURL = dir.appendingPathComponent("cache.json")

        let adapter = StubAdapter(
            id: "faketool",
            displayName: "Fake Tool",
            detectionCandidates: AdapterDetectionCandidates(
                toolName: "faketool",
                envVar: "FAKETOOL_BIN",
                candidatePaths: [stub.path],
                versionArgs: ["--version"]
            )
        )
        let registry = AgentCLIRegistry(
            adapters: [adapter],
            cacheFileURL: cacheURL,
            ttl: 3600,
            probeTimeout: 2,
            environment: [:],
            now: { Date() }
        )
        let probe = await registry.detect(adapterId: "faketool")
        XCTAssertNotNil(probe)
        XCTAssertTrue(probe!.isAvailable)
        XCTAssertEqual(probe!.executablePath, stub.path)
        XCTAssertEqual(probe!.version, "faketool 9.9.9")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "snapshot must persist")

        let available = await registry.availableAdapters()
        XCTAssertEqual(available.map(\.id), ["faketool"])
    }

    func testMissingToolReportsUnavailable() async throws {
        let adapter = StubAdapter(
            id: "ghosttool",
            displayName: "Ghost",
            detectionCandidates: AdapterDetectionCandidates(
                toolName: "grux-ghost-tool-nope",
                envVar: "GHOST_BIN",
                candidatePaths: ["/nonexistent/ghost"],
                versionArgs: ["--version"]
            )
        )
        let registry = AgentCLIRegistry(adapters: [adapter], cacheFileURL: nil, environment: [:])
        let probe = await registry.detect(adapterId: "ghosttool")
        XCTAssertNotNil(probe)
        XCTAssertFalse(probe!.isAvailable)
        XCTAssertNil(probe!.executablePath)
    }

    // MARK: - Cache honoring vs re-probe

    func testFreshCacheEntryIsReusedWithoutReprobing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("cache.json")
        let now = Date()

        // Seed a fresh cache entry pointing at a path that does NOT exist. If
        // the registry honored the cache it returns this bogus path; if it
        // re-probed it would find nothing and report unavailable.
        let cached = AgentCLIProbe(adapterId: "cachedtool", executablePath: "/cached/only/in/cache", version: "cached 1.0", probedAt: now)
        try writeSnapshot(AgentCLICacheSnapshot(probes: ["cachedtool": cached]), to: cacheURL)

        let adapter = StubAdapter(
            id: "cachedtool",
            displayName: "Cached",
            detectionCandidates: AdapterDetectionCandidates(
                toolName: "grux-cached-tool-nope",
                envVar: "CACHED_BIN",
                candidatePaths: ["/nonexistent/cached"],
                versionArgs: ["--version"]
            )
        )
        let registry = AgentCLIRegistry(adapters: [adapter], cacheFileURL: cacheURL, ttl: 3600, environment: [:], now: { now })
        let probe = await registry.detect(adapterId: "cachedtool")
        XCTAssertEqual(probe?.executablePath, "/cached/only/in/cache", "a fresh cache entry must be reused, not re-probed")
        XCTAssertEqual(probe?.version, "cached 1.0")
    }

    func testStaleCacheTriggersReprobe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("cache.json")
        let stub = try writeStub(named: "restale", in: dir, prints: "restale 2.0")
        let now = Date()

        // Cache entry is far older than the TTL -> must be discarded and the
        // real stub found instead.
        let stale = AgentCLIProbe(adapterId: "restale", executablePath: "/stale/cache/path", version: "old", probedAt: now.addingTimeInterval(-100_000))
        try writeSnapshot(AgentCLICacheSnapshot(probes: ["restale": stale]), to: cacheURL)

        let adapter = StubAdapter(
            id: "restale",
            displayName: "Restale",
            detectionCandidates: AdapterDetectionCandidates(
                toolName: "restale",
                envVar: "RESTALE_BIN",
                candidatePaths: [stub.path],
                versionArgs: ["--version"]
            )
        )
        let registry = AgentCLIRegistry(adapters: [adapter], cacheFileURL: cacheURL, ttl: 3600, environment: [:], now: { now })
        let probe = await registry.detect(adapterId: "restale")
        XCTAssertEqual(probe?.executablePath, stub.path, "a stale cache entry must be re-probed")
        XCTAssertEqual(probe?.version, "restale 2.0")
    }

    // MARK: - OAuth-safe environment

    func testOauthSafeEnvironmentStripsBillingKeys() {
        let base = [
            "ANTHROPIC_API_KEY": "redacted",
            "ANTHROPIC_BASE_URL": "https://example",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_OAUTH_TOKEN": "redacted",
            "PATH": "/usr/bin",
            "HOME": "/Users/x"
        ]
        let cleaned = AgentCLIRegistry.oauthSafeEnvironment(base: base)
        XCTAssertNil(cleaned["ANTHROPIC_API_KEY"])
        XCTAssertNil(cleaned["ANTHROPIC_BASE_URL"])
        XCTAssertNil(cleaned["CLAUDECODE"])
        XCTAssertNil(cleaned["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(cleaned["PATH"], "/usr/bin", "non-billing keys must survive")
        XCTAssertEqual(cleaned["HOME"], "/Users/x")
        XCTAssertEqual(cleaned["NODE_NO_WARNINGS"], "1")
    }

    func testDefaultAdaptersCoverTheFourCLIs() {
        let ids = Set(AgentCLIRegistry.defaultAdapters().map(\.id))
        XCTAssertEqual(ids, ["claude", "codex", "gemini", "aider"])
    }

    // MARK: - helpers

    private func writeSnapshot(_ snapshot: AgentCLICacheSnapshot, to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(snapshot).write(to: url, options: .atomic)
    }
}
