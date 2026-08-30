import Foundation

// Host-failover HTTP client for the companion social-ops service (port 3856).
// Mirrors PRDigestService's posture exactly: a base-URL precedence list, short
// timeouts, try each base in order, and throw a single typed error when none
// answer. The companion host owns the credentials vault, the per-brand browser
// sweep, and the operator-command executor; this client only reads state and
// posts commands or a sweep request.
//
// Base precedence: whatever hosts the user configured, in file order, then
// localhost (for when Grux runs on the same box as the service). NO host is
// compiled in: a private hostname or LAN address belongs to one network, not
// to the product. Not configuring anything is the shipped default and is a
// supported state; every call then fails with
// PrivateServiceNotice.socialOps.explanation, which SocialOpsSection renders in
// place of the empty grid.
//
// THE LOOPBACK ENTRY IS WHY THIS FILE NEEDED THE NOTICE AT ALL. baseURLs is
// never empty, so an unconfigured install still tries http://localhost:3856,
// still gets connection refused, and used to report exactly that: "no base URL
// reachable", or worse, the URLError text naming a port. A reader with no
// companion service was told about a socket. The notice tells them what the
// panel is for and that not having the service is normal.

enum SocialOpsService {
    // Configured hosts plus the local fallback. Recomputed per call so editing
    // the file takes effect without a relaunch.
    static var baseURLs: [String] { configuredHosts() + [loopbackBase] }
    private static let loopbackBase = "http://localhost:3856"

    // ~/.grux/social-ops-hosts.txt, one base URL per line. Blank lines and
    // lines starting with "#" are ignored. Absent file = no configured hosts.
    // Same plain-file convention as the bearer token below. Internal rather
    // than private because PrivateServiceNotice.socialOps.userConfigured
    // answers the same question from the same file and reads it through this
    // one parser (the authHeaders() precedent: one reader per ~/.grux file).
    static func configuredHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("social-ops-hosts.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // The raw secret. `authHeaders(for:)` below owns WHICH bases may receive
    // it; this reader only fetches it. Same shared secret PRInboxServer
    // mints at ~/.grux/pr-inbox-token.txt; the companion service reads the identical value
    // from its gitignored .env. Empty string when no token file exists yet
    // (loopback calls do not require it).
    private static func bearerToken() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grux", isDirectory: true)
            .appendingPathComponent("pr-inbox-token.txt")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // GET /api/social-ops/state -> full snapshot of every tracked cell.
    static func fetchState() async throws -> SocialOpsSnapshot {
        // The failover rule lives once in PrivateServiceFetch, and so does the
        // per-attempt HTTP shape. userConfigured excludes the compiled-in
        // loopback entry: only a host from ~/.grux/social-ops-hosts.txt
        // counts, so an untouched install still gets the notice when
        // localhost refuses, while a configured host that is down gets named.
        // ONE read of the hosts file feeds both arguments, so the base list
        // and the flag cannot disagree mid-edit.
        let configured = configuredHosts()
        return try await PrivateServiceFetch.run(
            service: "social operations service",
            bases: configured + [loopbackBase],
            userConfigured: !configured.isEmpty,
            absenceExplanation: PrivateServiceNotice.socialOps.explanation,
            attempt: PrivateServiceFetch.jsonAttempt(
                SocialOpsSnapshot.self,
                path: "/api/social-ops/state",
                headers: { authHeaders(for: $0) }
            )
        )
    }

    // POST /api/social-ops/command body {brand, platform, action}. Returns the
    // refreshed snapshot the companion service sends back so the caller can apply it without
    // a second round trip. Some companion builds return only an ack; in that case the
    // caller should follow with fetchState().
    @discardableResult
    static func sendCommand(brand: String, platform: SocialPlatform,
                            action: SocialOpAction) async throws -> SocialOpsSnapshot? {
        let payload: [String: Any] = [
            "brand": brand,
            "platform": platform.rawValue,
            "action": action.rawValue,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await post(path: "/api/social-ops/command", body: body)
        return try? JSONDecoder().decode(SocialOpsSnapshot.self, from: data)
    }

    // POST /api/social-ops/sweep -> run a sweep now. Fire and forget; the
    // companion service pushes the resulting change-events to Grux's inbox as cells flip.
    static func triggerSweep() async throws {
        _ = try await post(path: "/api/social-ops/sweep", body: Data("{}".utf8))
    }

    // MARK: - Shared POST with host failover

    // Kept off jsonAttempt but ON the throwing overload: callers treat the
    // response body as OPTIONAL (some companion builds answer a command with
    // the refreshed snapshot, others with a bare ack), so this returns raw
    // Data and lets each caller decode tolerantly, which a typed
    // jsonAttempt(T.self) cannot express. The catch arms (cancellation
    // rethrown, URLError as transport, anything else as answered) are the
    // overload's own, so this third home cannot fork them again.
    private static func post(path: String, body: Data) async throws -> Data {
        // A command that went nowhere is never "normal state", whatever the
        // config: absenceExplanation stays nil here, so a failed POST always
        // throws the technical form naming what was attempted and why each
        // base did not take it. ONE read of the hosts file feeds both
        // arguments, same rule as fetchState.
        let configured = configuredHosts()
        return try await PrivateServiceFetch.run(
            service: "social operations service (POST \(path))",
            bases: configured + [loopbackBase],
            userConfigured: !configured.isEmpty,
            absenceExplanation: nil
        ) { (base: URL) -> Data in
            guard let url = PrivateServiceFetch.join(base, path: path) else {
                throw URLError(.badURL)
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            applyAuth(&req, for: base)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ServiceError(message: "no HTTP response from \(base.absoluteString)")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ServiceError(message: "\(base.absoluteString) returned HTTP \(http.statusCode)")
            }
            return data
        }
    }

    // The hosts the companion service trusts WITHOUT a token, and therefore
    // the hosts Grux must not hand one to. server.py:296 checks the peer
    // address against exactly ("127.0.0.1", "::1", "::ffff:127.0.0.1") and
    // its test_loopback_is_trusted_without_token pins that, so this set is a
    // deliberate SUBSET of what the service trusts: "localhost" resolves to
    // one of those two, and both literals are listed there verbatim.
    //
    // BEING A SUBSET IS THE WHOLE SAFETY ARGUMENT. Withholding the token
    // from a host the service does NOT trust turns every POST into a 401,
    // so a wrong entry here breaks the feature rather than leaking anything.
    // 127.0.0.2 is deliberately absent for that reason: it is loopback to
    // the kernel but not to server.py's list, so it keeps the token.
    private static func isServiceTrustedLoopback(_ base: URL) -> Bool {
        // Brackets trimmed because URL.host has returned the IPv6 literal
        // both ways ("::1" and "[::1]") across Foundation versions, and a
        // host that reads one way on one toolchain and the other way on the
        // next would quietly start shipping the token to loopback again.
        let host = (base.host ?? "").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch host {
        case "localhost", "127.0.0.1", "::1": return true
        default: return false
        }
    }

    // The auth logic lives once: jsonAttempt call sites take the function,
    // the hand-rolled POST closure applies it to its own request. Internal
    // rather than private because BrandsPosterService reads the same
    // ~/.grux/pr-inbox-token.txt secret through this one helper.
    //
    // A FUNCTION OF THE BASE, NOT A STANDING DICTIONARY. The failover loop
    // walks a whole precedence list, so a dictionary computed once attached
    // the shared secret to every base it reached, loopback included. That
    // contradicted this file's own comment ("loopback calls do not require
    // it") and put the token on a socket any local process can bind when the
    // companion is not running. The service trusts loopback by peer address
    // and never reads the header there, so withholding it costs nothing and
    // is the behaviour the comment already claimed.
    //
    // A PLAIN-HTTP REMOTE BASE STILL GETS THE TOKEN, on purpose. The service
    // is HTTP-only on port 3856 and requires the bearer from every
    // non-loopback peer, so refusing there would 401 the documented
    // configuration rather than protect it. The exposure that remains is a
    // LAN or tunnel observer, which is a transport decision for the
    // deployment, not something this call site can fix by dropping a header.
    static func authHeaders(for base: URL) -> [String: String] {
        guard !isServiceTrustedLoopback(base) else { return [:] }
        let token = bearerToken()
        return token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"]
    }

    private static func applyAuth(_ req: inout URLRequest, for base: URL) {
        for (field, value) in authHeaders(for: base) {
            req.setValue(value, forHTTPHeaderField: field)
        }
    }
}
