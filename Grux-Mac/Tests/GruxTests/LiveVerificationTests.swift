import XCTest
import Network
@testable import Grux

// Live-network end-to-end verification. Every test is gated behind
// GRUX_LIVE=1 so CI and ordinary `swift test` runs stay hermetic; these only
// fire when an operator explicitly opts in:
//
//   GRUX_LIVE=1 swift test --filter LiveVerificationTests
//
// Coverage:
//   - MCP: spawn the reference @modelcontextprotocol/server-everything via
//     npx over stdio, run the real initialize handshake, list tools.
//   - YouTube: fetch the live transcript for jNQXAC9IVRw ("Me at the zoo").
//   - Webhooks: stand up an in-test NWListener HTTP server and push one
//     delivery through WebhookManager's production URLSession sender,
//     verifying the HMAC signature on the received bytes.
final class LiveVerificationTests: XCTestCase {

    private static func requireLive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["GRUX_LIVE"] == "1",
            "live-network test; set GRUX_LIVE=1 to run"
        )
    }

    // MARK: - (a) MCP live spawn

    // Search PATH plus the same well-known dirs MCPConnection injects, so the
    // skip decision matches what the connection will actually be able to run.
    private func npxPath() -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        let fm = FileManager.default
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent("npx")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // Pre-download the server package into the npx cache so the connection's
    // fixed 20s handshake timeout is not spent on a cold npm install.
    private func warmNpxCache(npx: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: npx)
        p.arguments = ["-y", "-p", "@modelcontextprotocol/server-everything", "node", "-e", "process.exit(0)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return // connection spawn will surface any real problem
        }
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if p.isRunning { p.terminate() }
    }

    func test_mcp_liveSpawn_initializeAndListTools() async throws {
        try Self.requireLive()
        guard let npx = npxPath() else {
            throw XCTSkip("npx not found on PATH or in well-known bins; cannot spawn an MCP server")
        }
        warmNpxCache(npx: npx)

        let connection = MCPConnection(
            serverName: "everything-live-test",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-everything"],
            envValues: [:]
        )
        defer { Task { await connection.shutdown() } }

        try await connection.start()
        let ready = await connection.isReady
        XCTAssertTrue(ready, "connection should be ready after initialize handshake")

        let tools = try await connection.listTools()
        XCTAssertFalse(tools.isEmpty, "server-everything should advertise at least one tool")
        XCTAssertTrue(tools.allSatisfy { !$0.name.isEmpty })
        await connection.shutdown()
    }

    // MARK: - (b) YouTube live transcript

    func test_youtube_liveTranscript_meAtTheZoo() async throws {
        try Self.requireLive()

        // "Me at the zoo", 19 seconds, public since 2005, has captions.
        let result = try await YouTubeTranscript.fetch(
            urlOrId: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        )
        XCTAssertEqual(result.videoId, "jNQXAC9IVRw")
        XCTAssertFalse(result.segments.isEmpty, "expected at least one caption segment")

        let text = result.plainText
        XCTAssertFalse(text.isEmpty, "transcript plain text should be non-empty")
        if !text.lowercased().contains("elephants") {
            // Caption wording can drift between manual / auto tracks; fall
            // back to asserting we got a substantive transcript.
            XCTAssertGreaterThan(
                text.count, 50,
                "transcript lacked 'elephants' and was too short to be the real captions: '\(text)'"
            )
        }
    }

    // MARK: - (c) Webhook live delivery

    // Minimal one-shot HTTP server on a loopback TCP port. Accepts a single
    // connection, reads one full request (headers + Content-Length body),
    // replies 200, and hands the captured request to the test.
    private final class OneShotHTTPServer: @unchecked Sendable {
        struct CapturedRequest {
            let headers: [String: String]  // lowercased names
            let body: Data
        }

        private let listener: NWListener
        private let lock = NSLock()
        private var buffer = Data()
        private var captured: CapturedRequest?
        private let semaphore = DispatchSemaphore(value: 0)

        var port: UInt16 { listener.port?.rawValue ?? 0 }

        init() throws {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: .any)
        }

        func start() throws {
            let readySem = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { readySem.signal() }
                if case .failed = state { readySem.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .global(qos: .userInitiated))
                self.receiveLoop(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            guard readySem.wait(timeout: .now() + 10) == .success, listener.port != nil else {
                throw NSError(domain: "OneShotHTTPServer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "listener did not become ready"
                ])
            }
        }

        private func receiveLoop(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.lock.lock()
                    self.buffer.append(data)
                    let snapshot = self.buffer
                    self.lock.unlock()
                    if let request = Self.parse(snapshot) {
                        self.lock.lock()
                        let already = self.captured != nil
                        if !already { self.captured = request }
                        self.lock.unlock()
                        if !already {
                            let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                            connection.send(
                                content: Data(response.utf8),
                                completion: .contentProcessed { _ in
                                    connection.cancel()
                                }
                            )
                            self.semaphore.signal()
                        }
                        return
                    }
                }
                if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                self.receiveLoop(connection)
            }
        }

        // Returns a parsed request once headers AND the full Content-Length
        // body have arrived; nil while incomplete.
        private static func parse(_ raw: Data) -> CapturedRequest? {
            guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headerData = raw[raw.startIndex..<headerEnd.lowerBound]
            guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
            var headers: [String: String] = [:]
            for line in headerText.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let body = raw[headerEnd.upperBound...]
            guard body.count >= contentLength else { return nil }
            return CapturedRequest(headers: headers, body: Data(body.prefix(contentLength)))
        }

        func waitForRequest(timeout: TimeInterval) -> CapturedRequest? {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return captured
        }

        func stop() {
            listener.cancel()
        }
    }

    func test_webhook_liveDelivery_signedAndReceived() async throws {
        try Self.requireLive()

        let server = try OneShotHTTPServer()
        try server.start()
        defer { server.stop() }
        let port = server.port
        XCTAssertGreaterThan(port, 0, "listener should have bound a real port")

        // Production send path: default sender (real URLSession POST) and
        // default sleeper. Only the audit sink is swapped so the test does
        // not write delivery records into the app's on-disk store.
        let manager = WebhookManager(auditSink: { _ in })

        let secret = "whsec_live_verification_secret"
        let config = WebhookConfig(
            name: "live-verify",
            url: "http://127.0.0.1:\(port)/hook",
            events: [.testFire]
        )

        let delivery = await manager.deliver(
            config: config,
            secret: secret,
            event: .testFire,
            payload: ["message": "live verification", "webhookName": config.name]
        )

        XCTAssertEqual(delivery.outcome, .delivered, "delivery failed: \(delivery.errorMessage ?? "?")")
        XCTAssertEqual(delivery.statusCode, 200)
        XCTAssertEqual(delivery.attempts, 1)

        guard let request = server.waitForRequest(timeout: 20) else {
            XCTFail("listener never received the webhook POST")
            return
        }

        // Headers per the wire contract in WebhookManager.
        XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertEqual(request.headers["x-grux-event"], WebhookEvent.testFire.rawValue)
        XCTAssertNotNil(UUID(uuidString: request.headers["x-grux-delivery"] ?? ""))

        // HMAC: recompute over the exact received bytes and compare.
        let signatureHeader = request.headers["x-grux-signature"] ?? ""
        XCTAssertTrue(signatureHeader.hasPrefix("sha256="), "missing or malformed signature header")
        let expected = WebhookManager.signature(secret: secret, body: request.body)
        XCTAssertEqual(signatureHeader, expected, "HMAC signature did not verify over the received body")

        // Body sanity: canonical envelope JSON with our payload.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertEqual(json["event"] as? String, "test_fire")
        let payload = try XCTUnwrap(json["payload"] as? [String: String])
        XCTAssertEqual(payload["message"], "live verification")
    }
}
