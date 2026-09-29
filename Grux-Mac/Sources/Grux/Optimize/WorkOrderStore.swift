import Foundation
import AppKit

/// The work orders on this Mac, one folder each under `~/.grux/work-orders`.
///
///     <id>/order.json      what was asked and when, written by Grux
///     <id>/work-order.md   the work order, exactly as it was copied
///     <id>/progress.log    one line per station, appended by the agent
///     acknowledged.json    proposal ids whose Success card the person closed
///     seen.json            proposal ids whose Proposed card was shown here
///
/// Files rather than a database because the other half of this feature is a
/// coding agent in a terminal: it can read a path and append a line with
/// `echo`, whatever agent it is, and Grux can read both back.
///
/// LIVE, NEVER A MANUAL REFRESH. The store watches the root, every order
/// folder and every progress.log through `FileWatch` (a DispatchSource per
/// path; FileWatch says why not FSEvents), so a line an agent appends moves
/// the published station in the same moment, and an order added or removed
/// outside Grux shows the same way. `pollWhileActive` is the slow fallback
/// for a path the watcher could not open.
@MainActor
final class WorkOrderStore: ObservableObject {

    static let shared = WorkOrderStore(root: Persistence.gruxDir.appendingPathComponent("work-orders", isDirectory: true))

    struct Order: Identifiable, Equatable {
        let id: String
        let request: String
        let created: Date
        let progress: WorkOrderProgress
        /// When the agent last reported, or when Grux wrote the order.
        let updated: Date
        let dir: URL
        /// The Optimize proposal this order carries out, if it came from one.
        var proposalId: String? = nil

        var progressFile: URL { dir.appendingPathComponent("progress.log") }
        var workOrderFile: URL { dir.appendingPathComponent("work-order.md") }

        /// Still moving on the line, but no new line for `quietAfter`: the
        /// agent stopped or lost the order, so the row offers it again. Never
        /// at a review: there the agent is waiting on the person, on purpose.
        func isWaiting(now: Date = Date()) -> Bool {
            !progress.stage.isFinished && !progress.stage.isReview
                && now.timeIntervalSince(updated) >= WorkOrderStore.quietAfter
        }
    }

    /// How long an order may go without a new line before the row says
    /// "Waiting for your agent" and offers Copy again and Remove.
    static let quietAfter: TimeInterval = 30 * 60

    private struct Meta: Codable {
        let id: String
        let request: String
        let created: Date
        /// Absent in orders written before proposals were linked.
        var proposal: String? = nil
    }

    @Published private(set) var orders: [Order] = []
    /// Proposals whose Success card the person closed with Got it. Kept on
    /// disk, so a relaunch never shows that proposal again.
    @Published private(set) var acknowledgedProposals: Set<String> = []
    /// Proposals whose Proposed card was shown on this install. With an
    /// order for the proposal, the evidence that THIS install did the work,
    /// so a build that already has the change shows its Success card here
    /// and nothing at all on a fresh install.
    @Published private(set) var seenProposals: Set<String> = []
    let root: URL
    private var acknowledgedFile: URL { root.appendingPathComponent("acknowledged.json") }
    private var seenFile: URL { root.appendingPathComponent("seen.json") }
    private var watch: FileWatch?
    /// Orders copied again after they finished: watched until the agent's
    /// next line, so a resumed order moves live rather than reading as done
    /// or stopped until a relaunch.
    private var rearmed: Set<String> = []

    init(root: URL) {
        self.root = root
        // Made up front so it can be watched before the first order exists.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        watch = FileWatch { [weak self] in self?.reload() }
        reload()
    }

    /// What the watcher holds open, for tests.
    var watchedPaths: Set<String> { watch?.watchedPaths ?? [] }

    /// Orders waiting for the person at one of the three reviews.
    var waitingOnYou: Int { orders.filter { $0.progress.stage.isReview }.count }

    /// True while any order is still moving, which is when the view polls.
    var hasActive: Bool { orders.contains { !$0.progress.stage.isFinished } }

    // MARK: - Reading

    func reload() {
        let fm = FileManager.default
        // Folders only: acknowledged.json sits beside them.
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // What is watched: the root, and every order not done (its folder
        // and its log). A done order holds no descriptor, so they cannot
        // pile up over months; the root still sees it removed, and Copy
        // again re-arms it. A stopped order stays watched: its agent may
        // carry on. A folder with no readable order.json yet is watched too:
        // another process writes the folder first and its files after,
        // inside the folder.
        //
        // Watch BEFORE reading, from what the last read knew, so a line
        // appended while this runs still fires; then trim to what this read
        // found done.
        let finished = Set(orders.filter { $0.progress.stage == .done }.map(\.id)).subtracting(rearmed)
        func paths(_ names: [String]) -> [URL] {
            [root] + names.flatMap { name -> [URL] in
                let folder = root.appendingPathComponent(name, isDirectory: true)
                return [folder, folder.appendingPathComponent("progress.log")]
            }
        }
        watch?.watch(paths(dirs.map(\.lastPathComponent).filter { !finished.contains($0) }))
        var out: [Order] = []
        var moving: [String] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("order.json")),
                  let meta = try? decoder.decode(Meta.self, from: data) else {
                moving.append(dir.lastPathComponent)
                continue
            }
            // The folder comes from the root and the id, NOT from the listing:
            // a listing resolves symlinks (`/var` to `/private/var`), and the
            // work order names its progress file by the path it was written
            // with, so the two would disagree about where the agent reports.
            let home = root.appendingPathComponent(meta.id, isDirectory: true)
            let logURL = home.appendingPathComponent("progress.log")
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let touched = (try? fm.attributesOfItem(atPath: logURL.path)[.modificationDate] as? Date) ?? meta.created
            let order = Order(id: meta.id, request: meta.request, created: meta.created,
                              progress: WorkOrderProgress.parse(log), updated: max(touched, meta.created), dir: home,
                              proposalId: meta.proposal)
            out.append(order)
            if order.progress.stage != .done { rearmed.remove(order.id) }
            if order.progress.stage != .done || rearmed.contains(order.id) { moving.append(dir.lastPathComponent) }
        }
        rearmed = rearmed.filter { id in out.contains { $0.id == id } }
        let sorted = out.sorted { $0.created > $1.created }
        if sorted != orders { orders = sorted }
        let acknowledged = readIDs(acknowledgedFile)
        if acknowledged != acknowledgedProposals { acknowledgedProposals = acknowledged }
        let seen = readIDs(seenFile)
        if seen != seenProposals { seenProposals = seen }
        watch?.watch(paths(moving))
    }

    /// The person copied a finished order again: watch it until the agent's
    /// next line, so what it writes shows live.
    func copiedAgain(_ id: String) {
        guard orders.contains(where: { $0.id == id && $0.progress.stage == .done }) else { return }
        rearmed.insert(id)
        reload()
    }

    /// The person closed a proposal's Success card with Got it.
    func acknowledge(proposal id: String) {
        var ids = acknowledgedProposals
        guard ids.insert(id).inserted else { return }
        writeIDs(ids, to: acknowledgedFile)
        reload()
    }

    /// The Proposed card for this proposal was shown on this install.
    func markSeen(proposal id: String) {
        var ids = seenProposals
        guard ids.insert(id).inserted else { return }
        writeIDs(ids, to: seenFile)
        reload()
    }

    private func readIDs(_ file: URL) -> Set<String> {
        (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            .map(Set.init) ?? []
    }

    private func writeIDs(_ ids: Set<String>, to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ids.sorted()) {
            try? data.write(to: file, options: .atomic)
        }
    }

    func workOrderText(_ order: Order) -> String? {
        try? String(contentsOf: order.workOrderFile, encoding: .utf8)
    }

    /// Writes the order's text again, for one whose work-order.md went
    /// missing while its agent is still reporting: the id, the folder and
    /// the progress log stay, so nothing the agent does lands in a void.
    func rewriteWorkOrder(_ order: Order, detail: String?) -> String? {
        let text = WorkOrderPrompt.build(id: order.id, request: order.request, detail: detail,
                                         images: Self.imageFiles(in: order.dir).map(\.path),
                                         context: WorkOrderContext.live(orderDir: order.dir))
        guard (try? text.write(to: order.workOrderFile, atomically: true, encoding: .utf8)) != nil else { return nil }
        return text
    }

    // MARK: - Writing

    /// Writes a new order and returns it, or nil for an empty request. The
    /// context is built for the order's own folder, because the work order
    /// tells the agent where to report.
    ///
    /// `detail` is what Grux already knows about the request (a proposal's
    /// files, acceptance checks and evidence). It goes INTO the one template,
    /// so every handoff Grux writes is the same line.
    /// `proposal` links the order to the Optimize proposal it carries out,
    /// so the card can turn into its Success card when the order is done.
    /// `images` are PNG bytes the person attached: written as image-1.png and
    /// on into the order's folder, and listed by path in work-order.md. Bytes
    /// that are not an image fail the whole order, folder and all.
    @discardableResult
    func create(request: String, detail: String? = nil, proposal: String? = nil, images: [Data] = [],
                context: (_ orderDir: URL) -> WorkOrderContext) -> Order? {
        guard let text = WorkOrderPrompt.clean(request) else { return nil }
        let fm = FileManager.default
        var id = Self.newID()
        while fm.fileExists(atPath: root.appendingPathComponent(id).path) { id = Self.newID() }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = Meta(id: id, request: text, created: Date(), proposal: proposal)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(meta).write(to: dir.appendingPathComponent("order.json"), options: .atomic)
            var imagePaths: [String] = []
            for (index, image) in images.enumerated() {
                guard NSImage(data: image) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
                let file = dir.appendingPathComponent("image-\(index + 1).png")
                try image.write(to: file, options: .atomic)
                imagePaths.append(file.path)
            }
            let prompt = WorkOrderPrompt.build(id: id, request: text, detail: detail, images: imagePaths,
                                               context: context(dir))
            try prompt.write(to: dir.appendingPathComponent("work-order.md"), atomically: true, encoding: .utf8)
            try "# \(id): one line per station, `<stage> | <note>`\n".write(
                to: dir.appendingPathComponent("progress.log"), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
        reload()
        return orders.first { $0.id == id }
    }

    /// The screenshots written beside an order, in the order they were attached.
    static func imageFiles(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix("image-"), name.hasSuffix(".png"),
                  let n = Int(name.dropFirst("image-".count).dropLast(".png".count)) else { return nil }
            return (n, dir.appendingPathComponent(name))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
        reload()
    }

    /// Writes an order for `request` from this Mac's live context and copies
    /// its text: the one copy every handoff goes through (Copy work order in
    /// the legacy panel and on the hub card, the card's proposed fix, and
    /// Self-Upgrade's Copy handoff). Nil, and nothing copied, for an empty
    /// request. `copy` is for tests, which must not touch the clipboard.
    @discardableResult
    func createAndCopy(_ request: String, detail: String? = nil, proposal: String? = nil, images: [Data] = [],
                       copy: (String) -> Void = OptimizeClipboard.copy) -> Order? {
        guard let order = create(request: request, detail: detail, proposal: proposal, images: images,
                                 context: { WorkOrderContext.live(orderDir: $0) }),
              let text = workOrderText(order) else { return nil }
        copy(text)
        return order
    }

    /// The slow fallback behind the watcher: a re-read every 30 s while an
    /// order is still moving, until the calling view's task is cancelled. It
    /// catches a path the watcher could not open, and re-opens it on the
    /// way. The watcher does the live work; nobody waits on this.
    func pollWhileActive() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if hasActive { reload() }
        }
    }

    /// Opaque, short, and never a readable slug: `wo-` and six characters with
    /// the ambiguous ones (0, o, 1, l, i) left out so it survives being read
    /// aloud or retyped.
    static func newID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return "wo-" + String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

extension WorkOrderContext {

    /// Where `build.sh` records the checkout it installed from.
    static var sourceFile: URL { Persistence.gruxDir.appendingPathComponent("source.json") }

    /// This Mac, right now: the running app, the recorded source, the folders.
    @MainActor
    static func live(orderDir: URL) -> WorkOrderContext {
        let info = Bundle.main.infoDictionary ?? [:]
        let source = (try? Data(contentsOf: sourceFile)).flatMap { try? JSONDecoder().decode(WorkOrderSource.self, from: $0) }
        let binary = Bundle.main.executablePath
        let mtime = binary.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        let sourceExists = source.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return WorkOrderContext(
            appPath: Bundle.main.bundlePath,
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            installed: installed(source: source, binaryMtime: mtime?.timeIntervalSince1970, sourceExists: sourceExists),
            supportDir: Persistence.supportDir.path,
            orderDir: orderDir.path)
    }
}
