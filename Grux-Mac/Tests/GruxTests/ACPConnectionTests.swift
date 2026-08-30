import XCTest
import Foundation
@testable import GruxAgentCore

// Drives a real ACPConnection over the FileHandle pipe test seam against a fake
// in-process ACP agent (no subprocess). Covers:
//   1. the initialize handshake round-trip
//   2. a server-initiated request answered by the injected handler
//   3. the per-request timeout path when the agent ignores a request
final class ACPConnectionTests: XCTestCase {

    func testInitializeRoundTrip() async throws {
        let agent = FakePipeACPAgent()
        agent.start()
        let conn = ACPConnection(
            testWrite: agent.clientToServer.fileHandleForWriting,
            testRead: agent.serverToClient.fileHandleForReading
        )
        try await conn.start()
        let ready = await conn.isReady
        XCTAssertTrue(ready, "handshake should leave the connection ready")
        XCTAssertTrue(agent.sawInitialize.withLock { $0 })
        await conn.shutdown()
        agent.stop()
    }

    func testServerInitiatedRequestAnsweredByInjectedHandler() async throws {
        let agent = FakePipeACPAgent()
        let answered = expectation(description: "agent received the client's response")
        agent.onCapturedResponse = { answered.fulfill() }
        agent.start()

        // The app-supplied handler answers the agent's fs read.
        let handler: ACPServerRequestHandler = { method, params in
            if method == "fs/read_text_file" {
                let path = params?["path"]?.stringValue ?? "?"
                return .result(.object(["content": .string("body of \(path)")]))
            }
            return .error(code: -32601, message: "unsupported")
        }
        let conn = ACPConnection(
            testWrite: agent.clientToServer.fileHandleForWriting,
            testRead: agent.serverToClient.fileHandleForReading,
            serverRequestHandler: handler
        )
        try await conn.start()

        // Agent asks the client to read a file.
        agent.sendServerRequest(id: 4242, method: "fs/read_text_file", params: .object(["path": .string("/etc/hosts")]))

        await fulfillment(of: [answered], timeout: 5)
        let captured = agent.capturedResponse.withLock { $0 }
        XCTAssertEqual(captured?.intID, 4242, "the client's reply must echo the agent's request id")
        XCTAssertEqual(captured?.result?["content"]?.stringValue, "body of /etc/hosts")

        await conn.shutdown()
        agent.stop()
    }

    func testRequestTimesOutWhenAgentIgnores() async throws {
        let agent = FakePipeACPAgent()
        agent.ignoreHangMethod.withLock { $0 = true }
        agent.start()
        let conn = ACPConnection(
            testWrite: agent.clientToServer.fileHandleForWriting,
            testRead: agent.serverToClient.fileHandleForReading
        )
        try await conn.start()   // initialize is still answered

        do {
            _ = try await conn.request(method: "session/hang", params: nil, timeout: 0.3)
            XCTFail("expected a timeout from the unresponsive agent")
        } catch let ACPConnectionError.timeout(method, _) {
            XCTAssertEqual(method, "session/hang")
        } catch {
            // A teardown-driven serverCrashed is also acceptable once wedged.
        }
        await conn.shutdown()
        agent.stop()
    }

    // Bug #6: a restart must not carry a dead agent's half-written frame into the
    // new agent's handshake. reset() (called on (re)spawn and teardown) drops the
    // partial frame so the fresh agent's first frame decodes cleanly.
    func testLineSplitterResetDropsStalePartialFrame() {
        let splitter = ACPLineSplitter()
        // A half-written frame with no terminating newline stays buffered.
        let partial = Data(#"{"jsonrpc":"2.0","id":1,"result":{"half"#.utf8)
        XCTAssertTrue(splitter.feed(partial).isEmpty, "no newline yet, nothing emitted")

        splitter.reset()

        // Without reset, this fresh frame would be prefixed by the stale partial
        // and fail to decode. After reset it must decode on its own.
        let fresh = Data((#"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"# + "\n").utf8)
        let lines = splitter.feed(fresh)
        XCTAssertEqual(lines.count, 1)
        let decoded = ACPFrameCodec.decodeIncoming(lines[0])
        XCTAssertEqual(decoded?.intID, 2, "fresh frame decodes cleanly, not poisoned by the stale partial")
    }
}

// MARK: - Fake in-process ACP agent

// Minimal ACP agent over a pair of Pipes: answers initialize, can push a
// server-initiated request to the client, and captures the client's response to
// it. No Process, so the test exercises the real framing, correlation, and
// bidirectional handling fast.
private final class FakePipeACPAgent {
    let clientToServer = Pipe()   // client writes requests + responses here
    let serverToClient = Pipe()   // agent writes responses + requests here

    let sawInitialize = ACPLockedBox(false)
    let ignoreHangMethod = ACPLockedBox(false)
    let capturedResponse = ACPLockedBox<ACPIncoming?>(nil)
    var onCapturedResponse: (() -> Void)?

    private let queue = DispatchQueue(label: "grux.tests.fake-acp")
    private let splitter = ACPLineSplitter()

    func start() {
        clientToServer.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.handle(data) }
        }
    }

    func stop() {
        clientToServer.fileHandleForReading.readabilityHandler = nil
    }

    private func handle(_ data: Data) {
        for line in splitter.feed(data) {
            guard let incoming = ACPFrameCodec.decodeIncoming(line) else { continue }
            route(incoming)
        }
    }

    private func route(_ incoming: ACPIncoming) {
        // A frame with no method but a result/error is the client's reply to a
        // request WE initiated.
        if incoming.method == nil, incoming.result != nil || incoming.error != nil {
            capturedResponse.withLock { $0 = incoming }
            onCapturedResponse?()
            return
        }
        switch incoming.method {
        case "initialize":
            sawInitialize.withLock { $0 = true }
            respond(id: incoming.intID, result: .object([
                "protocolVersion": .int(1),
                "agentCapabilities": .object([:])
            ]))
        case "session/hang":
            if ignoreHangMethod.withLock({ $0 }) { return }
            respond(id: incoming.intID, result: .object([:]))
        default:
            if let id = incoming.intID {
                respond(id: id, result: .object(["ok": .bool(true)]))
            }
        }
    }

    // Push an agent-originated request to the client.
    func sendServerRequest(id: Int, method: String, params: ACPJSONValue?) {
        let frame = ACPRequest(id: id, method: method, params: params)
        guard let data = try? ACPFrameCodec.encodeLine(frame) else { return }
        queue.async { [weak self] in
            try? self?.serverToClient.fileHandleForWriting.write(contentsOf: data)
        }
    }

    private func respond(id: Int?, result: ACPJSONValue) {
        guard let id else { return }
        let frame = ACPResponseFrame(id: .int(id), result: result, error: nil)
        guard let data = try? ACPFrameCodec.encodeLine(frame) else { return }
        try? serverToClient.fileHandleForWriting.write(contentsOf: data)
    }
}

// Local lock box (named to avoid colliding with the MCP test suite's LockedBox).
private final class ACPLockedBox<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    @discardableResult
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
