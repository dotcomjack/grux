import Foundation

// Thin client for a companion Lance vector store running on another machine.
// Mirrors that service's schema exactly: {id, source, ts, text, embedding,
// brand_hint}. Embeddings are computed on the service, so this side only
// sends/receives text + metadata.
//
// There is NO default host: the service is one the user stands up themselves,
// so an unconfigured install has nothing to point at and every call fails soft
// with .unreachable("not configured"). Callers already treat a failure as soft
// (surface "memory unavailable" rather than failing the parent feature), which
// is exactly the unconfigured experience.
//
//   defaults write com.gruxai.grux grux.services.ragBaseURL http://host:3850
public actor RAGClient {
    public struct Document: Codable, Sendable {
        public let id: String
        public let source: String
        public let ts: Int?
        public let text: String
        public let brandHint: String

        public init(id: String, source: String, text: String, ts: Int? = nil, brandHint: String = "") {
            self.id = id
            self.source = source
            self.ts = ts
            self.text = text
            self.brandHint = brandHint
        }

        enum CodingKeys: String, CodingKey {
            case id, source, ts, text
            case brandHint = "brand_hint"
        }
    }

    public struct Hit: Codable, Sendable {
        public let id: String
        public let source: String
        public let ts: Int
        public let text: String
        public let brandHint: String
        public let score: Double

        enum CodingKeys: String, CodingKey {
            case id, source, ts, text, score
            case brandHint = "brand_hint"
        }
    }

    public struct IndexResponse: Codable, Sendable {
        public let indexed: Int
        public let tableRows: Int

        enum CodingKeys: String, CodingKey {
            case indexed
            case tableRows = "table_rows"
        }
    }

    public struct QueryResponse: Codable, Sendable {
        public let q: String
        public let k: Int
        public let hits: [Hit]
    }

    public struct Health: Codable, Sendable {
        public let ok: Bool
        public let model: String
        public let rows: Int
    }

    public enum RAGError: Error, Sendable {
        case http(Int, String)
        case decode(String)
        case unreachable(String)
    }

    // UserDefaults key holding the service base URL. Empty (the default) means
    // the feature is not configured.
    public static let baseURLDefaultsKey = "grux.services.ragBaseURL"

    // nil when nothing is configured. Every request path checks this and throws
    // .unreachable rather than trapping on a force-unwrapped URL.
    private let baseURL: URL?
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // baseURL defaults to nil, meaning "resolve from config at call time".
    // Passing one explicitly (tests, a caller with its own endpoint) still works.
    public init(baseURL: URL? = nil,
                timeout: TimeInterval = 10) {
        self.baseURL = baseURL ?? RAGClient.configuredBaseURL()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func health() async throws -> Health {
        try await get(path: "healthz", as: Health.self)
    }

    public func index(_ docs: [Document]) async throws -> IndexResponse {
        try await post(path: "api/rag/index", body: docs, as: IndexResponse.self)
    }

    public func index(_ doc: Document) async throws -> IndexResponse {
        try await index([doc])
    }

    // The configured base URL, or nil when the user has not pointed Grux at a
    // service. Read at construction so a single client keeps one endpoint for
    // its lifetime.
    private static func configuredBaseURL() -> URL? {
        let raw = (UserDefaults.standard.string(forKey: baseURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    // Every request funnels through here, so "not configured" fails soft in one
    // place instead of trapping on a nil URL at six call sites.
    private func requireBase() throws -> URL {
        guard let baseURL else {
            throw RAGError.unreachable("memory service not configured (set \(RAGClient.baseURLDefaultsKey))")
        }
        return baseURL
    }

    public func query(_ q: String, k: Int = 10, source: String? = nil, brandHint: String? = nil) async throws -> QueryResponse {
        let queryURL = try requireBase().appendingPathComponent("api/rag/query")
        guard var comps = URLComponents(url: queryURL, resolvingAgainstBaseURL: false) else {
            throw RAGError.unreachable("could not parse query URL components for \(queryURL.absoluteString)")
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "k", value: String(k))
        ]
        if let source { items.append(URLQueryItem(name: "source", value: source)) }
        if let brandHint { items.append(URLQueryItem(name: "brand_hint", value: brandHint)) }
        comps.queryItems = items
        guard let url = comps.url else {
            throw RAGError.unreachable("could not build query URL for q=\(q)")
        }
        return try await getURL(url, as: QueryResponse.self)
    }

    private func get<T: Decodable>(path: String, as: T.Type) async throws -> T {
        let url = try requireBase().appendingPathComponent(path)
        return try await getURL(url, as: T.self)
    }

    private func getURL<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await send(req)
    }

    private func post<B: Encodable, T: Decodable>(path: String, body: B, as: T.Type) async throws -> T {
        let url = try requireBase().appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return try await send(req)
    }

    public func deleteDoc(id: String) async throws -> Int {
        let url = try requireBase().appendingPathComponent("api/rag/doc/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        struct R: Decodable { let table_rows: Int }
        let r: R = try await send(req)
        return r.table_rows
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw RAGError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RAGError.http(-1, "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RAGError.http(http.statusCode, body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RAGError.decode(error.localizedDescription)
        }
    }
}
