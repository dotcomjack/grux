import Foundation

/// TypeSafe's Jev: typed decisions with calibrated confidence, about half a
/// second round trip. Bring your own key; without one this provider is never
/// constructed by the engine. The request and response shapes here are the
/// ones observed on 2026-09-20 and pinned by JevDecisionProviderTests.
struct JevDecisionProvider: DecisionProvider {
    let kind: DecisionProviderKind = .jev

    enum Failure: Error, Equatable {
        case noKey
        case http(Int)
        case malformed
    }

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"

    private let apiKey: String
    private let session: URLSession
    /// Where each response is reported for what it says about the credit
    /// (P-R-3). Nil is the app's `CreditMonitor.shared`; a test passes its own.
    private let credits: CreditMonitor?

    init(apiKey: String, session: URLSession? = nil, credits: CreditMonitor? = nil) {
        self.apiKey = apiKey
        self.credits = credits
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 3
            cfg.timeoutIntervalForResource = 5
            self.session = URLSession(configuration: cfg)
        }
    }

    static func requestBody(state: String, questions: [String: DecisionQuestion]) -> [String: Any] {
        var qs: [String: Any] = [:]
        for (name, q) in questions {
            switch q {
            case .choice(let instructions, let criteria):
                qs[name] = ["type": "choice", "instructions": instructions, "criteria": criteria]
            case .noul(let instructions):
                qs[name] = ["type": "noul", "instructions": instructions]
            case .score(let instructions, let levels):
                qs[name] = ["type": "score", "instructions": instructions, "criteria": levels]
            }
        }
        return ["state": state, "model": model, "questions": qs]
    }

    static func parse(_ data: Data, latencyMs: Int) throws -> DecisionResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else { throw Failure.malformed }
        var out: [String: DecisionAnswer] = [:]
        for (name, raw) in answers {
            guard let a = raw as? [String: Any], let type = a["type"] as? String else { throw Failure.malformed }
            switch type {
            case "choice":
                guard let choice = a["choice"] as? String else { throw Failure.malformed }
                out[name] = .choice(choice,
                                    confidence: (a["confidence"] as? Double) ?? 0,
                                    probabilities: (a["probabilities"] as? [String: Double]) ?? [:])
            case "noul":
                guard let p = a["noul"] as? Double else { throw Failure.malformed }
                out[name] = .noul(p)
            case "score":
                guard let s = a["score"] as? Double else { throw Failure.malformed }
                out[name] = .score(s, confidence: (a["confidence"] as? Double) ?? 0)
            default:
                throw Failure.malformed
            }
        }
        let usage = root["usage"] as? [String: Any]
        return DecisionResult(answers: out,
                              latencyMs: latencyMs,
                              inputTokens: (usage?["input_tokens"] as? Int) ?? 0,
                              outputTokens: (usage?["output_tokens"] as? Int) ?? 0,
                              provider: .jev)
    }

    func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("https://gruxai.com", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Grux OS: decisions", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(state: state, questions: questions))
        let started = Date()
        let (data, response) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        // The engine turns every throw here into an on device answer, so the
        // fallback is unchanged. What P-R-3 adds is that the response is READ
        // first: a non-2xx goes to the credit monitor, which marks the credit
        // out only for the provider's own documented out of credit response.
        guard (200..<300).contains(http.statusCode) else {
            await CreditMonitor.observe(.jev, status: http.statusCode, body: data, on: credits)
            throw Failure.http(http.statusCode)
        }
        // A success is a call that produced a decision, not merely a 2xx: a
        // body that does not parse throws before it can end an episode.
        let result = try Self.parse(data, latencyMs: ms)
        await CreditMonitor.observe(.jev, status: http.statusCode, body: Data(), on: credits)
        return result
    }
}
