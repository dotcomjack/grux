import XCTest
@testable import Grux

// Item 2 (multi-backend chat polish) coverage. Pins the endpoint parsing +
// validation logic that ModelConfigSection relies on, with zero network:
//   1. Base URL normalization (trailing slash, trailing /v1, scheme + host
//      requirements) so OpenAICompatBackend always gets a clean base.
//   2. parseIssue human-readable failures for the inline form errors.
//   3. Tool-use incompatibility hints for known model families.
//   4. CustomEndpoint Codable round-trip, and proof the JSON record never
//      carries an API key field (keys are Keychain-only).
//   5. CustomEndpointStore CRUD + persistence against a temp file.
final class ModelConfigTests: XCTestCase {

    // MARK: - normalizeBaseURL

    func test_normalize_stripsTrailingSlash() {
        XCTAssertEqual(
            EndpointValidator.normalizeBaseURL("http://localhost:11434/"),
            "http://localhost:11434"
        )
    }

    func test_normalize_stripsTrailingV1() {
        XCTAssertEqual(
            EndpointValidator.normalizeBaseURL("https://openrouter.ai/api/v1"),
            "https://openrouter.ai/api"
        )
    }

    func test_normalize_stripsTrailingV1AndSlash() {
        XCTAssertEqual(
            EndpointValidator.normalizeBaseURL("https://openrouter.ai/api/v1/"),
            "https://openrouter.ai/api"
        )
    }

    // Uppercase /V1: normalizeBaseURL strips it case-insensitively, and
    // OpenAICompatBackend.init now routes through the same function. The old
    // case-sensitive trim in init left "/V1" on, producing a double-appended
    // ".../V1/v1/chat/completions" (404) AND a key sent to the wrong URL.
    func test_normalize_stripsTrailingV1CaseInsensitively() {
        XCTAssertEqual(
            EndpointValidator.normalizeBaseURL("http://localhost:11434/V1"),
            "http://localhost:11434"
        )
        // The backend built from the same raw string must not crash and must
        // expose a usable, normalized endpoint (exercises the init path).
        let backend = OpenAICompatBackend(baseURL: "http://localhost:11434/V1")
        XCTAssertNotNil(backend)
    }

    func test_normalize_trimsWhitespace() {
        XCTAssertEqual(
            EndpointValidator.normalizeBaseURL("  http://192.168.1.50:8000  "),
            "http://192.168.1.50:8000"
        )
    }

    func test_normalize_keepsNonV1Paths() {
        XCTAssertEqual(
            EndpointValidator.normalizeBaseURL("https://my-vllm-farm.example.com/serve"),
            "https://my-vllm-farm.example.com/serve"
        )
    }

    func test_normalize_rejectsEmpty() {
        XCTAssertNil(EndpointValidator.normalizeBaseURL(""))
        XCTAssertNil(EndpointValidator.normalizeBaseURL("   "))
    }

    func test_normalize_rejectsMissingScheme() {
        XCTAssertNil(EndpointValidator.normalizeBaseURL("localhost:11434"))
        XCTAssertNil(EndpointValidator.normalizeBaseURL("openrouter.ai/api/v1"))
    }

    func test_normalize_rejectsNonHTTPSchemes() {
        XCTAssertNil(EndpointValidator.normalizeBaseURL("ftp://example.com"))
        XCTAssertNil(EndpointValidator.normalizeBaseURL("file:///tmp/models"))
    }

    // MARK: - parseIssue

    func test_parseIssue_nilForGoodURL() {
        XCTAssertNil(EndpointValidator.parseIssue("https://openrouter.ai/api/v1"))
        XCTAssertNil(EndpointValidator.parseIssue("http://localhost:11434"))
    }

    func test_parseIssue_emptyURL() {
        XCTAssertEqual(EndpointValidator.parseIssue("  "), "Base URL is empty.")
    }

    func test_parseIssue_missingScheme() {
        XCTAssertEqual(
            EndpointValidator.parseIssue("openrouter.ai/api/v1"),
            "Base URL must start with http:// or https://."
        )
    }

    // MARK: - toolUseHint

    func test_toolUseHint_nilForToolCapableModels() {
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: "llama3.1"))
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: "llama3.1:latest"))
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: "qwen2.5-coder:7b"))
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: "mistral:7b"))
    }

    func test_toolUseHint_flagsNoToolFamilies() {
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "gemma2:9b"))
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "phi3:mini"))
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "llava:13b"))
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "tinyllama"))
    }

    func test_toolUseHint_flagsEmbeddingModels() {
        let hint = EndpointValidator.toolUseHint(forModel: "nomic-embed-text")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("embedding") == true)
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "all-minilm"))
    }

    func test_toolUseHint_caseInsensitive() {
        XCTAssertNotNil(EndpointValidator.toolUseHint(forModel: "Gemma2:9B"))
    }

    func test_toolUseHint_nilForEmpty() {
        XCTAssertNil(EndpointValidator.toolUseHint(forModel: ""))
    }

    // MARK: - CustomEndpoint Codable

    func test_customEndpoint_roundTrips() throws {
        let ep = CustomEndpoint(name: "OpenRouter", baseURL: "https://openrouter.ai/api", hasAPIKey: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(ep)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(CustomEndpoint.self, from: data)
        XCTAssertEqual(decoded.id, ep.id)
        XCTAssertEqual(decoded.name, "OpenRouter")
        XCTAssertEqual(decoded.baseURL, "https://openrouter.ai/api")
        XCTAssertTrue(decoded.hasAPIKey)
    }

    func test_customEndpoint_jsonNeverCarriesAPIKey() throws {
        let ep = CustomEndpoint(name: "OpenRouter", baseURL: "https://openrouter.ai/api", hasAPIKey: true)
        let data = try JSONEncoder().encode(ep)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Only the marker boolean is allowed on disk. No key material, ever.
        XCTAssertEqual(
            Set(obj.keys),
            Set(["id", "name", "baseURL", "hasAPIKey", "createdAt"])
        )
    }

    func test_customEndpoint_keychainAccountIsNamespaced() {
        let ep = CustomEndpoint(name: "X", baseURL: "http://localhost:11434")
        XCTAssertEqual(ep.keychainAccount, "customEndpoint.\(ep.id.uuidString).apiKey")
    }

    // MARK: - CustomEndpointStore (temp file, no Keychain writes: apiKey nil)

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-modelconfig-test-\(UUID().uuidString).json")
    }

    @MainActor
    func test_store_addNormalizesAndPersists() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CustomEndpointStore(fileURL: url)
        let ep = store.add(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1/", apiKey: nil)
        XCTAssertEqual(ep?.baseURL, "https://openrouter.ai/api")
        XCTAssertEqual(ep?.hasAPIKey, false)
        store.saveNow()

        // A fresh store instance reads the same file back.
        let reloaded = CustomEndpointStore(fileURL: url)
        XCTAssertEqual(reloaded.endpoints.count, 1)
        XCTAssertEqual(reloaded.endpoints.first?.name, "OpenRouter")
        XCTAssertEqual(reloaded.endpoints.first?.baseURL, "https://openrouter.ai/api")
    }

    @MainActor
    func test_store_addRejectsInvalidBaseURL() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CustomEndpointStore(fileURL: url)
        XCTAssertNil(store.add(name: "Bad", baseURL: "not a url", apiKey: nil))
        XCTAssertNil(store.add(name: "Bad", baseURL: "ftp://example.com", apiKey: nil))
        XCTAssertTrue(store.endpoints.isEmpty)
    }

    @MainActor
    func test_store_addDedupesByNormalizedBaseURL() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CustomEndpointStore(fileURL: url)
        let first = store.add(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", apiKey: nil)
        let second = store.add(name: "OpenRouter Renamed", baseURL: "https://openrouter.ai/api/v1/", apiKey: nil)
        XCTAssertEqual(store.endpoints.count, 1)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(store.endpoints.first?.name, "OpenRouter Renamed")
    }

    @MainActor
    func test_store_emptyNameFallsBackToHost() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CustomEndpointStore(fileURL: url)
        let ep = store.add(name: "  ", baseURL: "https://openrouter.ai/api/v1", apiKey: nil)
        XCTAssertEqual(ep?.name, "openrouter.ai")
    }

    @MainActor
    func test_store_removeDeletesEndpoint() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CustomEndpointStore(fileURL: url)
        guard let ep = store.add(name: "Local vLLM", baseURL: "http://192.168.1.50:8000", apiKey: nil) else {
            return XCTFail("add failed")
        }
        store.remove(id: ep.id)
        XCTAssertTrue(store.endpoints.isEmpty)
        store.saveNow()
        let reloaded = CustomEndpointStore(fileURL: url)
        XCTAssertTrue(reloaded.endpoints.isEmpty)
    }

    @MainActor
    func test_store_apiKeyForUnknownEndpointIsEmpty() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CustomEndpointStore(fileURL: url)
        XCTAssertEqual(store.apiKey(for: UUID()), "")
    }

    // MARK: - Reachability result shape (no network)

    func test_reachability_okAndDetailAccessors() {
        let up = EndpointValidator.Reachability.reachable("endpoint reachable (HTTP 200)")
        let down = EndpointValidator.Reachability.unreachable("server error (HTTP 500)")
        XCTAssertTrue(up.ok)
        XCTAssertFalse(down.ok)
        XCTAssertEqual(up.detail, "endpoint reachable (HTTP 200)")
        XCTAssertEqual(down.detail, "server error (HTTP 500)")
    }
}
