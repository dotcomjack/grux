import Foundation

/// The models Grux asked a server on this Mac to keep loaded, by the base URL
/// and model id each call actually used. A lock box so the backend actor can
/// record and the main actor can read without hopping.
private final class KeptModelsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: Set<String>] = [:]
    func insert(baseURL: String, model: String) {
        lock.lock(); kept[baseURL, default: []].insert(model); lock.unlock()
    }
    func takeAll() -> [(baseURL: String, model: String)] {
        lock.lock(); defer { lock.unlock() }
        let all = kept.flatMap { base, models in models.map { (baseURL: base, model: $0) } }
        return all.sorted { ($0.baseURL, $0.model) < ($1.baseURL, $1.model) }
    }
}

private let keptModels = KeptModelsBox()

/// Lets go of the local model's memory. While a model is loaded, Ollama holds
/// its weights and up to 8 GiB of saved prompt readings (`maxPagedOutBytes` in
/// its MLX runner); measured 2026-10-24 on a MacBook Pro, grux-local:4b's runner
/// held 12 GB of graphics memory after 265 turns, while RSS read 0.79 GB. Grux
/// asks Ollama to keep the model for LocalTurn.keepAlive so the next turn reuses
/// what it read, so Grux unloads it itself when the Mac is critically short of
/// memory and when Grux quits: only the models Grux itself asked to keep, at the
/// server and under the name each call used, so another app's model on a shared
/// Ollama is never touched.
enum LocalModelUnload {
    /// Under XCTest the stubbed backends record stub models, and an unload from
    /// the test host would reach whatever real Ollama the Mac running the tests
    /// has. Tests read `takeRequests()`; nothing is sent.
    static let isUnderTest: Bool = NSClassFromString("XCTestCase") != nil

    /// Called by OpenAICompatBackend for every native call that carried keep_alive.
    static func noteKept(baseURL: String, model: String) {
        guard !model.isEmpty else { return }
        keptModels.insert(baseURL: baseURL, model: model)
    }

    /// The unload call (`keep_alive: 0` on `/api/generate`, as Ollama documents
    /// it) for `model` at `baseURL`, or nil when that server is not this Mac.
    static func request(baseURL: String, model: String) -> URLRequest? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !model.isEmpty,
              let url = URL(string: "\(trimmed)/api/generate"),
              let body = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0]) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 2
        req.httpBody = body
        return req
    }

    /// The unload calls for every model Grux asked to keep, and forgets them:
    /// a model Grux unloaded is not Grux's to unload again until it is used.
    static func takeRequests() -> [URLRequest] {
        keptModels.takeAll().compactMap { request(baseURL: $0.baseURL, model: $0.model) }
    }

    /// Fire and forget, for memory pressure.
    static func unload() {
        guard !isUnderTest else { return }
        for req in takeRequests() { URLSession.shared.dataTask(with: req).resume() }
    }

    /// Waits at most one second in all, for applicationWillTerminate.
    static func unloadBeforeQuit() {
        guard !isUnderTest else { return }
        let reqs = takeRequests()
        guard !reqs.isEmpty else { return }
        let group = DispatchGroup()
        for req in reqs {
            group.enter()
            URLSession.shared.dataTask(with: req) { _, _, _ in group.leave() }.resume()
        }
        _ = group.wait(timeout: .now() + 1)
    }
}
