import Foundation

/// "Files that name themselves": a new screenshot, or a new image or PDF in
/// Downloads with a machine-made name, is renamed from the text it shows.
/// Design: docs/superpowers/specs/2026-10-27-files-name-themselves-design.md.
///
/// Off by default, and while off it touches no folder at all: macOS protects
/// Desktop, Documents and Downloads, and a read before there is a window to
/// explain it hung launch once (`LaunchTouchesNoProtectedFolderTests`). So
/// building this object reads only Grux's own ledger, and the folders are
/// listed for the first time by the pass `apply(enabled: true)` starts, off
/// the main actor.
///
/// Everything stays on this Mac: Vision and PDFKit read the text, and a
/// loopback Ollama writes the name (`FileNamingRoute`). Nothing about a file,
/// neither its text nor its names, goes to WakeLog or NSLog: the log lines
/// carry the event, the reason, the model and the time in ms.
@MainActor
final class FileNamingService: ObservableObject {

    static let shared = FileNamingService()

    @Published private(set) var status: FileNamingStatus = .idle
    /// Newest first, at most 10, from the ledger.
    @Published private(set) var recent: [FileRename] = []
    /// Set by the app at launch to post the "Renamed" notification.
    var onRenamed: (@MainActor (FileRename) -> Void)?

    typealias TextReader = (URL, FileNamingKind) async -> String
    /// Lists one folder, or nil when it cannot be listed. Runs off the main
    /// actor, always.
    typealias Lister = @Sendable (URL) -> [FileNamingEntry]?

    // MARK: - Seams (tests hand in their own; the app uses the defaults)

    private let folderSource: () -> [FileNamingFolder]
    private let lister: Lister
    private let routeSource: () async -> FileNamingRoute.Resolution
    private let readText: TextReader
    private let fileManager: FileManager
    private let ledger: FileRenameLedger
    private let settleInterval: TimeInterval
    private let settleTimeout: TimeInterval
    private let pendingInterval: TimeInterval
    private let retryInterval: TimeInterval

    /// - Parameters:
    ///   - folders: the folders to watch, instead of the screenshot folder and
    ///     Downloads. Tests pass a temporary folder so the suite never lists a
    ///     real one.
    ///   - folderSource: where the folders come from, called once per arm.
    ///     Wins over `folders`; a test counts its calls.
    ///   - lister: how a folder is listed, instead of `FileNamingEntry.list`.
    ///   - backend, model: a model to call instead of resolving the local
    ///     route, so a test needs no server.
    ///   - textReader: instead of Vision and PDFKit.
    ///   - settleInterval: a new file is named once its size held across two
    ///     reads this far apart.
    ///   - settleTimeout: a file still changing this long after it appeared
    ///     is dropped.
    ///   - pendingInterval, retryInterval: how often the fallback re-check
    ///     runs while a file is settling, and while a folder is not watched.
    init(folders: [FileNamingFolder]? = nil,
         folderSource: (() -> [FileNamingFolder])? = nil,
         lister: Lister? = nil,
         backend: ModelBackend? = nil,
         model: String? = nil,
         fileManager: FileManager = .default,
         ledgerURL: URL? = nil,
         textReader: TextReader? = nil,
         settleInterval: TimeInterval = 0.5,
         settleTimeout: TimeInterval = 600,
         pendingInterval: TimeInterval = 1,
         retryInterval: TimeInterval = 30) {
        if let folderSource {
            self.folderSource = folderSource
        } else if let folders {
            self.folderSource = { folders }
        } else {
            self.folderSource = { FileNamingRules.watchedFolders(fileManager: fileManager) }
        }
        if let lister {
            self.lister = lister
        } else {
            self.lister = { FileNamingEntry.list($0) }
        }
        if let backend {
            let route = FileNamingRoute.Route(backend: backend, model: model ?? "", apiKey: "")
            routeSource = { .ok(route) }
        } else {
            routeSource = { await FileNamingRoute.resolution() }
        }
        if let textReader {
            readText = textReader
        } else {
            readText = { url, kind in await FileTextReader.text(of: url, kind: kind) }
        }
        self.fileManager = fileManager
        ledger = FileRenameLedger(url: ledgerURL ?? FileRenameLedger.defaultURL, fileManager: fileManager)
        self.settleInterval = settleInterval
        self.settleTimeout = settleTimeout
        self.pendingInterval = pendingInterval
        self.retryInterval = retryInterval
        recent = ledger.recent(10)
    }

    // MARK: - State

    /// What a folder held when it was first listed, by file number, plus
    /// every file number seen in it since. Names are not identity: a person
    /// renaming a file, or Grux's own rename, keeps the number, so neither is
    /// ever read as a new file (review 2026-10-28, which found renamed
    /// captures being renamed again).
    private struct Baseline {
        let armedAt: Date
        var seen: Set<UInt64>
    }

    /// A new file waiting for its size to hold still.
    private struct Arrival {
        let name: String
        let folder: FileNamingFolder
        let fileID: UInt64
        let firstSeen: Date
        var lastSize: Int64
        var lastSizeAt: Date
    }

    /// A settled file, waiting for the model.
    private struct Ready {
        let url: URL
        let folder: FileNamingFolder
        let fingerprint: FileFingerprint
    }

    /// A file counts as new only when it was created at or after the folder's
    /// baseline, less this much. A file moved or copied in keeps its creation
    /// date, so an old file dragged into Downloads is not new.
    static let creationSlack: TimeInterval = 2

    private var watch: FileWatch?
    private var folders: [FileNamingFolder] = []
    /// Folder path to its baseline. A folder with none has never been listed
    /// since arming (or its last listing failed): it is not watched, and the
    /// first listing that works becomes its baseline.
    private var baselines: [String: Baseline] = [:]
    /// Full path to a new file that has not settled yet.
    private var arrivals: [String: Arrival] = [:]
    private var queue: [Ready] = []
    private var queuedPaths: Set<String> = []
    private var worker: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var passAgain = false
    private var fallback: Task<Void, Never>?
    private var fallbackDelay: TimeInterval = 0
    /// Bumped on every arm and disarm, so work started under an old arm
    /// never renames anything.
    private var generation = 0

    /// The folders the file watch holds open, for tests.
    var watchedPaths: Set<String> { watch?.watchedPaths ?? [] }

    // MARK: - On and off

    /// Arms or disarms. Idempotent: the same value twice does nothing.
    func apply(enabled: Bool) {
        guard enabled != status.enabled else { return }
        if enabled { arm() } else { disarm() }
    }

    /// Takes no listing itself: the first pass, off the main actor, lists each
    /// folder and that listing is its baseline. Listing Desktop, Documents or
    /// Downloads before macOS has granted access waits on the permission
    /// dialog, and on the main actor that froze the app, at launch too when a
    /// grant had been reset (review 2026-10-28).
    private func arm() {
        generation += 1
        folders = folderSource()
        baselines = [:]
        arrivals = [:]
        watch = FileWatch { [weak self] in self?.foldersChanged() }
        status.enabled = true
        status.armed = false
        status.folders = folders.map(\.url.path)
        status.unwatched = status.folders
        WakeLog.shared.log("autoname: arming, \(folders.count) folders")
        requestPass()
        Task { await refreshStatus() }
    }

    private func disarm() {
        generation += 1
        watch?.stop()
        watch = nil
        worker?.cancel()
        worker = nil
        passTask?.cancel()
        passTask = nil
        passAgain = false
        fallback?.cancel()
        fallback = nil
        queue = []
        queuedPaths = []
        baselines = [:]
        arrivals = [:]
        folders = []
        status.enabled = false
        status.armed = false
        status.folders = []
        status.unwatched = []
        WakeLog.shared.log("autoname: disarmed")
    }

    /// Re-resolves the local route for the status line.
    func refreshStatus() async {
        let resolution = await routeSource()
        noteRoute(resolution)
    }

    private func noteRoute(_ resolution: FileNamingRoute.Resolution) {
        let name = resolution.statusName
        let model = resolution.route?.model
        if name != status.route || model != status.model {
            WakeLog.shared.log("autoname: route \(name)" + (model.map { ", model \($0)" } ?? ""))
        }
        status.route = name
        status.model = model
    }

    // MARK: - Watching

    private func foldersChanged() {
        rewatch()
        requestPass()
    }

    /// Opens a watch on every folder that has a baseline, and only those: a
    /// folder Grux could not list is not opened from the main actor either.
    /// FileWatch drops a folder that was deleted or replaced; this reopens it
    /// once it is back.
    private func rewatch() {
        watch?.watch(folders.filter { baselines[$0.url.path] != nil }.map(\.url))
    }

    /// Asks for a pass over every watched folder. The FileWatch event and the
    /// fallback call it; tests call it directly. Returns at once: the listing
    /// runs off the main actor.
    func rescan() {
        requestPass()
    }

    /// A pass, awaited to the end, including any pass asked for while it ran.
    func rescanNow() async {
        requestPass()
        while let task = passTask { await task.value }
    }

    private func requestPass() {
        guard status.enabled else { return }
        guard passTask == nil else { passAgain = true; return }
        let gen = generation
        let targets = folders
        let lister = self.lister
        passTask = Task { [weak self] in
            let urls = targets.map(\.url)
            let listings = await Task.detached(priority: .utility) { urls.map { lister($0) } }.value
            guard let self, self.generation == gen else { return }
            self.passTask = nil
            self.absorb(listings, of: targets, at: Date())
            if self.passAgain {
                self.passAgain = false
                self.requestPass()
            } else {
                self.scheduleFallback()
            }
        }
    }

    /// FileWatch is the main mechanism; this is the slow net under it, and it
    /// runs only while there is something to do: every `pendingInterval`
    /// while a new file is settling, every `retryInterval` while a folder is
    /// not watched (access not granted yet, or the folder is gone). FileWatch's
    /// own doc asks callers for this: a folder deleted and made again sends no
    /// further event to the old descriptor (review 2026-10-28).
    private func scheduleFallback() {
        guard status.enabled else { return }
        let delay: TimeInterval
        if !arrivals.isEmpty {
            delay = pendingInterval
        } else if folders.contains(where: { baselines[$0.url.path] == nil }) {
            delay = retryInterval
        } else {
            return
        }
        if fallback != nil {
            if fallbackDelay <= delay { return }
            fallback?.cancel()
        }
        fallbackDelay = delay
        let gen = generation
        fallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.fallback = nil
            self.rewatch()
            self.requestPass()
        }
    }

    nonisolated private static func isTracked(_ entry: FileNamingEntry) -> Bool {
        entry.isRegular && !FileNamingRules.isPartialOrHidden(entry.name)
    }

    /// One pass's listings, on the main actor. A folder whose listing failed
    /// loses its baseline and waits; a folder listed for the first time takes
    /// that listing as its baseline and queues nothing; in a folder with a
    /// baseline, a file is new only when its number is unseen AND it was
    /// created after the baseline. A partial or hidden entry is never marked
    /// seen: a capture's temporary file and a `.crdownload` keep their number
    /// when they take their final name, and that name is the arrival.
    private func absorb(_ listings: [[FileNamingEntry]?], of targets: [FileNamingFolder], at now: Date) {
        for (folder, listing) in zip(targets, listings) {
            let path = folder.url.path
            guard let entries = listing else {
                if baselines.removeValue(forKey: path) != nil {
                    WakeLog.shared.log("autoname: a watched folder could not be listed; waiting for it")
                }
                for (key, arrival) in arrivals where arrival.folder.url.path == path { arrivals[key] = nil }
                continue
            }
            guard var baseline = baselines[path] else {
                baselines[path] = Baseline(armedAt: now, seen: Set(entries.filter(Self.isTracked).map(\.fileID)))
                WakeLog.shared.log("autoname: a folder is watched, \(entries.count) entries already there are left alone")
                continue
            }
            let cutoff = baseline.armedAt.addingTimeInterval(-Self.creationSlack)
            for entry in entries.sorted(by: { $0.name < $1.name }) where Self.isTracked(entry) {
                guard baseline.seen.insert(entry.fileID).inserted, entry.created >= cutoff else { continue }
                switch FileNamingRules.candidacy(fileName: entry.name, in: folder, isScreenCapture: { folder.screenshots }) {
                case .ignore: continue
                case .skip(let reason): skip(reason)
                case .candidate:
                    let url = folder.url.appendingPathComponent(entry.name)
                    arrivals[url.path] = Arrival(name: entry.name, folder: folder, fileID: entry.fileID,
                                                 firstSeen: now, lastSize: entry.size, lastSizeAt: now)
                }
            }
            baselines[path] = baseline
            settle(in: folder, entries: entries, at: now)
        }
        rewatch()
        status.unwatched = folders.map(\.url.path).filter { baselines[$0] == nil }
        status.armed = folders.contains { baselines[$0.url.path] != nil }
    }

    /// Settling never holds the queue: each pass hands on the files whose
    /// size held across two reads `settleInterval` apart and leaves the rest
    /// waiting. It used to be one file at a time inside the worker, so a
    /// download that never settled (Firefox writes a 0 byte file under the
    /// final name, then moves the `.part` over it) held every screenshot
    /// behind it for 60 s and was then dropped for good (review 2026-10-28).
    private func settle(in folder: FileNamingFolder, entries: [FileNamingEntry], at now: Date) {
        let path = folder.url.path
        var byName: [String: FileNamingEntry] = [:]
        for entry in entries { byName[entry.name] = entry }
        for (key, arrival) in arrivals where arrival.folder.url.path == path {
            guard let entry = byName[arrival.name], entry.fileID == arrival.fileID, entry.isRegular else {
                // Renamed, moved, deleted or replaced before it settled. A
                // replacement has its own number and is its own arrival.
                arrivals[key] = nil
                skip(.changedMeanwhile)
                continue
            }
            if entry.size > 0, entry.size == arrival.lastSize,
               now.timeIntervalSince(arrival.lastSizeAt) >= settleInterval {
                arrivals[key] = nil
                let others = entries.filter { $0.isRegular && $0.name != entry.name }.map(\.name)
                if FileNamingRules.hasPair(entry.name, among: others) {
                    skip(.unsupported)
                    continue
                }
                enqueue(Ready(url: folder.url.appendingPathComponent(entry.name), folder: folder,
                              fingerprint: FileFingerprint(size: entry.size, fileNumber: entry.fileID)))
                continue
            }
            if now.timeIntervalSince(arrival.firstSeen) >= settleTimeout {
                arrivals[key] = nil
                skip(.unsupported)
                continue
            }
            if entry.size != arrival.lastSize {
                arrivals[key]?.lastSize = entry.size
                arrivals[key]?.lastSizeAt = now
            }
        }
    }

    private func enqueue(_ item: Ready) {
        guard queuedPaths.insert(item.url.path).inserted else { return }
        queue.append(item)
        startWorker()
    }

    /// One file at a time, so the local model sees at most one naming call
    /// and a person's chat turn waits behind at most that one.
    private func startWorker() {
        guard worker == nil else { return }
        let gen = generation
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == gen, !self.queue.isEmpty else { break }
                let item = self.queue.removeFirst()
                await self.process(item, generation: gen)
                self.queuedPaths.remove(item.url.path)
            }
            if let self, self.generation == gen { self.worker = nil }
        }
    }

    // MARK: - One file

    private func process(_ item: Ready, generation gen: Int) async {
        let url = item.url
        let fileName = url.lastPathComponent
        // The capture mark is read now, after the file settled, because macOS
        // writes a capture under a temporary name first. Off the main actor,
        // like every other read of a watched folder.
        var isCapture = false
        if item.folder.screenshots {
            isCapture = await Task.detached(priority: .utility) { FileNamingRules.isScreenCapture(url) }.value
        }
        guard generation == gen else { return }
        let kind: FileNamingKind
        switch FileNamingRules.candidacy(fileName: fileName, in: item.folder, isScreenCapture: { isCapture }) {
        case .ignore: return
        case .skip(let reason): skip(reason); return
        case .candidate(let k): kind = k
        }

        let proposal = await propose(url: url, kind: kind)
        guard generation == gen else { return }
        guard let base = proposal.name else {
            if let reason = FileNamingSkip(rawValue: proposal.reason) { skip(reason) }
            log(proposal, outcome: "left")
            return
        }
        do {
            let renamer = FileRenamer(fileManager: fileManager)
            let renamed = try renamer.rename(url, to: base, expecting: item.fingerprint)
            // A rename in the same folder keeps the file number, so it is
            // already seen; said here so that never rests on how the move
            // was made.
            baselines[item.folder.url.path]?.seen.insert(item.fingerprint.fileNumber)
            let entry = FileRename(id: UUID(), folder: item.folder.url.path, oldName: fileName,
                                   newName: renamed.lastPathComponent, at: Date(), undoneAt: nil,
                                   fileID: item.fingerprint.fileNumber)
            ledger.append(entry)
            recent = ledger.recent(10)
            status.named += 1
            status.lastNamedAt = entry.at
            log(proposal, outcome: "renamed")
            onRenamed?(entry)
        } catch FileRenameError.changedMeanwhile {
            skip(.changedMeanwhile)
            log(proposal, outcome: "changedMeanwhile")
        } catch {
            skip(.error)
            log(proposal, outcome: "error")
        }
    }

    private func skip(_ reason: FileNamingSkip) {
        status.skipped[reason.rawValue, default: 0] += 1
    }

    // MARK: - The pipeline

    private struct Proposal {
        /// nil means leave the file alone, for `reason`.
        let name: String?
        let reason: String
        let readMs: Int
        let modelMs: Int
        let model: String?
    }

    /// Route, read, ask, clean. Shared by the live path and the preview, so
    /// the eval measures exactly what renames files.
    private func propose(url: URL, kind: FileNamingKind) async -> Proposal {
        let resolution = await routeSource()
        noteRoute(resolution)
        guard let route = resolution.route else {
            return Proposal(name: nil, reason: resolution.statusName, readMs: 0, modelMs: 0, model: nil)
        }

        let readStart = Date()
        let text = await readText(url, kind)
        let readMs = Self.ms(since: readStart)
        guard !text.isEmpty else {
            return Proposal(name: nil, reason: FileNamingSkip.noText.rawValue, readMs: readMs, modelMs: 0, model: route.model)
        }

        // A person's chat turn goes first. The gate is first come first
        // served, not a priority lock, and the short-answer call never takes
        // it on its own, so this is the warmLocalPrefix pattern: wait out the
        // turn, take the slot, and give it straight back if a turn started
        // while we queued for it.
        while true {
            while AppState.shared.chatTurnInFlight {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled {
                    return Proposal(name: nil, reason: FileNamingSkip.error.rawValue, readMs: readMs, modelMs: 0, model: route.model)
                }
            }
            await LocalModelGate.shared.acquire()
            if !AppState.shared.chatTurnInFlight { break }
            await LocalModelGate.shared.release()
        }

        // THE TRADE, named (review 2026-10-28). On an Ollama with one slot per
        // model, this call replaces the chat's cached prompt prefix, and the
        // next local chat turn reads its whole prompt again (measured
        // 2026-10-24 on a 16 GB test Mac, for `ChatService.warmLocalPrefix`:
        // 18.39 and 15.73 s cold against 2.85 s warm). Accepted because a
        // name is rare, a few a day, against chat turns all day. What keeps
        // the cost down is keeping this call short: at most 3,000 characters
        // of text in and 24 tokens out. Measure the first chat turn after a
        // rename on a 16 GB Mac before adding a re-warm here.
        let modelStart = Date()
        let reply: String?
        var failure = FileNamingSkip.error
        do {
            reply = try await route.backend.completeShortAnswer(
                apiKey: route.apiKey,
                model: route.model,
                system: FileNamePrompt.system,
                messages: [ClaudeMessage(role: "user", content: FileNamePrompt.user(text: text))],
                maxTokens: 24,
                temperature: 0,
                spanName: "files.autoname",
                feature: "file_autoname")
        } catch ClaudeError.http(200, let message) where message == OpenAICompatBackend.thinkingBudgetMessage {
            // A model that thought through its whole budget gave no name.
            reply = nil
            failure = .modelDeclined
        } catch {
            reply = nil
        }
        await LocalModelGate.shared.release()
        let modelMs = Self.ms(since: modelStart)

        guard let reply else {
            return Proposal(name: nil, reason: failure.rawValue, readMs: readMs, modelMs: modelMs, model: route.model)
        }
        let currentBase = url.deletingPathExtension().lastPathComponent
        guard let name = FileNamePrompt.clean(reply, sourceText: text, fileExtension: url.pathExtension),
              name.lowercased() != currentBase.lowercased() else {
            return Proposal(name: nil, reason: FileNamingSkip.modelDeclined.rawValue,
                            readMs: readMs, modelMs: modelMs, model: route.model)
        }
        return Proposal(name: name, reason: "named", readMs: readMs, modelMs: modelMs, model: route.model)
    }

    /// The whole pipeline on one file, renaming nothing. Works when the
    /// feature is off and ignores the "appeared after arming" rule; every
    /// other rule applies, with the file's own folder treated as both a
    /// screenshot folder and Downloads. The eval harness's entry point.
    func preview(path: String) async -> FileNamingPreview {
        let url = URL(fileURLWithPath: path)
        func leave(_ reason: String) -> FileNamingPreview {
            FileNamingPreview(path: path, decision: "leave", reason: reason, proposedName: nil,
                              readMs: 0, modelMs: 0, model: nil)
        }
        let folderURL = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        let lister = self.lister
        // Every read of the file and its folder off the main actor: the path
        // can be anywhere, Documents included.
        let probe = await Task.detached(priority: .utility) { () -> (regular: Bool, capture: Bool, others: [String]) in
            let regular = FileFingerprint.of(url, fileManager: .default) != nil
            let others = (lister(folderURL) ?? []).filter { $0.isRegular && $0.name != fileName }.map(\.name)
            return (regular, regular && FileNamingRules.isScreenCapture(url), others)
        }.value
        guard probe.regular else { return leave(FileNamingSkip.unsupported.rawValue) }
        let folder = FileNamingFolder(url: folderURL, screenshots: true, downloads: true)
        let kind: FileNamingKind
        switch FileNamingRules.candidacy(fileName: fileName, in: folder, isScreenCapture: { probe.capture }) {
        case .ignore: return leave(FileNamingSkip.unsupported.rawValue)
        case .skip(let reason): return leave(reason.rawValue)
        case .candidate(let k): kind = k
        }
        if FileNamingRules.hasPair(fileName, among: probe.others) { return leave(FileNamingSkip.unsupported.rawValue) }
        let p = await propose(url: url, kind: kind)
        return FileNamingPreview(path: path, decision: p.name == nil ? "leave" : "rename", reason: p.reason,
                                 proposedName: p.name, readMs: p.readMs, modelMs: p.modelMs, model: p.model)
    }

    // MARK: - Undo

    @discardableResult
    func undo(id: UUID) -> FileUndoOutcome {
        let entry = ledger.entry(id: id)
        let outcome = ledger.undo(id: id)
        if outcome == .restored, let entry {
            // The restored name is the same file, so the same number: already
            // seen while armed, and in the baseline of any later arm, so it is
            // never read as new and renamed straight back. Marked here as well
            // so that never rests on how the move was made.
            if let fileID = entry.fileID { baselines[entry.folder]?.seen.insert(fileID) }
            status.undone += 1
        }
        recent = ledger.recent(10)
        WakeLog.shared.log("autoname: undo \(Self.outcomeName(outcome))")
        return outcome
    }

    @discardableResult
    func undoLast() -> FileUndoOutcome {
        guard let last = ledger.entries.last(where: { $0.undoneAt == nil }) else {
            WakeLog.shared.log("autoname: undo nothingToUndo")
            return .nothingToUndo
        }
        return undo(id: last.id)
    }

    // MARK: - Log lines (never a file's text or names)

    private func log(_ p: Proposal, outcome: String) {
        WakeLog.shared.log("autoname: \(outcome) (\(p.reason)), model \(p.model ?? "none"), read \(p.readMs) ms, model \(p.modelMs) ms")
    }

    /// The case only. A failure's description can hold a path, so it stays
    /// out of the log.
    private static func outcomeName(_ outcome: FileUndoOutcome) -> String {
        switch outcome {
        case .restored: return "restored"
        case .nothingToUndo: return "nothingToUndo"
        case .newNameGone: return "newNameGone"
        case .oldNameTaken: return "oldNameTaken"
        case .failed: return "failed"
        }
    }

    private static func ms(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
