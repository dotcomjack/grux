import Foundation
import Combine

// Proactive reachability poll for the local model surface (the AmbientLLM proxy
// on the companion service at cfg.localLLMEndpoint and the offline-chat Ollama
// base at cfg.ollamaBaseURL). Without this, a companion reboot or Ollama outage only ever
// shows up as a silent per-call fallback to Claude, so the user never learns
// the local path is down until they dig through telemetry. This surfaces it in
// Settings instead. Pure best-effort: an ephemeral session, a short timeout,
// and it never throws to the UI.
@MainActor
final class LocalHealthMonitor: ObservableObject {
    static let shared = LocalHealthMonitor()

    // nil = not yet checked. true/false = last probe result. Mirrors the dot
    // colors in ModelConfigView (amber while nil, green/red after a probe).
    @Published private(set) var reachable: Bool? = nil
    @Published private(set) var lastChecked: Date? = nil
    @Published private(set) var lastError: String? = nil

    private var timer: Timer?
    private var checking = false
    private let pollInterval: TimeInterval = 60
    private let probeTimeout: TimeInterval = 4

    private init() {}

    // Idempotent: a second call while the timer is live is a no-op. Runs one
    // probe immediately, then repeats on a ~60s cadence. The Settings view calls
    // this from .onAppear; calling it again on a later appear does not restack
    // timers.
    func startIfNeeded() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkNow() }
        }
        // Keep firing while the Settings sheet drives a modal run loop.
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        Task { @MainActor in await checkNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // True when there is actually a local endpoint worth probing. With nothing
    // configured we stay idle and leave `reachable` at nil rather than reporting
    // a misleading red dot for a feature the user never turned on.
    private func hasConfiguredEndpoint(_ cfg: GruxConfig) -> Bool {
        if cfg.useLocalQwenForAmbient && !cfg.localLLMEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !cfg.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    // One best-effort sweep. Probes whichever local surfaces are configured and
    // marks reachable=true if ANY answers (either path being up means a local
    // route exists). Never throws; failures land in lastError.
    func checkNow() async {
        if checking { return }
        checking = true
        defer { checking = false }

        let cfg = AppState.shared.config
        guard hasConfiguredEndpoint(cfg) else {
            // Nothing to poll: stay idle / not-checked, clear any stale error.
            reachable = nil
            lastError = nil
            return
        }

        let session = ephemeralSession()
        defer { session.invalidateAndCancel() }

        var anyUp = false
        var firstError: String? = nil

        // Companion AmbientLLM proxy (POST endpoint): we only need to know the host is
        // answering, so a HEAD/GET to its URL is enough. A 4xx/5xx still proves
        // the host is reachable; only a transport failure counts as down.
        if cfg.useLocalQwenForAmbient {
            let ep = cfg.localLLMEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ep.isEmpty {
                let (ok, err) = await probe(urlString: ep, session: session)
                if ok { anyUp = true } else if firstError == nil { firstError = err }
            }
        }

        // Offline-chat Ollama base: /api/tags is the same lightweight surface
        // ModelRegistry.discoverLocal uses, so success here mirrors discovery.
        let base = cfg.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            let tagsURL = base.hasSuffix("/") ? "\(base)api/tags" : "\(base)/api/tags"
            let (ok, err) = await probe(urlString: tagsURL, session: session)
            if ok { anyUp = true } else if firstError == nil { firstError = err }
        }

        reachable = anyUp
        lastError = anyUp ? nil : firstError
        lastChecked = Date()
    }

    // A reachability probe is "host answered at all", not "200 OK". Any HTTP
    // response (even an error status) means the box is up; only a transport
    // error (refused, timed out, no route) is unreachable.
    private func probe(urlString: String, session: URLSession) async -> (Bool, String?) {
        guard let url = URL(string: urlString) else {
            return (false, "bad URL: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = probeTimeout
        do {
            let (_, resp) = try await session.data(for: req)
            if resp is HTTPURLResponse {
                return (true, nil)
            }
            return (false, "no HTTP response")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func ephemeralSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = probeTimeout
        c.timeoutIntervalForResource = probeTimeout
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }
}

// Talks to the local-LLM proxy configured in Settings, which fronts Ollama.
// Mirrors `ClaudeClient.complete()` so callers can swap providers by toggling
// the AppState.useLocalQwenForAmbient flag.
//
// Endpoint shape (POST /api/llm/local):
//   request:  { system?, messages, max_tokens?, temperature?, model? }
//   response: { content, model, ms, input_tokens?, output_tokens?, stop_reason? }
//
// No endpoint ships baked in: cfg.localLLMEndpoint is empty until the user
// points it at their own proxy, path /api/llm/local.
// Falls through if the endpoint is unreachable; callers can pair this with
// a Claude fallback so ambient summarizers never drop a tick.

enum LocalLLMError: Error, LocalizedError {
    case http(Int, String)
    case decoding(String)
    case unreachable(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "LocalLLM HTTP \(code): \(body.prefix(200))"
        case .decoding(let msg): return "LocalLLM decoding error: \(msg)"
        case .unreachable(let msg): return "LocalLLM unreachable: \(msg)"
        }
    }
}

actor LocalLLMClient {
    private let session: URLSession
    private(set) var lastInputTokens: Int = 0
    private(set) var lastOutputTokens: Int = 0
    private(set) var lastLatencyMs: Int = 0

    init(timeoutSeconds: TimeInterval = 120) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds + 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    // Endpoint pulled from AppState at call time so a Settings change takes
    // effect on the next ambient tick without a relaunch.
    func complete(
        endpoint: String,
        model: String,
        system: String?,
        messages: [ClaudeMessage],
        maxTokens: Int = 512,
        temperature: Double = 0.3,
        spanName: String = "localllm.complete",
        feature: String = "ambient_local"
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw LocalLLMError.unreachable("bad URL: \(endpoint)")
        }
        let started = Date()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": temperature
        ]
        if let system, !system.isEmpty { body["system"] = system }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw LocalLLMError.unreachable("no response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
                throw LocalLLMError.http(http.statusCode, bodyStr)
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LocalLLMError.decoding("top-level not dict")
            }
            let content = (obj["content"] as? String) ?? ""
            self.lastInputTokens = (obj["input_tokens"] as? Int) ?? 0
            self.lastOutputTokens = (obj["output_tokens"] as? Int) ?? 0
            self.lastLatencyMs = (obj["ms"] as? Int) ?? Int(Date().timeIntervalSince(started) * 1000)
            return content
        } catch let e as LocalLLMError {
            throw e
        } catch {
            throw LocalLLMError.unreachable(error.localizedDescription)
        }
    }
}

// The text an AmbientLLM call produced plus the provider that actually produced
// it ("local/qwen3:8b" or "claude/<model>"). Returning the provider as part of
// the result, instead of a shared mutable global, means concurrent callers (the
// nightly decision-log and person-memory passes can fire in the same minute)
// never read each other's provider. Each call owns its own attribution.
struct AmbientLLMResult {
    let text: String
    let provider: String
}

// Convenience router used by ambient call sites: prefer local-Qwen when the
// toggle is on, fall back to ClaudeClient on error so a companion reboot or LAN
// glitch never drops an hourly summary or workday rollup.
//
// `featureTag` names the caller (ambient summary, folder classifier, and so on)
// so a call can be identified in the local logs.
@MainActor
enum AmbientLLM {
    // Primary entry point: returns the text AND the provider that produced it,
    // so the caller has race-free attribution in the local logs. Callers
    // that don't care which provider answered can use `complete` below.
    static func completeTagged(
        system: String?,
        messages: [ClaudeMessage],
        maxTokens: Int,
        temperature: Double,
        featureTag: String
    ) async throws -> AmbientLLMResult {
        let cfg = AppState.shared.config
        if cfg.useLocalQwenForAmbient && !cfg.localLLMEndpoint.isEmpty {
            do {
                let local = LocalLLMClient()
                let modelName = cfg.localLLMModel.isEmpty ? GruxConfig.defaultLocalModel : cfg.localLLMModel
                let reply = try await local.complete(
                    endpoint: cfg.localLLMEndpoint,
                    model: modelName,
                    system: system,
                    messages: messages,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    feature: featureTag
                )
                return AmbientLLMResult(text: reply, provider: "local/\(modelName)")
            } catch {
                WakeLog.shared.log("ambientLLM: local failed (\(error.localizedDescription)), falling back to Claude")
            }
        }
        // ROUTED. This fallback built its own ClaudeClient and sent
        // AppState.anthropicKey, which made the whole ambient family (hourly
        // summaries, workday rollups, person memory, decision log, cold email)
        // hosted-Anthropic-or-nothing the moment the local Qwen companion was
        // off or unreachable. A custom-endpoint user had no path here at all.
        // Resolved ONCE, after the local attempt, never inside a loop.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        // The empty-model fallback is unchanged: an unset model id is a 404 on
        // any provider, so the historical default still stands in.
        let cloudModel = routing.modelId.isEmpty ? "claude-haiku-4-5-20251001" : routing.modelId
        let reply = try await routing.backend.complete(
            apiKey: routing.apiKey,
            model: cloudModel,
            system: system,
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            // Explicit because a ModelBackend requirement carries no default
            // arguments; these are ClaudeClient's own, so the wire is unchanged.
            spanName: "claude.complete",
            feature: featureTag
        )
        // The tag names the model that actually answered rather than a hardcoded
        // "claude/" prefix, because after routing this is no longer guaranteed to
        // be Anthropic and every consumer of `provider` writes it into a log or a
        // record. A tag that lies is worse than no tag.
        return AmbientLLMResult(text: reply, provider: "cloud/\(cloudModel)")
    }

    // Text-only convenience for callers that don't need provider attribution
    // (hourly summarizer, workday rollups, folder classifier).
    static func complete(
        system: String?,
        messages: [ClaudeMessage],
        maxTokens: Int,
        temperature: Double,
        featureTag: String
    ) async throws -> String {
        try await completeTagged(
            system: system,
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            featureTag: featureTag
        ).text
    }
}
