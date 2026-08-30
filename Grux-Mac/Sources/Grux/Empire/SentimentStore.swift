import Foundation

// Brand-sentiment digest pulled from a companion sentiment service.
//
// ARCHITECTURE NOTE (substitution from the original spec):
// The spec imagined the service POSTing a digest to a Grux "/api/inbox". Grux
// runs no inbound HTTP server, so instead Grux PULLS the digest, the same proven
// direction the LLM and RAG clients already use. The nightly crawl +
// summarization happens on the service side; this side just fetches the latest
// digest, caches it, and renders it in the Empire Dashboard.
//
// Fetched on the `fire-sentiment-test` trigger and when the dashboard opens.
// Endpoint: <configured base>/api/digest/latest. Unconfigured by default, see
// SentimentDigestService.baseURLDefaultsKey below.

struct SentimentDigest: Codable, Equatable {
    var generatedAt: String
    var generatedAtEpoch: Double
    var brandCount: Int
    var totalMentions: Int
    var fallbackUsed: Bool
    var brands: [BrandSentiment]
}

struct BrandSentiment: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var mood: String          // positive | mixed | negative | quiet
    var score: Double         // -1.0 ... 1.0
    var summary: String
    var highlights: [String]
    var mentionCount: Int
    var provider: String      // ollama | anthropic | heuristic | none
    var sources: [String: Int]?
    var notes: [String]?

    var id: String { key }
}

@MainActor
final class SentimentStore: ObservableObject {
    static let shared = SentimentStore()

    @Published private(set) var digest: SentimentDigest?
    @Published private(set) var lastFetched: Date?
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastError: String?
    // True when the last fetch failed and we are showing a cached digest.
    @Published private(set) var servingStale: Bool = false

    private var loaded = false

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("sentiment.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sentiment.md")
    }

    private init() {}

    // Restore the last cached digest on launch so the dashboard has something to
    // show before the first live fetch returns.
    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: jsonURL),
           let cached = try? JSONDecoder().decode(SentimentDigest.self, from: data) {
            self.digest = cached
        }
    }

    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        do {
            let fresh = try await SentimentDigestService.fetchLatest()
            self.digest = fresh
            self.lastFetched = Date()
            self.servingStale = false
            persist(fresh)
        } catch {
            // Companion asleep / network drop / quota: keep the cached digest and
            // surface the reason in the UI.
            self.lastError = error.localizedDescription
            self.servingStale = (self.digest != nil)
            WakeLog.shared.log("sentiment: fetch failed: \(error.localizedDescription)")
        }
    }

    private func persist(_ d: SentimentDigest) {
        if let data = try? JSONEncoder().encode(d) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        writeMarkdownMirror(d)
    }

    // Human + CLI readable mirror at ~/.grux/sentiment.md, same convention as
    // inbox.md and brand-time. Lets a smoke test grep the result without parsing
    // app state.
    private func writeMarkdownMirror(_ d: SentimentDigest) {
        var lines: [String] = []
        lines.append("# Brand Sentiment Digest")
        lines.append("")
        lines.append("Generated: \(d.generatedAt) | brands: \(d.brandCount) | mentions: \(d.totalMentions) | fallback: \(d.fallbackUsed)")
        lines.append("")
        for b in d.brands.sorted(by: { $0.mentionCount > $1.mentionCount }) {
            let scoreStr = String(format: "%.2f", b.score)
            lines.append("## \(b.name) | \(b.mood) (\(scoreStr)) | \(b.mentionCount) mention\(b.mentionCount == 1 ? "" : "s") | \(b.provider)")
            lines.append(b.summary)
            for h in b.highlights { lines.append("  - \(h)") }
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    }
}

enum SentimentDigestService {
    static let baseURLDefaultsKey = "grux.services.sentimentBaseURL"

    // Where the sentiment service lives. EMPTY by default: it runs on the
    // user's own machine on their own network, which Grux cannot guess. Set
    // `grux.services.sentimentBaseURL` to point at it; a comma-separated list
    // is tried in order, so a tailnet name can fall back to a LAN address.
    // Empty is already handled below: the fetch loop never runs, fetchLatest
    // throws, and refresh() keeps serving the cached digest.
    static var baseURLs: [String] {
        (UserDefaults.standard.string(forKey: baseURLDefaultsKey) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func fetchLatest() async throws -> SentimentDigest {
        var lastErr = "sentiment service not configured (set \(baseURLDefaultsKey))"
        for base in baseURLs {
            guard let url = URL(string: base + "/api/digest/latest") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    lastErr = "no HTTP response from \(base)"
                    continue
                }
                if http.statusCode == 404 {
                    throw FetchError(message: "service has no digest yet (404); run a crawl")
                }
                guard (200..<300).contains(http.statusCode) else {
                    lastErr = "\(base) returned HTTP \(http.statusCode)"
                    continue
                }
                return try JSONDecoder().decode(SentimentDigest.self, from: data)
            } catch let e as FetchError {
                throw e
            } catch {
                lastErr = "\(base): \(error.localizedDescription)"
                continue
            }
        }
        throw FetchError(message: lastErr)
    }
}
