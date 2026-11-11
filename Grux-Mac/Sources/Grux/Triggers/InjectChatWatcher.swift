import Foundation

/// The `~/.grux/inject-chat.txt` door, read as soon as something has written it.
///
/// D113: it was the one file trigger left on a repeating timer, 0.8 s, so every line
/// written there (a swarm agent's report, a harness turn) waited 0 to 0.8 s before Grux
/// saw it, and the timer woke the main thread 1.25 times a second, forever. Measured on a
/// 16 GB Mac mini (2026-11-01, 36 local turns): Grux's own share of a turn, from reading
/// the line to the reply, was 0.05 s over Ollama's answer; the timer was the biggest part
/// of the rest.
///
/// It is not one of `TriggerWatcher`'s files because it is never left missing: it stays
/// one 0600 file (see `startInjectChatWatcher`), and writing into a file that exists
/// changes nothing in its folder, which is all `TriggerWatcher` watches. So this watches
/// the file itself and follows it when something puts a new file in its place
/// (AgentService writes it atomically), deletes it, or removes its folder.
@MainActor
final class InjectChatWatcher {
    let file: URL
    private let deliver: (String) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pendingTake: DispatchWorkItem?
    private var retryPending = false
    private var stopped = false
    /// Test seam: how many times the file has been taken.
    private(set) var takeCount = 0
    /// Test seam: how many steps were put off for later. `later` is this file's one way
    /// to schedule anything (`IdleCostTests.testTheInjectChatDoorHasNoTimer`).
    private(set) var laterCount = 0
    /// Test seam: steps put off that have not run or been dropped yet. A door left alone
    /// has none, so a poll of any period shows here (`InjectChatWatcherTests`).
    private(set) var outstanding = 0

    /// How long the file must go unwritten before it is read. A shell writes
    /// `{ echo "done:"; cat result.txt; } > inject-chat.txt` as two writes through one
    /// open file, a few milliseconds apart (wave 29 review). Read between them, the
    /// person's one report went to chat as two turns.
    static let settleSeconds: TimeInterval = 0.1
    /// How soon to try again when the file cannot be watched (its folder cannot be made).
    static let retrySeconds: TimeInterval = 2.0

    init(file: URL, deliver: @escaping (String) -> Void) {
        self.file = file
        self.deliver = deliver
    }

    /// Puts the door in place, watches it, and reads anything already waiting there.
    func start() {
        ensureFile()
        arm()
        scheduleTake()
    }

    func stop() {
        stopped = true
        pendingTake?.cancel()
        pendingTake = nil
        source?.cancel()
        source = nil
    }

    /// The folder and the file, 0600 every time, so a file another writer put in its
    /// place is private too.
    private func ensureFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func arm() {
        source?.cancel()
        source = nil
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else {
            WakeLog.shared.log("inject-chat: could not watch \(file.path); trying again in \(Int(Self.retrySeconds)) s")
            retryLater()
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self, weak s] in
            MainActor.assumeIsolated {
                guard let self, let s else { return }
                // The file this watch holds was replaced, moved or deleted: watch the
                // one at the path now.
                if !s.data.isDisjoint(with: [.delete, .rename]) {
                    self.ensureFile()
                    self.arm()
                }
                self.scheduleTake()
            }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    /// One retry at a time, and only while the watch is down: nothing wakes at idle.
    private func retryLater() {
        guard !retryPending else { return }
        retryPending = true
        later(Self.retrySeconds, DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryPending = false
                guard !self.stopped, self.source == nil else { return }
                self.ensureFile()
                self.arm()
                self.scheduleTake()
            }
        })
    }

    /// Reads the file once it has gone `settleSeconds` without a write.
    private func scheduleTake() {
        pendingTake?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.take() }
        }
        pendingTake = item
        later(Self.settleSeconds, item)
    }

    private func later(_ seconds: TimeInterval, _ item: DispatchWorkItem) {
        laterCount += 1
        outstanding += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                self?.outstanding -= 1
                if !item.isCancelled { item.perform() }
            }
        }
    }

    /// Moves the file aside, puts a fresh one in its place, then reads the one it took.
    /// Moved, not emptied in place: a writer that still holds the file open writes on
    /// into the taken one, so its words never land at an old offset behind NUL bytes.
    private func take() {
        takeCount += 1
        pendingTake = nil
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 0 else { return }
        let taken = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).taken-\(UUID().uuidString)")
        source?.cancel()
        source = nil
        let moved = (try? fm.moveItem(at: file, to: taken)) != nil
        ensureFile()
        arm()
        // Decoded with a replacement mark for any byte that is not UTF-8, so a line in
        // another encoding still arrives instead of being deleted unread.
        let read = { (url: URL) in fm.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        let text: String
        if moved {
            text = read(taken)
            try? fm.removeItem(at: taken)
        } else {
            // It could not be moved: read it and empty it where it is, so a line is
            // never left sitting there unread.
            text = read(file)
            if let handle = FileHandle(forWritingAtPath: file.path) {
                try? handle.truncate(atOffset: 0)
                try? handle.close()
            }
        }
        // Something written in the moment between the move and the new watch.
        if let next = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, next > 0 {
            scheduleTake()
        }
        // NUL too: a file of zero bytes from a writer that seeked is not a line.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !trimmed.isEmpty else { return }
        deliver(trimmed)
    }
}
