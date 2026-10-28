import Foundation

/// The one way file text reaches a model: an Ollama server on THIS Mac, or
/// nothing.
///
/// Nothing in the router enforces "this Mac" on its own, which is why this
/// type exists and why it shares nothing with the router. Findings from
/// 2026-10-27 (recon, model.md) and the review of 2026-10-28:
///   - The ambient helper falls back to the routed cloud provider when its
///     local call fails, so it is never used here.
///   - The registry's local route sends to the backend discovery built, and
///     discovery runs only at launch and on a few toggles. Its backend stays
///     bound to the address discovery last saw: change the base URL from a
///     LAN Ollama to localhost and a check of the config passed while the
///     text still went to the LAN machine. So the backend here is built from
///     the address this file just checked, every time, and the model list is
///     read from that same server.
///   - `ModelRates.host` cut the address its own way: `http://evil.example#@localhost:11434`
///     read as localhost there and connects to evil.example. The check here
///     parses the address the way Foundation will for the request, and the
///     host it checked is the host the backend is given.
///   - An OpenAI-compatible server on loopback can be a proxy to anywhere,
///     so the server must answer Ollama's own `/api/version`.
/// With no route the feature does nothing and Settings says why. It never
/// falls back to anything else. `FileNamingRouteTests` reads this folder's
/// source and fails if it ever names a cloud route or the router's local
/// backend.
@MainActor
enum FileNamingRoute {

    struct Route {
        let backend: ModelBackend
        let model: String
        let apiKey: String
    }

    enum Resolution {
        case ok(Route)
        /// The configured server is not on this Mac.
        case notLoopback
        /// No Ollama on this Mac answered with a usable model.
        case noLocalModel

        /// The status `route` string.
        var statusName: String {
            switch self {
            case .ok: return "ok"
            case .notLoopback: return "notLoopback"
            case .noLocalModel: return "noLocalModel"
            }
        }

        var route: Route? {
            if case .ok(let r) = self { return r }
            return nil
        }
    }

    static func resolve() async -> Route? {
        await resolution().route
    }

    static func resolution() async -> Resolution {
        let cfg = AppState.shared.config
        guard let base = loopbackBase(cfg.ollamaBaseURL) else { return .notLoopback }
        guard let installed = await ollamaModels(at: base) else { return .noLocalModel }
        let usable = GruxConfig.usableLocalModels(installed)
        guard !usable.isEmpty else { return .noLocalModel }
        guard let model = pickModel(memoryGB: HardwareProfile.detect().physicalMemoryGB,
                                    installed: usable,
                                    fallback: cfg.offlineLLMModel) else { return .noLocalModel }
        return .ok(Route(backend: backend(for: base), model: model,
                         apiKey: ModelRegistry.compatKey(forBaseURL: base)))
    }

    /// Loopback only: localhost, 127.0.0.0/8 or ::1.
    nonisolated static func isAllowedServer(baseURL: String) -> Bool {
        loopbackBase(baseURL) != nil
    }

    /// `raw` as `scheme://host[:port]` when it names a server on this Mac,
    /// else nil. Parsed by `URL(string:)`, which is what builds the request
    /// URL, and refused when anything in it could make the two readings
    /// differ: a user or password, a query, a fragment, a path other than
    /// the `/v1` the base URL field allows, or a host that is not exactly
    /// `localhost`, `::1` or four decimal octets starting at 127. The result
    /// is read back the way the backend appends a path to it, and must give
    /// the same host and port.
    nonisolated static func loopbackBase(_ raw: String) -> String? {
        guard let normalized = EndpointValidator.normalizeBaseURL(raw),
              let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let host = hostOf(url), isLoopbackHost(host)
        else { return nil }
        let authority = host.contains(":") ? "[\(host)]" : host
        let base = "\(scheme)://\(authority)" + (url.port.map { ":\($0)" } ?? "")
        guard let request = URL(string: base + "/api/chat"),
              hostOf(request) == host, request.port == url.port,
              request.user == nil, request.fragment == nil, request.query == nil
        else { return nil }
        return base
    }

    /// The host Foundation will connect to, lowercased, IPv6 brackets off.
    nonisolated private static func hostOf(_ url: URL) -> String? {
        guard let raw = url.host, !raw.isEmpty else { return nil }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : host
    }

    /// `localhost`, `::1`, or `127.a.b.c` written as plain decimal octets.
    /// A leading zero, a short form such as `127.1` and a hex octet are
    /// refused: a resolver can read those differently.
    nonisolated static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy(\.isASCII) && octet.allSatisfy(\.isNumber)
                && !(octet.count > 1 && octet.first == "0") && (Int(octet) ?? 256) <= 255
        }
    }

    // MARK: - The server

    /// How long each question to the server may take. A server on this Mac
    /// answers at once or is not running.
    nonisolated static let probeTimeout: TimeInterval = 3

    /// The models installed on the Ollama at `base`, or nil when the server
    /// there is not Ollama or does not answer. Ollama is the server whose
    /// `GET /api/version` answers `{"version": "..."}`, the same check the
    /// backend makes before it sends anything to `/api/chat`.
    static func ollamaModels(at base: String) async -> [String]? {
        guard let versionURL = URL(string: base + "/api/version"),
              let tagsURL = URL(string: base + "/api/tags") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeout
        let session = URLSession(configuration: config)
        // A session of its own must be invalidated or it leaks its pool.
        defer { session.finishTasksAndInvalidate() }
        let auth = ModelRegistry.discoveryAuthorization(forBaseURL: base)
        func object(at url: URL) async -> [String: Any]? {
            var request = URLRequest(url: url)
            request.timeoutInterval = probeTimeout
            if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let version = await object(at: versionURL), version["version"] is String,
              let tags = await object(at: tagsURL), let models = tags["models"] as? [[String: Any]]
        else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// One backend per checked address, kept so its session and its "this is
    /// Ollama" answer are reused, as the registry does for its own.
    private static var backends: [String: OpenAICompatBackend] = [:]

    static func backend(for base: String) -> OpenAICompatBackend {
        if let cached = backends[base] { return cached }
        let backend = OpenAICompatBackend(baseURL: base)
        backends[base] = backend
        return backend
    }

    // MARK: - Which model

    /// Grux Local's published tags (README), one per memory tier.
    nonisolated static let gruxLocalPrefix = "gruxai.com/grux/grux-local:"

    /// The Grux Local size made for this Mac's memory: 8 GB class `2b`,
    /// 16 GB class `4b`, 24 GB and up `9b`. The same thresholds as
    /// `MemoryTier` and `LocalTurn.contextTokens`.
    nonisolated static func idealGruxLocalTag(memoryGB: Double) -> String {
        switch MemoryTier.tier(forMemoryGB: memoryGB) {
        case .ram8: return gruxLocalPrefix + "2b"
        case .ram16: return gruxLocalPrefix + "4b"
        default: return gruxLocalPrefix + "9b"
        }
    }

    /// The installed Grux Local for this Mac, else any installed Grux Local,
    /// else the chat model already configured. Using the chat model rather
    /// than pulling a second one keeps one model in memory, which is what
    /// fits beside chat on a 16 GB Mac.
    ///
    /// Both names count. Ollama lists a model pulled from the registry as
    /// `gruxai.com/grux/grux-local:4b` and one built or copied locally as
    /// `grux-local:4b`. Measured in a live run on the 16 GB test Mac (review
    /// 2026-10-28): its Ollama listed `grux-local:2b`, `:4b`, `:9b` and
    /// `:latest`, none matched the registry name, and the preview named files
    /// with the chat model, qwen3.5:4b, instead.
    ///
    /// Nil when nothing on the server qualifies. An Ollama `-cloud` tag is never
    /// picked: Ollama forwards those to its hosted service, so the file's text
    /// would leave the Mac through a loopback address (review 2026-10-28). The
    /// chat model is used only when the server actually holds it.
    nonisolated static func pickModel(memoryGB: Double, installed: [String], fallback: String) -> String? {
        let onThisMac = installed.filter { !isCloudTag($0) }
        let ideal = idealGruxLocalTag(memoryGB: memoryGB)
        if let hit = onThisMac.first(where: { sameTag($0, ideal) }) { return hit }
        if let any = onThisMac.first(where: { isGruxLocal($0) }) { return any }
        if !isCloudTag(fallback), let chat = onThisMac.first(where: { sameTag($0, fallback) }) { return chat }
        return nil
    }

    /// An Ollama tag served by Ollama's hosted service, not this Mac
    /// (`gpt-oss:120b-cloud`, `some-model:cloud`).
    nonisolated static func isCloudTag(_ tag: String) -> Bool {
        let t = tag.lowercased()
        return t.hasSuffix("-cloud") || t.hasSuffix(":cloud") || t.contains("-cloud:")
    }

    /// The same model, by either name and with or without `:latest`.
    nonisolated static func sameTag(_ reported: String, _ wanted: String) -> Bool {
        canonicalTag(reported) == canonicalTag(wanted)
    }

    /// Any size of Grux Local, by either name.
    nonisolated static func isGruxLocal(_ tag: String) -> Bool {
        let t = canonicalTag(tag)
        return t == "grux-local" || t.hasPrefix("grux-local:")
    }

    /// Lowercased, the registry host and namespace off, and a trailing
    /// `:latest` off: `gruxai.com/grux/grux-local:4b` and `grux-local:4b`
    /// are one model.
    nonisolated static func canonicalTag(_ tag: String) -> String {
        var t = tag.lowercased().trimmingCharacters(in: .whitespaces)
        let registry = "gruxai.com/grux/"
        if t.hasPrefix(registry) { t.removeFirst(registry.count) }
        if t.hasSuffix(":latest") { t.removeLast(":latest".count) }
        return t
    }
}
