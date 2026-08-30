import XCTest
@testable import Grux

// Unit tests for DesignProjectStore. Every test runs against a throwaway temp
// directory via the init(rootDir:) seam, so the real ~/Documents/Grux/design
// library is never touched. Covers create round trip, artifact writes + path
// fencing, full-folder version snapshot / restore / prune, transcript, and the
// index-drift self-heal.
@MainActor
final class DesignProjectStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: DesignProjectStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-design-tests-\(UUID().uuidString)", isDirectory: true)
        store = DesignProjectStore(rootDir: tempDir)
    }

    override func tearDown() async throws {
        store = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Create + reload

    func testCreateRoundTrip() throws {
        let proj = store.create(title: "Launch page", kind: .prototype, brandSlug: "acme", tags: ["web", "hero"])
        XCTAssertEqual(proj.title, "Launch page")
        XCTAssertEqual(proj.kind, .prototype)
        XCTAssertEqual(proj.brandSlug, "acme")
        XCTAssertEqual(proj.tags, ["web", "hero"])
        XCTAssertFalse(proj.slug.isEmpty)

        // A second store over the same directory sees it (index.json round trip).
        let reloaded = DesignProjectStore(rootDir: tempDir)
        XCTAssertEqual(reloaded.projects.count, 1)
        XCTAssertEqual(reloaded.project(id: proj.id)?.title, "Launch page")
    }

    func testEmptyTitleFallsBack() throws {
        let proj = store.create(title: "   ")
        XCTAssertEqual(proj.title, "Untitled design")
    }

    func testDuplicateTitlesGetUniqueSlugs() throws {
        let a = store.create(title: "Same Name")
        let b = store.create(title: "Same Name")
        XCTAssertNotEqual(a.slug, b.slug)
    }

    // MARK: - Artifact writes + path fencing

    func testWriteArtifactAndPreviewURL() throws {
        let proj = store.create(title: "Proto")
        XCTAssertNil(store.siteIndexURL(id: proj.id), "no preview before any write")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "<h1>Hi</h1>"))
        let idx = try XCTUnwrap(store.siteIndexURL(id: proj.id))
        XCTAssertEqual(try String(contentsOf: idx, encoding: .utf8), "<h1>Hi</h1>")
        XCTAssertTrue(store.artifactFiles(id: proj.id).contains("site/index.html"))
    }

    func testWriteArtifactRejectsTraversalAndOutsideSite() throws {
        let proj = store.create(title: "Fenced")
        XCTAssertFalse(store.writeArtifact(id: proj.id, relativePath: "site/../escape.txt", content: "x"))
        XCTAssertFalse(store.writeArtifact(id: proj.id, relativePath: "/etc/evil", content: "x"))
        XCTAssertFalse(store.writeArtifact(id: proj.id, relativePath: "assets/app.js", content: "x"))
        // Nothing escaped the project folder.
        let escape = tempDir.appendingPathComponent(proj.slug).appendingPathComponent("escape.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape.path))
    }

    func testWriteArtifactCreatesNestedDirs() throws {
        let proj = store.create(title: "Nested")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/css/app.css", content: ".a{}"))
        XCTAssertTrue(store.artifactFiles(id: proj.id).contains("site/css/app.css"))
    }

    // MARK: - Versioning

    func testSnapshotSkipsEmptySite() throws {
        let proj = store.create(title: "Empty")
        XCTAssertNil(store.snapshot(id: proj.id, label: "generation"),
                     "an empty site has nothing to snapshot")
        XCTAssertTrue(store.versions(id: proj.id).isEmpty)
    }

    func testSnapshotThenRestoreIsUndoable() throws {
        let proj = store.create(title: "Versioned")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "A"))
        let v = try XCTUnwrap(store.snapshot(id: proj.id, label: "generation"))
        XCTAssertGreaterThan(v.byteCount, 0)
        XCTAssertEqual(store.versions(id: proj.id).count, 1)

        // New content overwrites; snapshot still holds "A".
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "B"))
        XCTAssertEqual(try String(contentsOf: store.siteIndexURL(id: proj.id)!, encoding: .utf8), "B")

        // Restore brings back "A", and snapshots "B" first so it stays undoable.
        XCTAssertTrue(store.restore(id: proj.id, versionId: v.id))
        XCTAssertEqual(try String(contentsOf: store.siteIndexURL(id: proj.id)!, encoding: .utf8), "A")
        XCTAssertTrue(store.versions(id: proj.id).map { $0.label }.contains("restore"))
    }

    func testVersionCapPrunesOldest() throws {
        let proj = store.create(title: "Capped")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "v0"))
        for i in 1...25 {
            _ = store.snapshot(id: proj.id, label: "s\(i)")
            XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "v\(i)"))
        }
        let versions = store.versions(id: proj.id)
        XCTAssertEqual(versions.count, DesignProjectStore.maxVersions)
        // s1...s5 pruned, oldest surviving is s6, newest is s25.
        XCTAssertEqual(versions.first?.label, "s6")
        XCTAssertEqual(versions.last?.label, "s25")
        // Pruned snapshot folders are really gone.
        let versionsDir = tempDir
            .appendingPathComponent(proj.slug, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        let dirs = try FileManager.default.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, DesignProjectStore.maxVersions)
    }

    // MARK: - Transcript

    func testTranscriptRoundTrip() throws {
        let proj = store.create(title: "Chatty")
        XCTAssertTrue(store.transcript(id: proj.id).isEmpty)
        store.appendMessage(id: proj.id, DesignChatMessage(role: .user, text: "build a hero"))
        store.appendMessage(id: proj.id, DesignChatMessage(role: .assistant, text: "done, wrote site/index.html"))
        let messages = store.transcript(id: proj.id)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].text, "done, wrote site/index.html")

        store.clearTranscript(id: proj.id)
        XCTAssertTrue(store.transcript(id: proj.id).isEmpty)
    }

    // MARK: - Mutations + resolve

    func testMutations() throws {
        let proj = store.create(title: "Old name")
        XCTAssertEqual(store.rename(id: proj.id, title: "New name")?.title, "New name")
        XCTAssertEqual(store.project(id: proj.id)?.slug, proj.slug, "slug stays fixed across rename")
        XCTAssertEqual(store.setTags(id: proj.id, tags: ["a", "b"])?.tags, ["a", "b"])
        XCTAssertEqual(store.setBrand(id: proj.id, brandSlug: "northwind")?.brandSlug, "northwind")
        XCTAssertEqual(store.toggleStar(id: proj.id)?.starred, true)
        XCTAssertEqual(store.toggleStar(id: proj.id)?.starred, false)
    }

    func testResolveByIdSlugTitleSubstring() throws {
        let proj = store.create(title: "Quarterly Plan")
        XCTAssertEqual(store.resolve(proj.id.uuidString)?.id, proj.id)
        XCTAssertEqual(store.resolve(proj.slug)?.id, proj.id)
        XCTAssertEqual(store.resolve("quarterly plan")?.id, proj.id)
        XCTAssertEqual(store.resolve("Quarterly")?.id, proj.id)
        XCTAssertNil(store.resolve("nonexistent"))
    }

    func testListFiltersAndSorting() throws {
        let a = store.create(title: "Alpha", tags: ["web"])
        _ = store.create(title: "Beta", tags: ["deck"])
        let c = store.create(title: "Gamma", tags: ["web"])
        _ = store.toggleStar(id: a.id)

        XCTAssertEqual(store.list().first?.id, a.id, "starred floats first")
        XCTAssertEqual(Set(store.list(tag: "web").map { $0.id }), Set([a.id, c.id]))
        XCTAssertEqual(store.list(starredOnly: true).map { $0.id }, [a.id])
        XCTAssertEqual(store.allTags, ["deck", "web"])
    }

    func testDeleteRemovesFolderAndRow() throws {
        let proj = store.create(title: "Doomed")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "x"))
        let dir = tempDir.appendingPathComponent(proj.slug, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        store.delete(id: proj.id)
        XCTAssertNil(store.project(id: proj.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Run guards

    func testRestoreAndDeleteNoOpWhileRunning() throws {
        let proj = store.create(title: "Busy")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "A"))
        let v = try XCTUnwrap(store.snapshot(id: proj.id, label: "generation"))
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "B"))

        // While a run is reported active on the project, both no-op.
        store.isProjectRunning = { _ in true }
        XCTAssertFalse(store.restore(id: proj.id, versionId: v.id), "restore no-ops while running")
        XCTAssertEqual(try String(contentsOf: store.siteIndexURL(id: proj.id)!, encoding: .utf8), "B",
                       "restore left the live tree untouched")
        store.delete(id: proj.id)
        XCTAssertNotNil(store.project(id: proj.id), "delete no-ops while running")

        // Once idle, both work again.
        store.isProjectRunning = { _ in false }
        XCTAssertTrue(store.restore(id: proj.id, versionId: v.id))
        XCTAssertEqual(try String(contentsOf: store.siteIndexURL(id: proj.id)!, encoding: .utf8), "A")
        store.delete(id: proj.id)
        XCTAssertNil(store.project(id: proj.id))
    }

    // MARK: - Data-loss regressions

    // At the version cap, the undo snapshot() prunes the oldest version. When the
    // version being restored IS the oldest, the prune must not delete it out from
    // under the restore and wipe the live tree.
    func testRestoreAtVersionCapDoesNotWipeSite() throws {
        let proj = store.create(title: "Capped restore")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "ORIGINAL"))
        let oldest = try XCTUnwrap(store.snapshot(id: proj.id, label: "s1"))

        // Fill snapshots exactly to the cap. `oldest` is first in line to prune.
        for i in 2...DesignProjectStore.maxVersions {
            XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "v\(i)"))
            _ = store.snapshot(id: proj.id, label: "s\(i)")
        }
        XCTAssertEqual(store.versions(id: proj.id).count, DesignProjectStore.maxVersions)
        XCTAssertEqual(store.versions(id: proj.id).first?.id, oldest.id, "oldest is next to be pruned")

        // Move the live tree off the oldest content so restore is a real change.
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "CURRENT"))

        // Restore the oldest version. The undo snapshot() pushes over the cap and
        // prunes the oldest, which is the version being restored. It must survive.
        XCTAssertTrue(store.restore(id: proj.id, versionId: oldest.id), "restore at the cap must succeed")
        let idx = try XCTUnwrap(store.siteIndexURL(id: proj.id), "site/index.html must exist after restore")
        XCTAssertEqual(try String(contentsOf: idx, encoding: .utf8), "ORIGINAL",
                       "restore brought back the oldest content and did not wipe the site")
        XCTAssertFalse(store.artifactFiles(id: proj.id).isEmpty, "the live tree was not lost")
    }

    // When the undo snapshot() FAILS (not the benign empty-site skip) on a site
    // that has content, restore must abort without touching the live tree.
    func testRestoreDoesNotWipeSiteWhenUndoSnapshotFails() throws {
        try XCTSkipIf(getuid() == 0, "directory permission gate does not hold for root")
        let proj = store.create(title: "Snapshot fail")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "A"))
        let v = try XCTUnwrap(store.snapshot(id: proj.id, label: "generation"))
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "B"))

        // Make versions/ read-only so the undo snapshot's copy into it throws
        // (returns nil) while the live site still holds "B".
        let versionsDir = tempDir
            .appendingPathComponent(proj.slug, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: versionsDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: versionsDir.path) }

        XCTAssertFalse(store.restore(id: proj.id, versionId: v.id),
                       "restore must abort when the undo snapshot fails")
        let idx = try XCTUnwrap(store.siteIndexURL(id: proj.id), "live site must survive a failed restore")
        XCTAssertEqual(try String(contentsOf: idx, encoding: .utf8), "B",
                       "the live tree was left untouched")
    }

    // delete() must honor the restore kill switch: while writes are suspended it
    // no-ops rather than removing a folder the restore may have just swapped in.
    func testDeleteNoOpsWhileWritesSuspended() throws {
        let proj = store.create(title: "Suspended")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "x"))
        let dir = tempDir.appendingPathComponent(proj.slug, isDirectory: true)

        Persistence.writesSuspended = true
        defer { Persistence.writesSuspended = false }
        store.delete(id: proj.id)

        XCTAssertNotNil(store.project(id: proj.id), "delete no-ops while writes are suspended")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "the folder survives the suspended delete")
    }

    // A real removal failure must abort the delete and keep the index row, so the
    // in-memory index and the on-disk folder never desync.
    func testDeleteKeepsIndexRowWhenRemovalFails() throws {
        try XCTSkipIf(getuid() == 0, "directory permission gate does not hold for root")
        let proj = store.create(title: "Stubborn")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "x"))
        let dir = tempDir.appendingPathComponent(proj.slug, isDirectory: true)
        let siteDir = dir.appendingPathComponent("site", isDirectory: true)
        let fm = FileManager.default

        // Freeze the tree read-only so no entry inside can be unlinked: removeItem
        // throws with nothing deleted, and delete() must keep the index row.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: siteDir.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: siteDir.path)
        }

        store.delete(id: proj.id)

        XCTAssertNotNil(store.project(id: proj.id), "a failed removal keeps the index row (no desync)")
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "the project folder survives a failed delete")
        XCTAssertTrue(fm.fileExists(atPath: siteDir.appendingPathComponent("index.html").path),
                      "nothing inside was partially removed")
    }

    // MARK: - Transcript char-count cache

    func testTranscriptCharCountTracksMutations() throws {
        let proj = store.create(title: "Counter")
        XCTAssertEqual(store.transcriptCharCount(id: proj.id), 0)
        store.appendMessage(id: proj.id, DesignChatMessage(role: .user, text: "hello"))       // 5
        store.appendMessage(id: proj.id, DesignChatMessage(role: .assistant, text: "hi"))      // 2
        XCTAssertEqual(store.transcriptCharCount(id: proj.id), 7, "append keeps the cache warm")

        store.clearTranscript(id: proj.id)
        XCTAssertEqual(store.transcriptCharCount(id: proj.id), 0, "clear resets the cache")

        // A cold read (no prior cache seed) still computes from disk correctly.
        store.appendMessage(id: proj.id, DesignChatMessage(role: .user, text: "abcd"))
        let reloaded = DesignProjectStore(rootDir: tempDir)
        XCTAssertEqual(reloaded.transcriptCharCount(id: proj.id), 4)
    }

    // MARK: - Drift recovery

    func testIndexDriftRecovery() throws {
        let proj = store.create(title: "Recoverable")
        XCTAssertTrue(store.writeArtifact(id: proj.id, relativePath: "site/index.html", content: "content"))

        // Simulate a lost index.json (failed write / restored tree). The folder
        // and its project.json remain.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("index.json"))

        let reborn = DesignProjectStore(rootDir: tempDir)
        XCTAssertEqual(reborn.projects.count, 1)
        XCTAssertEqual(reborn.project(id: proj.id)?.title, "Recoverable")
    }
}
