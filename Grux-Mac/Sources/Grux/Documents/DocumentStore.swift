import Foundation

// MARK: - Persistence root
//
// Additive extension, keeps the shared Persistence.swift untouched while
// following its exact directory convention. Documents live at
// ~/Library/Application Support/Grux/documents/. Same sensitivity posture as
// meetingsDir (not iCloud-mirrored).
extension Persistence {
    static var documentsDir: URL {
        let dir = supportDir.appendingPathComponent("documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - DocumentStore
//
// JSON-on-disk store for the document library. Layout mirrors
// ChatThreadStore's "one record per file + index.json" pattern, except a
// document's content is an opaque file (markdown, pdf, docx...) instead of
// embedded JSON:
//
//   documents/
//     index.json                      compact [GruxDocument] listing
//     <docId>/
//       content.<ext>                 the live document bytes
//       versions.json                 [DocumentVersion] metadata
//       versions/<versionId>.<ext>    snapshot bytes, newest-last
//
// Every save through update() snapshots the PRIOR content first (the
// ShellSnapshotStore reversibility idea, minus the shadow git), keeping the
// most recent 20 snapshots per document.
@MainActor
final class DocumentStore: ObservableObject {
    static let shared = DocumentStore()

    // How many version snapshots we keep per document.
    static let maxVersions = 20

    @Published private(set) var documents: [GruxDocument] = []

    private let rootDir: URL

    private init() {
        self.rootDir = Persistence.documentsDir
        loadIndex()
        reindexIfDriftDetected()
    }

    // Test seam, lets DocumentStoreTests run against a temp directory
    // without touching the real Application Support library.
    init(rootDir: URL) {
        self.rootDir = rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Listing

    // Starred first, then most-recently-updated. Optional tag / query filters.
    func list(tag: String? = nil, starredOnly: Bool = false, query: String? = nil) -> [GruxDocument] {
        var rows = documents
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
                    || ($0.preview?.lowercased().contains(needle) ?? false)
                    || $0.tags.contains { $0.lowercased().contains(needle) }
            }
        }
        return rows.sorted { a, b in
            if a.starred != b.starred { return a.starred }
            return a.updatedAt > b.updatedAt
        }
    }

    // Every distinct tag across the library, alphabetized. Drives the
    // library's tag filter menu.
    var allTags: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for doc in documents {
            for t in doc.tags where !seen.contains(t.lowercased()) {
                seen.insert(t.lowercased())
                out.append(t)
            }
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }

    func document(id: UUID) -> GruxDocument? {
        documents.first { $0.id == id }
    }

    // Tool-facing fuzzy resolve: UUID, exact title (case-insensitive), then
    // title substring. Same shape as FolderStore.resolve.
    func resolve(_ hint: String) -> GruxDocument? {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = UUID(uuidString: trimmed), let doc = document(id: id) {
            return doc
        }
        let needle = trimmed.lowercased()
        if let exact = documents.first(where: { $0.title.lowercased() == needle }) {
            return exact
        }
        return documents.first { $0.title.lowercased().contains(needle) }
    }

    // MARK: - Create / import

    @discardableResult
    func create(
        title: String,
        content: String = "",
        kind: DocumentKind = .markdown,
        tags: [String] = []
    ) -> GruxDocument {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var doc = GruxDocument(
            title: cleanTitle.isEmpty ? "Untitled document" : cleanTitle,
            kind: kind,
            tags: normalizedTags(tags)
        )
        doc.preview = Self.previewLine(from: content)
        try? FileManager.default.createDirectory(at: docDir(doc.id), withIntermediateDirectories: true)
        try? content.data(using: .utf8)?.write(to: contentURL(for: doc), options: .atomic)
        documents.append(doc)
        saveIndex()
        return doc
    }

    // Copy an external file into the library. Kind is inferred from the
    // extension; preview text is extracted via TextExtract / PDFSupport.
    @discardableResult
    func importFile(from sourceURL: URL, tags: [String] = []) -> GruxDocument? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else { return nil }
        let kind = DocumentKind(fileExtension: sourceURL.pathExtension)
        var doc = GruxDocument(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            kind: kind,
            tags: normalizedTags(tags),
            sourceFileName: sourceURL.lastPathComponent
        )
        let dest = docDir(doc.id)
            .appendingPathComponent("content." + kind.fileExtension)
        do {
            try fm.createDirectory(at: docDir(doc.id), withIntermediateDirectories: true)
            try fm.copyItem(at: sourceURL, to: dest)
        } catch {
            try? fm.removeItem(at: docDir(doc.id))
            return nil
        }
        if let text = TextExtract.extractText(from: dest) {
            doc.preview = Self.previewLine(from: text)
        }
        documents.append(doc)
        saveIndex()
        return doc
    }

    // MARK: - Content access

    func contentURL(id: UUID) -> URL? {
        guard let doc = document(id: id) else { return nil }
        return contentURL(for: doc)
    }

    // UTF-8 text for editable kinds; extracted text for binary kinds.
    func content(id: UUID) -> String? {
        guard let doc = document(id: id) else { return nil }
        let url = contentURL(for: doc)
        if doc.kind.isEditable {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return TextExtract.extractText(from: url)
    }

    // MARK: - Update (the versioned save path)

    // Write new content, snapshotting the PRIOR content as a version first
    // and pruning to the most recent `maxVersions` snapshots. Only editable
    // kinds go through here, binary kinds are import-only.
    @discardableResult
    func update(id: UUID, content: String, versionLabel: String = "edit") -> GruxDocument? {
        guard var doc = document(id: id), doc.kind.isEditable else { return nil }
        snapshotCurrentContent(of: doc, label: versionLabel)
        try? content.data(using: .utf8)?.write(to: contentURL(for: doc), options: .atomic)
        doc.preview = Self.previewLine(from: content)
        doc.updatedAt = Date()
        replaceInIndex(doc)
        return doc
    }

    @discardableResult
    func rename(id: UUID, title: String) -> GruxDocument? {
        guard var doc = document(id: id) else { return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        doc.title = clean.isEmpty ? "Untitled document" : clean
        doc.updatedAt = Date()
        replaceInIndex(doc)
        return doc
    }

    @discardableResult
    func setTags(id: UUID, tags: [String]) -> GruxDocument? {
        guard var doc = document(id: id) else { return nil }
        doc.tags = normalizedTags(tags)
        doc.updatedAt = Date()
        replaceInIndex(doc)
        return doc
    }

    @discardableResult
    func toggleStar(id: UUID) -> GruxDocument? {
        guard var doc = document(id: id) else { return nil }
        doc.starred.toggle()
        replaceInIndex(doc)
        return doc
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: docDir(id))
        documents.removeAll { $0.id == id }
        saveIndex()
    }

    // MARK: - Versions

    func versions(id: UUID) -> [DocumentVersion] {
        Persistence.load([DocumentVersion].self, from: versionsIndexURL(id), fallback: [])
    }

    func versionContent(id: UUID, versionId: UUID) -> String? {
        guard let doc = document(id: id) else { return nil }
        guard let version = versions(id: id).first(where: { $0.id == versionId }) else { return nil }
        let url = versionFileURL(docId: id, versionId: version.id, kind: doc.kind)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // Restore an old snapshot as the live content. The pre-restore content is
    // itself snapshotted first, so a restore is always undoable.
    @discardableResult
    func restore(id: UUID, versionId: UUID) -> GruxDocument? {
        guard let snapshot = versionContent(id: id, versionId: versionId) else { return nil }
        return update(id: id, content: snapshot, versionLabel: "restore")
    }

    // MARK: - Snapshot internals

    private func snapshotCurrentContent(of doc: GruxDocument, label: String) {
        let liveURL = contentURL(for: doc)
        guard let data = try? Data(contentsOf: liveURL) else { return }
        let version = DocumentVersion(label: label, byteCount: data.count)
        let versionsDir = docDir(doc.id).appendingPathComponent("versions", isDirectory: true)
        try? FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        let snapURL = versionFileURL(docId: doc.id, versionId: version.id, kind: doc.kind)
        guard (try? data.write(to: snapURL, options: .atomic)) != nil else { return }

        var all = versions(id: doc.id)
        all.append(version)
        // Prune oldest-first beyond the cap, removing their snapshot files.
        while all.count > Self.maxVersions {
            let dropped = all.removeFirst()
            try? FileManager.default.removeItem(
                at: versionFileURL(docId: doc.id, versionId: dropped.id, kind: doc.kind)
            )
        }
        Persistence.save(all, to: versionsIndexURL(doc.id))
    }

    // MARK: - Paths

    private func docDir(_ id: UUID) -> URL {
        rootDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func contentURL(for doc: GruxDocument) -> URL {
        docDir(doc.id).appendingPathComponent("content." + doc.kind.fileExtension)
    }

    private func versionsIndexURL(_ id: UUID) -> URL {
        docDir(id).appendingPathComponent("versions.json")
    }

    private func versionFileURL(docId: UUID, versionId: UUID, kind: DocumentKind) -> URL {
        docDir(docId)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(versionId.uuidString + "." + kind.fileExtension)
    }

    private var indexURL: URL {
        rootDir.appendingPathComponent("index.json")
    }

    // MARK: - Index persistence

    private func loadIndex() {
        documents = Persistence.load([GruxDocument].self, from: indexURL, fallback: [])
    }

    private func saveIndex() {
        Persistence.save(documents, to: indexURL)
    }

    private func replaceInIndex(_ doc: GruxDocument) {
        if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[idx] = doc
        } else {
            documents.append(doc)
        }
        saveIndex()
    }

    // Self-heal: if document folders exist on disk that the index forgot
    // (failed write, manual drop-in), surface them as untitled imports.
    private func reindexIfDriftDetected() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var changed = false
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let id = UUID(uuidString: item.lastPathComponent) else { continue }
            guard document(id: id) == nil else { continue }
            guard let files = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil),
                  let contentFile = files.first(where: { $0.lastPathComponent.hasPrefix("content.") })
            else { continue }
            let kind = DocumentKind(fileExtension: contentFile.pathExtension)
            var doc = GruxDocument(id: id, title: "Recovered document", kind: kind)
            if let text = TextExtract.extractText(from: contentFile) {
                doc.preview = Self.previewLine(from: text)
            }
            documents.append(doc)
            changed = true
        }
        if changed { saveIndex() }
    }

    // MARK: - Helpers

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

    static func previewLine(from text: String) -> String? {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(200))
    }
}
