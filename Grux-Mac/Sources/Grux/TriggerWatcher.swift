import Foundation

/// One filesystem watcher for every `~/.grux` file-drop trigger.
///
/// These were 57 independent repeating timers, together making **93 `stat()` calls per
/// second, 335,100 an hour, forever**, each one existing to notice a debug or automation
/// file that is almost never there. Measured off the source, not estimated: 17 at 0.4s,
/// 9 at 0.5s, 2 at 0.6s, 1 at 0.8s and 28 at 1.0s.
///
/// The syscalls were never the expensive part. **93 main-thread wakeups a second is what
/// holds a laptop CPU out of its deep idle states**, and a machine that never idles is a
/// machine with the fans on. An app doing nothing should cost nothing.
///
/// One vnode source on the directory replaces all of them. It costs zero while nothing
/// changes and fires once when a file appears, which is the only moment any of those
/// timers was ever going to do work.
///
/// Handlers keep their own existence check. That is deliberate redundancy: it made the
/// conversion a one-line change per site with the body untouched, and it means a handler
/// stays correct if it is ever called from somewhere else.
@MainActor
final class TriggerWatcher {
    static let shared = TriggerWatcher()

    private var handlers: [(file: URL, run: () -> Void)] = []
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var started = false

    /// The directory every trigger lives in. All 57 call sites resolved to this one path.
    let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux")

    private init() {}

    /// Register a file whose appearance should run `run`. Call before `start()`.
    func register(_ file: URL, _ run: @escaping () -> Void) {
        handlers.append((file, run))
    }

    /// Begin watching. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A file dropped while Grux was not running still has to be noticed, and a vnode
        // source only reports changes from the moment it is armed. So sweep once first.
        sweep()

        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Watching failed. Triggers still fire on the next launch through the sweep
            // above, which is the same guarantee the timers gave for a file dropped while
            // the app was closed. Deliberately NOT falling back to polling: restoring the
            // 93 wakeups a second is the thing this type exists to remove.
            WakeLog.shared.log("TriggerWatcher: could not watch \(directory.path), triggers are launch-only")
            return
        }

        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        // `.write` on a directory fires when an entry is added or removed, which covers
        // both a file being dropped and a handler deleting it afterwards. The delete
        // re-fires the sweep, finds nothing registered present, and stops. No loop.
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sweep() }
        }
        let fd = descriptor
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    private func sweep() {
        let fm = FileManager.default
        for handler in handlers where fm.fileExists(atPath: handler.file.path) {
            handler.run()
        }
    }

    /// Test seam. Returns how many triggers are registered, so a test can prove the
    /// conversion did not silently drop any of them.
    var registeredCount: Int { handlers.count }

    /// Test seam. Runs one sweep without needing a filesystem event.
    func sweepNow() { sweep() }
}
