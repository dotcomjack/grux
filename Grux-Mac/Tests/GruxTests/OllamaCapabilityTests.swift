import XCTest
import Network
@testable import Grux

/// `endpoint.ollama` must be satisfied by the thing the contract tells people to do.
///
/// The contract's remediation reads "Install Ollama and start it, or point Grux at
/// your Ollama host in Settings". That control writes `config.ollamaBaseURL`.
/// Nothing consulted it: `endpointConfigured` checked `config.localLLMEndpoint`,
/// which is a different endpoint entirely. LocalHealthMonitor's own header names
/// them as "the AmbientLLM proxy on the companion service at cfg.localLLMEndpoint
/// and the offline-chat Ollama base at cfg.ollamaBaseURL", and their Settings
/// prompts are ports 3849 and 11434. So a user who followed the instruction
/// exactly still saw the capability unsatisfied, with no way to clear it.
///
/// Identical shape to the mail-account divergence already recorded in
/// `alternateSource`, where the mailbox showed a setup card over 205 unread
/// messages. That one was found in a screenshot. This one was found by reading the
/// remediation text against the code that answers it.
///
/// The test stands up a real HTTP server that speaks Ollama's `/api/tags`, points
/// `ollamaBaseURL` at it, and runs the app's own discovery. `localLLMEndpoint` is
/// deliberately emptied first, so the pre-existing arm CANNOT be what turns the
/// answer true.
@MainActor
final class OllamaCapabilityTests: XCTestCase {

    private var savedOllama = ""
    private var savedLocalLLM = ""
    private var server: TagsServer?

    override func setUp() async throws {
        savedOllama = AppState.shared.config.ollamaBaseURL
        savedLocalLLM = AppState.shared.config.localLLMEndpoint
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        AppState.shared.config.ollamaBaseURL = savedOllama
        AppState.shared.config.localLLMEndpoint = savedLocalLLM
        ModelRegistry.shared.resetLocalForTest()
    }

    /// With no local server anywhere and no companion endpoint typed, the
    /// capability is unsatisfied. Establishes that the positive case below is
    /// actually measuring something rather than starting from true.
    func testUnsatisfiedWhenNoLocalModelIsReachable() {
        AppState.shared.config.localLLMEndpoint = ""
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:1"   // nothing listens on port 1
        XCTAssertFalse(CapabilityResolver.isSatisfied(.endpointOllama),
                       "the capability is satisfied with no local model and no endpoint configured")
    }

    /// The actual fix. A reachable Ollama at the configured host satisfies the
    /// capability, with the companion endpoint left empty so the old arm is out of
    /// the picture.
    func testAReachableOllamaAtTheConfiguredHostSatisfiesTheCapability() async throws {
        let s = try TagsServer()
        server = s
        try s.start()
        XCTAssertGreaterThan(s.port, 0, "the stub server never bound a port, so this test proves nothing")

        AppState.shared.config.localLLMEndpoint = ""
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:\(s.port)"

        await ModelRegistry.shared.discoverLocal()
        XCTAssertNotNil(ModelRegistry.shared.local,
                        "discovery did not find the stub, so the capability assertion below "
                        + "would pass or fail for the wrong reason. status: "
                        + (ModelRegistry.shared.localStatus ?? "nil"))

        XCTAssertTrue(CapabilityResolver.isSatisfied(.endpointOllama),
            "Ollama is running at the host Settings configured and the capability is still "
            + "unsatisfied, so the contract's own remediation cannot be followed to completion")
    }

    /// The default must not be mistaken for a configuration. `ollamaBaseURL` ships
    /// as http://localhost:11434, so any implementation resting on "is it
    /// non-empty" marks this satisfied on every install on earth including one
    /// with no local model at all.
    func testTheShippedDefaultAloneDoesNotSatisfyIt() {
        AppState.shared.config.localLLMEndpoint = ""
        AppState.shared.config.ollamaBaseURL = "http://localhost:11434"
        ModelRegistry.shared.resetLocalForTest()
        XCTAssertFalse(CapabilityResolver.isSatisfied(.endpointOllama),
            "a non-empty ollamaBaseURL alone satisfied the capability, but that field has a "
            + "default, so this marks every install configured whether or not anything runs")
    }

    /// The contract text and the resolver have to be talking about the same thing.
    /// If somebody rewrites the remediation to point at a different control, this
    /// fails and prompts them to move the resolver with it.
    func testTheContractStillTellsPeopleToPointGruxAtTheirOllamaHost() throws {
        let contract = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/contract.md"),
            encoding: .utf8)
        let row = try XCTUnwrap(
            contract.split(separator: "\n").first { $0.contains("`endpoint.ollama`") && $0.contains("|") },
            "no endpoint.ollama row in the contract tables")
        XCTAssertTrue(row.contains("Ollama host") || row.contains("Install Ollama"),
            "the remediation for endpoint.ollama changed. The resolver answers it by asking "
            + "whether a server at ollamaBaseURL responded, so if the instruction now points "
            + "somewhere else the two have drifted. Row: \(row)")
    }
}

/// A loopback HTTP server that answers Ollama's `/api/tags` and nothing else.
/// Stays up for the life of the test rather than one-shot, because discovery may
/// fall through to a second probe.
private final class TagsServer: @unchecked Sendable {
    private let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let body = #"{"models":[{"name":"llama3.1:latest"}]}"#
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "TagsServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
    }

    func stop() { listener.cancel() }
}
