import Foundation

/// Turns a termination signal into an ordinary quit.
///
/// D19: SIGTERM (`killall Grux`, `kill`, build.sh's fallback) ended Grux at once, with
/// no store flush and no clean-shutdown marker, so Self-Upgrade's crash detector read an
/// ordinary quit as a crash, and two inside 10 minutes restore the previous build.
enum TerminationSignal {
    /// If the ordinary quit has not ended the process by then, it exits anyway: a
    /// signal asks for an end, and an app that ignored it would be killed harder.
    static let fallbackExit: TimeInterval = 5

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sources: [Int32: DispatchSourceSignal] = [:]

    /// Replaces `signal`'s default action (ending the process) with `onSignal` on `queue`.
    static func install(_ signal: Int32 = SIGTERM, queue: DispatchQueue = .main,
                        onSignal: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        sources[signal]?.cancel()
        // A dispatch source only sees a signal whose default action is off.
        Darwin.signal(signal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
        source.setEventHandler { onSignal(signal) }
        source.resume()
        sources[signal] = source
    }

    /// Restores `signal`'s default action. For tests.
    static func uninstall(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        sources.removeValue(forKey: signal)?.cancel()
        Darwin.signal(signal, SIG_DFL)
    }
}
