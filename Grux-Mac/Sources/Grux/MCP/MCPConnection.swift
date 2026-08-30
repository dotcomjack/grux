import Foundation
import GruxMCPCore

// One live MCP server connection over the stdio transport: spawn the server
// as a subprocess, speak newline-delimited JSON-RPC 2.0 over its stdin and
// stdout, run the initialize handshake, then serve listTools/callTool with
// per-request timeouts. If the process dies mid-flight every pending request
// fails fast and the next call respawns the server (bounded restart budget so
// a crash-looping server cannot spin forever).
//
// Actor so the pending-continuation table, the line splitter, and process
// state are all serialized without locks. Pipe callbacks hop back in via
// unstructured Tasks.

enum MCPConnectionError: LocalizedError {
    case notStarted
    case spawnFailed(String)
    case serverCrashed(String)
    case timeout(method: String, seconds: TimeInterval)
    case rpcError(code: Int, message: String)
    case malformedResult(String)
    case restartBudgetExhausted

    var errorDescription: String? {
        switch self {
        case .notStarted: return "MCP server not started"
        case .spawnFailed(let why): return "failed to launch MCP server: \(why)"
        case .serverCrashed(let detail): return "MCP server exited unexpectedly\(detail.isEmpty ? "" : ": \(detail)")"
        case .timeout(let method, let seconds): return "MCP \(method) timed out after \(Int(seconds))s"
        case .rpcError(let code, let message): return "MCP error \(code): \(message)"
        case .malformedResult(let why): return "malformed MCP result: \(why)"
        case .restartBudgetExhausted: return "MCP server crashed repeatedly; not restarting again this session"
        }
    }
}

actor MCPConnection {
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case terminated(String)
    }

    // Spawn recipe (immutable for the connection's lifetime). envValues are
    // resolved from the Keychain by MCPManager BEFORE constructing the
    // connection so no Keychain reads happen off the main actor.
    private let serverName: String
    private let command: String
    private let args: [String]
    private let envValues: [String: String]

    // Test seam: when set, start() skips Process spawning and runs the
    // protocol over these handles instead (MCPFramingTests drives a fake
    // in-process pipe server through this). Restart logic is process-only.
    private let testWriteHandle: FileHandle?
    private let testReadHandle: FileHandle?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let splitter = MCPLineSplitter()

    // All stdin writes go through this serial queue, never the actor's
    // executor: write(2) blocks when the server stops draining its stdin
    // (or the frame exceeds the pipe buffer), and a blocked actor thread
    // would freeze timeoutPending/ingest, exactly the machinery that is
    // supposed to recover from a hung server. Serial keeps frame order.
    private let writeQueue = DispatchQueue(label: "grux.mcp.stdin-write")
    private var phase: Phase = .idle
    private var restartCount = 0
    private static let maxRestarts = 3

    // Most recent stderr line, surfaced in crash diagnostics.
    private var lastStderrLine = ""

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<MCPIncoming, Error>] = [:]

    // Requests whose stdin frame has not finished writing yet. A request
    // that times out while still in this set means write(2) is blocked:
    // the server stopped draining stdin and the connection is wedged for
    // good (a hung-but-alive child never fires terminationHandler, so
    // handleTermination cannot recover it).
    private var unwrittenRequests: Set<Int> = []
    // Consecutive request timeouts with no successful response in between.
    // A server that accepts frames but never answers is just as dead.
    private var consecutiveTimeouts = 0
    private static let wedgeTimeoutLimit = 3

    static let defaultCallTimeout: TimeInterval = 60
    static let handshakeTimeout: TimeInterval = 20

    init(serverName: String, command: String, args: [String], envValues: [String: String]) {
        self.serverName = serverName
        self.command = command
        self.args = args
        self.envValues = envValues
        self.testWriteHandle = nil
        self.testReadHandle = nil
    }

    // Test-only: drive the connection over caller-supplied pipe handles.
    init(serverName: String, testWrite: FileHandle, testRead: FileHandle) {
        self.serverName = serverName
        self.command = ""
        self.args = []
        self.envValues = [:]
        self.testWriteHandle = testWrite
        self.testReadHandle = testRead
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard phase == .idle || isTerminated else { return }
        phase = .starting
        do {
            try spawnIfNeeded()
            try await initializeHandshake()
            phase = .ready
        } catch {
            phase = .terminated(error.localizedDescription)
            tearDownProcess()
            throw error
        }
    }

    func shutdown() {
        failAllPending(with: MCPConnectionError.serverCrashed("shut down"))
        phase = .terminated("shut down")
        tearDownProcess()
    }

    var isReady: Bool { phase == .ready }

    private var isTerminated: Bool {
        if case .terminated = phase { return true }
        return false
    }

    private func spawnIfNeeded() throws {
        if let w = testWriteHandle, let r = testReadHandle {
            stdinHandle = w
            readHandle = r
            suppressSigpipe(on: w)
            attachReader(r)
            return
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let p = Process()
        // /usr/bin/env resolves bare command names (npx, uvx, node) against
        // PATH, which we augment because GUI apps inherit a bare launchd PATH
        // that misses Homebrew and user-local bins.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [command] + args
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.bun/bin"
        ]
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [basePath]).joined(separator: ":")
        for (k, v) in envValues { env[k] = v }
        p.environment = env
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.handleTermination(status: status) }
        }
        do {
            try p.run()
        } catch {
            throw MCPConnectionError.spawnFailed("\(command): \(error.localizedDescription)")
        }
        process = p
        stdinHandle = stdin.fileHandleForWriting
        readHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
        suppressSigpipe(on: stdin.fileHandleForWriting)
        attachReader(stdout.fileHandleForReading)
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                // EOF: the fd stays readable forever, so the dispatch read
                // source would re-fire this handler in a tight loop (pinned
                // worker thread) unless we detach it here.
                h.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let line = text.split(separator: "\n").last.map(String.init) ?? ""
            if !line.isEmpty {
                NSLog("[MCP %@ stderr] %@", self?.serverName ?? "?", line)
                Task { await self?.noteStderr(line) }
            }
        }
    }

    // Writing into a pipe whose reader died raises SIGPIPE, which by default
    // terminates the whole app. Mark the fd so a dead-server write surfaces
    // as a catchable EPIPE error instead.
    private func suppressSigpipe(on handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    private func attachReader(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                // EOF: detach or the read source busy-spins (see stderr above).
                h.readabilityHandler = nil
                return
            }
            Task { await self?.ingest(data) }
        }
    }

    private func noteStderr(_ line: String) {
        lastStderrLine = line
    }

    private func handleTermination(status: Int32) {
        guard !isTerminated else { return }
        let detail = lastStderrLine.isEmpty ? "exit \(status)" : "exit \(status), \(lastStderrLine)"
        phase = .terminated(detail)
        failAllPending(with: MCPConnectionError.serverCrashed(detail))
        tearDownProcess()
        NSLog("[MCPConnection] %@ terminated (%@)", serverName, detail)
    }

    private func tearDownProcess() {
        readHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        if testWriteHandle == nil {
            try? stdinHandle?.close()
            if let p = process, p.isRunning {
                p.terminate()
                // A SIGTERM-ignoring hung server keeps its stdin reader fd
                // open, pinning any write(2) still blocked on writeQueue and
                // head-of-line-blocking the next generation's handshake
                // frames behind it. Escalate to SIGKILL after a grace period
                // so the kernel closes the fds and unblocks the queue.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    if p.isRunning {
                        kill(p.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        process = nil
        stdinHandle = nil
        readHandle = nil
        stderrHandle = nil
    }

    private func failAllPending(with error: Error) {
        let conts = pending.values
        pending.removeAll()
        unwrittenRequests.removeAll()
        for c in conts { c.resume(throwing: error) }
    }

    // Respawn after a crash, bounded. Test-mode connections never restart.
    private func ensureReady() async throws {
        switch phase {
        case .ready:
            return
        case .idle:
            try await start()
        case .starting:
            // A concurrent start is in flight; actor reentrancy means we can
            // briefly poll until it settles.
            for _ in 0..<200 where phase == .starting {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if phase != .ready { throw MCPConnectionError.notStarted }
        case .terminated:
            guard testWriteHandle == nil else { throw MCPConnectionError.notStarted }
            guard restartCount < Self.maxRestarts else { throw MCPConnectionError.restartBudgetExhausted }
            restartCount += 1
            NSLog("[MCPConnection] restarting %@ (attempt %d/%d)", serverName, restartCount, Self.maxRestarts)
            phase = .idle
            try await start()
        }
    }

    // MARK: - Handshake

    private func initializeHandshake() async throws {
        let params = MCPProtocol.initializeParams(clientName: "Grux", clientVersion: "1.0")
        let response = try await sendRequest(method: "initialize", params: params, timeout: Self.handshakeTimeout)
        guard let result = response.result, result["protocolVersion"]?.strictStringValue != nil else {
            throw MCPConnectionError.malformedResult("initialize response missing protocolVersion")
        }
        try sendNotification(method: "notifications/initialized")
    }

    // MARK: - Public API

    func listTools() async throws -> [MCPToolDescriptor] {
        try await ensureReady()
        var all: [MCPToolDescriptor] = []
        var cursor: String? = nil
        // Paginated per spec; cap pages defensively.
        for _ in 0..<16 {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let response = try await sendRequest(method: "tools/list", params: params, timeout: Self.handshakeTimeout)
            guard let result = response.result else {
                throw MCPConnectionError.malformedResult("tools/list returned no result")
            }
            let page = MCPToolDescriptor.parseList(result)
            all.append(contentsOf: page.tools)
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        return all
    }

    func callTool(name: String, arguments: JSONValue, timeoutSeconds: TimeInterval = MCPConnection.defaultCallTimeout) async throws -> MCPCallToolResult {
        try await ensureReady()
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments
        ])
        let response = try await sendRequest(method: "tools/call", params: params, timeout: timeoutSeconds)
        guard let result = response.result else {
            throw MCPConnectionError.malformedResult("tools/call returned no result")
        }
        return MCPCallToolResult.parse(result)
    }

    // MARK: - Wire I/O

    private func sendRequest(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> MCPIncoming {
        guard let stdin = stdinHandle else { throw MCPConnectionError.notStarted }
        let id = nextID
        nextID += 1
        let frame = MCPRequest(id: id, method: method, params: params)
        let data: Data
        do {
            data = try MCPFrameCodec.encodeLine(frame)
        } catch {
            throw MCPConnectionError.malformedResult("encode failed: \(error.localizedDescription)")
        }

        let response: MCPIncoming = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            unwrittenRequests.insert(id)
            // The blocking write happens on writeQueue, never the actor's
            // executor, so a server that stops draining stdin cannot wedge
            // the actor: the timeout below still fires and fails this call.
            writeQueue.async { [weak self] in
                do {
                    try stdin.write(contentsOf: data)
                    Task { await self?.noteStdinWriteFinished(id: id) }
                } catch {
                    Task { await self?.failPending(id: id, error: MCPConnectionError.serverCrashed("stdin write failed")) }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutPending(id: id, method: method, seconds: timeout)
            }
        }

        if let err = response.error {
            throw MCPConnectionError.rpcError(code: err.code, message: err.message)
        }
        return response
    }

    private func sendNotification(method: String, params: JSONValue? = nil) throws {
        guard let stdin = stdinHandle else { throw MCPConnectionError.notStarted }
        let frame = MCPRequest(id: nil, method: method, params: params)
        let data = try MCPFrameCodec.encodeLine(frame)
        // Fire-and-forget off the actor; notifications have no reply to fail.
        writeQueue.async {
            try? stdin.write(contentsOf: data)
        }
    }

    private func noteStdinWriteFinished(id: Int) {
        unwrittenRequests.remove(id)
    }

    private func timeoutPending(id: Int, method: String, seconds: TimeInterval) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        let stdinWedged = unwrittenRequests.contains(id)
        unwrittenRequests.remove(id)
        cont.resume(throwing: MCPConnectionError.timeout(method: method, seconds: seconds))
        consecutiveTimeouts += 1

        // Recovery: a hung-but-alive server never exits, so terminationHandler
        // never fires and phase would stay .ready forever, with every retry
        // queueing behind the blocked write. Leave .ready here so the next
        // ensureReady() respawns per the header contract. A single timeout
        // with a completed write is tolerated (slow tool), but a write that
        // never finished, or repeated timeouts in a row, means wedged.
        if phase == .ready, stdinWedged || consecutiveTimeouts >= Self.wedgeTimeoutLimit {
            let detail = stdinWedged
                ? "stdin wedged (server stopped draining)"
                : "unresponsive (\(consecutiveTimeouts) consecutive timeouts)"
            NSLog("[MCPConnection] %@ %@ - tearing down for respawn", serverName, detail)
            phase = .terminated(detail)
            failAllPending(with: MCPConnectionError.serverCrashed(detail))
            tearDownProcess()
        }
    }

    private func failPending(id: Int, error: Error) {
        unwrittenRequests.remove(id)
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: error)
    }

    private func ingest(_ data: Data) {
        for line in splitter.feed(data) {
            guard let incoming = MCPFrameCodec.decodeIncoming(line) else {
                NSLog("[MCPConnection] %@ sent undecodable frame (%d bytes)", serverName, line.count)
                continue
            }
            if incoming.isResponse {
                if let id = incoming.intID {
                    // A correlated response arriving AT ALL proves the server is
                    // alive, even if the request already timed out and was
                    // removed from `pending` (a slow-but-successful tool call).
                    // Reset the wedge counter here, before the pending lookup,
                    // so three slow-but-answered calls can't trip the
                    // "unresponsive" teardown on a healthy server.
                    consecutiveTimeouts = 0
                    if let cont = pending.removeValue(forKey: id) {
                        cont.resume(returning: incoming)
                    }
                }
            } else if incoming.isServerRequest {
                respondToServerRequest(incoming)
            }
            // Server notifications (logging, progress) are ignored in v1.
        }
    }

    // Servers may ping the client; answer so they do not drop the session.
    // Anything else gets a polite method-not-found.
    private func respondToServerRequest(_ incoming: MCPIncoming) {
        guard let stdin = stdinHandle, let id = incoming.id else { return }
        struct Reply: Encodable {
            let jsonrpc = "2.0"
            let id: JSONValue
            let result: JSONValue?
            let error: MCPErrorObject?
        }
        let reply: Reply
        if incoming.method == "ping" {
            reply = Reply(id: id, result: .object([:]), error: nil)
        } else {
            reply = Reply(id: id, result: nil, error: MCPErrorObject(code: -32601, message: "method not supported by Grux client", data: nil))
        }
        if let data = try? MCPFrameCodec.encodeLine(reply) {
            writeQueue.async {
                try? stdin.write(contentsOf: data)
            }
        }
    }
}
