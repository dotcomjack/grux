import XCTest
@testable import Grux

// SkillFolderBackend: SKILL.md export/read round-trip and the merge-not-wipe
// import semantics (newest-wins, dedupe by name, drift reindex). All against
// temp dirs so the real Application Support tree is never touched.
@MainActor
final class SkillFolderBackendTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-skillfolders-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempSkillsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-tests-\(UUID().uuidString)-skills.json")
    }

    func test_export_thenRead_roundTripsFields() {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = Skill(name: "release-notes", trigger: "the user asks for release notes",
                      procedure: "1. Pull merged PRs\n2. Group by scent")
        let b = Skill(name: "deploy-check", trigger: "before any deploy claim",
                      procedure: "Hit the endpoint, load the page, then say done")
        SkillFolderBackend.export([a, b], to: root)

        // Folders were written with SKILL.md inside.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("release-notes/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("deploy-check/SKILL.md").path))

        let read = SkillFolderBackend.readFolders(from: root)
        XCTAssertEqual(read.count, 2)
        let notes = read.first { $0.name == "release-notes" }
        XCTAssertEqual(notes?.trigger, "the user asks for release notes")
        XCTAssertTrue(notes?.procedure.contains("Group by scent") == true)
    }

    func test_importFolders_mergesIntoEmptyStore() {
        let root = tempDir()
        let skillsURL = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: skillsURL) }

        SkillFolderBackend.export([
            Skill(name: "alpha", trigger: "t", procedure: "a-body"),
            Skill(name: "beta", trigger: "t", procedure: "b-body")
        ], to: root)

        let store = SkillStore(fileURL: skillsURL)
        SkillFolderBackend.importFolders(into: store, from: root)

        XCTAssertEqual(store.skills.count, 2)
        XCTAssertEqual(store.skill(named: "alpha")?.procedure, "a-body")
        XCTAssertEqual(store.skill(named: "beta")?.procedure, "b-body")
    }

    func test_importFolders_newestWins_olderIsIgnored() {
        let root = tempDir()
        let skillsURL = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: skillsURL) }

        let now = Date()
        let store = SkillStore(fileURL: skillsURL)
        // Two live skills, both stamped ~now by upsert.
        store.upsert(name: "shared", trigger: "t", procedure: "store-version")
        store.upsert(name: "keep", trigger: "t", procedure: "store-keep")

        // A newer folder for "shared" must win; an older folder for "keep" must not.
        SkillFolderBackend.export([
            Skill(name: "shared", trigger: "t2", procedure: "folder-newer", updatedAt: now.addingTimeInterval(3600)),
            Skill(name: "keep", trigger: "t3", procedure: "folder-older", updatedAt: now.addingTimeInterval(-3600))
        ], to: root)

        SkillFolderBackend.importFolders(into: store, from: root)

        XCTAssertEqual(store.skill(named: "shared")?.procedure, "folder-newer", "newer folder wins")
        XCTAssertEqual(store.skill(named: "keep")?.procedure, "store-keep", "older folder is ignored")
        XCTAssertEqual(store.skills.count, 2, "merge dedupes by name, never duplicates")
    }

    func test_importFolders_isIdempotent() {
        let root = tempDir()
        let skillsURL = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: skillsURL) }

        SkillFolderBackend.export([Skill(name: "solo", trigger: "t", procedure: "p")], to: root)
        let store = SkillStore(fileURL: skillsURL)
        SkillFolderBackend.importFolders(into: store, from: root)
        SkillFolderBackend.importFolders(into: store, from: root)
        XCTAssertEqual(store.skills.count, 1, "re-importing the same folder does not duplicate")
    }

    // MARK: - Edit-preserving export (bug 2a)

    func test_exportAfterSave_preservesNewerHandEdit() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Mirror a skill whose store copy is an hour old.
        let old = Date().addingTimeInterval(-3600)
        let stored = Skill(name: "hand", trigger: "t", procedure: "store-body", updatedAt: old)
        SkillFolderBackend.export([stored], to: root)

        // The user hand-edits the SKILL.md body directly on disk (front matter left
        // alone), so the on-disk file is now newer than the store's copy.
        let file = root.appendingPathComponent("hand/SKILL.md")
        let handEdited = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "store-body", with: "HAND-EDITED-body")
        try handEdited.write(to: file, atomically: true, encoding: .utf8)

        // An unrelated skill save fires the mirror hook. The stale store copy of
        // "hand" must NOT clobber the newer on-disk hand edit.
        let other = Skill(name: "other", trigger: "t", procedure: "p", updatedAt: Date())
        SkillFolderBackend.exportAfterSave([stored, other], to: root)

        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.contains("HAND-EDITED-body"), "a newer on-disk hand edit is preserved")
        XCTAssertFalse(after.contains("store-body"), "the stale store copy did not overwrite the hand edit")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("other/SKILL.md").path), "the unrelated skill still mirrored")
    }

    func test_exportAfterSave_writesGenuineUpdate() {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // An old file on disk, then a genuine store update (newer body + stamp).
        SkillFolderBackend.export(
            [Skill(name: "x", trigger: "t", procedure: "v1", updatedAt: Date().addingTimeInterval(-3600))],
            to: root)
        let v2 = Skill(name: "x", trigger: "t", procedure: "v2", updatedAt: Date().addingTimeInterval(60))
        SkillFolderBackend.exportAfterSave([v2], to: root)

        let onDisk = SkillFolderBackend.readFolders(from: root).first { $0.name == "x" }
        XCTAssertEqual(onDisk?.procedure, "v2", "a genuine store update still propagates to the mirror")
    }

    // MARK: - Timestamp fidelity (bug 2b)

    func test_exportRead_preservesSubSecondUpdatedAt() {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A stamp with a non-zero fractional second: truncation to whole seconds
        // would drop the .750 and make an equal-second edit compare as older.
        let base = Date(timeIntervalSince1970: 1_700_000_000.750)
        SkillFolderBackend.export([Skill(name: "frac", trigger: "t", procedure: "p", updatedAt: base)], to: root)

        let read = SkillFolderBackend.readFolders(from: root).first { $0.name == "frac" }
        XCTAssertNotNil(read)
        XCTAssertEqual(read!.updatedAt.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.001,
                       "fractional seconds survive the SKILL.md round-trip")
    }

    // MARK: - Deletion propagation (bug 3)

    func test_removeFolder_deletedSkillDoesNotReappearAfterImport() {
        let root = tempDir()
        let skillsURL = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: skillsURL) }

        SkillFolderBackend.export([
            Skill(name: "keeper", trigger: "t", procedure: "keep-body"),
            Skill(name: "goner", trigger: "t", procedure: "gone-body")
        ], to: root)

        // Propagate a deletion the way SkillStore.remove does on the default store.
        SkillFolderBackend.removeFolder(for: "goner", from: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("goner/SKILL.md").path))

        // Import must not resurrect the deleted skill.
        let store = SkillStore(fileURL: skillsURL)
        SkillFolderBackend.importFolders(into: store, from: root)

        XCTAssertNotNil(store.skill(named: "keeper"))
        XCTAssertNil(store.skill(named: "goner"), "a removed folder cannot be re-imported")
        XCTAssertEqual(store.skills.count, 1)
    }

    func test_reindexIfDriftDetected_onlyAddsUnknownFolders() {
        let root = tempDir()
        let skillsURL = tempSkillsURL()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: skillsURL) }

        let store = SkillStore(fileURL: skillsURL)
        store.upsert(name: "known", trigger: "t", procedure: "known-store")

        // A hand-dropped folder for a brand new skill, plus a folder that
        // collides with an existing skill: only the new one should be added,
        // and the existing skill must be left untouched.
        SkillFolderBackend.export([
            Skill(name: "known", trigger: "t", procedure: "known-folder"),
            Skill(name: "dropped-in", trigger: "t", procedure: "dropped-body")
        ], to: root)

        SkillFolderBackend.reindexIfDriftDetected(into: store, from: root)

        XCTAssertEqual(store.skill(named: "dropped-in")?.procedure, "dropped-body")
        XCTAssertEqual(store.skill(named: "known")?.procedure, "known-store",
                       "reindex never overwrites a skill the store already tracks")
        XCTAssertEqual(store.skills.count, 2)
    }
}
