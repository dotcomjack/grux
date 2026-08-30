import Foundation

// Shared transactional-email sender for the two email features (support
// triage replies + voice-drafted cold outreach). Talks to the Resend REST
// API (https://resend.com/docs/api-reference/emails/send-email) over plain
// URLSession, matching the no-third-party-HTTP convention the rest of Grux
// uses (Claude.swift, LocalLLM.swift, WebResearch.swift).
//
// Auth: the full-access Resend workspace key lives in the Keychain under
// `.resendApiKey` (service com.gruxai.grux). It never appears in source or a
// config file. Provision it once with:
//   security add-generic-password -U -s com.gruxai.grux -a resendApiKey -w <key>
//
// Nothing here sends on its own. Both callers stage a draft and require an
// explicit tap from the user before invoking send().
enum ResendError: Error, LocalizedError {
    case missingKey
    case http(Int, String)
    case noId
    case noRecipient
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Missing Resend API key. Provision it into the Grux keychain (account resendApiKey)."
        case .http(let code, let body): return "Resend HTTP \(code): \(body.prefix(240))"
        case .noId: return "Resend accepted the request but returned no message id."
        case .noRecipient: return "No recipient email address. Cannot send."
        case .notFound(let what): return "Not found: \(what)"
        }
    }
}

struct ResendSendResult {
    let id: String
}

actor ResendClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // Sends one email. `from` must be a verified-domain sender, e.g.
    // "Acme Support <support@acme.example>". `listUnsubscribe`
    // (when non-nil) is sent as the CAN-SPAM List-Unsubscribe header; cold
    // outreach always sets it, transactional support replies leave it nil.
    // `replyTo` and `inReplyTo` wire a support reply back onto its thread when
    // the source message id is known.
    @discardableResult
    func send(
        from: String,
        to: [String],
        subject: String,
        text: String,
        html: String? = nil,
        listUnsubscribe: String? = nil,
        replyTo: String? = nil,
        inReplyTo: String? = nil
    ) async throws -> ResendSendResult {
        // KeychainStore.get is nonisolated and thread-safe (SecItemCopyMatching),
        // so read it directly on this actor's executor; no main-thread hop.
        let key = KeychainStore.get(.resendApiKey)
        guard !key.isEmpty else { throw ResendError.missingKey }
        guard !to.filter({ $0.contains("@") }).isEmpty else { throw ResendError.noRecipient }

        var headers: [String: String] = [:]
        if let listUnsubscribe, !listUnsubscribe.isEmpty {
            headers["List-Unsubscribe"] = listUnsubscribe
            // RFC 8058: pairs with the mailto/https List-Unsubscribe so Gmail
            // and friends show a native one-click unsubscribe.
            headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
        }
        if let inReplyTo, !inReplyTo.isEmpty {
            headers["In-Reply-To"] = inReplyTo
            headers["References"] = inReplyTo
        }

        var body: [String: Any] = [
            "from": from,
            "to": to,
            "subject": DashSanitizer.clean(subject),
            "text": DashSanitizer.clean(text)
        ]
        // Branded HTML body (when supplied) so the email renders in the brand's
        // format; the plain text above stays the fallback for text-only clients.
        if let html, !html.isEmpty { body["html"] = html }
        if !headers.isEmpty { body["headers"] = headers }
        if let replyTo, !replyTo.isEmpty { body["reply_to"] = replyTo }

        var req = URLRequest(url: URL(string: "https://api.resend.com/emails")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ResendError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = obj["id"] as? String, !id.isEmpty
        else { throw ResendError.noId }
        return ResendSendResult(id: id)
    }
}

// Enforces the house copy rule: zero em dashes (U+2014) and zero en dashes
// (U+2013) in any copy the user will see. The LLM drafters are also told to avoid
// them in their system prompts, but models slip, so every outbound subject and
// body is scrubbed here as the last line of defense before Resend. Hyphens and
// minus signs (U+002D) are intentionally left alone.
enum DashSanitizer {
    static func clean(_ s: String) -> String {
        var out = s
        // Strip the two banned characters: em dash (U+2014) and en dash (U+2013).
        // A spaced dash (" X ") collapses to a comma+space; a bare one also becomes
        // a comma so we never leave a dangling double space. ASCII hyphen-minus
        // (U+002D) is deliberately untouched, so "2-pack" and "cruelty-free"
        // survive intact.
        for dash in ["\u{2014}", "\u{2013}"] {
            out = out.replacingOccurrences(of: " \(dash) ", with: ", ")
            out = out.replacingOccurrences(of: dash, with: ", ")
        }
        // Tidy any ", ," or doubled spaces the swaps may have produced.
        out = out.replacingOccurrences(of: ", ,", with: ",")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    // Chat-display variant: strip the two banned dashes WITHOUT the whitespace
    // tidy that clean() does. Assistant replies and the semantic-memory mirror
    // carry significant whitespace (code indentation, YAML, aligned columns), so
    // a blanket double-space collapse would silently corrupt them. A spaced dash
    // still collapses its own surrounding spaces into a comma, a bare dash
    // becomes a comma, and every run of spaces the model emitted is preserved.
    static func stripDashesOnly(_ s: String) -> String {
        var out = s
        for dash in ["\u{2014}", "\u{2013}"] {
            out = out.replacingOccurrences(of: " \(dash) ", with: ", ")
            out = out.replacingOccurrences(of: dash, with: ", ")
        }
        return out
    }
}
