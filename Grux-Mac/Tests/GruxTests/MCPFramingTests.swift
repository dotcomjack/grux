import XCTest
@testable import Grux
// The splitter these tests exercise moved to GruxMCPCore, so they now cover the ONE
// copy the app, the stdio server and the control socket all share.
import GruxMCPCore

// Items 14 and 15 (in-app MCP client + registry) framing coverage:
//   1. JSONValue bridges cleanly in both directions (Any <-> Codable) since
//      it is the seam between MCP JSON and ClaudeTool's [String: Any] world.
//   2. JSON-RPC request encoding omits the id key for notifications and pins
//      jsonrpc "2.0" (stdio servers reject anything else).
//   3. MCPLineSplitter survives frames split across reads, multiple frames
//      per read, CRLF, and blank keepalive lines.
//   4. Tool namespacing round-trips mcp_<slug>_<tool> and sanitizes hostile
//      server names; parse() splits on the FIRST underscore so tool names
//      containing underscores survive.
//   5. tools/list and tools/call result parsing, including isError and the
//      text flattening contract dispatchTool feeds back to Claude.
//   6. A fake in-process pipe server drives a real MCPConnection through the
//      initialize handshake, tools/list, tools/call, and an RPC error,
//      without spawning any subprocess.

final class MCPFramingTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValueBridgesFromAnyAndBack() throws {
        let input: [String: Any] = [
            "text": "hi",
            "count": 3,
            "ratio": 1.5,
            "flag": true,
            "nested": ["a": [1, 2, 3]],
            "nothing": NSNull()
        ]
        let value = JSONValue.bridged(fromAny: input)
        let back = try XCTUnwrap(value.anyValue as? [String: Any])
        XCTAssertEqual(back["text"] as? String, "hi")
        XCTAssertEqual(back["count"] as? Int, 3)
        XCTAssertEqual(back["ratio"] as? Double, 1.5)
        XCTAssertEqual(back["flag"] as? Bool, true)
        let nested = try XCTUnwrap(back["nested"] as? [String: Any])
        XCTAssertEqual(nested["a"] as? [Int], [1, 2, 3])
        XCTAssertTrue(back["nothing"] is NSNull)
    }

    // JSONSerialization hands back NSNumbers; CFBoolean discrimination must
    // keep `true` a bool while `1` stays an int (the shared init(any:) checks
    // `as? Bool` first, which would also match NSNumber 0/1).
    func testBridgedKeepsBoolAndIntDistinctFromJSONSerialization() throws {
        let raw = #"{"flag": true, "count": 1, "zero": 0}"#.data(using: .utf8)!
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let value = JSONValue.bridged(fromAny: parsed)
        XCTAssertEqual(value["flag"], .bool(true))
        XCTAssertEqual(value["count"], .int(1))
        XCTAssertEqual(value["zero"], .int(0))
    }

    func testJSONValueCodableRoundTrip() throws {
        let original = JSONValue.object([
            "s": .string("x"),
            "i": .int(42),
            "d": .double(2.25),
            "b": .bool(false),
            "n": .null,
            "a": .array([.int(1), .string("two")])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testBridgedFallsBackToStringForNonJSONTypes() {
        // Mirrors the shared JSONValue.init(any:) posture: never crash, never
        // drop a key, stringify the unknown.
        if case .string = JSONValue.bridged(fromAny: Date()) {
            // expected
        } else {
            XCTFail("non-JSON types must bridge to a string description")
        }
    }

    // MARK: - Request encoding

    func testRequestEncodingIncludesIdAndVersion() throws {
        let req = MCPRequest(id: 7, method: "tools/list", params: .object([:]))
        let data = try MCPFrameCodec.encodeLine(req)
        XCTAssertEqual(data.last, 0x0A, "frames must be newline terminated")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["id"] as? Int, 7)
        XCTAssertEqual(obj["method"] as? String, "tools/list")
    }

    func testNotificationEncodingOmitsId() throws {
        let note = MCPRequest(id: nil, method: "notifications/initialized")
        let data = try MCPFrameCodec.encodeLine(note)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertNil(obj["id"], "notifications must not carry an id key")
        XCTAssertNil(obj["params"], "nil params must be omitted, not null")
    }

    func testIncomingDecodeResponseAndError() throws {
        let ok = #"{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}"#.data(using: .utf8)!
        let incoming = try XCTUnwrap(MCPFrameCodec.decodeIncoming(ok))
        XCTAssertTrue(incoming.isResponse)
        XCTAssertEqual(incoming.intID, 3)
        XCTAssertNil(incoming.error)

        let bad = #"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"nope"}}"#.data(using: .utf8)!
        let errIncoming = try XCTUnwrap(MCPFrameCodec.decodeIncoming(bad))
        XCTAssertTrue(errIncoming.isResponse)
        XCTAssertEqual(errIncoming.error?.code, -32601)
        XCTAssertEqual(errIncoming.error?.message, "nope")
    }

    // MARK: - Line splitting

    func testLineSplitterHandlesChunksCRLFAndBlanks() {
        let splitter = MCPLineSplitter()
        // First frame split across two reads.
        XCTAssertTrue(splitter.feed(Data(#"{"id":1"#.utf8)).isEmpty)
        let first = splitter.feed(Data(",\"result\":{}}\n".utf8))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(String(data: first[0], encoding: .utf8), #"{"id":1,"result":{}}"#)

        // Two frames plus a blank keepalive and CRLF in one read.
        let burst = "{\"id\":2}\r\n\n{\"id\":3}\n".data(using: .utf8)!
        let lines = splitter.feed(burst)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), #"{"id":2}"#)
        XCTAssertEqual(String(data: lines[1], encoding: .utf8), #"{"id":3}"#)
    }

    // A server that floods stdout with no newline must not grow the splitter
    // buffer without bound (OOM DoS). Past maxFrameBytes the partial frame is
    // discarded; a later genuine newline re-syncs the stream.
    func testLineSplitterCapsUnterminatedFlood() {
        let splitter = MCPLineSplitter()
        // Feed 5 x 5 MB = 25 MB of newline-free junk. The cap (16 MB) trips and
        // the partial frame is discarded to zero, so the buffer never grows
        // without bound. Each feed yields no completed line.
        let junk = Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024)
        for _ in 0..<5 { XCTAssertTrue(splitter.feed(junk).isEmpty) }
        // The buffer was cleared on the 4th feed (20 MB > 16 MB) and again on
        // the 5th, leaving only the latest 5 MB; a single newline now flushes
        // the remaining junk so the NEXT frame parses cleanly.
        _ = splitter.feed(Data("\n".utf8)) // flush residual junk frame
        let lines = splitter.feed(Data("{\"id\":9}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), #"{"id":9}"#)
    }

    // MARK: - Namespacing

    func testNamespacingRoundTrip() throws {
        let name = MCPToolNaming.namespaced(serverSlug: "github", tool: "create_issue")
        XCTAssertEqual(name, "mcp_github_create_issue")
        let parsed = try XCTUnwrap(MCPToolNaming.parse(name))
        XCTAssertEqual(parsed.serverSlug, "github")
        XCTAssertEqual(parsed.tool, "create_issue", "must split on the FIRST underscore only")
    }

    func testSlugSanitizesHostileServerNames() {
        XCTAssertEqual(MCPToolNaming.slug(forServerName: "My GitHub (work)"), "my-github-work")
        XCTAssertEqual(MCPToolNaming.slug(forServerName: "under_scores here"), "under-scores-here")
        XCTAssertEqual(MCPToolNaming.slug(forServerName: "!!!"), "server")
        XCTAssertFalse(MCPToolNaming.slug(forServerName: "x_y").contains("_"),
                       "slugs must never contain underscores or parse() becomes ambiguous")
    }

    // Two distinctly-named servers that truncate to the same 20-char slug must
    // get distinct slugs so the second one's tools stay routable.
    func testDisambiguatedSlugsAvoidTruncationCollision() {
        let a = UUID()
        let b = UUID()
        // Both slug to "github-enterprise-se" under the 20-char cap.
        XCTAssertEqual(MCPToolNaming.slug(forServerName: "GitHub Enterprise Server Production"),
                       MCPToolNaming.slug(forServerName: "GitHub Enterprise Server Staging"))
        let slugs = MCPToolNaming.disambiguatedSlugs(for: [
            (a, "GitHub Enterprise Server Production"),
            (b, "GitHub Enterprise Server Staging")
        ])
        XCTAssertNotNil(slugs[a])
        XCTAssertNotNil(slugs[b])
        XCTAssertNotEqual(slugs[a], slugs[b], "colliding slugs must be disambiguated")
        // First server keeps the plain slug; second gets the discriminator.
        XCTAssertEqual(slugs[a], "github-enterprise-se")
        XCTAssertTrue(slugs[b]!.hasPrefix("github-enterpri-"))
        // Resulting namespaced names must round-trip.
        let nameB = MCPToolNaming.namespaced(serverSlug: slugs[b]!, tool: "search")
        XCTAssertNotEqual(nameB, MCPToolNaming.namespaced(serverSlug: slugs[a]!, tool: "search"))
    }

    func testNamespacedNameRespectsAnthropicLengthCap() {
        let long = String(repeating: "a", count: 100)
        let name = MCPToolNaming.namespaced(serverSlug: "server", tool: long)
        XCTAssertLessThanOrEqual(name.count, MCPToolNaming.maxNameLength)
        XCTAssertTrue(name.hasPrefix("mcp_server_"))
    }

    func testNonMCPNamesDoNotParse() {
        XCTAssertNil(MCPToolNaming.parse("add_task"))
        XCTAssertNil(MCPToolNaming.parse("mcp_noseparator"))
        XCTAssertFalse(MCPToolNaming.isMCPToolName("slack_send"))
    }

    // MARK: - Result parsing

    func testToolsListParsing() throws {
        let result = JSONValue.object([
            "tools": .array([
                .object([
                    "name": .string("echo"),
                    "description": .string("Echoes input."),
                    "inputSchema": .object(["type": .string("object")])
                ]),
                .object(["description": .string("nameless, must be dropped")])
            ]),
            "nextCursor": .string("page2")
        ])
        let parsed = MCPToolDescriptor.parseList(result)
        XCTAssertEqual(parsed.tools.map(\.name), ["echo"])
        XCTAssertEqual(parsed.tools[0].description, "Echoes input.")
        XCTAssertEqual(parsed.nextCursor, "page2")
    }

    func testCallToolResultFlattening() {
        let result = JSONValue.object([
            "isError": .bool(false),
            "content": .array([
                .object(["type": .string("text"), "text": .string("line one")]),
                .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("AAAA")]),
                .object(["type": .string("text"), "text": .string("line two")])
            ])
        ])
        let parsed = MCPCallToolResult.parse(result)
        XCTAssertFalse(parsed.isError)
        XCTAssertEqual(parsed.flattenedText, "line one\n[image/png image, 4 base64 chars]\nline two")

        let errResult = MCPCallToolResult.parse(.object([
            "isError": .bool(true),
            "content": .array([.object(["type": .string("text"), "text": .string("boom")])])
        ]))
        XCTAssertTrue(errResult.isError)
        XCTAssertEqual(errResult.flattenedText, "boom")
    }

    // MARK: - Fake in-process pipe server end to end

    func testConnectionHandshakeListAndCallAgainstFakeServer() async throws {
        let server = FakePipeMCPServer()
        server.start()
        let conn = MCPConnection(
            serverName: "fake",
            testWrite: server.clientToServer.fileHandleForWriting,
            testRead: server.serverToClient.fileHandleForReading
        )
        try await conn.start()

        let tools = try await conn.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        // The pipe is FIFO and the fake server handles frames in order on a
        // serial queue, so by the time tools/list was answered the
        // notifications/initialized frame (written earlier) was processed.
        XCTAssertTrue(server.sawInitializedNotification.withLock { $0 },
                      "client must send notifications/initialized after the initialize response")

        let result = try await conn.callTool(
            name: "echo",
            arguments: .object(["text": .string("hi grux")]),
            timeoutSeconds: 5
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.flattenedText, "echo: hi grux")

        // Unknown tool surfaces as a JSON-RPC error, not a hang.
        do {
            _ = try await conn.callTool(name: "missing", arguments: .object([:]), timeoutSeconds: 5)
            XCTFail("expected rpcError")
        } catch let MCPConnectionError.rpcError(code, message) {
            XCTAssertEqual(code, -32602)
            XCTAssertTrue(message.contains("missing"))
        }

        await conn.shutdown()
        server.stop()
    }

    // A server that handshakes fine but then stops answering must not stay
    // .ready forever: repeated timeouts tear the connection down so the next
    // call can respawn it (per the header contract), instead of every retry
    // queueing behind a wedged request until app relaunch.
    func testRepeatedTimeoutsTearDownUnresponsiveConnection() async throws {
        let server = FakePipeMCPServer()
        server.ignoreToolCalls.withLock { $0 = true }
        server.start()
        let conn = MCPConnection(
            serverName: "hung",
            testWrite: server.clientToServer.fileHandleForWriting,
            testRead: server.serverToClient.fileHandleForReading
        )
        try await conn.start()
        let readyBefore = await conn.isReady
        XCTAssertTrue(readyBefore)

        for _ in 0..<3 {
            do {
                _ = try await conn.callTool(name: "echo", arguments: .object([:]), timeoutSeconds: 0.2)
                XCTFail("expected a timeout from the unresponsive server")
            } catch {
                // timeout (then serverCrashed once torn down) both acceptable
            }
        }
        let readyAfter = await conn.isReady
        XCTAssertFalse(readyAfter, "consecutive timeouts must tear down the connection for respawn")
        await conn.shutdown()
        server.stop()
    }

    // A server whose read end is gone (crashed child) must surface as a
    // thrown error, not a SIGPIPE that kills the whole process. The
    // connection marks the write fd F_SETNOSIGPIPE and performs the write
    // off the actor, so the EPIPE comes back as serverCrashed.
    func testWriteToDeadReaderFailsWithoutKillingProcess() async {
        let toServer = Pipe()
        let fromServer = Pipe()
        // Simulate the server dying: nobody will ever read our requests.
        try? toServer.fileHandleForReading.close()
        let conn = MCPConnection(
            serverName: "dead",
            testWrite: toServer.fileHandleForWriting,
            testRead: fromServer.fileHandleForReading
        )
        do {
            try await conn.start()
            XCTFail("handshake against a dead reader must throw")
        } catch {
            // Reaching here at all proves the EPIPE was caught, not fatal.
        }
        await conn.shutdown()
    }
}

// MARK: - Fake server

// Minimal in-process MCP server speaking newline-delimited JSON-RPC over a
// pair of Pipes. Supports initialize, tools/list (one page, one echo tool),
// and tools/call for that tool. No Process involved, so the test exercises
// MCPConnection's real framing, correlation, and handshake paths fast.
final class FakePipeMCPServer {
    let clientToServer = Pipe()  // MCPConnection writes requests here
    let serverToClient = Pipe()  // MCPConnection reads responses here

    let sawInitializedNotification = LockedBox(false)
    // When true, tools/call frames are swallowed (handshake still answers):
    // simulates a server that accepts stdin but stops responding.
    let ignoreToolCalls = LockedBox(false)

    private let queue = DispatchQueue(label: "grux.tests.fake-mcp-server")
    private let splitter = MCPLineSplitter()

    func start() {
        clientToServer.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.handle(data) }
        }
    }

    func stop() {
        clientToServer.fileHandleForReading.readabilityHandler = nil
    }

    private func handle(_ data: Data) {
        for line in splitter.feed(data) {
            guard let incoming = MCPFrameCodec.decodeIncoming(line) else { continue }
            route(incoming)
        }
    }

    private func route(_ incoming: MCPIncoming) {
        switch incoming.method {
        case "initialize":
            respond(id: incoming.intID, result: .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("fake"), "version": .string("1.0")])
            ]))
        case "notifications/initialized":
            sawInitializedNotification.withLock { $0 = true }
        case "tools/list":
            respond(id: incoming.intID, result: .object([
                "tools": .array([
                    .object([
                        "name": .string("echo"),
                        "description": .string("Echoes the text argument."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object(["text": .object(["type": .string("string")])]),
                            "required": .array([.string("text")])
                        ])
                    ])
                ])
            ]))
        case "tools/call":
            if ignoreToolCalls.withLock({ $0 }) { return }
            let toolName = incoming.params?["name"]?.stringValue ?? ""
            if toolName == "echo" {
                let text = incoming.params?["arguments"]?["text"]?.stringValue ?? ""
                respond(id: incoming.intID, result: .object([
                    "isError": .bool(false),
                    "content": .array([.object(["type": .string("text"), "text": .string("echo: \(text)")])])
                ]))
            } else {
                respondError(id: incoming.intID, code: -32602, message: "unknown tool '\(toolName)' (missing)")
            }
        default:
            break
        }
    }

    private struct OKFrame: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let result: JSONValue
    }

    private struct ErrFrame: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let error: MCPErrorObject
    }

    private func respond(id: Int?, result: JSONValue) {
        guard let id, let data = try? MCPFrameCodec.encodeLine(OKFrame(id: id, result: result)) else { return }
        try? serverToClient.fileHandleForWriting.write(contentsOf: data)
    }

    private func respondError(id: Int?, code: Int, message: String) {
        guard let id else { return }
        let frame = ErrFrame(id: id, error: MCPErrorObject(code: code, message: message, data: nil))
        guard let data = try? MCPFrameCodec.encodeLine(frame) else { return }
        try? serverToClient.fileHandleForWriting.write(contentsOf: data)
    }
}

// Tiny lock wrapper so the fake server can flip a flag from its queue while
// the test thread reads it, without importing anything beyond Foundation.
final class LockedBox<T> {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    @discardableResult
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
