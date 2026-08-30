//
//  ReplicateClient.swift
//  Grux Creative Studio - Replicate predictions client
//
//  REPLACES FalClient. fal.ai is out of the business model, and the only other
//  media path Grux has, `endpoint.media_service`, points at a machine on the
//  owner's own network, so a stranger who downloads Grux had no way to make
//  Media Studio work at all. Replicate is the approved media vendor and works
//  for anybody with their own key.
//
//  The configured image service stays and is still authoritative for
//  product-in-scene renders, where a real product has to be composited
//  byte-exact into a scene. That is a different job from pure generation, and
//  this owns the pure-generation path: no reference image, no sku, just a
//  directive.
//
//  Wire protocol (Replicate predictions API, verified against the current docs
//  rather than from memory, because the auth scheme changed: it is `Bearer`,
//  and older Replicate code in the wild sends `Token`):
//    1. Submit  POST https://api.replicate.com/v1/models/<owner>/<name>/predictions
//               header Authorization: Bearer <key>
//               body   {"input": {prompt, aspect_ratio, num_outputs, output_format}}
//               -> {id, status, urls: {get, cancel}, output}
//    2. Poll    GET  urls.get  -> {status, output, error}
//               (1s interval, 120s ceiling)
//    3. Download each output url to raw Data.
//
//  There is no separate "fetch the result" step: unlike fal's queue API, the
//  poll response CARRIES the output. So this is one fewer round trip and one
//  fewer thing to get wrong.
//
//  The parsing helpers are pure and unit-tested with fixture JSON; the actor
//  does the network. The key never touches source or logs: it is read from the
//  Keychain (KeychainStore.replicateApiKey) with a GRUX_REPLICATE_KEY env
//  fallback so a headless verification run works without a Settings round-trip.
//

import Foundation

/// Typed errors, mirroring the shape FalError had so the call sites in
/// CreativeEngine read the same way.
enum ReplicateError: LocalizedError, Equatable {
    case missingKey
    case http(Int, String)
    case timeout
    case decoding(String)
    /// Replicate reports a model-side failure as a TERMINAL STATUS, not as an HTTP error.
    /// A poll loop that only looks for "succeeded" spins until the ceiling and then reports
    /// a timeout, which sends the reader to look at their network for a prompt the model
    /// rejected in two seconds.
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Replicate key missing, set in Settings"
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(180))"
        case .timeout: return "Replicate prediction timed out"
        case .decoding(let m): return "decode: \(m)"
        case .predictionFailed(let m): return "Replicate could not run this: \(m)"
        }
    }
}

/// Replicate model ids, in `owner/name` form. `GRUX_REPLICATE_IMAGE_MODEL`
/// overrides at call time so ops can repoint Grux without a rebuild.
enum ReplicateModels {
    static let defaultImage = "black-forest-labs/flux-dev"

    static func imageModel(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let override = env["GRUX_REPLICATE_IMAGE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return defaultImage
    }
}

/// One generated image pulled back as raw bytes.
struct ReplicateImage: Sendable {
    let data: Data
    let contentType: String
    let width: Int?
    let height: Int?

    var fileExtension: String {
        let ct = contentType.lowercased()
        if ct.contains("png") { return "png" }
        if ct.contains("webp") { return "webp" }
        return "jpg"
    }
}

actor ReplicateClient {
    static let shared = ReplicateClient()

    private static let apiBase = "https://api.replicate.com/v1"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 130
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Public entry point

    func generateImages(
        prompt: String,
        aspect: AspectPreset,
        count: Int,
        model: String? = nil
    ) async throws -> [ReplicateImage] {
        try await performGeneration(
            prompt: prompt, aspect: aspect, count: count,
            modelId: model ?? ReplicateModels.imageModel()
        )
    }

    // MARK: - Network

    private func performGeneration(
        prompt: String, aspect: AspectPreset, count: Int, modelId: String
    ) async throws -> [ReplicateImage] {
        let key = resolveKey()
        guard !key.isEmpty else { throw ReplicateError.missingKey }
        // Replicate image models cap num_outputs at 4, where fal allowed 8. Clamping rather
        // than erroring: asking for more pictures than the vendor makes is not a reason to
        // return none.
        let clampedCount = max(1, min(count, 4))

        let body: [String: Any] = [
            "input": [
                "prompt": prompt,
                "aspect_ratio": Self.aspectRatio(for: aspect),
                "num_outputs": clampedCount,
                "output_format": "jpg"
            ]
        ]
        var submitReq = URLRequest(url: URL(string: "\(Self.apiBase)/models/\(modelId)/predictions")!)
        submitReq.httpMethod = "POST"
        submitReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        submitReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitReq.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (submitData, submitResp) = try await session.data(for: submitReq)
        try Self.ensureOK(submitResp, submitData)
        let submitted = try Self.parsePrediction(submitData)

        // The submit response can ALREADY be terminal on a cached prediction, so the poll
        // loop is entered with it rather than after an unconditional first sleep.
        //
        // It returns the raw bytes alongside the decoded prediction because `output` is
        // polymorphic and is read out of raw JSON. Returning only the decoded value would
        // mean re-fetching the payload purely to look at a field that was already in hand.
        let finished = try await pollUntilTerminal(
            first: submitted, firstPayload: submitData, key: key)
        let urls = try Self.outputURLs(finished)

        var out: [ReplicateImage] = []
        for u in urls {
            guard let url = URL(string: u) else { continue }
            do {
                let (data, resp) = try await session.data(from: url)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                // Replicate's payload carries no content type for the file, unlike fal's, so
                // it comes off the download response and falls back to the path extension.
                let declared = (resp as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Type")
                out.append(ReplicateImage(
                    data: data,
                    contentType: declared ?? Self.contentType(forPathExtension: url.pathExtension),
                    width: nil, height: nil
                ))
            } catch { continue }
        }
        guard !out.isEmpty else { throw ReplicateError.decoding("no image bytes downloaded") }
        return out
    }

    private func pollUntilTerminal(
        first: Prediction, firstPayload: Data, key: String
    ) async throws -> Data {
        var current = first
        var payload = firstPayload
        let deadline = Date().addingTimeInterval(120)
        while true {
            switch Self.outcome(of: current.status) {
            case .succeeded: return payload
            case .failed:
                throw ReplicateError.predictionFailed(
                    current.error ?? "the model reported status \(current.status)")
            case .pending: break
            }
            guard Date() < deadline else { throw ReplicateError.timeout }
            try await Task.sleep(nanoseconds: 1_000_000_000)   // 1s

            let getURL = current.getURL ?? "\(Self.apiBase)/predictions/\(current.id)"
            guard let url = URL(string: getURL) else {
                throw ReplicateError.decoding("bad poll url")
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await session.data(for: req)
            try Self.ensureOK(resp, data)
            payload = data
            current = try Self.parsePrediction(data)
        }
    }

    /// Keychain first, then GRUX_REPLICATE_KEY so headless runs work without opening
    /// Settings. Never logged.
    private func resolveKey() -> String {
        let kc = KeychainStore.get(.replicateApiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        if !kc.isEmpty { return kc }
        let env = ProcessInfo.processInfo.environment["GRUX_REPLICATE_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return env ?? ""
    }

    // MARK: - Pure helpers (unit-tested, no network)

    private static func ensureOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw ReplicateError.http(-1, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReplicateError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    struct Prediction: Decodable, Equatable {
        let id: String
        let status: String
        let error: String?
        /// `output` is deliberately NOT typed here. Replicate returns a bare string for some
        /// models and an array for others, and a Decodable that guesses one shape throws on
        /// the other. `outputURLs` reads it out of raw JSON instead.
        let getURL: String?

        enum CodingKeys: String, CodingKey { case id, status, error, urls }
        enum URLKeys: String, CodingKey { case get }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            // `error` is documented as null on success, and at least one model reports it as
            // an object rather than a string, so a hard String decode would throw on a
            // prediction that actually succeeded.
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            let urls = try? c.nestedContainer(keyedBy: URLKeys.self, forKey: .urls)
            getURL = try? urls?.decodeIfPresent(String.self, forKey: .get)
        }
    }

    enum Outcome { case pending, succeeded, failed }

    /// The status lifecycle, from Replicate's own documentation rather than from memory:
    /// `starting`, `processing`, `succeeded`, `failed`, `canceled`, `aborted`.
    ///
    /// `aborted` is the one that is easy to miss and it means the prediction exceeded its
    /// deadline BEFORE it started running, which is a queue problem rather than a prompt
    /// problem. It is terminal either way, so treating it as pending would hang the loop for
    /// the full 120 seconds and then report a timeout that hides the real reason.
    ///
    /// An UNKNOWN status counts as pending, deliberately: a vendor adding a new
    /// non-terminal state should make Grux wait, not make it declare failure.
    static func outcome(of status: String) -> Outcome {
        switch status.lowercased() {
        case "succeeded":                        return .succeeded
        case "failed", "canceled", "cancelled", "aborted": return .failed
        default:                                 return .pending
        }
    }

    static func parsePrediction(_ data: Data) throws -> Prediction {
        do {
            let p = try JSONDecoder().decode(Prediction.self, from: data)
            guard !p.status.isEmpty else {
                throw ReplicateError.decoding("prediction: missing status field")
            }
            return p
        } catch let e as ReplicateError {
            throw e
        } catch {
            throw ReplicateError.decoding("prediction: \(error)")
        }
    }

    /// Every output URL, from either shape Replicate uses.
    ///
    /// Read out of raw JSON rather than through Codable because the field is genuinely
    /// polymorphic: image models return `["https://...", ...]`, some return a bare
    /// `"https://..."`, and a typed decode of one shape throws on the other. Replicate's own
    /// guide says the same thing in TypeScript: "Some image models return an array of output
    /// files, others just a single file."
    static func outputURLs(_ data: Data) throws -> [String] {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let root else { throw ReplicateError.decoding("output: payload is not an object") }
        switch root["output"] {
        case let one as String where !one.isEmpty:
            return [one]
        case let many as [Any]:
            let urls = many.compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard !urls.isEmpty else { throw ReplicateError.decoding("output: array had no urls") }
            return urls
        default:
            throw ReplicateError.decoding("output: absent or not a url")
        }
    }

    /// Grux aspect preset to Replicate's `aspect_ratio` string. Every value here is one of
    /// the ratios flux accepts by name, so none of them fall into its "custom" branch.
    static func aspectRatio(for aspect: AspectPreset) -> String {
        switch aspect {
        case .square:     return "1:1"
        case .portrait45: return "4:5"
        case .vertical:   return "9:16"
        case .landscape:  return "16:9"
        }
    }

    static func contentType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "webp": return "image/webp"
        default:     return "image/jpeg"
        }
    }
}
