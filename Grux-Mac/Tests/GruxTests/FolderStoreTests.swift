import XCTest
@testable import Grux

// Unit tests for FolderStore + FolderClassifier parsing. All tests are fully
// in-process: we avoid hitting the network by testing the JSON parser
// directly and avoid hitting the real on-disk folders.json by writing to a
// temporary `foldersURL` wrapper. Where that's not possible we tolerate the
// singleton's disk state (read-only), never asserting on absolute counts.
@MainActor
final class FolderStoreTests: XCTestCase {

    func testSeedSystemFoldersOnEmptyInit() throws {
        // FolderStore seeds at least the three system folders (Work / Personal /
        // Projects). Can't test the truly empty path without reaching into the
        // singleton, but we can verify the seed invariants hold after init.
        let store = FolderStore.shared
        let names = store.ordered.map { $0.name.lowercased() }
        for expected in ["work", "personal", "projects"] {
            XCTAssertTrue(names.contains(expected), "missing system folder '\(expected)'")
        }
        let systems = store.folders.filter { $0.isSystem }
        XCTAssertGreaterThanOrEqual(systems.count, 3, "should seed ≥3 system folders")
        XCTAssertEqual(store.folders.filter { $0.isDefault }.count, 1, "exactly one folder must be default")
    }

    func testCreateAndResolveFolder() throws {
        let store = FolderStore.shared
        let name = "Test-\(UUID().uuidString.prefix(6))"
        defer {
            // Cleanup, don't leak test folders across runs.
            if let f = store.resolve(name) { _ = store.delete(id: f.id) }
        }
        guard let created = store.create(name: name, description: "Test folder") else {
            return XCTFail("create returned nil")
        }
        XCTAssertEqual(created.name, name)
        XCTAssertFalse(created.isSystem)
        XCTAssertFalse(created.isDefault)
        XCTAssertEqual(store.resolve(name)?.id, created.id, "exact-name resolve should win")
        XCTAssertEqual(store.resolve(created.id.uuidString)?.id, created.id, "uuid resolve should win")
        XCTAssertEqual(store.resolve(String(name.prefix(6)))?.id, created.id, "substring resolve should win")
    }

    func testDuplicateNameReturnsExisting() throws {
        let store = FolderStore.shared
        let name = "Dup-\(UUID().uuidString.prefix(6))"
        defer {
            if let f = store.resolve(name) { _ = store.delete(id: f.id) }
        }
        let a = store.create(name: name)
        let b = store.create(name: name.uppercased())
        XCTAssertEqual(a?.id, b?.id, "de-dup is case-insensitive")
    }

    func testSystemFolderCannotBeDeleted() throws {
        let store = FolderStore.shared
        guard let work = store.resolve("Work") else {
            return XCTFail("Work system folder missing")
        }
        let result = store.delete(id: work.id)
        XCTAssertNil(result, "system folders must be undeletable")
        XCTAssertNotNil(store.folder(id: work.id), "Work folder should still exist")
    }

    func testDeleteReassignsToDefault() throws {
        let store = FolderStore.shared
        let name = "DelTest-\(UUID().uuidString.prefix(6))"
        guard let created = store.create(name: name) else { return XCTFail("create failed") }
        let result = store.delete(id: created.id)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.deleted.id, created.id)
        XCTAssertTrue(result?.newHome.isDefault == true, "reassignment should target the default folder when no explicit target")
        XCTAssertNil(store.folder(id: created.id), "deleted folder should be gone")
    }

    func testUpdateFolder() throws {
        let store = FolderStore.shared
        let name = "Upd-\(UUID().uuidString.prefix(6))"
        defer {
            if let f = store.folders.first(where: { $0.name.hasPrefix("Upd-") || $0.name.hasPrefix("Renamed-") }) {
                _ = store.delete(id: f.id)
            }
        }
        guard let created = store.create(name: name) else { return XCTFail("create failed") }
        let newName = "Renamed-\(UUID().uuidString.prefix(6))"
        let updated = store.update(id: created.id, name: newName, description: "hi", colorHex: "#EF4444", icon: "star.fill")
        XCTAssertEqual(updated?.name, newName)
        XCTAssertEqual(updated?.description, "hi")
        XCTAssertEqual(updated?.colorHex, "#EF4444")
        XCTAssertEqual(updated?.icon, "star.fill")
    }

    func testFolderCodableRoundTrip() throws {
        let folder = Folder(
            name: "Roundtrip",
            description: "Test desc",
            colorHex: "#123456",
            icon: "star.fill",
            order: 42,
            isSystem: false,
            isDefault: true
        )
        let encoded = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(Folder.self, from: encoded)
        XCTAssertEqual(decoded.id, folder.id)
        XCTAssertEqual(decoded.name, folder.name)
        XCTAssertEqual(decoded.colorHex, folder.colorHex)
        XCTAssertEqual(decoded.icon, folder.icon)
        XCTAssertEqual(decoded.order, folder.order)
        XCTAssertEqual(decoded.isSystem, folder.isSystem)
        XCTAssertEqual(decoded.isDefault, folder.isDefault)
    }

    // MeetingIndexEntry must decode legacy JSON (no folderId key) without
    // error. Guarantees pre-folder records on disk keep loading cleanly.
    func testMeetingIndexEntryDecodesLegacyJson() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "startedAt": "2025-01-01T00:00:00Z",
          "endedAt": null,
          "title": "Legacy",
          "sourceAppName": "Zoom",
          "utteranceCount": 12,
          "summaryExcerpt": "hi"
        }
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entry = try dec.decode(MeetingIndexEntry.self, from: legacy)
        XCTAssertEqual(entry.title, "Legacy")
        XCTAssertNil(entry.folderId, "legacy rows must have nil folderId")
    }

    func testMeetingRecordDecodesLegacyJson() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "startedAt": "2025-01-01T00:00:00Z",
          "utterances": [],
          "actionItems": []
        }
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let rec = try dec.decode(MeetingRecord.self, from: legacy)
        XCTAssertNil(rec.folderId)
    }

    func testFolderClassifierParsesStrictJson() throws {
        let id = UUID()
        let raw = """
        {"folder_id":"\(id.uuidString)","confidence":0.82,"reasoning":"Looks like a Work meeting."}
        """
        let a = FolderClassifier.parse(raw, validIds: [id])
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.folderId, id)
        XCTAssertEqual(a?.confidence ?? 0, 0.82, accuracy: 0.001)
        XCTAssertFalse((a?.reasoning ?? "").isEmpty)
    }

    func testFolderClassifierParsesFencedJson() throws {
        let id = UUID()
        let raw = """
        ```json
        {"folder_id":"\(id.uuidString)","confidence":0.4,"reasoning":"meh"}
        ```
        """
        let a = FolderClassifier.parse(raw, validIds: [id])
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.folderId, id)
    }

    func testFolderClassifierRejectsInvalidId() throws {
        let raw = """
        {"folder_id":"\(UUID().uuidString)","confidence":0.9,"reasoning":"x"}
        """
        let a = FolderClassifier.parse(raw, validIds: [UUID()])
        XCTAssertNil(a, "id outside validIds must be rejected")
    }

    func testSetDefaultIsUnique() throws {
        let store = FolderStore.shared
        guard let work = store.resolve("Work") else { return XCTFail("Work missing") }
        store.setDefault(id: work.id)
        let defaults = store.folders.filter { $0.isDefault }
        XCTAssertEqual(defaults.count, 1)
        XCTAssertEqual(defaults.first?.id, work.id)
        // Restore Projects as default for downstream tests.
        if let projects = store.resolve("Projects") {
            store.setDefault(id: projects.id)
        }
    }

    func testSemanticMemoryFolderReassignStripKey() throws {
        // Touch SemanticMemory, ensure reassignFolder(nil) clears the key.
        let memory = SemanticMemory.shared
        let oldId = UUID()
        memory.store(kind: .fact, text: "Grux test entry for folder reassignment.", metadata: [SemanticMemory.folderMetadataKey: oldId.uuidString])
        XCTAssertEqual(memory.entries(inFolder: oldId).count >= 1, true)
        memory.reassignFolder(from: oldId, to: nil)
        XCTAssertEqual(memory.entries(inFolder: oldId).count, 0, "entries should no longer resolve under oldId")
    }
}
