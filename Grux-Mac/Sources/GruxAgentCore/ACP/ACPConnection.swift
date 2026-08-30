import Foundation

// MARK: - Agent Client Protocol (ACP) client
//
// A bidirectional JSON-RPC 2.0 client over an agent subprocess's stdio. Unlike
// the MCP client (which only ever answers a server `ping`), ACP agents send the
// client real requests mid-run: permission prompts, filesystem reads, and so
// on. So this connection carries an injectable server-request handler that app
// logic supplies to answer those.
//
// This is fresh Foundation-only code. It deliberately does NOT import the app's
// MCP layer; it reproduces the same transport hygiene the MCP contract proved
// out (writeQueue for blocking writes, F_SETNOSIGPIPE, EOF handler detach,
// pending-continuation correlation with per-request timeouts, terminate-then-
// SIGKILL teardown, bounded restart budget) with ACP's own wire types and its
// own `initialize` handshake.

// MARK: - Wire value

// Minimal Any-Codable JSON value for ACP params/results. Self-contained so the
// core stays Foundation-only (the app's JSONValue lives in the Grux target).
public enum ACPJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ACPJSONValue])
    case object([String: ACPJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ACPJSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: ACPJSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var objectValue: [String: ACPJSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [ACPJSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .int(let i) = self { return i }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public subscript(key: String) -> ACPJSONValue? { objectValue?[key] }
}

public struct ACPErrorObject: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: ACPJSONValue?
    public init(code: Int, message: String, data: ACPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// Outgoing client-originated frame. nil id = notification (the synthesized
// Encodable omits nil optionals, so the id key vanishes, per JSON-RPC 2.0).
struct ACPRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: ACPJSONValue?

    init(id: Int?, method: String, params: ACPJSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

// Reply we write back to an agent-initiated request.
struct ACPResponseFrame: Encodable {
    let jsonrpc = "2.0"
    let id: ACPJSONValue
    let result: ACPJSONValue?
    let error: ACPErrorObject?
}

// One decoded inbound line, before we know its kind. id is a full JSONValue so
// string-typed ids (agents may use them) round-trip when we answer.
public struct ACPIncoming: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: ACPJSONValue?
    public let method: String?
    public let params: ACPJSONValue?
    public let result: ACPJSONValue?
    public let error: ACPErrorObject?

    public var isResponse: Bool { method == nil && (result != nil || error != nil) }
    public var isServerRequest: Bool { method != nil && id != nil }
    public var isNotification: Bool { method != nil && id == nil }
    public var intID: Int? { id?.intValue }
}

enum ACPFrameCodec {
    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decodeIncoming(_ line: Data) -> ACPIncoming? {
        try? JSONDecoder().decode(ACPIncoming.self, from: line)
    }
}

// Newline-delimited frame splitter. Tolerates split frames, multiple frames per
// read, CRLF, blank keepalives; 16 MB unterminated-frame cap for OOM safety.
// Not thread-safe: confined to one actor.
final class ACPLineSplitter {
    private var buffer = Data()
    static let maxFrameBytes = 16 * 1024 * 1024

    func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        if buffer.count > Self.maxFrameBytes {
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }

    // Drop any buffered partial frame. Called on (re)spawn and teardown so a
    // restart never feeds a dead agent's half-written frame into the new agent's
    // handshake, which would poison decoding (bug: stale partial-frame buffer
    // survived a restart).
    func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

// MARK: - Server-request handling

// What the app returns when the agent asks it something.
public enum ACPServerResponse: Sendable {
    case result(ACPJSONValue)
    case error(code: Int, message: String)
}

// Injected by the caller so agent-initiated requests (fs reads, permission
// prompts) can be answered by app logic. Must be Sendable: it is stored on the
// actor and invoked from an unstructured Task.
public typealias ACPServerRequestHandler = @Sendable (_ method: String, _ params: ACPJSONValue?) async -> ACPServerResponse

// Default: answer ping, refuse everything else politely.
public let acpDefaultServerRequestHandler: ACPServerRequestHandler = { method, _ in
    if method == "ping" { return .result(.object([:])) }
    return .error(code: -32601, message: "method not supported by Grux ACP client")
}

public enum ACPProtocol {
    // ACP negotiates an integer protocol version.
    public static let version = 1

    public static func initializeParams(clientCapabilities: ACPJSONValue = .object([:])) -> ACPJSONValue {
        .object([
            "protocolVersion": .int(version),
            "clientCapabilities": clientCapabilities
        ])
    }
}

public enum ACPConnectionError: LocalizedError {
    case notStarted
    case spawnFailed(String)
    case serverCrashed(String)
    case timeout(method: String, seconds: TimeInterval)
    case rpcError(code: Int, message: String)
    case restartBudgetExhausted

    public var errorDescription: String? {
        switch self {
        case .notStarted: return "ACP agent not started"
        case .spawnFailed(let why): return "failed to launch ACP agent: \(why)"
        case .serverCrashed(let detail): return "ACP agent exited unexpectedly\(detail.isEmpty ? "" : ": \(detail)")"
        case .timeout(let method, let seconds): return "ACP \(method) timed out after \(Int(seconds))s"
        case .rpcError(let code, let message): return "ACP error \(code): \(message)"
        case .restartBudgetExhausted: return "ACP agent crashed repeatedly; not restarting again this session"
        }
    }
}

// MARK: - Connection

public actor ACPConnection {
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case terminated(String)
    }

    private let command: String
    private let args: [String]
    private let env: [String: String]
    private let serverRequestHandler: ACPServerRequestHandler

    // Sanctioned writable root for the agent, carved into the sandbox profile
    // (see SwarmWorker.sandboxDecision). The profile is allow-default with writes
    // to the live Grux build trees DENIED; a sanctioned writableRoot is
    // additionally carved in. nil means no extra carve (the agent still runs
    // under the same write-deny-over-live-build-trees guard). A writableRoot that
    // is an ancestor of a protected live build tree is a fatal misconfig and
    // refuses the spawn.
    private let writableRoot: String?
    // Placeholder root used when no writableRoot is supplied. Unsanctioned and
    // not an ancestor of any protected tree, so sandboxDecision grants no carve
    // and is non-fatal (just the write-deny over the protected trees).
    private static let noWriteSentinelRoot = "/var/empty/grux-acp-no-writable-root"

    // Test seam: drive the protocol over caller FileHandles, no Process.
    private let testWriteHandle: FileHandle?
    private let testReadHandle: FileHandle?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let splitter = ACPLineSplitter()

    // Blocking write(2) NEVER runs on the actor executor: a stalled agent would
    // freeze the timeout/recovery machinery. Serial keeps frame order.
    private let writeQueue = DispatchQueue(label: "grux.acp.stdin-write")
    private var phase: Phase = .idle
    private var restartCount = 0
    private static let maxRestarts = 3

    private var lastStderrLine = ""
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<ACPIncoming, Error>] = [:]
    private var unwrittenRequests: Set<Int> = []
    private var consecutiveTimeouts = 0
    private static let wedgeTimeoutLimit = 3

    public static let defaultCallTimeout: TimeInterval = 120
    public static let handshakeTimeout: TimeInterval = 20

    public init(
        command: String,
        args: [String],
        env: [String: String] = ProcessInfo.processInfo.environment,
        writableRoot: String? = nil,
        serverRequestHandler: @escaping ACPServerRequestHandler = acpDefaultServerRequestHandler
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.writableRoot = writableRoot
        self.serverRequestHandler = serverRequestHandler
        self.testWriteHandle = nil
        self.testReadHandle = nil
    }

    // Test-only: drive the connection over caller-supplied pipe handles.
    public init(
        testWrite: FileHandle,
        testRead: FileHandle,
        serverRequestHandler: @escaping ACPServerRequestHandler = acpDefaultServerRequestHandler
    ) {
        self.command = ""
        self.args = []
        self.env = [:]
        self.writableRoot = nil
        self.serverRequestHandler = serverRequestHandler
        self.testWriteHandle = testWrite
        self.testReadHandle = testRead
    }

    // MARK: - Lifecycle

    public func start(initializeParams: ACPJSONValue? = nil) async throws {
        guard phase == .idle || isTerminated else { return }
        phase = .starting
        do {
            try spawnIfNeeded()
            let params = initializeParams ?? ACPProtocol.initializeParams()
            _ = try await sendRequest(method: "initialize", params: params, timeout: Self.handshakeTimeout)
            phase = .ready
        } catch {
            phase = .terminated(error.localizedDescription)
            tearDownProcess()
            throw error
        }
    }

    public func shutdown() {
        failAllPending(with: ACPConnectionError.serverCrashed("shut down"))
        phase = .terminated("shut down")
        tearDownProcess()
    }

    public var isReady: Bool { phase == .ready }

    private var isTerminated: Bool {
        if case .terminated = phase { return true }
        return false
    }

    private func spawnIfNeeded() throws {
        // Fresh frame buffer on every (re)spawn: a restart must never carry a
        // dead agent's half-written frame into the new agent's handshake.
        splitter.reset()

        if let w = testWriteHandle, let r = testReadHandle {
            stdinHandle = w
            readHandle = r
            suppressSigpipe(on: w)
            attachReader(r)
            return
        }

        // CONFINEMENT: never exec the agent directly. Wrap it in sandbox-exec
        // with SwarmWorker's allow-default profile that DENIES writes to the live
        // Grux build trees, exactly like SwarmWorker / AgentBridgeRunner. The
        // agent's own writableRoot is carved back in only when sanctioned; with
        // no writableRoot there is no extra carve. A fatal misconfig (writable
        // root is an ancestor of a protected tree) refuses the spawn.
        let confineRoot = writableRoot ?? Self.noWriteSentinelRoot
        let decision = SwarmWorker.sandboxDecision(writableRoot: confineRoot)
        if decision.fatalMisconfig {
            throw ACPConnectionError.spawnFailed("refused to spawn \(command): \(decision.reason ?? "writable root overlaps a protected live build tree")")
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let p = Process()
        // Under confinement:  sandbox-exec -p <profile> /usr/bin/env <command> <args>
        // (/usr/bin/env resolves bare command names against an augmented PATH;
        // GUI apps inherit a bare launchd PATH missing Homebrew / user bins.)
        let sandboxBin = "/usr/bin/sandbox-exec"
        if FileManager.default.isExecutableFile(atPath: sandboxBin) {
            p.executableURL = URL(fileURLWithPath: sandboxBin)
            var wrapped: [String] = ["-p", decision.profile]
            if command.contains("/") {
                wrapped.append(command)
            } else {
                wrapped.append(contentsOf: ["/usr/bin/env", command])
            }
            wrapped.append(contentsOf: args)
            p.arguments = wrapped
        } else {
            // sandbox-exec should always exist on macOS; fall back to a direct
            // (UNCONFINED) spawn rather than refusing all work.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [command] + args
        }
        var environment = env
        environment["PATH"] = AgentCLIRegistry.augmentedPATH(base: env)
        p.environment = environment
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
            throw ACPConnectionError.spawnFailed("\(command): \(error.localizedDescription)")
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
                h.readabilityHandler = nil    // EOF: detach or the source busy-spins
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let line = text.split(separator: "\n").last.map(String.init) ?? ""
            if !line.isEmpty { Task { await self?.noteStderr(line) } }
        }
    }

    private func suppressSigpipe(on handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    private func attachReader(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil    // EOF: detach (see MCP contract §3)
                return
            }
            Task { await self?.ingest(data) }
        }
    }

    private func noteStderr(_ line: String) { lastStderrLine = line }

    private func handleTermination(status: Int32) {
        guard !isTerminated else { return }
        let detail = lastStderrLine.isEmpty ? "exit \(status)" : "exit \(status), \(lastStderrLine)"
        phase = .terminated(detail)
        failAllPending(with: ACPConnectionError.serverCrashed(detail))
        tearDownProcess()
    }

    private func tearDownProcess() {
        readHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        if testWriteHandle == nil {
            try? stdinHandle?.close()
            if let p = process, p.isRunning {
                p.terminate()
                // Escalate to SIGKILL after a grace period so a SIGTERM-ignoring
                // child cannot pin a blocked write on writeQueue forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
        stdinHandle = nil
        readHandle = nil
        stderrHandle = nil
        // Drop any partial frame so a later restart begins clean.
        splitter.reset()
    }

    private func failAllPending(with error: Error) {
        let conts = pending.values
        pending.removeAll()
        unwrittenRequests.removeAll()
        for c in conts { c.resume(throwing: error) }
    }

    private func ensureReady() async throws {
        switch phase {
        case .ready:
            return
        case .idle:
            try await start()
        case .starting:
            for _ in 0..<200 where phase == .starting {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if phase != .ready { throw ACPConnectionError.notStarted }
        case .terminated:
            guard testWriteHandle == nil else { throw ACPConnectionError.notStarted }
            guard restartCount < Self.maxRestarts else { throw ACPConnectionError.restartBudgetExhausted }
            restartCount += 1
            phase = .idle
            try await start()
        }
    }

    // MARK: - Public request API

    // Send a request, ensuring the agent is up first (respawns a crashed one
    // within the restart budget).
    public func request(
        method: String,
        params: ACPJSONValue? = nil,
        timeout: TimeInterval = ACPConnection.defaultCallTimeout
    ) async throws -> ACPIncoming {
        try await ensureReady()
        return try await sendRequest(method: method, params: params, timeout: timeout)
    }

    public func notify(method: String, params: ACPJSONValue? = nil) throws {
        guard let stdin = stdinHandle else { throw ACPConnectionError.notStarted }
        let frame = ACPRequest(id: nil, method: method, params: params)
        let data = try ACPFrameCodec.encodeLine(frame)
        writeQueue.async { try? stdin.write(contentsOf: data) }
    }

    // MARK: - Wire I/O

    private func sendRequest(method: String, params: ACPJSONValue?, timeout: TimeInterval) async throws -> ACPIncoming {
        guard let stdin = stdinHandle else { throw ACPConnectionError.notStarted }
        let id = nextID
        nextID += 1
        let frame = ACPRequest(id: id, method: method, params: params)
        let data: Data
        do {
            data = try ACPFrameCodec.encodeLine(frame)
        } catch {
            throw ACPConnectionError.serverCrashed("encode failed: \(error.localizedDescription)")
        }

        let response: ACPIncoming = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            unwrittenRequests.insert(id)
            writeQueue.async { [weak self] in
                do {
                    try stdin.write(contentsOf: data)
                    Task { await self?.noteStdinWriteFinished(id: id) }
                } catch {
                    Task { await self?.failPending(id: id, error: ACPConnectionError.serverCrashed("stdin write failed")) }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutPending(id: id, method: method, seconds: timeout)
            }
        }

        if let err = response.error {
            throw ACPConnectionError.rpcError(code: err.code, message: err.message)
        }
        return response
    }

    private func noteStdinWriteFinished(id: Int) {
        unwrittenRequests.remove(id)
    }

    private func timeoutPending(id: Int, method: String, seconds: TimeInterval) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        let stdinWedged = unwrittenRequests.contains(id)
        unwrittenRequests.remove(id)
        cont.resume(throwing: ACPConnectionError.timeout(method: method, seconds: seconds))
        consecutiveTimeouts += 1
        if phase == .ready, stdinWedged || consecutiveTimeouts >= Self.wedgeTimeoutLimit {
            let detail = stdinWedged
                ? "stdin wedged (agent stopped draining)"
                : "unresponsive (\(consecutiveTimeouts) consecutive timeouts)"
            phase = .terminated(detail)
            failAllPending(with: ACPConnectionError.serverCrashed(detail))
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
            guard let incoming = ACPFrameCodec.decodeIncoming(line) else { continue }
            if incoming.isResponse {
                if let id = incoming.intID {
                    // A correlated response proves liveness even past a timeout.
                    consecutiveTimeouts = 0
                    if let cont = pending.removeValue(forKey: id) {
                        cont.resume(returning: incoming)
                    }
                }
            } else if incoming.isServerRequest {
                handleServerRequest(incoming)
            }
            // Agent notifications (progress, logging) are ignored here; a caller
            // that wants them can extend ingest.
        }
    }

    // Agent-initiated request: hand it to the injected handler and write the
    // reply. The handler is async, so hop off the ingest path via a Task.
    private func handleServerRequest(_ incoming: ACPIncoming) {
        guard let id = incoming.id else { return }
        let method = incoming.method ?? ""
        let params = incoming.params
        let handler = serverRequestHandler
        Task { [weak self] in
            let response = await handler(method, params)
            await self?.writeServerResponse(id: id, response: response)
        }
    }

    private func writeServerResponse(id: ACPJSONValue, response: ACPServerResponse) {
        guard let stdin = stdinHandle else { return }
        let frame: ACPResponseFrame
        switch response {
        case .result(let value):
            frame = ACPResponseFrame(id: id, result: value, error: nil)
        case .error(let code, let message):
            frame = ACPResponseFrame(id: id, result: nil, error: ACPErrorObject(code: code, message: message, data: nil))
        }
        guard let data = try? ACPFrameCodec.encodeLine(frame) else { return }
        writeQueue.async { try? stdin.write(contentsOf: data) }
    }
}
