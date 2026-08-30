import XCTest
@testable import Grux

// Unit tests for DocumentStore (roadmap items 11 + 12 data layer). Every
// test runs against a throwaway temp directory via the init(rootDir:) test
// seam, the real Application Support library is never touched.
@MainActor
final class DocumentStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: DocumentStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-doc-tests-\(UUID().uuidString)", isDirectory: true)
        store = DocumentStore(rootDir: tempDir)
    }

    override func tearDown() async throws {
        store = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Round trip

    func testCreateAndReadRoundTrip() throws {
        let doc = store.create(title: "Launch notes", content: "# Hello\nBody line", tags: ["launch", "ideas"])
        XCTAssertEqual(doc.title, "Launch notes")
        XCTAssertEqual(doc.kind, .markdown)
        XCTAssertEqual(doc.tags, ["launch", "ideas"])
        XCTAssertEqual(store.content(id: doc.id), "# Hello\nBody line")
        XCTAssertEqual(doc.preview, "# Hello Body line")

        // A second store over the same directory must see the same document
        // (index.json round trip).
        let reloaded = DocumentStore(rootDir: tempDir)
        XCTAssertEqual(reloaded.documents.count, 1)
        XCTAssertEqual(reloaded.content(id: doc.id), "# Hello\nBody line")
        XCTAssertEqual(reloaded.document(id: doc.id)?.title, "Launch notes")
    }

    func testEmptyTitleFallsBack() throws {
        let doc = store.create(title: "   ")
        XCTAssertEqual(doc.title, "Untitled document")
    }

    func testTagNormalizationDedupes() throws {
        let doc = store.create(title: "T", tags: ["Work", "work", "  ", "Ideas"])
        XCTAssertEqual(doc.tags, ["Work", "Ideas"])
    }

    // MARK: - Versioning

    func testUpdateSnapshotsPriorVersion() throws {
        let doc = store.create(title: "Versioned", content: "v1")
        XCTAssertTrue(store.versions(id: doc.id).isEmpty, "fresh doc has no snapshots")

        _ = store.update(id: doc.id, content: "v2")
        let versions = store.versions(id: doc.id)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(store.versionContent(id: doc.id, versionId: versions[0].id), "v1",
                       "snapshot holds the PRE-update content")
        XCTAssertEqual(store.content(id: doc.id), "v2")
    }

    func testVersionCapKeepsLastTwenty() throws {
        let doc = store.create(title: "Capped", content: "v0")
        for i in 1...25 {
            _ = store.update(id: doc.id, content: "v\(i)")
        }
        let versions = store.versions(id: doc.id)
        XCTAssertEqual(versions.count, DocumentStore.maxVersions)
        // Oldest surviving snapshot is v5 (v0...v4 pruned); newest is v24.
        XCTAssertEqual(store.versionContent(id: doc.id, versionId: versions.first!.id), "v5")
        XCTAssertEqual(store.versionContent(id: doc.id, versionId: versions.last!.id), "v24")
        // Pruned snapshot files are really gone from disk.
        let versionsDir = tempDir
            .appendingPathComponent(doc.id.uuidString, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, DocumentStore.maxVersions)
    }

    func testRestoreBringsBackOldContentAndIsUndoable() throws {
        let doc = store.create(title: "Restorable", content: "original")
        _ = store.update(id: doc.id, content: "edited")
        let snapshot = store.versions(id: doc.id).first!

        _ = store.restore(id: doc.id, versionId: snapshot.id)
        XCTAssertEqual(store.content(id: doc.id), "original")

        // The restore itself snapshotted "edited", so it can be undone too.
        let labels = store.versions(id: doc.id).map { $0.label }
        XCTAssertTrue(labels.contains("restore"))
        let editedSnapshot = store.versions(id: doc.id).last!
        XCTAssertEqual(store.versionContent(id: doc.id, versionId: editedSnapshot.id), "edited")
    }

    func testUpdateRejectsNonEditableKinds() throws {
        let pdfSource = tempDir.appendingPathComponent("source.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: pdfSource)
        guard let doc = store.importFile(from: pdfSource) else {
            return XCTFail("import returned nil")
        }
        XCTAssertEqual(doc.kind, .pdf)
        XCTAssertNil(store.update(id: doc.id, content: "nope"), "binary kinds must not be editable")
    }

    // MARK: - Import

    func testImportPlainTextFile() throws {
        let source = tempDir.appendingPathComponent("notes.txt")
        try "imported body text".write(to: source, atomically: true, encoding: .utf8)
        guard let doc = store.importFile(from: source) else {
            return XCTFail("import returned nil")
        }
        XCTAssertEqual(doc.kind, .plainText)
        XCTAssertEqual(doc.title, "notes")
        XCTAssertEqual(doc.sourceFileName, "notes.txt")
        XCTAssertEqual(store.content(id: doc.id), "imported body text")
        XCTAssertEqual(doc.preview, "imported body text")
    }

    func testImportMissingFileReturnsNil() throws {
        let ghost = tempDir.appendingPathComponent("ghost.md")
        XCTAssertNil(store.importFile(from: ghost))
        XCTAssertTrue(store.documents.isEmpty)
    }

    // MARK: - Mutations

    func testRenameSetTagsToggleStar() throws {
        let doc = store.create(title: "Old name")
        XCTAssertEqual(store.rename(id: doc.id, title: "New name")?.title, "New name")
        XCTAssertEqual(store.setTags(id: doc.id, tags: ["a", "b"])?.tags, ["a", "b"])
        XCTAssertEqual(store.toggleStar(id: doc.id)?.starred, true)
        XCTAssertEqual(store.toggleStar(id: doc.id)?.starred, false)
    }

    func testDeleteRemovesFilesAndIndexRow() throws {
        let doc = store.create(title: "Doomed", content: "x")
        _ = store.update(id: doc.id, content: "y")
        let docDir = tempDir.appendingPathComponent(doc.id.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: docDir.path))

        store.delete(id: doc.id)
        XCTAssertNil(store.document(id: doc.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docDir.path))

        let reloaded = DocumentStore(rootDir: tempDir)
        XCTAssertNil(reloaded.document(id: doc.id))
    }

    // MARK: - Listing + resolve

    func testListFiltersAndSorting() throws {
        let a = store.create(title: "Alpha doc", content: "about apples", tags: ["fruit"])
        _ = store.create(title: "Beta doc", content: "about bears", tags: ["animal"])
        let c = store.create(title: "Gamma doc", content: "about grapes", tags: ["fruit"])
        _ = store.toggleStar(id: a.id)

        // Starred floats first even though others updated later.
        XCTAssertEqual(store.list().first?.id, a.id)
        // Tag filter.
        XCTAssertEqual(Set(store.list(tag: "fruit").map { $0.id }), Set([a.id, c.id]))
        // Query matches preview text.
        XCTAssertEqual(store.list(query: "bears").count, 1)
        // Starred only.
        XCTAssertEqual(store.list(starredOnly: true).map { $0.id }, [a.id])
        // allTags is deduped + sorted.
        XCTAssertEqual(store.allTags, ["animal", "fruit"])
    }

    func testResolveByIdTitleAndSubstring() throws {
        let doc = store.create(title: "Quarterly Plan")
        XCTAssertEqual(store.resolve(doc.id.uuidString)?.id, doc.id)
        XCTAssertEqual(store.resolve("quarterly plan")?.id, doc.id, "exact title, case-insensitive")
        XCTAssertEqual(store.resolve("Quarterly")?.id, doc.id, "substring")
        XCTAssertNil(store.resolve("nonexistent"))
        XCTAssertNil(store.resolve("   "))
    }
}
