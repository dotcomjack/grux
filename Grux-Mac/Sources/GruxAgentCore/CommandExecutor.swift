import Foundation

public struct CommandTimeout: Error, Equatable, Sendable {
    public init() {}
}

public struct CommandRequest: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var cwd: String
    public var env: [String: String]
    public var timeoutSec: Int

    public init(executable: String, arguments: [String], cwd: String, env: [String: String], timeoutSec: Int) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.env = env
        self.timeoutSec = timeoutSec
    }
}

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandExecutor: Sendable {
    func execute(_ request: CommandRequest) async throws -> CommandResult
}

public struct PreparedCommand: @unchecked Sendable {
    public let process: Process
    public let stdin: Pipe
    public let stdout: Pipe
    public let stderr: Pipe
}

public struct LocalExecutor: CommandExecutor {
    public init() {}

    /// Configures a process and its pipes. The caller runs it and owns the
    /// read loop. `execute` is the wait-until-exit path for callers that do
    /// not stream.
    public func prepare(_ request: CommandRequest) -> PreparedCommand {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: request.executable)
        proc.arguments = request.arguments
        if !request.cwd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        }
        proc.environment = request.env
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        return PreparedCommand(process: proc, stdin: stdin, stdout: stdout, stderr: stderr)
    }

    public func execute(_ request: CommandRequest) async throws -> CommandResult {
        let prepared = prepare(request)
        let proc = prepared.process
        try? prepared.stdin.fileHandleForWriting.close()

        let stdoutPipe = prepared.stdout
        let stderrPipe = prepared.stderr
        let outTask = Task.detached { (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data() }
        let errTask = Task.detached { (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data() }

        let code: Int32
        do {
            code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                let gate = ResumeGate()
                let hold = TimerHold()
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                hold.timer = timer
                timer.schedule(deadline: .now() + .seconds(max(request.timeoutSec, 0)))
                timer.setEventHandler {
                    hold.timer?.cancel()
                    hold.timer = nil
                    if proc.isRunning {
                        proc.terminate()
                    }
                    let won = gate.tryBegin()
                    proc.waitUntilExit()
                    if won {
                        cont.resume(throwing: CommandTimeout())
                    }
                }
                proc.terminationHandler = { p in
                    hold.timer?.cancel()
                    hold.timer = nil
                    if gate.tryBegin() {
                        cont.resume(returning: p.terminationStatus)
                    }
                }
                timer.resume()
                do {
                    try proc.run()
                } catch {
                    timer.cancel()
                    if gate.tryBegin() {
                        cont.resume(throwing: error)
                    }
                }
            }
            let out = await outTask.value
            let err = await errTask.value
            return CommandResult(
                exitCode: code,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self)
            )
        } catch {
            _ = await outTask.value
            _ = await errTask.value
            throw error
        }
    }
}

private final class TimerHold: @unchecked Sendable {
    var timer: DispatchSourceTimer?
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false

    func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if began { return false }
        began = true
        return true
    }
}
