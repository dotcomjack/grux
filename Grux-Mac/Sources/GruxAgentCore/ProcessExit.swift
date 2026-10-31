import Foundation

// D64: `Process.waitUntilExit()` sleeps in the calling thread's run loop until
// Foundation posts the child's exit to it. Called from a Swift concurrency
// thread (an actor's async method, a cooperative pool thread) that post can be
// missed, and the wait never returns: measured 2026-10-30, a SwarmWorker
// sat 32 minutes in `waitUntilExit` (`__CFRunLoopServiceMachPort`) with its
// child long gone, so a Self-Upgrade build would read "building" forever.
// `isRunning` is updated off the run loop, so polling it always ends once the
// child has exited. Every wait in this module goes through one of these two.
extension Process {

    /// Waits for the child to exit without parking a cooperative thread in a
    /// run loop. A cancelled task still waits (it falls back to a short
    /// blocking sleep), so `terminationStatus` is always safe to read after.
    public func waitForExit(pollNanoseconds: UInt64 = 20_000_000) async {
        while isRunning {
            do {
                try await Task.sleep(nanoseconds: pollNanoseconds)
            } catch {
                usleep(useconds_t(pollNanoseconds / 1_000))
            }
        }
    }

    /// The same wait for a synchronous caller.
    public func waitForExitBlocking(pollMicroseconds: useconds_t = 20_000) {
        while isRunning { usleep(pollMicroseconds) }
    }
}
