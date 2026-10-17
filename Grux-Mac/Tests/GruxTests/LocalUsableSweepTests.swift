import Network
import XCTest
@testable import Grux

/// `ModelRegistry.local` says a server answered; `localUsable` says a model
/// can take a turn. Ollama answering with nothing pulled is the first and not
/// the second, and every place that offers or prices a local turn must ask the
/// second (PR 40 aggregate review, P3s and sweep).
@MainActor
final class LocalUsableSweepTests: XCTestCase {
    private var savedBase = ""
    private var server: TagsStub?

    override func setUp() async throws {
        savedBase = AppState.shared.config.ollamaBaseURL
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() async throws {
        server?.stop()
        AppState.shared.config.ollamaBaseURL = savedBase
        ModelRegistry.shared.resetLocalForTest()
        CostMeter.shared.chatEstimate = nil
    }

    /// Discovery against a loopback Ollama listing `models`.
    private func discover(models: [String]) async throws {
        server?.stop()
        let s = try TagsStub(models: models)
        server = s
        try s.start()
        XCTAssertGreaterThan(s.port, 0, "the stub never bound a port")
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:\(s.port)"
        await ModelRegistry.shared.discoverLocal()
        XCTAssertNotNil(ModelRegistry.shared.local, "discovery did not reach the stub")
    }

    private func estimateAlternative() -> CheaperAlternative? {
        CostMeter.shared.publishChatEstimate(systemBlocks: [["type": "text", "text": "You are Grux."]],
                                             messages: [["role": "user", "content": "hello there"]],
                                             tools: [], modelId: "claude-sonnet-4-6", provider: "anthropic",
                                             maxOutputTokens: 200)
        return CostMeter.shared.chatEstimate?.cheaperAlternative
    }

    /// (1) An empty Ollama is not a free way to run this turn.
    func test_theEstimateOffersAFreeLocalTurnOnlyWhenAModelIsThere() async throws {
        try await discover(models: [])
        XCTAssertNotEqual(estimateAlternative()?.estimatedUSD, 0,
                          "an Ollama with nothing pulled is offered as a $0 turn that would bill Anthropic")
        // Control: with a model, the free alternative is offered.
        try await discover(models: ["llama3.1:8b"])
        let alt = estimateAlternative()
        XCTAssertEqual(alt?.estimatedUSD, 0, "control: a real local model is not offered")
        XCTAssertEqual(alt?.modelId, "llama3.1:8b")
    }

    /// (2) Settings' local status reads as a warning until a model is usable.
    func test_settingsWarnsUntilAModelIsUsable() throws {
        let src = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(src.contains(".foregroundStyle(modelRegistry.localUsable ? Color.secondary : Color.orange)"),
                      "\"local server reachable, no models installed\" renders as fine")
        XCTAssertTrue(src.contains("if state.offlineMode && !modelRegistry.localUsable {"),
                      "offline mode on an empty server says nothing")
        XCTAssertFalse(src.contains("modelRegistry.local != nil") || src.contains("modelRegistry.local == nil"))
    }

    /// (3, sweep) A network failure offers "Continue offline" only when a
    /// local model can take the retry, and so does the limit card.
    func test_continueOfflineIsOfferedOnlyWithAUsableModel() async throws {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "https://api.anthropic.com/v1/messages")!])
        try await discover(models: [])
        let empty = ChatService.classifyChatFailure(error: offline, userText: "hi", imageData: nil, imageMediaType: nil)
        XCTAssertNotEqual(empty.kind, .network, "Continue offline is offered to an Ollama with nothing pulled")
        try await discover(models: ["llama3.1:8b"])
        let ready = ChatService.classifyChatFailure(error: offline, userText: "hi", imageData: nil, imageMediaType: nil)
        XCTAssertEqual(ready.kind, .network, "control: a usable model is not offered")
        let chat = try source("Sources/Grux/ChatView.swift")
        XCTAssertTrue(chat.contains("if ModelRegistry.shared.localUsable {\n                            Button(\"Use local model\")"),
                      "the limit card offers a local model that cannot take the turn")
    }

    /// The sweep, kept: every remaining `local != nil` outside the registry is
    /// a REACHABILITY question by design, named here so a new one is a choice.
    func test_everyReachabilityCheckIsOneOfTheKnownOnes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "ModelRegistry.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for line in lines where (line.contains("local != nil") || line.contains("local == nil"))
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                found.append(url.lastPathComponent)
            }
        }
        // ConnectModelSection: the route's own `reachable` input, beside `usable`.
        // ComparisonService: iterates the listed tags, so an empty server adds no contender.
        // OnboardingView x3: reachability first, then an explicit usable-model check
        // (probe and Use a local model), or a hosted endpoint's model list (OpenRouter).
        XCTAssertEqual(found.sorted(), ["ComparisonService.swift", "ConnectModelSection.swift",
                                        "OnboardingView.swift", "OnboardingView.swift", "OnboardingView.swift"],
                       "a new place reads reachability; if it means a usable model, use localUsable")
    }

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }
}

/// A loopback Ollama answering /api/tags with a fixed model list.
private final class TagsStub: @unchecked Sendable {
    private let listener: NWListener
    private let body: String
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(models: [String]) throws {
        body = #"{"models":["# + models.map { #"{"name":""# + $0 + #""}"# }.joined(separator: ",") + "]}"
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        let body = self.body
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "TagsStub", code: 1)
        }
    }

    func stop() { listener.cancel() }
}
