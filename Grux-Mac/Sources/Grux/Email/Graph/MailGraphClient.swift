import Foundation

// MailGraphClient: direct, headless access to Microsoft 365 mailboxes via the
// Microsoft Graph API. This is the real fix for reading a Microsoft 365 mailbox
// without a browser tab or IMAP: app-only OAuth2 (client-credentials) + admin
// consent means the token auto-refreshes and no human step is ever needed after
// the one-time Azure app registration.
//
// One Azure AD app (Mail.ReadWrite + Mail.Send, application permissions) covers
// EVERY mailbox in the tenant, so a single registration serves every address.
//
// Nothing here reaches a tenant until the user connects one. Every request in
// this actor takes a token first, so `accessToken` is the one gate, and it
// checks `endpoint.microsoft_graph` before it builds a URL. An install that has
// not connected gets that capability's remediation back as the error, which is
// what the mailbox logs when it falls through to reading the open tab instead.
//
// Auth:  POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
//        grant_type=client_credentials, scope=https://graph.microsoft.com/.default
// Read:  GET  https://graph.microsoft.com/v1.0/users/{mailbox}/mailFolders/inbox/messages
//
// The pure parsers (parseToken / mapMessages) are nonisolated + unit tested; the
// networking is a thin actor around them with a cached token.

actor MailGraphClient {
    struct Config: Sendable, Equatable {
        let tenantId: String
        let clientId: String
        let clientSecret: String
    }

    enum GraphError: LocalizedError {
        case notConnected
        case missingConfig
        case http(Int, String)
        case badResponse
        var errorDescription: String? {
            switch self {
            // The capability's own sentence, so a reader meets the same words
            // here, in the log, and on the setup card.
            case .notConnected: return SetupRequirement.endpointMicrosoftGraph.remediation
            case .missingConfig: return "Graph mail is not configured (tenant/client/secret)."
            case .http(let c, let m): return "Graph HTTP \(c): \(m.prefix(200))"
            case .badResponse: return "Graph returned an unexpected response."
            }
        }
    }

    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    // MARK: Token (client-credentials, cached until ~1 min before expiry)

    // Drop the cached token so the next call fetches a fresh one. Used after a
    // 401/403, e.g. when admin consent was granted AFTER we cached a token: the
    // cached one lacks the new roles, but a fresh fetch picks them up. This is
    // what lets Graph self-heal instead of needing an app restart.
    func invalidateToken() { cachedToken = nil; tokenExpiry = .distantPast }

    func accessToken(_ config: Config, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = cachedToken, Date() < tokenExpiry { return t }
        // Opt in gate, and it lives here rather than at the caller because every
        // Graph request in this actor takes a token first. Reaching a mailbox is
        // something the user sets up on purpose, so an install that has not is
        // refused before a URL exists, with the contract's own remediation.
        let connected = await MainActor.run {
            CapabilityResolver.isSatisfied(.endpointMicrosoftGraph)
        }
        guard connected else { throw GraphError.notConnected }
        // The passed-in Config is still checked on its own terms: the capability
        // answers "did the user connect a tenant", this answers "is the config
        // in my hand complete", and a caller can hand over either.
        guard !config.tenantId.isEmpty, !config.clientId.isEmpty, !config.clientSecret.isEmpty else {
            throw GraphError.missingConfig
        }
        var req = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(config.tenantId)/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id=\(Self.formEncode(config.clientId))",
            "scope=\(Self.formEncode("https://graph.microsoft.com/.default"))",
            "client_secret=\(Self.formEncode(config.clientSecret))",
            "grant_type=client_credentials"
        ].joined(separator: "&")
        req.httpBody = form.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GraphError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GraphError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let parsed = Self.parseToken(data) else { throw GraphError.badResponse }
        cachedToken = parsed.token
        // Refresh a minute early to avoid edge-of-expiry failures.
        tokenExpiry = Date().addingTimeInterval(Double(max(60, parsed.expiresIn - 60)))
        return parsed.token
    }

    // MARK: Read unread inbox messages -> InboxMessage (the triage's input type)

    func unread(mailbox: String, config: Config, limit: Int = 12) async throws -> [InboxMessage] {
        do {
            return try await fetchUnread(mailbox: mailbox, config: config, limit: limit, forceRefresh: false)
        } catch GraphError.http(let code, _) where code == 401 || code == 403 {
            // Token may be stale (e.g. consent granted after it was cached). Drop
            // it and retry ONCE with a fresh token, so Graph self-heals without a
            // restart. If the fresh token still 401/403s, it is a real permission
            // problem and the error propagates (caller falls back to the tab).
            invalidateToken()
            return try await fetchUnread(mailbox: mailbox, config: config, limit: limit, forceRefresh: true)
        }
    }

    private func fetchUnread(mailbox: String, config: Config, limit: Int, forceRefresh: Bool) async throws -> [InboxMessage] {
        let token = try await accessToken(config, forceRefresh: forceRefresh)
        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/users/\(mailbox)/mailFolders/inbox/messages")!
        comps.queryItems = [
            URLQueryItem(name: "$filter", value: "isRead eq false"),
            URLQueryItem(name: "$select", value: "id,subject,bodyPreview,from,body,internetMessageHeaders"),
            URLQueryItem(name: "$top", value: "\(limit)"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GraphError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GraphError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return Self.mapMessages(data)
    }

    // MARK: Pure parsers (nonisolated, unit tested)

    nonisolated static func parseToken(_ data: Data) -> (token: String, expiresIn: Int)? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = o["access_token"] as? String, !tok.isEmpty else { return nil }
        // expires_in may decode as Int or String depending on serialization.
        let exp = (o["expires_in"] as? Int) ?? Int((o["expires_in"] as? String) ?? "") ?? 3600
        return (tok, exp)
    }

    // Map a Graph /messages response to InboxMessage. Honest, structured fields:
    // sender name + address come straight from message.from.emailAddress, no
    // scraping or guessing.
    nonisolated static func mapMessages(_ data: Data) -> [InboxMessage] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = o["value"] as? [[String: Any]] else { return [] }
        var out: [InboxMessage] = []
        for m in arr {
            let from = (m["from"] as? [String: Any])?["emailAddress"] as? [String: Any]
            let name = (from?["name"] as? String) ?? ""
            let email = (from?["address"] as? String) ?? ""
            let subject = (m["subject"] as? String) ?? "(no subject)"
            let preview = (m["bodyPreview"] as? String) ?? ""
            let id = (m["id"] as? String) ?? ""
            guard !email.isEmpty else { continue }   // need a reply-to address
            // Full body (incl. quoted thread) so the drafter is thread-aware.
            // Graph returns HTML or text; normalize to text and cap.
            var body = ""
            if let b = m["body"] as? [String: Any], let content = b["content"] as? String {
                let isHTML = ((b["contentType"] as? String) ?? "").lowercased() == "html"
                body = String((isHTML ? htmlToText(content) : content).prefix(6000))
            }
            let (isBulk, isAuto) = parseHeaderFlags(m["internetMessageHeaders"])
            out.append(InboxMessage(
                fromName: name.isEmpty ? email : name,
                fromEmail: email,
                subject: subject.isEmpty ? "(no subject)" : subject,
                preview: preview,
                messageId: id,
                body: body.isEmpty ? nil : body,
                isBulk: isBulk,
                isAutoSubmitted: isAuto))
        }
        return out
    }

    // Parse the bulk / automated signals out of Graph's internetMessageHeaders
    // (an array of {name, value}). These are the most reliable "do not auto-reply
    // to this" signals: List-Unsubscribe and Precedence: bulk mark bulk/marketing
    // mail, and Auto-Submitted (anything other than "no") marks machine-generated
    // mail. Header names are case-insensitive per RFC. Returns (isBulk, isAuto).
    nonisolated static func parseHeaderFlags(_ raw: Any?) -> (isBulk: Bool, isAutoSubmitted: Bool) {
        guard let headers = raw as? [[String: Any]] else { return (false, false) }
        var isBulk = false
        var isAuto = false
        for h in headers {
            let name = ((h["name"] as? String) ?? "").lowercased()
            let value = ((h["value"] as? String) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            switch name {
            case "list-unsubscribe", "list-id":
                isBulk = true
            case "precedence":
                if value == "bulk" || value == "list" || value == "junk" { isBulk = true }
            case "auto-submitted":
                if !value.isEmpty && value != "no" { isAuto = true }
            case "x-auto-response-suppress":
                isAuto = true
            default:
                break
            }
        }
        return (isBulk, isAuto)
    }

    // Lightweight HTML -> text for email bodies (no dependency): drop style/script,
    // turn block tags + <br> into newlines, strip remaining tags, decode the
    // common entities, collapse runs of blank lines. Keeps the quoted thread text
    // (blockquotes) so the drafter can read the conversation history.
    nonisolated static func htmlToText(_ html: String) -> String {
        var s = html
        for (pat, rep) in [
            ("(?is)<(script|style)[^>]*>.*?</\\1>", " "),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|tr|li|blockquote|h[1-6])>", "\n"),
            ("(?i)<blockquote[^>]*>", "\n> "),
            ("<[^>]+>", "")
        ] {
            s = s.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&rsquo;": "'", "&mdash;": "-"]
        for (e, c) in entities { s = s.replacingOccurrences(of: e, with: c) }
        // collapse 3+ newlines to 2, trim trailing spaces per line
        s = s.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func formEncode(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }
}
