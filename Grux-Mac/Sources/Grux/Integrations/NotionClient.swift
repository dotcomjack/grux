import Foundation

// Minimal Notion API client for Grux.
//
// Design: BYO Internal Integration token (ntn_…). The user creates an
// integration at https://www.notion.so/my-integrations, copies the secret,
// shares the target page/database with the integration, and pastes both
// the token and database ID into Grux Settings → Integrations.
//
// This avoids OAuth entirely - Omi ships OAuth because they're a cloud
// service with a backend to hold the client secret. For a local-first
// macOS app, Internal Integration + token-paste is the recommended path
// (Notion's own docs call this out).
//
// Keys:
//   KeychainStore.notionToken        → ntn_… secret
//   KeychainStore.notionDatabaseId   → target database UUID (no dashes ok)
//
// API version pinned to 2022-06-28 (same as Omi).

enum NotionError: Error, LocalizedError {
    case missingToken
    case missingDatabase
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:    return "No Notion token. Paste your Internal Integration secret in Settings → Integrations."
        case .missingDatabase: return "No Notion database ID. Paste one in Settings → Integrations after sharing a page with the integration."
        case .http(let code, let body): return "Notion HTTP \(code): \(body.prefix(200))"
        case .decoding(let msg): return "Notion decode: \(msg)"
        }
    }
}

actor NotionClient {
    static let shared = NotionClient()

    private let session: URLSession
    private static let apiVersion = "2022-06-28"

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Auth state

    nonisolated static func isConnected() -> Bool {
        let t = KeychainStore.get(.notionToken).trimmingCharacters(in: .whitespacesAndNewlines)
        let d = KeychainStore.get(.notionDatabaseId).trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !d.isEmpty
    }

    private func token() throws -> String {
        let t = KeychainStore.get(.notionToken).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw NotionError.missingToken }
        return t
    }

    private func databaseID() throws -> String {
        let d = KeychainStore.get(.notionDatabaseId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { throw NotionError.missingDatabase }
        return d
    }

    // MARK: - Verify (users/me)

    struct UserMe: Codable {
        let id: String
        let name: String?
        let type: String?
    }

    func verify() async -> Result<UserMe, NotionError> {
        do {
            let data = try await call(method: "GET", path: "users/me", body: nil)
            let me = try JSONDecoder().decode(UserMe.self, from: data)
            return .success(me)
        } catch let e as NotionError {
            return .failure(e)
        } catch {
            return .failure(.http(0, "\(error)"))
        }
    }

    // MARK: - Databases

    struct DatabaseInfo {
        let id: String
        let title: String
    }

    // Search all databases the integration can see. Useful for populating
    // a picker in the Integrations UI.
    func listDatabases() async throws -> [DatabaseInfo] {
        let payload: [String: Any] = [
            "filter": ["value": "database", "property": "object"],
            "page_size": 50
        ]
        let data = try await call(method: "POST", path: "search", body: payload)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw NotionError.decoding("search results shape")
        }
        var out: [DatabaseInfo] = []
        for row in results {
            guard let id = row["id"] as? String else { continue }
            let titleArr = (row["title"] as? [[String: Any]]) ?? []
            let title = titleArr.compactMap { ($0["plain_text"] as? String) }.joined()
            out.append(DatabaseInfo(id: id, title: title.isEmpty ? "(untitled)" : title))
        }
        return out
    }

    // MARK: - Push a page into the configured database
    //
    // Schema expected on the database:
    //   • `Name` or `Title`  (title) - we'll detect which via property name
    //   • any other properties are optional
    // We accept title + optional rich metadata and render the body as a
    // sequence of paragraph blocks.

    @discardableResult
    func createPage(title: String, bodyParagraphs: [String], properties: [String: Any] = [:]) async throws -> String {
        let dbID = try databaseID()

        // Build title property - Notion requires a rich_text array.
        // The title-property NAME differs per user: most templates use "Name",
        // some use "Title". We write the same value to whichever is configured
        // by sending both keys - Notion will 400 on whichever doesn't exist
        // on the DB, so we first retrieve the DB schema to pick the right key.
        let titleKey = try await titlePropertyKey(databaseID: dbID)

        var props: [String: Any] = properties
        props[titleKey] = [
            "title": [
                ["text": ["content": title.isEmpty ? "(untitled)" : title]]
            ]
        ]

        // Children blocks - one paragraph per line, keeping under Notion's
        // 100-block limit per request (we chunk if needed below).
        let firstBatch = Array(bodyParagraphs.prefix(95))
        let children: [[String: Any]] = firstBatch.map { para in
            [
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["type": "text", "text": ["content": String(para.prefix(1_900))]]]
                ]
            ]
        }

        let payload: [String: Any] = [
            "parent": ["database_id": dbID],
            "properties": props,
            "children": children
        ]
        let data = try await call(method: "POST", path: "pages", body: payload)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageID = json["id"] as? String else {
            throw NotionError.decoding("no page id in response")
        }

        // Overflow paragraphs via append.
        if bodyParagraphs.count > 95 {
            let rest = Array(bodyParagraphs.dropFirst(95))
            for chunk in stride(from: 0, to: rest.count, by: 95).map({ Array(rest[$0..<min($0+95, rest.count)]) }) {
                let blocks: [[String: Any]] = chunk.map { para in
                    [
                        "object": "block",
                        "type": "paragraph",
                        "paragraph": [
                            "rich_text": [["type": "text", "text": ["content": String(para.prefix(1_900))]]]
                        ]
                    ]
                }
                _ = try await call(
                    method: "PATCH",
                    path: "blocks/\(pageID)/children",
                    body: ["children": blocks]
                )
            }
        }

        return pageID
    }

    // Reads the DB schema once and returns the name of the title property.
    // Falls back to "Name" if we can't determine it.
    private var cachedTitleKey: [String: String] = [:]
    private func titlePropertyKey(databaseID: String) async throws -> String {
        if let cached = cachedTitleKey[databaseID] { return cached }
        let data = try await call(method: "GET", path: "databases/\(databaseID)", body: nil)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = json["properties"] as? [String: Any] else {
            return "Name"
        }
        for (key, raw) in props {
            if let dict = raw as? [String: Any], (dict["type"] as? String) == "title" {
                cachedTitleKey[databaseID] = key
                return key
            }
        }
        cachedTitleKey[databaseID] = "Name"
        return "Name"
    }

    // MARK: - HTTP

    private func call(method: String, path: String, body: [String: Any]?) async throws -> Data {
        let tok = try token()
        guard let url = URL(string: "https://api.notion.com/v1/\(path)") else {
            throw NotionError.http(0, "bad path")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let s = String(data: data, encoding: .utf8) ?? ""
            throw NotionError.http(http.statusCode, s)
        }
        return data
    }
}
