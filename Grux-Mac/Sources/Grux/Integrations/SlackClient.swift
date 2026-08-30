import Foundation

// Minimal Slack Web API client for Grux.
//
// Design: BYO token, no OAuth server. The user creates their own Slack app
// once (https://api.slack.com/apps → "Create New App" → "From scratch"),
// adds the user-token scopes below, installs it in their workspace, and
// pastes the resulting "User OAuth Token" (xoxp-…) into Grux Settings.
// Token lives in macOS Keychain under .slackUserToken.
//
// Required user-token scopes (Omi precedent):
//   chat:write, channels:read, channels:history,
//   groups:read, users:read, search:read
//
// We use user tokens (xoxp) instead of bot tokens (xoxb) so posts appear
// as the human - matches how Omi ships and avoids the "a bot sent this"
// UX that makes personal workday-log summaries look off.
//
// Optional app-level token (xapp-…) unlocks Socket Mode for slash commands.
// See SlackSocketMode.swift for that path.

struct SlackChannel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let is_private: Bool?
    let is_archived: Bool?
    let is_member: Bool?

    var displayName: String {
        (is_private ?? false) ? "🔒 \(name)" : "#\(name)"
    }
}

enum SlackError: Error, LocalizedError {
    case missingToken
    case http(Int, String)
    case apiError(String)            // Slack returned ok=false with this error string
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "No Slack token. Paste your User OAuth Token in Settings → Integrations."
        case .http(let code, let body): return "Slack HTTP \(code): \(body.prefix(200))"
        case .apiError(let msg): return "Slack API: \(msg)"
        case .decoding(let msg): return "Slack decode: \(msg)"
        }
    }
}

actor SlackClient {
    static let shared = SlackClient()

    private let session: URLSession
    private var cachedChannels: [SlackChannel] = []
    private var channelsFetchedAt: Date?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Auth

    private func token() throws -> String {
        let t = KeychainStore.get(.slackUserToken).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw SlackError.missingToken }
        return t
    }

    // True if a token is present. Does NOT validate it's still good.
    nonisolated static func isConnected() -> Bool {
        !KeychainStore.get(.slackUserToken).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Verify (auth.test)

    struct AuthTestResult: Codable {
        let ok: Bool
        let error: String?
        let user: String?
        let team: String?
        let url: String?
    }

    func verify() async -> Result<AuthTestResult, SlackError> {
        do {
            let data = try await call(method: "auth.test", form: [:])
            let result = try JSONDecoder().decode(AuthTestResult.self, from: data)
            if result.ok {
                return .success(result)
            }
            return .failure(.apiError(result.error ?? "unknown"))
        } catch let e as SlackError {
            return .failure(e)
        } catch {
            return .failure(.apiError("\(error)"))
        }
    }

    // MARK: - Channels

    struct ChannelListResult: Codable {
        let ok: Bool
        let error: String?
        let channels: [SlackChannel]?
        let response_metadata: ResponseMeta?
        struct ResponseMeta: Codable { let next_cursor: String? }
    }

    // Refreshes the in-memory channel cache. Paginates until exhausted.
    // Bounded to 3 pages × 200 to keep memory sane for large workspaces.
    func refreshChannels() async throws -> [SlackChannel] {
        var all: [SlackChannel] = []
        var cursor: String = ""
        for _ in 0..<3 {
            var form: [String: String] = [
                "types": "public_channel,private_channel",
                "exclude_archived": "true",
                "limit": "200"
            ]
            if !cursor.isEmpty { form["cursor"] = cursor }
            let data = try await call(method: "conversations.list", form: form)
            let res = try JSONDecoder().decode(ChannelListResult.self, from: data)
            guard res.ok else { throw SlackError.apiError(res.error ?? "unknown") }
            all.append(contentsOf: res.channels ?? [])
            cursor = res.response_metadata?.next_cursor ?? ""
            if cursor.isEmpty { break }
        }
        cachedChannels = all.sorted { $0.name.lowercased() < $1.name.lowercased() }
        channelsFetchedAt = Date()
        return cachedChannels
    }

    // Returns cached channels if fresh (<5min), otherwise refreshes.
    func channels(forceRefresh: Bool = false) async throws -> [SlackChannel] {
        if !forceRefresh,
           let fetched = channelsFetchedAt,
           Date().timeIntervalSince(fetched) < 300,
           !cachedChannels.isEmpty {
            return cachedChannels
        }
        return try await refreshChannels()
    }

    // Resolve a channel name / #channel / ID into a channel ID. Case-insensitive.
    func resolveChannelID(_ needle: String) async throws -> String {
        let t = needle.trimmingCharacters(in: .whitespaces)
        // Already an ID? (C-prefix for public, G- for group/private, D- for IM)
        if t.hasPrefix("C") || t.hasPrefix("G") || t.hasPrefix("D"), t.count >= 9 {
            return t
        }
        let stripped = t.hasPrefix("#") ? String(t.dropFirst()) : t
        let list = try await channels()
        if let match = list.first(where: { $0.name.lowercased() == stripped.lowercased() }) {
            return match.id
        }
        // Fuzzy: substring
        if let match = list.first(where: { $0.name.lowercased().contains(stripped.lowercased()) }) {
            return match.id
        }
        throw SlackError.apiError("channel '\(needle)' not found (seen \(list.count))")
    }

    // MARK: - Send

    struct PostMessageResult: Codable {
        let ok: Bool
        let error: String?
        let ts: String?
        let channel: String?
    }

    // Send a plain-text message to a channel name or ID.
    @discardableResult
    func sendMessage(to channel: String, text: String) async throws -> PostMessageResult {
        let cid = try await resolveChannelID(channel)
        let payload: [String: Any] = [
            "channel": cid,
            "text": text,
            "unfurl_links": false,
            "unfurl_media": false
        ]
        let data = try await callJSON(method: "chat.postMessage", body: payload)
        let res = try JSONDecoder().decode(PostMessageResult.self, from: data)
        guard res.ok else { throw SlackError.apiError(res.error ?? "unknown") }
        return res
    }

    // MARK: - HTTP plumbing

    // application/x-www-form-urlencoded POST - Slack's classic shape.
    private func call(method: String, form: [String: String]) async throws -> Data {
        let tok = try token()
        guard let url = URL(string: "https://slack.com/api/\(method)") else {
            throw SlackError.apiError("bad method \(method)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        let body = form.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SlackError.http(http.statusCode, body)
        }
        return data
    }

    // application/json POST - required for chat.postMessage when you want
    // blocks / structured content. Slack accepts either shape for most endpoints.
    private func callJSON(method: String, body: [String: Any]) async throws -> Data {
        let tok = try token()
        guard let url = URL(string: "https://slack.com/api/\(method)") else {
            throw SlackError.apiError("bad method \(method)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw SlackError.http(http.statusCode, bodyStr)
        }
        return data
    }

    private func urlEncode(_ s: String) -> String {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&=?+")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }
}
