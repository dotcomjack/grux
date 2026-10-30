import Foundation

/// The Claude models the Chat picker offers: the newest of each family the
/// person's key can reach, read from Anthropic's Models API.
///
/// WAS a literal list in ChatView, and a literal list is stale the day the next
/// model ships. Measured 2026-10-29: the picker offered Fable 5, Opus 4.8,
/// Sonnet 5 and Haiku 4.5 while the API listed Fable 5.1, Opus 5.5, Sonnet 5.5
/// and Haiku 5.5. The list is now asked for, once a launch, and the last good
/// answer is kept for the next launch, so the picker is current with no
/// release and still full offline or without a key.
@MainActor
final class ClaudeModelCatalog: ObservableObject {
    static let shared = ClaudeModelCatalog()

    /// What the picker shows before the API has answered once: the newest of
    /// each family on 2026-10-29.
    static let fallback = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    /// The families the picker offers, in the order it shows them. Others the
    /// API may list (a research-only family) are left out.
    static let families = ["fable", "opus", "sonnet", "haiku"]

    static let defaultsKey = "grux.claudeModelCatalog"

    @Published private(set) var ids: [String]

    private let defaults: UserDefaults
    private let session: URLSession
    private var fetched = false
    private var fetching = false

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        let saved = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        ids = saved.isEmpty ? Self.fallback : saved
    }

    /// Asks the API once a launch. A failure (no key, offline, a refusal)
    /// leaves the list as it was and is tried again on the next call.
    func refreshIfNeeded(apiKey: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fetched, !fetching, !key.isEmpty else { return }
        fetching = true
        defer { fetching = false }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (data, response) = try? await session.data(for: req),
              let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
              let newest = Self.newestPerFamily(fromListing: data), !newest.isEmpty else { return }
        fetched = true
        if newest != ids {
            ids = newest
            defaults.set(newest, forKey: Self.defaultsKey)
        }
    }

    struct Listing: Decodable {
        struct Model: Decodable {
            let id: String
            let created_at: String?
        }
        let data: [Model]
    }

    /// The newest model of each family in a `GET /v1/models` body, in
    /// `families` order, or nil when the body is not a listing. Newest by
    /// `created_at`; the API lists newest first, and that order breaks a tie
    /// or a date that does not parse. Pure.
    nonisolated static func newestPerFamily(fromListing data: Data) -> [String]? {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return nil }
        let parser = ISO8601DateFormatter()
        var newest: [String: (id: String, at: Date)] = [:]
        for model in listing.data {
            guard let family = family(of: model.id) else { continue }
            let at = model.created_at.flatMap { parser.date(from: $0) } ?? .distantPast
            if let held = newest[family], held.at >= at { continue }
            newest[family] = (model.id, at)
        }
        return families.compactMap { newest[$0]?.id }
    }

    /// "opus" for "claude-opus-5-5", nil for anything that is not one of
    /// `families`.
    nonisolated static func family(of id: String) -> String? {
        let parts = id.lowercased().split(separator: "-")
        guard parts.count >= 2, parts[0] == "claude", families.contains(String(parts[1])) else { return nil }
        return String(parts[1])
    }
}
