import XCTest
@testable import Grux

// Phase 1 (Model Foundation) coverage. Pins the contract the seam relies on:
//   1. The two new GruxConfig fields decode with defaults from a legacy
//      config.json that predates them (decodeIfPresent migration safety).
//   2. The new fields round-trip through encode/decode unchanged.
//   3. Both backends conform to ModelBackend, the retroactive ClaudeClient
//      conformance and the concrete OpenAICompatBackend, so the registry seam
//      type-checks and either can be returned by active().
//   4. A fresh OpenAICompatBackend reports a zeroed usage snapshot (matches the
//      ClaudeClient last* caching pattern; local servers report 0 cache tokens).
final class ModelBackendTests: XCTestCase {

    // MARK: - Config migration

    func test_legacyConfigDecodes_withOfflineDefaults() throws {
        // A minimal pre-Phase-1 config.json: the required keys, none of the
        // new offline keys. decodeIfPresent must supply the documented defaults
        // rather than throwing (which would reset all of the user's settings).
        let legacy = """
        {
            "anthropicApiKey": "",
            "model": "claude-haiku-4-5-20251001",
            "captureIntervalSeconds": 30,
            "driftThreshold": 2,
            "autoPromoteDetectedTask": true,
            "notificationsEnabled": true,
            "screenAnalysisEnabled": true,
            "launchAtLogin": false,
            "snoozeMinutes": 15,
            "activeHoursStart": 6,
            "activeHoursEnd": 23
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GruxConfig.self, from: legacy)
        // Was "qwen3:8b". Changed deliberately: measured on Ollama's
        // OpenAI-compatible endpoint, qwen3 returns EMPTY content at ordinary
        // token budgets because the whole budget goes into its think block.
        // A legacy config must decode to a model that answers, not one that
        // hangs, so this asserts the shared constant rather than a literal.
        XCTAssertEqual(cfg.offlineLLMModel, GruxConfig.defaultLocalModel)
        XCTAssertEqual(cfg.ollamaBaseURL, "http://localhost:11434")
        // A pre-Phase-1 config has no offlineMode key: default false (start online).
        XCTAssertFalse(cfg.offlineMode)
    }

    func test_offlineFields_roundTrip() throws {
        var cfg = GruxConfig.default
        cfg.offlineLLMModel = "qwen2.5-coder"
        cfg.ollamaBaseURL = "http://192.168.1.50:11434"
        cfg.offlineMode = true
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(GruxConfig.self, from: data)
        XCTAssertEqual(decoded.offlineLLMModel, "qwen2.5-coder")
        XCTAssertEqual(decoded.ollamaBaseURL, "http://192.168.1.50:11434")
        // offlineMode now PERSISTS (opted in 2026-06-09): survives a restart.
        XCTAssertTrue(decoded.offlineMode)
    }

    // MARK: - Conformance

    func test_claudeClient_isModelBackend() {
        let backend: ModelBackend = ClaudeClient()
        XCTAssertNotNil(backend)
    }

    func test_openAICompatBackend_isModelBackend() {
        let backend: ModelBackend = OpenAICompatBackend(baseURL: "http://localhost:11434")
        XCTAssertNotNil(backend)
    }

    // MARK: - Usage snapshot baseline

    func test_openAICompatBackend_freshUsageSnapshotIsZero() async {
        let backend = OpenAICompatBackend(baseURL: "http://localhost:11434/v1/")
        let u = await backend.usageSnapshot()
        XCTAssertEqual(u.input, 0)
        XCTAssertEqual(u.output, 0)
        XCTAssertEqual(u.cacheCreate, 0)
        XCTAssertEqual(u.cacheRead, 0)
    }
}
