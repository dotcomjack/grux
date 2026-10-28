import Foundation

/// One serial queue for every read, listing and move in a watched folder,
/// and for the ledger's writes. Serial and outside Swift's cooperative pool on
/// purpose: a listing of Desktop, Documents or Downloads before macOS has
/// granted access blocks its thread on the permission dialog and cannot be
/// canceled. On the pool, each toggle while the dialog was up held one more
/// of its few threads (review 2026-10-28). Here at most one thread waits, and
/// no listing of a folder starts while another is still in flight, because
/// none starts while anything is in flight.
enum FileNamingIO {
    static let queue = DispatchQueue(label: "com.gruxai.grux.file-naming", qos: .utility)

    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

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
    /// Whether a file's content is whole. Runs off the main actor.
    typealias Completeness = @Sendable (URL, FileNamingKind) -> Bool
    /// Lets go of a naming model that is not the chat model.
    typealias Unloader = (FileNamingRoute.Route) -> Void

    // MARK: - Seams (tests hand in their own; the app uses the defaults)

    private let folderSource: @Sendable () -> [FileNamingFolder]
    private let lister: Lister
    private let routeSource: () async -> FileNamingRoute.Resolution
    private let readText: TextReader
    private let fileManager: FileManager
    private let ledger: FileRenameLedger
    private let settleInterval: TimeInterval
    private let settleTimeout: TimeInterval
    private let pendingInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let quietInterval: TimeInterval
    private let completeness: Completeness
    private let incompleteRecheck: TimeInterval
    private let unloader: Unloader
    private let previewUnloadDelay: TimeInterval

    /// - Parameters:
    ///   - folders: the folders to watch, instead of the screenshot folder and
    ///     Downloads. Tests pass a temporary folder so the suite never lists a
    ///     real one.
    ///   - folderSource: where the folders come from, called once per arm,
    ///     off the main actor. Wins over `folders`; a test counts its calls.
    ///   - lister: how a folder is listed, instead of `FileNamingEntry.list`.
    ///   - backend, model: a model to call instead of resolving the local
    ///     route, so a test needs no server.
    ///   - textReader: instead of Vision and PDFKit.
    ///   - settleInterval: a new file is named once its size held across two
    ///     reads this far apart.
    ///   - settleTimeout: a file still changing this long after it appeared
    ///     is dropped.
    ///   - pendingInterval, retryInterval: how often the settling files are
    ///     read again, and how often a folder that is not watched is retried.
    ///   - quietInterval: a file is named only once it has not been written
    ///     for this long.
    ///   - completeness: instead of `FileTextReader.isComplete`.
    ///   - incompleteRecheck: a file that read as not whole is checked again
    ///     at most this often.
    ///   - unloader: instead of asking Ollama to unload the naming model.
    ///   - previewUnloadDelay: how long after a preview its naming model is
    ///     let go, unless another preview comes first.
    init(folders: [FileNamingFolder]? = nil,
         folderSource: (@Sendable () -> [FileNamingFolder])? = nil,
         lister: Lister? = nil,
         backend: ModelBackend? = nil,
         model: String? = nil,
         fileManager: FileManager = .default,
         ledgerURL: URL? = nil,
         textReader: TextReader? = nil,
         settleInterval: TimeInterval = 0.5,
         settleTimeout: TimeInterval = 600,
         pendingInterval: TimeInterval = 1,
         retryInterval: TimeInterval = 30,
         quietInterval: TimeInterval = 3,
         completeness: Completeness? = nil,
         incompleteRecheck: TimeInterval = 10,
         unloader: Unloader? = nil,
         previewUnloadDelay: TimeInterval = 60) {
        if let folderSource {
            self.folderSource = folderSource
        } else if let folders {
            self.folderSource = { folders }
        } else {
            self.folderSource = { FileNamingRules.watchedFolders() }
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
        self.quietInterval = quietInterval
        if let completeness {
            self.completeness = completeness
        } else {
            self.completeness = { url, kind in FileTextReader.isComplete(url, kind: kind) }
        }
        if let unloader {
            self.unloader = unloader
        } else {
            // `keep_alive: 0` on the loopback base the call used, the request
            // LocalModelUnload already builds; never sent from the test host.
            self.unloader = { route in
                guard !LocalModelUnload.isUnderTest, let base = route.baseURL,
                      let request = LocalModelUnload.request(baseURL: base, model: route.model) else { return }
                URLSession.shared.dataTask(with: request).resume()
            }
        }
        self.incompleteRecheck = incompleteRecheck
        self.previewUnloadDelay = previewUnloadDelay
        recent = ledger.recent(10)
    }

    // MARK: - State

    /// What a folder held when it was first listed, by file number, plus
    /// every file number seen in it since. Names are not identity: a person
    /// renaming a file, or Grux's own rename, keeps the number, so neither is
    /// ever read as a new file (review 2026-10-28, which found renamed
    /// captures being renamed again).
    ///
    /// `names` are the names, of files that are not empty, that the folder's
    /// last listing held. A new number under one of those names is the same
    /// file written again, not a new one: a tool that saves by writing a
    /// temporary file and moving it over the original (`exiftool
    /// -overwrite_original`, `qpdf --replace-input`) gives it a new number AND
    /// a new creation date (review 2026-10-28). The last listing only, never
    /// every name ever seen: that read a new download reusing a deleted
    /// file's generic name (`document.pdf`) as a rewrite forever (review
    /// 2026-10-28). A temp-then-move keeps the name in every listing; a
    /// delete and a later download leave at least one listing without it.
    private struct Baseline {
        let armedAt: Date
        var seen: Set<UInt64>
        var names: Set<String>
    }

    /// A new file waiting for its size to hold still.
    private struct Arrival {
        let name: String
        let folder: FileNamingFolder
        let fileID: UInt64
        let kind: FileNamingKind
        let firstSeen: Date
        var lastSize: Int64
        var lastSizeAt: Date
        /// When the content last read as not whole, so the check, which can
        /// parse a whole PDF, runs at most every `incompleteRecheck`.
        var incompleteAt: Date?
    }

    /// One settling file as the pending check read it, off the main actor.
    private struct PendingRead {
        let path: String
        let entry: FileNamingEntry?
        /// The content check ran on this read.
        let checked: Bool
        /// Held its size, quiet, and complete: ready for the model.
        let ready: Bool
    }

    /// A settled file, waiting for the model.
    private struct Ready {
        let url: URL
        let folder: FileNamingFolder
        let fingerprint: FileFingerprint
        let kind: FileNamingKind
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
    private var pendingTask: Task<Void, Never>?
    private var pendingTimer: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    /// Folder path to every name its last listing held, partial names
    /// included, for the pair check.
    private var latestNames: [String: Set<String>] = [:]
    /// The route of the last naming call, until the queue drains. Never set
    /// by a preview, so a pass while the eval runs does not unload its model
    /// between items (review 2026-10-28).
    private var lastNamingRoute: FileNamingRoute.Route?
    /// The route of the last preview's naming call, and its pending unload.
    private var lastPreviewRoute: FileNamingRoute.Route?
    private var previewUnload: Task<Void, Never>?
    /// Resolving the folders, off the main actor, at arm.
    private var armTask: Task<Void, Never>?
    /// Every file number present in a watched folder at its baseline, and
    /// every one Grux renamed or put back, across all the folders and arms. A
    /// move between two watched folders keeps the number, so a capture the
    /// person put back with Undo and then dragged into Downloads is not new
    /// there (review 2026-10-28).
    private var known: Set<UInt64> = []
    /// Undos with their disk work in flight, so one is never run twice.
    private var undoing: Set<UUID> = []
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

    /// Touches no folder on the main actor: the folders are resolved, and
    /// the first pass lists each one, on `FileNamingIO`, and that listing is
    /// its baseline. Listing Desktop, Documents or Downloads before macOS has
    /// granted access waits on the permission dialog, and on the main actor
    /// that froze the app, at launch too when a grant had been reset. Even the
    /// screenshot folder's existence check waits when the folder sits inside
    /// Desktop or Documents (review 2026-10-28). A folder that does not exist
    /// is kept: its listing fails, and the retry arms it when it appears.
    private func arm() {
        generation += 1
        let gen = generation
        folders = []
        baselines = [:]
        arrivals = [:]
        latestNames = [:]
        watch = FileWatch { [weak self] in self?.foldersChanged() }
        status.enabled = true
        status.armed = false
        status.folders = []
        status.unwatched = []
        status.missing = []
        status.screenshotFolder = nil
        let source = folderSource
        armTask = Task { [weak self] in
            let resolved = await FileNamingIO.run { source() }
            guard let self, self.generation == gen else { return }
            self.armTask = nil
            self.folders = resolved
            self.status.folders = resolved.map(\.url.path)
            self.status.unwatched = self.status.folders
            self.status.screenshotFolder = resolved.first(where: \.screenshots)?.url.path
            WakeLog.shared.log("autoname: arming, \(resolved.count) folders")
            self.requestPass()
        }
        Task { await refreshStatus() }
    }

    private func disarm() {
        if let route = lastNamingRoute { unloadIfNotChat(route) }
        lastNamingRoute = nil
        generation += 1
        armTask?.cancel()
        armTask = nil
        watch?.stop()
        watch = nil
        worker?.cancel()
        worker = nil
        passTask?.cancel()
        passTask = nil
        passAgain = false
        pendingTask?.cancel()
        pendingTask = nil
        pendingTimer?.cancel()
        pendingTimer = nil
        retryTimer?.cancel()
        retryTimer = nil
        queue = []
        queuedPaths = []
        baselines = [:]
        arrivals = [:]
        latestNames = [:]
        folders = []
        status.enabled = false
        status.armed = false
        status.folders = []
        status.unwatched = []
        status.missing = []
        status.screenshotFolder = nil
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
    /// retry for a folder not watched call it; tests call it directly. Returns at once: the listing
    /// runs off the main actor.
    func rescan() {
        requestPass()
    }

    /// A pass, awaited to the end, including any pass asked for while it ran.
    func rescanNow() async {
        if let arming = armTask { await arming.value }
        requestPass()
        while let task = passTask { await task.value }
    }

    private func requestPass() {
        // While the folders are being resolved there is nothing to list; the
        // arm asks for the first pass itself.
        guard status.enabled, armTask == nil else { return }
        guard passTask == nil else { passAgain = true; return }
        let gen = generation
        let targets = folders
        let lister = self.lister
        passTask = Task { [weak self] in
            let urls = targets.map(\.url)
            // A folder that cannot be listed is also checked for existence,
            // here on the queue: inside Desktop or Documents even that waits
            // on the permission dialog.
            let read = await FileNamingIO.run { () -> (listings: [[FileNamingEntry]?], missing: [String]) in
                let listings = urls.map { lister($0) }
                var missing: [String] = []
                for (url, listing) in zip(urls, listings) where listing == nil {
                    var isDir: ObjCBool = false
                    if !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
                        missing.append(url.path)
                    }
                }
                return (listings, missing)
            }
            let listings = read.listings
            guard let self, self.generation == gen else { return }
            self.passTask = nil
            self.status.missing = read.missing
            self.absorb(listings, of: targets, at: Date())
            if self.passAgain {
                self.passAgain = false
                self.requestPass()
            } else {
                self.scheduleTimers()
            }
        }
    }

    /// FileWatch is the main mechanism; these are the two slow checks beside
    /// it, each running only while it has something to do. While a new file is
    /// settling, every `pendingInterval` reads THAT file again and nothing
    /// else: re-listing every folder once a second was a full listing of
    /// Downloads and the screenshot folder, and a sort of both on the main
    /// actor, for as long as a 0 byte file sat there, up to 10 minutes
    /// (review 2026-10-28). While a folder is not watched (access not granted
    /// yet, or the folder is gone), every `retryInterval` lists the folders
    /// again; FileWatch's own doc asks for that, since a folder deleted and
    /// made again sends nothing to the old descriptor.
    private func scheduleTimers() {
        guard status.enabled else { return }
        let gen = generation
        if !arrivals.isEmpty, pendingTimer == nil, pendingTask == nil {
            let delay = pendingInterval
            pendingTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                self.pendingTimer = nil
                self.checkPending()
            }
        }
        if retryTimer == nil, folders.contains(where: { baselines[$0.url.path] == nil }) {
            let delay = retryInterval
            retryTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                self.retryTimer = nil
                self.requestPass()
            }
        }
    }

    /// One `lstat` per settling file, off the main actor, and the content
    /// check for the ones that look done. A file is ready when its size held
    /// across two reads `settleInterval` apart, it has not been written for
    /// `quietInterval`, and its content is whole: two equal sizes alone named
    /// a download written straight to its final name from its first half
    /// during a one second stall (review 2026-10-28).
    private func checkPending() {
        guard status.enabled, pendingTask == nil, !arrivals.isEmpty else { return }
        let gen = generation
        let snapshot = Array(arrivals.values)
        let settle = settleInterval
        let quiet = quietInterval
        let complete = completeness
        let recheck = incompleteRecheck
        let now = Date()
        pendingTask = Task { [weak self] in
            let reads = await FileNamingIO.run { () -> [PendingRead] in
                snapshot.map { arrival in
                    let url = arrival.folder.url.appendingPathComponent(arrival.name)
                    let entry = FileNamingEntry.read(url)
                    var checked = false
                    var ready = false
                    // The content check, which can parse a whole PDF, only
                    // once the size and the clock say the writing stopped, and
                    // after a "not whole" at most every `recheck`: a stalled
                    // download used to be parsed every second for 10 minutes
                    // (review 2026-10-28).
                    if let e = entry, e.isRegular, e.fileID == arrival.fileID, e.size > 0,
                       e.size == arrival.lastSize, now.timeIntervalSince(arrival.lastSizeAt) >= settle,
                       now.timeIntervalSince(e.modified) >= quiet,
                       arrival.incompleteAt.map({ now.timeIntervalSince($0) >= recheck }) ?? true {
                        checked = true
                        ready = complete(url, arrival.kind)
                    }
                    return PendingRead(path: url.path, entry: entry, checked: checked, ready: ready)
                }
            }
            guard let self, self.generation == gen else { return }
            self.pendingTask = nil
            self.applyPending(reads, at: now)
            self.scheduleTimers()
            self.unloadIfIdle()
        }
    }

    private func applyPending(_ reads: [PendingRead], at now: Date) {
        for read in reads {
            guard let arrival = arrivals[read.path] else { continue }
            guard let entry = read.entry, entry.isRegular else {
                // Moved, renamed or deleted before it settled.
                arrivals[read.path] = nil
                skip(.changedMeanwhile)
                continue
            }
            guard entry.fileID == arrival.fileID else {
                // Written again under its name. The new number is a rewrite,
                // which the next listing marks seen and leaves alone.
                arrivals[read.path] = nil
                continue
            }
            if read.ready {
                arrivals[read.path] = nil
                let names = Array(latestNames[arrival.folder.url.path] ?? [])
                if FileNamingRules.hasPair(arrival.name, among: names) {
                    skip(.unsupported)
                    continue
                }
                enqueue(Ready(url: arrival.folder.url.appendingPathComponent(arrival.name), folder: arrival.folder,
                              fingerprint: FileFingerprint(size: entry.size, fileNumber: entry.fileID),
                              kind: arrival.kind))
                continue
            }
            if now.timeIntervalSince(arrival.firstSeen) >= settleTimeout {
                arrivals[read.path] = nil
                skip(.unsupported)
                continue
            }
            if entry.size != arrival.lastSize {
                arrivals[read.path]?.lastSize = entry.size
                arrivals[read.path]?.lastSizeAt = now
                arrivals[read.path]?.incompleteAt = nil
            } else if read.checked {
                arrivals[read.path]?.incompleteAt = now
            }
        }
    }

    nonisolated private static func isTracked(_ entry: FileNamingEntry) -> Bool {
        entry.isRegular && !FileNamingRules.isPartialOrHidden(entry.name)
    }

    /// One pass's listings, on the main actor. A folder whose listing failed
    /// loses its baseline and waits; a folder listed for the first time takes
    /// that listing as its baseline and queues nothing; in a folder with a
    /// baseline, a file is new only when its number is unseen, its name is
    /// not one the folder already held, and it was created after the
    /// baseline. Only unseen numbers are judged, so a pass costs a set lookup
    /// per entry. A partial or hidden entry is never marked seen: a capture's
    /// temporary file and a `.crdownload` keep their number when they take
    /// their final name, and that name is the arrival.
    private func absorb(_ listings: [[FileNamingEntry]?], of targets: [FileNamingFolder], at now: Date) {
        for (folder, listing) in zip(targets, listings) {
            let path = folder.url.path
            guard let entries = listing else {
                if baselines.removeValue(forKey: path) != nil {
                    WakeLog.shared.log("autoname: a watched folder could not be listed; waiting for it")
                }
                latestNames[path] = nil
                for (key, arrival) in arrivals where arrival.folder.url.path == path { arrivals[key] = nil }
                continue
            }
            latestNames[path] = Set(entries.map(\.name))
            let tracked = entries.filter(Self.isTracked)
            guard var baseline = baselines[path] else {
                let present = Set(tracked.map(\.fileID))
                known.formUnion(present)
                baselines[path] = Baseline(armedAt: now, seen: present,
                                           names: Set(tracked.filter { $0.size > 0 }.map(\.name)))
                WakeLog.shared.log("autoname: a folder is watched, \(entries.count) entries already there are left alone")
                continue
            }
            let cutoff = baseline.armedAt.addingTimeInterval(-Self.creationSlack)
            let previous = baseline.names
            let unseen = tracked.filter { !baseline.seen.contains($0.fileID) }.sorted { $0.name < $1.name }
            for entry in unseen {
                // An empty file is a placeholder, not an arrival: Firefox makes
                // one and later moves the finished `.part` over it, under a new
                // number. Neither its number nor its name is remembered, so the
                // finished file arrives as new.
                if entry.size == 0 { continue }
                baseline.seen.insert(entry.fileID)
                // A number known from another watched folder moved here.
                if known.contains(entry.fileID) { continue }
                // A new number under a name the last listing held is a
                // rewrite: left alone and not counted, since nothing new
                // arrived.
                guard !previous.contains(entry.name), entry.created >= cutoff || true else { continue } // RED E
                switch FileNamingRules.candidacy(fileName: entry.name, in: folder, isScreenCapture: { folder.screenshots }) {
                case .ignore: continue
                case .skip(let reason): skip(reason)
                case .candidate(let kind):
                    let url = folder.url.appendingPathComponent(entry.name)
                    arrivals[url.path] = Arrival(name: entry.name, folder: folder, fileID: entry.fileID, kind: kind,
                                                 firstSeen: now, lastSize: entry.size, lastSizeAt: now)
                }
            }
            baseline.names = Set(tracked.filter { $0.size > 0 }.map(\.name))
            baselines[path] = baseline
        }
        rewatch()
        status.unwatched = folders.map(\.url.path).filter { baselines[$0] == nil }
        status.armed = folders.contains { baselines[$0.url.path] != nil }
        unloadIfIdle()
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
            if let self, self.generation == gen {
                self.worker = nil
                self.unloadIfIdle()
            }
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
            isCapture = await FileNamingIO.run { FileNamingRules.isScreenCapture(url) }
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

        // The checks that passed when it settled, again: the model call can
        // run long after, behind a chat turn or other files, and a partner, a
        // write or a stall can land in that gap (review 2026-10-28).
        let folderURL = item.folder.url
        let complete = completeness
        let quiet = quietInterval
        let recheck = await FileNamingIO.run { () -> (whole: Bool, quiet: Bool, names: [String]?) in
            let quietNow = FileNamingEntry.read(url).map { Date().timeIntervalSince($0.modified) >= quiet } ?? false
            let names = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            return (complete(url, kind), quietNow, names)
        }
        guard generation == gen else { return }
        guard let names = recheck.names, !FileNamingRules.hasPair(fileName, among: names) else {
            skip(.unsupported)
            log(proposal, outcome: "pair")
            return
        }
        guard recheck.whole, recheck.quiet else {
            skip(.changedMeanwhile)
            log(proposal, outcome: "changedMeanwhile")
            return
        }
        do {
            let renamer = FileRenamer(fileManager: fileManager)
            let renamed = try renamer.rename(url, to: base, expecting: item.fingerprint)
            // A rename in the same folder keeps the file number, so it is
            // already seen; said here so that never rests on how the move
            // was made.
            baselines[item.folder.url.path]?.seen.insert(item.fingerprint.fileNumber)
            known.insert(item.fingerprint.fileNumber)
            // The old name is free again: a later download that takes it is a
            // new file, not this one written again.
            baselines[item.folder.url.path]?.names.remove(fileName)
            baselines[item.folder.url.path]?.names.insert(renamed.lastPathComponent)
            let entry = FileRename(id: UUID(), folder: item.folder.url.path, oldName: fileName,
                                   newName: renamed.lastPathComponent, at: Date(), undoneAt: nil,
                                   fileID: item.fingerprint.fileNumber)
            ledger.appendInMemory(entry)
            writeLedger()
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
    private func propose(url: URL, kind: FileNamingKind, forPreview: Bool = false) async -> Proposal {
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
        // rename on a 16 GB Mac before adding a re-warm here. A naming model
        // that is not the chat model is a second model in memory, and is let
        // go once the queue drains (`unloadIfIdle`).
        if forPreview { lastPreviewRoute = route } else { lastNamingRoute = route }
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
        // A preview right after another keeps the model it is about to use.
        previewUnload?.cancel()
        previewUnload = nil
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
        let probe = await FileNamingIO.run { () -> (regular: Bool, capture: Bool, others: [String]) in
            let regular = FileFingerprint.of(url, fileManager: .default) != nil
            let others = (lister(folderURL) ?? []).map(\.name).filter { $0 != fileName }
            return (regular, regular && FileNamingRules.isScreenCapture(url), others)
        }
        guard probe.regular else { return leave(FileNamingSkip.unsupported.rawValue) }
        let folder = FileNamingFolder(url: folderURL, screenshots: true, downloads: true)
        let kind: FileNamingKind
        switch FileNamingRules.candidacy(fileName: fileName, in: folder, isScreenCapture: { probe.capture }) {
        case .ignore: return leave(FileNamingSkip.unsupported.rawValue)
        case .skip(let reason): return leave(reason.rawValue)
        case .candidate(let k): kind = k
        }
        if FileNamingRules.hasPair(fileName, among: probe.others) { return leave(FileNamingSkip.unsupported.rawValue) }
        let complete = completeness
        let whole = await FileNamingIO.run { complete(url, kind) }
        guard whole else { return leave(FileNamingSkip.unsupported.rawValue) }
        let p = await propose(url: url, kind: kind, forPreview: true)
        if let route = lastPreviewRoute {
            lastPreviewRoute = nil
            schedulePreviewUnload(route)
        }
        return FileNamingPreview(path: path, decision: p.name == nil ? "leave" : "rename", reason: p.reason,
                                 proposedName: p.name, readMs: p.readMs, modelMs: p.modelMs, model: p.model)
    }

    // MARK: - The naming model

    /// A naming model that is not the chat model is a second model in
    /// memory: one screenshot loaded it beside chat, held for 30 minutes at
    /// the chat's window, and on a 16 GB Mac that can push the chat model out,
    /// so the next chat turn pays a cold load (review 2026-10-28). So it is
    /// let go once nothing is left to name. The chat model itself is never
    /// unloaded here.
    private func unloadIfIdle() {
        guard queue.isEmpty, worker == nil, arrivals.isEmpty, let route = lastNamingRoute else { return }
        lastNamingRoute = nil
        unloadIfNotChat(route)
    }

    /// The eval runs one preview after another, often with the feature off,
    /// where nothing else would ever let the naming model go: it stayed loaded
    /// beside chat for 30 minutes (review 2026-10-28). So a preview's model is
    /// let go `previewUnloadDelay` after the last preview, and a preview before
    /// then cancels it, which keeps the model warm across the eval's items.
    /// Not while the armed feature still has files to name: its own unload
    /// covers that model once the queue drains.
    private func schedulePreviewUnload(_ route: FileNamingRoute.Route) {
        previewUnload?.cancel()
        previewUnload = nil
        guard !route.model.isEmpty,
              !FileNamingRoute.sameTag(route.model, AppState.shared.config.offlineLLMModel) else { return }
        guard !status.armed || (queue.isEmpty && worker == nil && arrivals.isEmpty) else { return }
        let delay = previewUnloadDelay
        previewUnload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.previewUnload = nil
            self.unloadIfNotChat(route)
        }
    }

    private func unloadIfNotChat(_ route: FileNamingRoute.Route) {
        guard !route.model.isEmpty,
              !FileNamingRoute.sameTag(route.model, AppState.shared.config.offlineLLMModel) else { return }
        WakeLog.shared.log("autoname: unloading the naming model \(route.model), chat uses another")
        unloader(route)
    }

    // MARK: - Undo

    /// Undoes one rename with the file checks and the move done right here.
    /// Kept for callers that need the outcome at once; the app's own Undo
    /// buttons and the trigger use `undoInBackground`, which keeps the folder
    /// off the main actor.
    @discardableResult
    func undo(id: UUID) -> FileUndoOutcome {
        guard let entry = ledger.entry(id: id), entry.undoneAt == nil, !undoing.contains(id) else {
            WakeLog.shared.log("autoname: undo nothingToUndo")
            return .nothingToUndo
        }
        let outcome = FileRenameLedger.restore(entry, fileManager: fileManager)
        if outcome == .restored {
            ledger.markUndone(id: id)
            // Through the same queue as every other ledger write, so the
            // order on disk is the order they were made.
            writeLedger()
        }
        finishUndo(entry, outcome)
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

    /// Undoes one rename with the file checks, the move and the ledger write
    /// on `FileNamingIO`. Undo runs from a notification, Settings and a
    /// trigger, feature on or off, and a folder whose access was reset since
    /// the rename would hold the main actor on the permission dialog
    /// (review 2026-10-28).
    @discardableResult
    func undoInBackground(id: UUID) async -> FileUndoOutcome {
        guard let entry = ledger.entry(id: id), entry.undoneAt == nil, undoing.insert(id).inserted else {
            WakeLog.shared.log("autoname: undo nothingToUndo")
            return .nothingToUndo
        }
        let outcome = await FileNamingIO.run { FileRenameLedger.restore(entry, fileManager: .default) }
        undoing.remove(id)
        if outcome == .restored {
            ledger.markUndone(id: id)
            writeLedger()
        }
        finishUndo(entry, outcome)
        return outcome
    }

    @discardableResult
    func undoLastInBackground() async -> FileUndoOutcome {
        guard let last = ledger.entries.last(where: { $0.undoneAt == nil && !undoing.contains($0.id) }) else {
            WakeLog.shared.log("autoname: undo nothingToUndo")
            return .nothingToUndo
        }
        return await undoInBackground(id: last.id)
    }

    private func finishUndo(_ entry: FileRename?, _ outcome: FileUndoOutcome) {
        if outcome == .restored, let entry {
            // The restored name is the same file, so the same number: already
            // seen while armed, and in the baseline of any later arm, so it is
            // never read as new and renamed straight back, in this folder or
            // another watched one it is moved to.
            if let fileID = entry.fileID {
                baselines[entry.folder]?.seen.insert(fileID)
                known.insert(fileID)
            }
            baselines[entry.folder]?.names.remove(entry.newName)
            baselines[entry.folder]?.names.insert(entry.oldName)
            status.undone += 1
        }
        recent = ledger.recent(10)
        WakeLog.shared.log("autoname: undo \(Self.outcomeName(outcome))")
    }

    /// The ledger as it stands now, written on `FileNamingIO` in the order
    /// the writes were asked for, so a later write never loses to an earlier.
    private func writeLedger() {
        guard let data = ledger.encoded() else { return }
        let url = ledger.url
        FileNamingIO.queue.async { FileRenameLedger.write(data, to: url) }
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
        case .fileChanged: return "fileChanged"
        case .failed: return "failed"
        }
    }

    private static func ms(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
