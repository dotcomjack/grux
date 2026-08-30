import Foundation
import Security

// MARK: - CustomEndpoint

// A user-added OpenAI-compatible endpoint (OpenRouter, a vLLM farm, a remote
// Ollama box, a llama.cpp server). Persisted as JSON on disk WITHOUT the API
// key. The key lives in the macOS Keychain under a per-endpoint account name
// (service com.gruxai.grux, same as KeychainStore) so it never lands in a
// plaintext config file. `hasAPIKey` is a display marker only.
struct CustomEndpoint: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    // Normalized: no trailing slash, no trailing /v1. OpenAICompatBackend
    // appends /v1/chat/completions, so "https://openrouter.ai/api/v1" is
    // stored as "https://openrouter.ai/api".
    var baseURL: String
    var hasAPIKey: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, baseURL: String,
         hasAPIKey: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.hasAPIKey = hasAPIKey
        self.createdAt = createdAt
    }

    // Keychain account string for this endpoint's API key. Account names are
    // namespaced by UUID so endpoints never collide with each other or with
    // KeychainStore.Key entries.
    var keychainAccount: String { "customEndpoint.\(id.uuidString).apiKey" }
}

// MARK: - EndpointValidator

// Pure parsing + heuristics live here so they are unit-testable without any
// network. The single network call (checkReachability) is isolated and never
// runs inside tests.
enum EndpointValidator {

    // Normalize a candidate base URL: trim whitespace, strip trailing slashes
    // and a trailing /v1 segment (OpenAICompatBackend re-appends /v1 itself).
    // Returns nil when the input is not a usable http(s) URL with a host.
    static func normalizeBaseURL(_ raw: String) -> String? {
        var b = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return nil }
        while b.hasSuffix("/") { b.removeLast() }
        if b.lowercased().hasSuffix("/v1") {
            b.removeLast(3)
            while b.hasSuffix("/") { b.removeLast() }
        }
        guard let url = URL(string: b),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return b
    }

    // Human-readable parse problem for a candidate base URL. nil means the
    // URL parses cleanly (reachability is a separate, network-level check).
    static func parseIssue(_ raw: String) -> String? {
        let b = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { return "Base URL is empty." }
        let lower = b.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            return "Base URL must start with http:// or https://."
        }
        if normalizeBaseURL(b) == nil {
            return "Base URL is not a valid http(s) URL."
        }
        return nil
    }

    // Model families that are known to lack tool use (function calling) on
    // OpenAI-compatible servers, plus embedding-only models that are not chat
    // models at all. Matched against the family segment before the ":" tag.
    private static let noToolFamilies: [String] = [
        "gemma", "phi", "llava", "moondream", "tinyllama", "codellama",
        "vicuna", "starcoder", "stablelm", "orca-mini", "wizardcoder"
    ]

    // Said once so the picker hint and the catalog can never phrase it two ways.
    private static func noToolsMessage(_ tag: String) -> String {
        "\(tag) does not support tool use. Grux tools (screen, files, web, calendar) will not fire; replies will be text only."
    }

    // Incompatibility hint for a model tag, or nil when the model is expected
    // to handle Grux's tool-use loop. Pure, no IO, testable.
    //
    // THE CATALOG IS CONSULTED BEFORE THE HEURISTIC, because two shipped surfaces
    // were contradicting each other in the same window. Cookbook.catalog declares
    // gemma4:12b and gemma4:26b with supportsTools: true (sourced from the
    // published capability chips), while `noToolFamilies` carries "gemma" and the
    // family match is a prefix match, so "gemma4" matched "gemma". Settings
    // rendered "gemma4:12b does not support tool use" directly underneath a
    // picker offering a model the Cookbook recommends by name.
    //
    // A curated entry for an EXACT tag is evidence about that tag. The family
    // list is a guess about tags nobody has checked, which is still the right
    // answer for the long tail of models the catalog has never heard of, so it
    // stays as the fallback rather than being deleted.
    //
    // The embedding check runs ahead of both: an embedding model is not a chat
    // model at all, so "it supports tools" would be the wrong argument to have.
    static func toolUseHint(forModel tag: String) -> String? {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if t.contains("embed") || t.contains("minilm") || t.hasPrefix("bge-") {
            return "\(tag) is an embedding model, not a chat model. Pick a chat model for Grux."
        }
        if let known = Cookbook.catalog.first(where: { $0.id.lowercased() == t }) {
            return known.supportsTools ? nil : noToolsMessage(tag)
        }
        let family = t.split(separator: ":").first.map(String.init) ?? t
        for f in noToolFamilies where family == f || family.hasPrefix(f) {
            return noToolsMessage(tag)
        }
        return nil
    }

    // Outcome of a network reachability probe.
    enum Reachability: Equatable {
        case reachable(String)
        case unreachable(String)

        var ok: Bool {
            if case .reachable = self { return true }
            return false
        }

        var detail: String {
            switch self {
            case .reachable(let d), .unreachable(let d): return d
            }
        }
    }

    // GET {base}/v1/models with a short timeout. Any HTTP answer below 500 is
    // treated as reachable: a 401/403 means the server exists and wants a key,
    // which is fine to save (the key rides along on real chat calls). Only
    // transport errors and 5xx count as unreachable. HEAD is avoided because
    // many compat servers answer it with 405.
    static func checkReachability(baseURL: String, apiKey: String? = nil) async -> Reachability {
        guard let base = normalizeBaseURL(baseURL),
              let url = URL(string: "\(base)/v1/models")
        else { return .unreachable("invalid base URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 6
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: cfg)
        // Non-shared sessions must be invalidated or they leak their
        // connection pool and worker resources (Apple's documented contract).
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .unreachable("no HTTP response from \(base)")
            }
            if (200..<300).contains(http.statusCode) {
                return .reachable("endpoint reachable (HTTP \(http.statusCode))")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .reachable("endpoint reachable, auth required (HTTP \(http.statusCode)). Double check the API key.")
            }
            if http.statusCode < 500 {
                return .reachable("endpoint reachable (HTTP \(http.statusCode))")
            }
            return .unreachable("server error (HTTP \(http.statusCode))")
        } catch {
            return .unreachable("not reachable: \(error.localizedDescription)")
        }
    }
}

// MARK: - CustomEndpointStore

// Persistent registry of user-added OpenAI-compatible endpoints. Mirrors the
// FolderStore / InboxStore pattern: @MainActor singleton, @Published list,
// JSON on disk in Application Support with a debounced scheduleSave. API keys
// NEVER touch the JSON file; they live in the Keychain keyed per endpoint.
@MainActor
final class CustomEndpointStore: ObservableObject {
    static let shared = CustomEndpointStore()

    @Published private(set) var endpoints: [CustomEndpoint] = []

    private let fileURL: URL
    private var saveToken: DispatchWorkItem?

    // fileURL is injectable so tests can run against a temp file instead of
    // the real Application Support store.
    init(fileURL: URL = Persistence.supportDir.appendingPathComponent("custom-endpoints.json")) {
        self.fileURL = fileURL
        self.endpoints = Persistence.load([CustomEndpoint].self, from: fileURL, fallback: [])
    }

    // MARK: - CRUD

    // Add (or update, when the normalized base URL already exists) a custom
    // endpoint. The API key, when provided, is written to the Keychain and the
    // JSON record only carries the hasAPIKey marker. Returns nil when the base
    // URL fails parse-level validation.
    @discardableResult
    func add(name: String, baseURL: String, apiKey: String?) -> CustomEndpoint? {
        guard let base = EndpointValidator.normalizeBaseURL(baseURL) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? (URL(string: base)?.host ?? base) : trimmedName
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let idx = endpoints.firstIndex(where: { $0.baseURL == base }) {
            endpoints[idx].name = displayName
            if !key.isEmpty {
                _ = Self.keychainSet(account: endpoints[idx].keychainAccount, value: key)
                endpoints[idx].hasAPIKey = true
            }
            scheduleSave()
            return endpoints[idx]
        }

        var ep = CustomEndpoint(name: displayName, baseURL: base)
        if !key.isEmpty {
            _ = Self.keychainSet(account: ep.keychainAccount, value: key)
            ep.hasAPIKey = true
        }
        endpoints.append(ep)
        scheduleSave()
        return ep
    }

    // Remove an endpoint and delete its Keychain entry (no-op when no key was
    // ever stored; SecItemDelete treats item-not-found as success).
    func remove(id: UUID) {
        guard let idx = endpoints.firstIndex(where: { $0.id == id }) else { return }
        Self.keychainDelete(account: endpoints[idx].keychainAccount)
        endpoints.remove(at: idx)
        scheduleSave()
    }

    // The stored API key for an endpoint. Empty string means no key, matching
    // the KeychainStore.get contract so call sites stay branchless.
    func apiKey(for id: UUID) -> String {
        guard let ep = endpoints.first(where: { $0.id == id }) else { return "" }
        return Self.keychainGet(account: ep.keychainAccount)
    }

    func endpoint(id: UUID) -> CustomEndpoint? {
        endpoints.first(where: { $0.id == id })
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveToken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        saveToken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        objectWillChange.send()
    }

    // Internal (not private) so tests can flush the debounce synchronously.
    func saveNow() {
        Persistence.save(endpoints, to: fileURL)
    }
}

// MARK: - Keychain (per-endpoint API keys)

// Raw-account Keychain helpers mirroring KeychainStore's set/get/delete but
// keyed by an arbitrary account string instead of the fixed Key enum (enum
// cases can't be added from an extension). Same service, same accessibility,
// same never-crash error posture.
extension CustomEndpointStore {
    nonisolated static func keychainSet(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: account
        ]
        var findQuery = baseQuery
        findQuery[kSecReturnData as String] = false
        findQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let findStatus = KeychainStore.copyMatching(findQuery, nil)
        switch findStatus {
        case errSecSuccess:
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
            if updateStatus != errSecSuccess {
                NSLog("[CustomEndpointStore] keychain update \(account) returned OSStatus \(updateStatus)")
                return false
            }
            return true
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[CustomEndpointStore] keychain add \(account) returned OSStatus \(addStatus)")
                return false
            }
            return true
        default:
            NSLog("[CustomEndpointStore] keychain find \(account) returned OSStatus \(findStatus)")
            return false
        }
    }

    nonisolated static func keychainGet(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            // A read never prompts. See KeychainStore.neverPrompt for why.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = KeychainStore.copyMatching(query, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        case errSecItemNotFound:
            return ""
        default:
            NSLog("[CustomEndpointStore] keychain get \(account) returned OSStatus \(status)")
            return ""
        }
    }

    nonisolated static func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("[CustomEndpointStore] keychain delete \(account) returned OSStatus \(status)")
        }
    }
}

// MARK: - ModelRegistry validation surface

// Validation entry points hung off ModelRegistry so the Settings UI talks to
// one registry type for everything model-routing related. Parse-level check is
// nonisolated and pure; the reachability probe is async and main-actor like
// the rest of the registry.
extension ModelRegistry {
    // nil = the candidate base URL parses cleanly. Otherwise a human-readable
    // reason suitable for inline display next to the form field.
    nonisolated static func baseURLIssue(_ raw: String) -> String? {
        EndpointValidator.parseIssue(raw)
    }

    // Network probe used by the add-endpoint form before save. Reachable means
    // the server answered HTTP below 500 on GET {base}/v1/models.
    func validateEndpoint(baseURL: String, apiKey: String? = nil) async -> EndpointValidator.Reachability {
        await EndpointValidator.checkReachability(baseURL: baseURL, apiKey: apiKey)
    }
}
