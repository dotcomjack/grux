import Foundation

// MARK: - Persistence root
//
// Additive extension, keeps the shared Persistence.swift untouched while
// following the "user-visible artifacts live under ~/Documents/Grux/"
// convention (mirrors MemoryPortability.exportsDir and the swarms dir). Design
// projects are multi-file webs the WKWebView loads via loadFileURL and that
// the user may open in an editor, so they belong in the portable tree, not
// Application Support. This location gets free BackupManager coverage.
extension Persistence {
    /// NON-CREATING, and that is the whole point of it being written out longhand rather
    /// than folded into the init below.
    ///
    /// `DesignStudioView` holds `@ObservedObject private var store = DesignProjectStore.shared`
    /// as a property initialiser, so constructing the view hierarchy at launch touches the
    /// singleton, whose init read this getter, whose createDirectory put a `Grux/design`
    /// folder in the person's Documents. Measured on a Mac that had never run Grux: it
    /// appeared on the first launch, empty, before the Design Studio tab had ever been
    /// opened. Same shape as the backups folder beside it and fixed the same way.
    static var designDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Grux", isDirectory: true)
            .appendingPathComponent("design", isDirectory: true)
    }
}

// One turn of the Studio chat transcript. Persisted per-project in chat.json so
// a generation run can rebuild the message list and the left rail can render
// history. Follows the evolving-Codable house rule (hand-written init(from:)
// with decodeIfPresent defaults) so old files never break.
struct DesignChatMessage: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    let id: UUID
    var role: Role
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = (try? c.decode(Role.self, forKey: .role)) ?? .assistant
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

// MARK: - DesignProjectStore
//
// JSON-on-disk store for Design Studio projects. Skeleton copied from
// DocumentStore, but a project is a FOLDER of artifact files (not one opaque
// blob), so versioning snapshots the whole site/ tree instead of a single
// file. Layout:
//
//   design/
//     index.json                       compact [DesignProject] listing
//     <project-slug>/
//       project.json                   full DesignProject (portable + drift source)
//       site/  index.html, styles.css, app.js   the live artifact files
//       versions.json                  [DesignVersion] metadata, newest-last
//       versions/<versionId>/          FULL-FOLDER snapshot of site/ at that point
//       exports/                       PDF/PNG/ZIP/MD outputs (other workstreams)
//
// Folders are named by slug (stable, set at create, never renamed) so the tree
// stays human-navigable. A generation run snapshots the PRIOR site/ once (label
// "generation") before writing, keeping the most recent 20 snapshots. Restore
// snapshots the current tree first, so it is always undoable.
@MainActor
final class DesignProjectStore: ObservableObject {
    static let shared = DesignProjectStore()

    // How many full-folder snapshots we keep per project.
    static let maxVersions = 20

    @Published private(set) var projects: [DesignProject] = []

    private let rootDir: URL

    // Set at integration time to the engine's run check. When it reports a
    // generation is active on a project, restore and delete no-op so a snapshot
    // swap or folder removal can never race the writes of a live run.
    var isProjectRunning: ((UUID) -> Bool)?

    // Cached transcript character counts so the per-keystroke run estimate does
    // not re-read chat.json from disk each call. Kept warm by every transcript
    // mutation (append updates it incrementally, replace/clear reset it).
    private var transcriptCharCounts: [UUID: Int] = [:]

    private init() {
        // The directory is NOT created here. This init runs when the view hierarchy is
        // built, which is at launch, not when somebody opens Design Studio. It is created
        // by the writes below, which is when there is genuinely something to put in it.
        self.rootDir = Persistence.designDir
        loadIndex()
        reindexIfDriftDetected()
    }

    // Test seam: run against a temp directory without touching the real
    // ~/Documents/Grux/design library. Runs the same drift self-heal as the
    // shared init so recovery is exercisable in tests.
    init(rootDir: URL) {
        self.rootDir = rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        loadIndex()
        reindexIfDriftDetected()
    }

    // MARK: - Listing

    // Starred first, then most-recently-updated. Optional tag / query filters,
    // same shape as DocumentStore.list.
    func list(tag: String? = nil, starredOnly: Bool = false, query: String? = nil) -> [DesignProject] {
        var rows = projects
        if let tag, !tag.isEmpty {
            let needle = tag.lowercased()
            rows = rows.filter { $0.tags.contains { $0.lowercased() == needle } }
        }
        if starredOnly {
            rows = rows.filter { $0.starred }
        }
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = query.lowercased()
            rows = rows.filter {
                $0.title.lowercased().contains(needle)
                    || $0.slug.lowercased().contains(needle)
                    || ($0.preview?.lowercased().contains(needle) ?? false)
                    || $0.tags.contains { $0.lowercased().contains(needle) }
            }
        }
        return rows.sorted { a, b in
            if a.starred != b.starred { return a.starred }
            return a.updatedAt > b.updatedAt
        }
    }

    var allTags: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for proj in projects {
            for t in proj.tags where !seen.contains(t.lowercased()) {
                seen.insert(t.lowercased())
                out.append(t)
            }
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }

    func project(id: UUID) -> DesignProject? {
        projects.first { $0.id == id }
    }

    func project(slug: String) -> DesignProject? {
        projects.first { $0.slug == slug }
    }

    // Tool-facing fuzzy resolve: UUID, exact slug, exact title, then title
    // substring. Same shape as DocumentStore.resolve.
    func resolve(_ hint: String) -> DesignProject? {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = UUID(uuidString: trimmed), let proj = project(id: id) {
            return proj
        }
        let needle = trimmed.lowercased()
        if let bySlug = projects.first(where: { $0.slug.lowercased() == needle }) {
            return bySlug
        }
        if let exact = projects.first(where: { $0.title.lowercased() == needle }) {
            return exact
        }
        return projects.first { $0.title.lowercased().contains(needle) }
    }

    // MARK: - Create

    @discardableResult
    func create(
        title: String,
        kind: DesignArtifactKind = .prototype,
        brandSlug: String? = nil,
        designSystemFile: String? = nil,
        tags: [String] = []
    ) -> DesignProject {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? "Untitled design" : cleanTitle
        let slug = makeUniqueSlug(from: finalTitle)
        let proj = DesignProject(
            slug: slug,
            title: finalTitle,
            kind: kind,
            brandSlug: brandSlug,
            designSystemFile: designSystemFile,
            tags: normalizedTags(tags)
        )
        // Creating siteDir also creates the enclosing project folder.
        try? FileManager.default.createDirectory(at: siteDir(slug), withIntermediateDirectories: true)
        Persistence.save(proj, to: projectJSONURL(slug))
        projects.append(proj)
        saveIndex()
        return proj
    }

    // MARK: - Metadata mutations

    @discardableResult
    func rename(id: UUID, title: String) -> DesignProject? {
        guard var proj = project(id: id) else { return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slug (folder name) stays fixed so snapshots + on-disk paths never move.
        proj.title = clean.isEmpty ? "Untitled design" : clean
        proj.updatedAt = Date()
        replaceAndPersist(proj)
        return proj
    }

    @discardableResult
    func setTags(id: UUID, tags: [String]) -> DesignProject? {
        guard var proj = project(id: id) else { return nil }
        proj.tags = normalizedTags(tags)
        proj.updatedAt = Date()
        replaceAndPersist(proj)
        return proj
    }

    @discardableResult
    func setBrand(id: UUID, brandSlug: String?) -> DesignProject? {
        guard var proj = project(id: id) else { return nil }
        proj.brandSlug = brandSlug
        proj.updatedAt = Date()
        replaceAndPersist(proj)
        return proj
    }

    @discardableResult
    func setDesignSystemFile(id: UUID, file: String?) -> DesignProject? {
        guard var proj = project(id: id) else { return nil }
        proj.designSystemFile = file
        proj.updatedAt = Date()
        replaceAndPersist(proj)
        return proj
    }

    @discardableResult
    func toggleStar(id: UUID) -> DesignProject? {
        guard var proj = project(id: id) else { return nil }
        proj.starred.toggle()
        replaceAndPersist(proj)
        return proj
    }

    @discardableResult
    func setPreview(id: UUID, preview: String?) -> DesignProject? {
        guard var proj = project(id: id) else { return nil }
        proj.preview = preview
        replaceAndPersist(proj)
        return proj
    }

    func delete(id: UUID) {
        // Honor the restore kill switch. Once a restore has swapped the trees on
        // disk our in-memory index is stale, so a raw folder removal here could
        // delete a just-restored tree. delete() bypasses Persistence's guarded
        // writers entirely (raw removeItem), so it needs its own gate.
        guard !Persistence.writesSuspended else {
            WakeLog.shared.log("designStore: delete ignored, writes are suspended for a restore")
            return
        }
        if isProjectRunning?(id) == true {
            WakeLog.shared.log("designStore: delete ignored, a generation is running on project \(id)")
            return
        }
        guard let proj = project(id: id) else { return }
        // Abort on a real removal failure so the index row and the on-disk folder
        // never desync. The old try? swallowed failures: the row was dropped
        // while the folder survived, and reindexIfDriftDetected resurrected the
        // project on next launch. If the folder is already gone the delete goal
        // is met, so fall through and drop the row.
        let dir = projectDir(proj.slug)
        if FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                WakeLog.shared.log("designStore: delete failed for project \(id), keeping index row: \(error)")
                return
            }
        }
        projects.removeAll { $0.id == id }
        transcriptCharCounts.removeValue(forKey: id)
        saveIndex()
    }

    // MARK: - Artifact writes (the generation path)

    // Write one artifact file inside the project's site/ tree. `relativePath` is
    // project-relative and must satisfy the same site/ + no-traversal rules the
    // parser enforces (defense in depth: the file bytes came from model output).
    // Bumps updatedAt but does NOT snapshot; the engine snapshots once per run
    // via snapshot(id:label:) before the first write.
    @discardableResult
    func writeArtifact(id: UUID, relativePath: String, content: String) -> Bool {
        guard !Persistence.writesSuspended else { return false }
        guard let proj = project(id: id) else { return false }
        guard DesignArtifactParser.validate(path: relativePath) != nil else { return false }
        let projRoot = projectDir(proj.slug).standardizedFileURL
        let siteRoot = siteDir(proj.slug).standardizedFileURL
        let target = projRoot.appendingPathComponent(relativePath).standardizedFileURL
        // Final resolved path must stay inside site/.
        guard target.path == siteRoot.path || target.path.hasPrefix(siteRoot.path + "/") else { return false }
        guard let data = content.data(using: .utf8) else { return false }
        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard Persistence.write(data, to: target) else { return false }
        touchUpdatedAt(id: id)
        return true
    }

    // The file the preview WKWebView loads. nil until a generation writes it.
    func siteIndexURL(id: UUID) -> URL? {
        guard let proj = project(id: id) else { return nil }
        let url = siteDir(proj.slug).appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // The read-access root the preview fences file reads to.
    func siteRootURL(id: UUID) -> URL? {
        guard let proj = project(id: id) else { return nil }
        return siteDir(proj.slug)
    }

    // Every artifact file currently on disk, project-relative (e.g.
    // "site/index.html"). Powers the file strip + drives whether a preview
    // exists.
    func artifactFiles(id: UUID) -> [String] {
        guard let proj = project(id: id) else { return [] }
        let siteRoot = siteDir(proj.slug)
        guard let en = FileManager.default.enumerator(at: siteRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = url.standardizedFileURL.path
                .replacingOccurrences(of: siteRoot.standardizedFileURL.path + "/", with: "site/")
            out.append(rel)
        }
        return out.sorted()
    }

    // MARK: - Versions (full-folder snapshots)

    func versions(id: UUID) -> [DesignVersion] {
        guard let proj = project(id: id) else { return [] }
        return Persistence.load([DesignVersion].self, from: versionsIndexURL(proj.slug), fallback: [])
    }

    // Copy the current site/ tree into versions/<newId>/, append the metadata,
    // prune oldest-first past the cap. Returns nil when there is nothing to
    // snapshot (fresh project, empty site) so the first generation has no
    // spurious empty "before" snapshot.
    @discardableResult
    func snapshot(id: UUID, label: String) -> DesignVersion? {
        guard !Persistence.writesSuspended else { return nil }
        guard let proj = project(id: id) else { return nil }
        let siteRoot = siteDir(proj.slug)
        guard siteHasContent(siteRoot) else { return nil }
        let version = DesignVersion(
            id: UUID(),
            savedAt: Date(),
            label: label,
            byteCount: directoryByteCount(siteRoot)
        )
        let versionsRoot = versionsDir(proj.slug)
        try? FileManager.default.createDirectory(at: versionsRoot, withIntermediateDirectories: true)
        let dest = versionsRoot.appendingPathComponent(version.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.copyItem(at: siteRoot, to: dest)
        } catch {
            return nil
        }
        var all = versions(id: id)
        all.append(version)
        while all.count > Self.maxVersions {
            let dropped = all.removeFirst()
            try? FileManager.default.removeItem(
                at: versionsRoot.appendingPathComponent(dropped.id.uuidString, isDirectory: true)
            )
        }
        Persistence.save(all, to: versionsIndexURL(proj.slug))
        return version
    }

    // Restore a snapshot as the live site/. The current tree is snapshotted
    // first (label "restore"), so a restore is itself undoable. Posts
    // gruxDesignArtifactsUpdated so the preview reloads.
    @discardableResult
    func restore(id: UUID, versionId: UUID) -> Bool {
        guard !Persistence.writesSuspended else { return false }
        if isProjectRunning?(id) == true {
            WakeLog.shared.log("designStore: restore ignored, a generation is running on project \(id)")
            return false
        }
        guard let proj = project(id: id) else { return false }
        guard versions(id: id).contains(where: { $0.id == versionId }) else { return false }
        let fm = FileManager.default
        let source = versionsDir(proj.slug).appendingPathComponent(versionId.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return false }

        // Copy the target version out to a scratch folder BEFORE the undo
        // snapshot. At the version cap snapshot() prunes the oldest version to
        // make room, and the oldest can be the very one being restored: pruning
        // it would delete source out from under us and, after we cleared site/,
        // leave nothing to copy back (total loss of the live tree). The scratch
        // copy lives in the project folder (same volume, never enumerated as an
        // artifact or a version, invisible to reindex) so the prune cannot reach
        // it, and a defer removes it on every exit.
        let scratch = projectDir(proj.slug)
            .appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: source, to: scratch)
        } catch {
            return false
        }
        defer { try? fm.removeItem(at: scratch) }

        // Undo protection: snapshot the current tree first so the restore is
        // itself undoable. When the live site has content, a nil snapshot means
        // it FAILED (not the benign empty-site skip), so we must NOT clear site/
        // or the live tree is lost with no undo. When the site is empty there is
        // nothing to lose, so skip the snapshot and proceed.
        let siteRoot = siteDir(proj.slug)
        if siteHasContent(siteRoot) {
            guard snapshot(id: id, label: "restore") != nil else { return false }
        }
        try? fm.removeItem(at: siteRoot)
        do {
            try fm.copyItem(at: scratch, to: siteRoot)
        } catch {
            return false
        }
        touchUpdatedAt(id: id)
        NotificationCenter.default.post(name: .gruxDesignArtifactsUpdated, object: proj.id)
        return true
    }

    // MARK: - Chat transcript

    func transcript(id: UUID) -> [DesignChatMessage] {
        guard let proj = project(id: id) else { return [] }
        return Persistence.load([DesignChatMessage].self, from: chatURL(proj.slug), fallback: [])
    }

    // Total characters across the transcript, served from an in-memory cache so a
    // per-keystroke estimate never re-reads chat.json. Computed from disk once on
    // a cache miss, then kept warm by the mutators below.
    func transcriptCharCount(id: UUID) -> Int {
        if let cached = transcriptCharCounts[id] { return cached }
        let count = transcript(id: id).reduce(0) { $0 + $1.text.count }
        transcriptCharCounts[id] = count
        return count
    }

    func appendMessage(id: UUID, _ message: DesignChatMessage) {
        guard let proj = project(id: id) else { return }
        var all = transcript(id: id)
        all.append(message)
        Persistence.save(all, to: chatURL(proj.slug))
        if let cached = transcriptCharCounts[id] {
            transcriptCharCounts[id] = cached + message.text.count
        }
    }

    func replaceTranscript(id: UUID, _ messages: [DesignChatMessage]) {
        guard let proj = project(id: id) else { return }
        Persistence.save(messages, to: chatURL(proj.slug))
        transcriptCharCounts[id] = messages.reduce(0) { $0 + $1.text.count }
    }

    func clearTranscript(id: UUID) {
        replaceTranscript(id: id, [])
    }

    // MARK: - Paths

    private func projectDir(_ slug: String) -> URL {
        rootDir.appendingPathComponent(slug, isDirectory: true)
    }

    private func chatURL(_ slug: String) -> URL {
        projectDir(slug).appendingPathComponent("chat.json")
    }

    private func siteDir(_ slug: String) -> URL {
        projectDir(slug).appendingPathComponent("site", isDirectory: true)
    }

    private func versionsDir(_ slug: String) -> URL {
        projectDir(slug).appendingPathComponent("versions", isDirectory: true)
    }

    private func versionsIndexURL(_ slug: String) -> URL {
        projectDir(slug).appendingPathComponent("versions.json")
    }

    private func projectJSONURL(_ slug: String) -> URL {
        projectDir(slug).appendingPathComponent("project.json")
    }

    private var indexURL: URL {
        rootDir.appendingPathComponent("index.json")
    }

    // MARK: - Index persistence

    private func loadIndex() {
        projects = Persistence.load([DesignProject].self, from: indexURL, fallback: [])
    }

    private func saveIndex() {
        // CREATED HERE, which is the first moment there is genuinely something to put in it.
        // The init deliberately does not, because it runs at launch when the view hierarchy
        // is built rather than when anybody opens Design Studio.
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        Persistence.save(projects, to: indexURL)
    }

    // Replace one project in memory, persist both the index and its portable
    // project.json.
    private func replaceAndPersist(_ proj: DesignProject) {
        if let idx = projects.firstIndex(where: { $0.id == proj.id }) {
            projects[idx] = proj
        } else {
            projects.append(proj)
        }
        Persistence.save(proj, to: projectJSONURL(proj.slug))
        saveIndex()
    }

    private func touchUpdatedAt(id: UUID) {
        guard var proj = project(id: id) else { return }
        proj.updatedAt = Date()
        replaceAndPersist(proj)
    }

    // Self-heal: slug folders on disk with a readable project.json that the
    // index forgot (failed write, restored tree, hand-dropped project) get
    // re-added. Mirrors DocumentStore.reindexIfDriftDetected.
    private func reindexIfDriftDetected() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var changed = false
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let projJSON = item.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: projJSON.path) else { continue }
            let recovered = Persistence.load(DesignProject?.self, from: projJSON, fallback: nil)
            guard let recovered, project(id: recovered.id) == nil else { continue }
            projects.append(recovered)
            changed = true
        }
        if changed { saveIndex() }
    }

    // MARK: - Helpers

    private func makeUniqueSlug(from title: String) -> String {
        let base = Self.slugify(title)
        let root = base.isEmpty ? "design" : base
        let existing = Set(projects.map { $0.slug })
        var candidate = root
        var n = 2
        while existing.contains(candidate)
            || FileManager.default.fileExists(atPath: projectDir(candidate).path) {
            candidate = "\(root)-\(n)"
            n += 1
        }
        return candidate
    }

    static func slugify(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if ch == " " || ch == "-" || ch == "_" {
                if !lastDash && !out.isEmpty {
                    out.append("-")
                    lastDash = true
                }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60))
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in tags {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            out.append(t)
        }
        return out
    }

    private func siteHasContent(_ siteRoot: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: siteRoot.path) else { return false }
        guard let en = fm.enumerator(at: siteRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
        }
        return false
    }

    private func directoryByteCount(_ root: URL) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}
