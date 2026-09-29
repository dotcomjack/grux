import Foundation

/// Watches a set of files and folders and calls `onChange` on the main actor
/// when any of them changes. The one watcher behind "live state, never a
/// manual refresh" (Grux-Mac CLAUDE.md): the work orders, config.json and
/// theme.json all go through it.
///
/// ## Why a DispatchSource per path, and not FSEvents
///
/// A vnode source fires within the same run loop turn as the write, for
/// this process and every other, and it is deterministic under test. FSEvents
/// coalesces with a latency and reports by directory, which is the right
/// tool for a whole tree and the wrong one for "this one log gained a line".
/// The sets watched here are small (a handful of folders and files), so one
/// descriptor each is cheap.
///
/// Two shapes of write have to be caught, and they land differently:
///   - in place (`echo >> progress.log`, `echo > config.json`): the FILE
///     fires `.write` or `.extend`, its folder does not;
///   - atomic (an editor's save, `Data.write(options: .atomic)`, `mv`): the
///     FOLDER fires `.write` because an entry was replaced, and the old
///     file's source fires `.delete` or `.rename` and is dead from then on.
/// So owners watch the folder AND the file, and a source whose file went
/// away is dropped here, so the owner's next `watch(_:)` opens the new file.
///
/// Callers pair it with a slow poll as the fallback for a descriptor that
/// could not be opened (a folder that does not exist yet, a full fd table).
final class FileWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending = false
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    deinit {
        for source in sources.values { source.cancel() }
    }

    /// The paths currently watched, for tests.
    var watchedPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(sources.keys)
    }

    /// Makes the watched set exactly `urls`: opens what is new, cancels what
    /// is no longer wanted, and re-opens any path whose file was replaced.
    /// A path that does not exist is skipped until a later call finds it.
    func watch(_ urls: [URL]) {
        let wanted = Set(urls.map(\.path))
        lock.lock()
        for (path, source) in sources where !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        let missing = wanted.subtracting(sources.keys)
        lock.unlock()
        for path in missing { open(path) }
    }

    func stop() { watch([]) }

    private func open(_ path: String) {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.fired(path) }
        source.setCancelHandler { close(fd) }
        lock.lock()
        let raced = sources[path]
        sources[path] = source
        lock.unlock()
        raced?.cancel()
        source.resume()
    }

    /// Runs on the main queue, inside the source's handler, where `data` is
    /// the event that fired.
    private func fired(_ path: String) {
        lock.lock()
        let source = sources[path]
        lock.unlock()
        if let source, !source.data.isDisjoint(with: [.delete, .rename]) {
            // The file this descriptor points at is gone or moved; the next
            // watch(_:) opens whatever now lives at the path.
            lock.lock()
            if (sources[path] as AnyObject?) === (source as AnyObject) { sources[path] = nil }
            lock.unlock()
            source.cancel()
        }
        changed()
    }

    /// Several events from one write (the file and its folder, an append in
    /// two chunks) become one call on the next main turn.
    private func changed() {
        lock.lock()
        guard !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = false
            self.lock.unlock()
            MainActor.assumeIsolated { self.onChange() }
        }
    }
}
