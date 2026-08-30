import Foundation

// MARK: - AgentBridgeRunner
//
// Runs ONE AdapterInvocation as a subprocess and streams its output through the
// adapter's parser into AdapterEvents. This is the CLI-agnostic sibling of
// SwarmWorker.run(): same spawn hygiene (every production spawn wrapped in
// /usr/bin/sandbox-exec via SwarmWorker.sandboxDecision, so the write-deny guard
// over the live build trees is identical), same wall + idle TTL watchdogs, but
// the parsing and argv are supplied by an AgentAdapter rather than hard-coded to
// claude.
//
// CONCURRENCY (the whole point of this file): the actor NEVER blocks its
// executor on a synchronous pipe read. stdout is delivered off-actor through an
// AsyncStream<Data> driven by a FileHandle.readabilityHandler; the run loop
// awaits chunks at real suspension points, so cancel() and the detached
// watchdog interleave even when the child is alive but silent (e.g. claude not
// signed in, waiting on a prompt). The idle clock lives in a nonisolated locked
// box so the watchdog reads it without an actor hop. stderr is drained
// continuously into a capped ring so a chatty CLI can never fill the 64KB
// stderr pipe buffer and deadlock its own stdout write. stdin is fed off-actor
// AFTER the watchdog exists, so a child that never drains stdin cannot wedge the
// actor before any timeout is armed.
//
// The Studio's subscription-CLI route drives this: pick an adapter from
// AgentCLIRegistry, build the invocation, run it here, fold the events into the
// design run's log.

// Per-event callback. WEAK-retained by the runner (mirrors SwarmWorkerObserver):
// the CALLER must keep a strong reference for the lifetime of the run or events
// silently vanish.
public protocol AgentBridgeObserver: AnyObject, Sendable {
    func bridgeRun(_ runId: String, didEmit event: AdapterEvent) async
}

public struct BridgeRunResult: Sendable {
    public let runId: String
    public let success: Bool
    public let finalText: String
    public let events: [AdapterEvent]
    public let costUSD: Double?
    public let exitCode: Int32
    // Non-nil when the run was classified as limit-paused (a .limitSignal event
    // fired) or refused/failed for a structural reason, for the caller's log.
    public let note: String?

    public init(
        runId: String,
        success: Bool,
        finalText: String,
        events: [AdapterEvent],
        costUSD: Double?,
        exitCode: Int32,
        note: String? = nil
    ) {
        self.runId = runId
        self.success = success
        self.finalText = finalText
        self.events = events
        self.costUSD = costUSD
        self.exitCode = exitCode
        self.note = note
    }
}

// Nonisolated, thread-safe holder for the idle-TTL clock. The detached watchdog
// reads it WITHOUT hopping onto the runner actor: an actor hop would deadlock
// behind a long read exactly like the old `await self.lastEventAt` did. The read
// loop stamps it as bytes arrive.
final class BridgeTimestampBox: @unchecked Sendable {
    private var date: Date
    private let lock = NSLock()
    init(_ d: Date) { self.date = d }
    func set(_ d: Date) { lock.lock(); date = d; lock.unlock() }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return date }
}

// Nonisolated ring holding only the last `cap` bytes of stderr. Drained
// continuously off-actor so a chatty CLI never fills the 64KB stderr pipe buffer
// and deadlocks its own stdout write, while keeping a bounded diagnostics tail.
final class BridgeStderrRing: @unchecked Sendable {
    private var data = Data()
    private let cap: Int
    private let lock = NSLock()
    init(cap: Int) { self.cap = cap }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > cap {
            data.removeSubrange(data.startIndex..<data.index(data.startIndex, offsetBy: data.count - cap))
        }
    }
    func tailString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public actor AgentBridgeRunner {

    public let runId: String
    private let adapter: any AgentAdapter
    private let invocation: AdapterInvocation
    public weak var observer: (any AgentBridgeObserver)?

    private var process: Process?
    private var cancelled = false
    private(set) public var isRunning = false

    // The idle-TTL clock. Nonisolated box so the detached watchdog reads it
    // without an actor hop (see BridgeTimestampBox).
    private let lastEventBox = BridgeTimestampBox(Date())
    // Public read-only accessor for API compatibility. External callers get an
    // actor-isolated snapshot; the watchdog uses the box directly.
    public var lastEventAt: Date { lastEventBox.get() }

    // Cap on the raw-byte buffer when the child emits newline-free output. Matches
    // the 16MB frame cap the other splitters (ACPLineSplitter) enforce.
    private static let maxResidualBytes = 16 * 1024 * 1024
    // stderr diagnostics tail size.
    private static let stderrRingBytes = 8 * 1024

    public init(
        runId: String = UUID().uuidString,
        adapter: any AgentAdapter,
        invocation: AdapterInvocation,
        observer: (any AgentBridgeObserver)?
    ) {
        self.runId = runId
        self.adapter = adapter
        self.invocation = invocation
        self.observer = observer
    }

    public func cancel() async {
        cancelled = true
        if let p = process, p.isRunning { p.terminate() }
    }

    private func suppressSigpipe(on handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    // Split raw subprocess bytes into a decoded complete-lines block plus the
    // leftover partial-line bytes (returned via the inout buffer). Two properties
    // the naive `String(data:encoding:)`-per-chunk approach got wrong:
    //   #4  Buffering at the byte level means a chunk that splits a multi-byte
    //       UTF-8 character never drops data: the partial bytes stay in the
    //       buffer until their continuation arrives. A newline (0x0A) can never
    //       appear mid-codepoint, so the emitted block always ends on a clean
    //       boundary and decodes exactly.
    //   #5  byteBuffer is newline-free between calls (invariant: everything up to
    //       the last newline is emitted), so only the freshly arrived chunk is
    //       scanned for a newline. No quadratic rescan of accumulated output.
    // Returns nil when the chunk completes no new line (bytes buffered for later).
    static func splitCompleteLines(byteBuffer: inout Data, chunk: Data) -> String? {
        guard let nl = chunk.lastIndex(of: 0x0A) else {
            byteBuffer.append(chunk)
            return nil
        }
        var complete = byteBuffer
        complete.append(chunk[chunk.startIndex...nl])
        byteBuffer = Data(chunk[chunk.index(after: nl)...])
        return String(decoding: complete, as: UTF8.self)
    }

    // Run to completion. Wall TTL default 1800s; idle TTL default 600s (env
    // GRUX_WORKER_IDLE_TTL_SECONDS honored to match SwarmWorker).
    public func run(ttlSeconds: Int = 1800) async -> BridgeRunResult {
        isRunning = true
        defer { isRunning = false }

        var events: [AdapterEvent] = []
        func record(_ ev: AdapterEvent) async {
            events.append(ev)
            await observer?.bridgeRun(runId, didEmit: ev)
        }

        // Confinement decision up front. A FATAL misconfig (writable root is an
        // ancestor of a protected live build tree) refuses the run outright.
        let decision = SwarmWorker.sandboxDecision(writableRoot: invocation.cwd)
        if decision.fatalMisconfig {
            let why = decision.reason ?? "writable root overlaps a protected live build tree"
            return BridgeRunResult(runId: runId, success: false, finalText: "", events: events, costUSD: nil, exitCode: -1, note: "refused: \(why)")
        }

        // Build the spawn: wrap the agent binary in sandbox-exec. Mirrors
        // SwarmWorker.run for the executable/arg construction.
        let sandboxBin = "/usr/bin/sandbox-exec"
        let confine = FileManager.default.isExecutableFile(atPath: sandboxBin)
        let execPath = invocation.executablePath
        let proc = Process()
        var args: [String] = []
        if confine {
            proc.executableURL = URL(fileURLWithPath: sandboxBin)
            args.append(contentsOf: ["-p", decision.profile])
            if execPath.contains("/") {
                args.append(execPath)
            } else {
                args.append(contentsOf: ["/usr/bin/env", execPath])
            }
        } else {
            // sandbox-exec should always exist on macOS; fall back to a direct
            // (UNCONFINED) spawn rather than refusing all work.
            if execPath.contains("/") {
                proc.executableURL = URL(fileURLWithPath: execPath)
            } else {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                args.append(execPath)
            }
        }
        args.append(contentsOf: invocation.args)
        proc.arguments = args

        // Env: adapter-supplied, with PATH augmented for GUI-launched context.
        var env = invocation.env
        env["PATH"] = AgentCLIRegistry.augmentedPATH(base: invocation.env)
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: invocation.cwd)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        self.process = proc

        do {
            try proc.run()
        } catch {
            return BridgeRunResult(runId: runId, success: false, finalText: "", events: events, costUSD: nil, exitCode: -1, note: "spawn failed: \(error.localizedDescription)")
        }

        // stderr: drain continuously into a capped ring, off-actor. Without this
        // a CLI that writes >64KB to stderr blocks on the full pipe buffer and
        // mutually deadlocks with its own stdout write (bug #2). Detach on EOF so
        // the dispatch source doesn't busy-spin.
        let stderrRing = BridgeStderrRing(cap: Self.stderrRingBytes)
        let stderrFH = stderrPipe.fileHandleForReading
        stderrFH.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrRing.append(data)
        }

        // stdout: delivered off-actor through an AsyncStream driven by the
        // readabilityHandler. The run loop awaits chunks at real suspension
        // points, so cancel() and the watchdog interleave even when the child is
        // alive but silent (bug #1). Detach the handler on EOF (empty Data) to
        // avoid pinning a dispatch thread.
        let stdoutFH = stdoutPipe.fileHandleForReading
        let stdoutStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            stdoutFH.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }

        // Watchdogs: wall TTL + idle TTL. The detached watchdog terminates the
        // process when either fires; terminating closes stdout, which surfaces as
        // EOF on the readabilityHandler and finishes the stream. Reads the idle
        // clock from the nonisolated box, so no actor hop can deadlock it.
        let deadline = Date().addingTimeInterval(TimeInterval(ttlSeconds))
        let idleSeconds = (ProcessInfo.processInfo.environment["GRUX_WORKER_IDLE_TTL_SECONDS"].flatMap(Int.init)) ?? 600
        lastEventBox.set(Date())
        let idleClock = lastEventBox
        let watchdog = Task<Void, Never> { [weak proc] in
            while !Task.isCancelled {
                let now = Date()
                if now > deadline {
                    if let p = proc, p.isRunning { p.terminate() }
                    return
                }
                if now.timeIntervalSince(idleClock.get()) > Double(idleSeconds) {
                    if let p = proc, p.isRunning { p.terminate() }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { watchdog.cancel() }

        // Feed the prompt on stdin off-actor, AFTER the watchdog is armed. A huge
        // prompt that overflows the pipe buffer while the child does not drain it
        // would block; blocking a global-queue thread is recoverable (the
        // watchdog terminates the child, which unblocks the write via EPIPE),
        // blocking the actor is not (bug #3). SIGPIPE is suppressed so a dead
        // child surfaces as a swallowed EPIPE, not a signal.
        let stdinWriteFH = stdinPipe.fileHandleForWriting
        suppressSigpipe(on: stdinWriteFH)
        if let payload = invocation.stdinPayload {
            let data = Data(payload.utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdinWriteFH.write(contentsOf: data)
                try? stdinWriteFH.close()
            }
        } else {
            try? stdinWriteFH.close()
        }

        let parser = adapter.makeStreamParser()
        // Raw-byte residual: bytes that do not yet form a complete UTF-8 line.
        // Kept newline-free between iterations (invariant), so the newline scan
        // only ever inspects the freshly arrived chunk (bug #5, no quadratic
        // rescan). Buffering at the byte level means a chunk that splits a
        // multi-byte character never drops the chunk (bug #4): the partial bytes
        // wait here for their continuation.
        var byteBuffer = Data()
        // Text residual the parser hands back (a trailing partial line). Since we
        // only ever feed complete-newline-terminated blocks this stays empty, but
        // we honor the parser contract in case a parser ever holds lines back.
        var parserResidual = ""
        var costUSD: Double? = nil
        var finalText = ""
        var assistantAcc: [String] = []
        var sawSuccessFinal = false
        var limitDetected = false
        var ttlTerminated = false

        func consume(_ ev: AdapterEvent) async {
            switch ev {
            case .assistantText(let text, _):
                assistantAcc.append(text)
            case .usage(let cost, _, _, _):
                if let c = cost { costUSD = max(costUSD ?? 0, c) }
            case .finalResult(let text, let cost, let success, _):
                finalText = text
                if let c = cost { costUSD = max(costUSD ?? 0, c) }
                if success { sawSuccessFinal = true }
            case .limitSignal:
                limitDetected = true
            default:
                break
            }
            await record(ev)
        }

        for await chunk in stdoutStream {
            if cancelled { proc.terminate(); break }
            if Date() > deadline { ttlTerminated = true; proc.terminate(); break }
            // Any bytes at all mean the child is making progress; only true
            // silence should trip the idle watchdog.
            lastEventBox.set(Date())

            if let text = Self.splitCompleteLines(byteBuffer: &byteBuffer, chunk: chunk) {
                let (parsed, rem) = parser.parseChunk(parserResidual + text)
                parserResidual = rem
                for ev in parsed { await consume(ev) }
            } else if byteBuffer.count > Self.maxResidualBytes {
                // Pathological newline-free output. Drop it with a synthetic note
                // rather than letting the buffer grow without bound.
                byteBuffer.removeAll(keepingCapacity: false)
                await consume(.unknown(raw: "[grux-bridge] dropped over 16MB of newline-free agent output"))
            }
        }

        // Stop callbacks and flush any trailing partial line (a final line the
        // child wrote without a closing newline). readToEnd is unnecessary: the
        // readabilityHandler already delivered every byte up to EOF.
        stdoutFH.readabilityHandler = nil
        stderrFH.readabilityHandler = nil
        if !byteBuffer.isEmpty || !parserResidual.isEmpty {
            let text = parserResidual + String(decoding: byteBuffer, as: UTF8.self)
            let (parsed, _) = parser.parseChunk(text + "\n")
            for ev in parsed { await consume(ev) }
        }

        proc.waitUntilExit()
        let exitCode = proc.terminationStatus

        // Retroactively classify a watchdog kill the read path did not itself
        // notice (the deadline elapsed while the stream was quiet).
        let endNow = Date()
        if !ttlTerminated && endNow > deadline && exitCode != 0 { ttlTerminated = true }
        let idleHit = !ttlTerminated
            && endNow.timeIntervalSince(lastEventBox.get()) > Double(idleSeconds)
            && exitCode != 0
        let watchdogKilled = ttlTerminated || idleHit

        let stderrTail = stderrRing.tailString().trimmingCharacters(in: .whitespacesAndNewlines)

        let okExit = exitCode == 0
        var success = (sawSuccessFinal || okExit) && !limitDetected
        if watchdogKilled && !sawSuccessFinal { success = false }

        if finalText.isEmpty { finalText = assistantAcc.joined(separator: "\n") }

        let note: String? = {
            if cancelled { return "cancelled" }
            if limitDetected { return "paused: subscription usage limit" }
            if ttlTerminated { return "wall TTL exceeded (\(ttlSeconds)s)" }
            if idleHit { return "idle TTL exceeded (\(idleSeconds)s of silence)" }
            if !decision.carved, let why = decision.reason { return "write carve denied: \(why)" }
            if !success {
                if !stderrTail.isEmpty { return "exit \(exitCode): \(String(stderrTail.suffix(500)))" }
                return "exit \(exitCode)"
            }
            return nil
        }()

        return BridgeRunResult(
            runId: runId,
            success: success,
            finalText: finalText,
            events: events,
            costUSD: costUSD,
            exitCode: exitCode,
            note: note
        )
    }
}
