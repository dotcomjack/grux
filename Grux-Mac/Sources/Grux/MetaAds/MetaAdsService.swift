import Foundation

// Network layer for the Meta Ads tab. Polls the always-on autonomous Meta Ads
// engine (PM2 + SQLite + tick loop), which the user runs on a machine of their
// own, following the TestDigestService precedent for where its address lives.
//
// SAFETY: setMode and setKill are control-plane writes, but the engine itself is
// the only place that can act live, and it is double-gated (a real bootstrapped
// ad account AND mode == AUTONOMOUS). An account left at act_PLACEHOLDER cannot
// spend a cent whatever mode is flipped here. The kill switch is fail-safe: it
// only ever pauses / blocks, never activates.

enum MetaAdsService {
    // Where the ads engine lives. EMPTY by default: the engine is one the user
    // runs on their own machine, so there is no host worth guessing, and an
    // unconfigured install reports "not configured" instead of hammering
    // somebody else's LAN. Comma or newline separated, tried in order.
    //   defaults write com.gruxai.grux grux.services.metaAdsBaseURLs "http://host:3857,http://localhost:3857"
    static let baseURLsDefaultsKey = "grux.services.metaAdsBaseURLs"

    static var baseURLs: [String] {
        (UserDefaults.standard.string(forKey: baseURLsDefaultsKey) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Read

    static func fetchLatest() async throws -> MetaAdsSnapshot {
        // The failover rule lives once in PrivateServiceFetch: an unconfigured
        // install (empty defaults key) gets the notice, a configured engine
        // that is down gets the technical form naming each base, and a 404
        // never aborts the remaining bases. The per-attempt HTTP shape lives
        // there too. ONE read of the defaults key feeds both arguments, so
        // the base list and the flag cannot disagree mid-edit.
        let bases = baseURLs
        return try await PrivateServiceFetch.run(
            service: "ads engine",
            bases: bases,
            userConfigured: !bases.isEmpty,
            absenceExplanation: PrivateServiceNotice.metaAds.explanation,
            // Surfaces only when a warm cache reclassifies this absence into
            // an outage (the user removed their key over a cached snapshot):
            // the generic zero-bases detail counted hosts nobody named, and
            // the actionable fact is which key went missing.
            unconfiguredDetail: "the defaults key \(baseURLsDefaultsKey) is not set",
            attempt: PrivateServiceFetch.jsonAttempt(
                MetaAdsSnapshot.self,
                path: "/api/meta-ads/snapshot",
                notFoundMessage: "engine has no snapshot yet (404); it builds on the first tick"
            )
        )
    }

    // MARK: - Control plane

    // Flip a brand's engine mode (OBSERVE / RECOMMEND / AUTONOMOUS). Returns the
    // fresh snapshot the engine echoes back so the UI updates immediately. The
    // engine still refuses to act live unless the account is bootstrapped, so
    // requesting AUTONOMOUS on an act_PLACEHOLDER account stays a no-op spend-wise.
    @discardableResult
    static func setMode(brand: String, mode: String) async throws -> MetaAdsSnapshot? {
        let body: [String: Any] = ["brand": brand, "mode": mode]
        return try await post(path: "/api/meta-ads/mode", body: body)
    }

    // Toggle the global kill switch. on == true pauses everything (fail-safe).
    @discardableResult
    static func setKill(on: Bool) async throws -> MetaAdsSnapshot? {
        let body: [String: Any] = ["on": on]
        return try await post(path: "/api/meta-ads/kill", body: body)
    }

    // MARK: - Power-tool override actions
    //
    // Each mirrors the setMode/setKill pattern: POST to /api/meta-ads/<verb> and
    // return the echoed snapshot so the UI reflects engine truth after the call.
    // All are NO-OPS spend-wise while the account is act_PLACEHOLDER (the engine is the
    // only thing that could act live, and it is double-gated on a bootstrapped
    // account AND AUTONOMOUS). The UI gates every one of these behind an explicit
    // confirm, so nothing fires on a single tap.

    // Approve the engine's pending move (the SuggestedAction on an attention item).
    @discardableResult
    static func approveMove(id: String) async throws -> MetaAdsSnapshot? {
        return try await post(path: "/api/meta-ads/approve", body: ["id": id])
    }

    // Veto the engine's pending move.
    @discardableResult
    static func vetoMove(id: String) async throws -> MetaAdsSnapshot? {
        return try await post(path: "/api/meta-ads/veto", body: ["id": id])
    }

    // Pause a single ad (lineage node) for a brand.
    @discardableResult
    static func pauseAd(brand: String, nodeId: String) async throws -> MetaAdsSnapshot? {
        return try await post(path: "/api/meta-ads/pause", body: ["brand": brand, "node_id": nodeId])
    }

    // Force-scale a single ad to a new daily budget (cents). Clamped to the cap
    // engine-side; in SIMULATE this is a recorded intent, not a spend.
    @discardableResult
    static func scaleAd(brand: String, nodeId: String, cents: Int) async throws -> MetaAdsSnapshot? {
        return try await post(path: "/api/meta-ads/scale", body: ["brand": brand, "node_id": nodeId, "param_cents": cents])
    }

    // Kill a single ad (move it to the graveyard).
    @discardableResult
    static func killAd(brand: String, nodeId: String) async throws -> MetaAdsSnapshot? {
        return try await post(path: "/api/meta-ads/kill-ad", body: ["brand": brand, "node_id": nodeId])
    }

    // Spawn a new A/B variant off a family by changing exactly ONE variable.
    @discardableResult
    static func spawnVariant(brand: String, crid: String, variable: String, value: String) async throws -> MetaAdsSnapshot? {
        let body: [String: Any] = ["brand": brand, "crid": crid, "variable": variable, "value": value]
        return try await post(path: "/api/meta-ads/spawn", body: body)
    }

    // MARK: - POST helper

    // Tries each base URL in precedence order. On a 2xx, decodes the echoed
    // snapshot when present (the engine may return the updated snapshot, or an
    // {"ok": true} ack with no body); a missing/undecodable body is not an error.
    // Kept off jsonAttempt but ON the throwing overload: the engine may answer
    // a command with the updated snapshot OR a bare {"ok": true} ack, so the
    // decode below is deliberately tolerant (a missing or unreadable body is
    // not a fault), which a typed jsonAttempt(T.self) cannot express. The
    // catch arms (cancellation rethrown, URLError as transport, anything else
    // as answered) are the overload's own, so this third home cannot fork
    // them again.
    private static func post(path: String, body: [String: Any]) async throws -> MetaAdsSnapshot? {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw ServiceError(message: "could not encode request body")
        }
        // ONE read of the defaults key feeds the guard and both arguments,
        // same rule as fetchLatest.
        let bases = baseURLs
        guard !bases.isEmpty else {
            throw ServiceError(message: "no ads engine host is configured; set the defaults key \(baseURLsDefaultsKey)")
        }
        // A control-plane write (kill, pause, veto, scale) that went nowhere is
        // never "normal state", whatever the config: absenceExplanation stays
        // nil here, so a failed command always throws the technical form naming
        // what was attempted and why each base did not take it.
        return try await PrivateServiceFetch.run(
            service: "ads engine (POST \(path))",
            bases: bases,
            userConfigured: !bases.isEmpty,
            absenceExplanation: nil
        ) { (base: URL) -> MetaAdsSnapshot? in
            guard let url = PrivateServiceFetch.join(base, path: path) else {
                throw URLError(.badURL)
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 12
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = payload
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ServiceError(message: "no HTTP response from \(base.absoluteString)")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ServiceError(message: "\(base.absoluteString) returned HTTP \(http.statusCode)")
            }
            // Best-effort decode of an echoed snapshot; ack-only responses are fine.
            return try? JSONDecoder().decode(MetaAdsSnapshot.self, from: data)
        }
    }
}
