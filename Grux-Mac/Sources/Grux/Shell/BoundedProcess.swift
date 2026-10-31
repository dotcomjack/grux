import Foundation

/// Runs a process with its output read while it runs and the WHOLE wait bounded.
///
/// D16: `ShellRunner` waited for exit, then read the pipe to its end with no deadline,
/// so a background job that kept the pipe open (`cmd &`) held the caller until it
/// ended (measured once at 25 minutes), and output past the pipe's 64 KB buffer stalled
/// the command until the timeout killed it.
enum BoundedProcess {
    struct Result {
        let status: Int32
        let output: String
        /// The limit stopped it.
        var timedOut = false
    }

    /// How long output is still read after the process exits: a background job it
    /// started may hold the pipe open far longer, and its output is not waited for.
    static let drainGrace: TimeInterval = 0.5
    /// After the timeout's SIGTERM, how long before SIGKILL and an answer regardless.
    static let killGrace: TimeInterval = 2
    /// The most output kept. The pipe no longer stalls a writer at 64 KB, so `yes` for
    /// 30 s would otherwise fill memory; past this, output is read and dropped.
    static let maxOutputBytes = 4 * 1024 * 1024

    /// Runs `proc` (stdout and stderr together). Returns within about
    /// `timeout + killGrace + drainGrace` whatever the process or its children do.
    /// A process stopped by the limit reports a non-zero status.
    static func run(_ proc: Process, timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            let state = State(proc: proc, cont: cont)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            let reader = pipe.fileHandleForReading
            state.reader = reader
            // Reads until end of file even after the caller is answered: a background job
            // that still holds the pipe must never write into a closed one (it would die
            // of SIGPIPE), so the handle closes only when the last writer has.
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    state.reachedEnd()
                } else {
                    state.append(chunk)
                }
            }
            proc.terminationHandler = { _ in
                state.exited()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + drainGrace) { state.finish() }
            }
            do {
                try proc.run()
            } catch {
                reader.readabilityHandler = nil
                state.finish(launchError: "failed to launch \(proc.executableURL?.path ?? "process") - \(error.localizedDescription)")
                return
            }
            let queue = DispatchQueue.global(qos: .utility)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard proc.isRunning else { return }
                state.markTimedOut()
                proc.terminate()
                queue.asyncAfter(deadline: .now() + killGrace) {
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                    queue.asyncAfter(deadline: .now() + drainGrace) { state.finish() }
                }
            }
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let proc: Process
        private var cont: CheckedContinuation<Result, Never>?
        private var data = Data()
        private var hasExited = false
        private var atEnd = false
        private var timedOut = false
        var reader: FileHandle?

        init(proc: Process, cont: CheckedContinuation<Result, Never>) {
            self.proc = proc
            self.cont = cont
        }

        private var dropped = 0

        func append(_ chunk: Data) {
            lock.lock()
            // After the answer, or past the cap, output is read and dropped so the writer
            // never blocks.
            if cont != nil {
                let room = max(0, BoundedProcess.maxOutputBytes - data.count)
                data.append(chunk.prefix(room))
                dropped += chunk.count - min(room, chunk.count)
            }
            lock.unlock()
        }

        func markTimedOut() {
            lock.lock(); timedOut = true; lock.unlock()
        }

        func reachedEnd() {
            lock.lock()
            atEnd = true
            let done = hasExited
            lock.unlock()
            if done { finish() }
        }

        func exited() {
            lock.lock()
            hasExited = true
            let done = atEnd
            lock.unlock()
            if done { finish() }
        }

        func finish(launchError: String? = nil) {
            lock.lock()
            guard let cont else { lock.unlock(); return }
            self.cont = nil
            // Decoding repairs a multi-byte character cut by the drain grace or the kill.
            var output = launchError ?? String(decoding: data, as: UTF8.self)
            if launchError == nil, dropped > 0 { output += "\n…(output past \(BoundedProcess.maxOutputBytes / 1_048_576) MB dropped: \(dropped) bytes)" }
            let stopped = timedOut
            data = Data()
            lock.unlock()
            if launchError != nil { reader?.readabilityHandler = nil }
            // The handler holds this state and this state holds the process: let go.
            proc.terminationHandler = nil
            // terminationStatus raises while the process runs; one that outlived SIGKILL
            // (stuck in the kernel) reads as -1.
            let running = proc.isRunning
            let status: Int32 = launchError != nil || running ? -1 : proc.terminationStatus
            // The limit can fire the instant the process ends by itself: only a process
            // that the signal ended (or that outlived it) was stopped by the limit.
            let byLimit = stopped && (running || proc.terminationReason == .uncaughtSignal)
            cont.resume(returning: Result(status: status, output: output, timedOut: byLimit))
        }
    }
}
