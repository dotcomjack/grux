import XCTest
@testable import Grux

// Unit tests for NotesStore. Every test uses its own temp storage URL so
// nothing touches the real ~/Library/Application Support/Grux/notes.json.
// flush() forces past the debounced scheduleSave before reload assertions.
@MainActor
final class NotesStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-notes-test-\(UUID().uuidString).json")
    }

    func testCreateUpdateDelete() throws {
        let store = NotesStore(storageURL: tempURL())
        XCTAssertTrue(store.notes.isEmpty)

        let note = store.create(title: "Acme packaging", body: "Check kraft labels", tags: ["Acme", "ideas"])
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(note.displayTitle, "Acme packaging")
        XCTAssertEqual(note.tags, ["acme", "ideas"], "tags normalize to lowercase")

        let updated = store.update(id: note.id, body: "Check kraft labels and inserts")
        XCTAssertEqual(updated?.body, "Check kraft labels and inserts")
        XCTAssertNotNil(updated)
        XCTAssertGreaterThanOrEqual(updated!.updatedAt, note.updatedAt)

        store.delete(id: note.id)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testNoOpUpdateDoesNotBumpUpdatedAt() throws {
        // Programmatic editor syncs (NotesView selection changes) echo the
        // current values back; those must not re-timestamp the note or the
        // recency ordering churns just from browsing the list.
        let store = NotesStore(storageURL: tempURL())
        let note = store.create(title: "Stable", body: "unchanged body", tags: ["tag"])
        let stamp = store.note(id: note.id)!.updatedAt

        let echoed = store.update(id: note.id, title: "Stable", body: "unchanged body", tags: ["tag"])
        XCTAssertEqual(echoed?.updatedAt, stamp, "identical values must not bump updatedAt")

        let changed = store.update(id: note.id, body: "new body")
        XCTAssertNotNil(changed)
        XCTAssertGreaterThanOrEqual(changed!.updatedAt, stamp)
        XCTAssertEqual(changed!.body, "new body")
    }

    func testPersistenceRoundtrip() throws {
        let url = tempURL()
        let store = NotesStore(storageURL: url)
        let a = store.create(title: "Alpha", body: "first")
        _ = store.create(title: "Beta", body: "second", pinned: true)
        store.flush()

        let reloaded = NotesStore(storageURL: url)
        XCTAssertEqual(reloaded.notes.count, 2)
        XCTAssertEqual(reloaded.note(id: a.id)?.title, "Alpha")
        XCTAssertEqual(reloaded.notes.filter { $0.pinned }.count, 1)
    }

    func testOrderingPinnedFirstThenRecency() throws {
        let store = NotesStore(storageURL: tempURL())
        let old = store.create(title: "Old")
        let pinned = store.create(title: "Pinned", pinned: true)
        let fresh = store.create(title: "Fresh")
        _ = store.update(id: fresh.id, body: "touched last")

        let ordered = store.ordered
        XCTAssertEqual(ordered.first?.id, pinned.id, "pinned floats to top")
        XCTAssertEqual(ordered[1].id, fresh.id, "then most recently updated")
        XCTAssertEqual(ordered.last?.id, old.id)
    }

    func testSearchMatchesTitleBodyAndTags() throws {
        let store = NotesStore(storageURL: tempURL())
        _ = store.create(title: "Shopping list", body: "eggs, milk")
        _ = store.create(title: "Workout", body: "5x5 squats", tags: ["health"])
        _ = store.create(title: "Roadmap", body: "ship the notes tab")

        XCTAssertEqual(store.search("milk").count, 1, "body match")
        XCTAssertEqual(store.search("workout").count, 1, "title match")
        XCTAssertEqual(store.search("health").count, 1, "tag match")
        XCTAssertEqual(store.search("zzz-nothing").count, 0)
        XCTAssertEqual(store.search("").count, 3, "empty query lists all")
    }

    func testTogglePin() throws {
        let store = NotesStore(storageURL: tempURL())
        let n = store.create(title: "Pin me")
        XCTAssertFalse(n.pinned)
        XCTAssertEqual(store.togglePin(id: n.id)?.pinned, true)
        XCTAssertEqual(store.togglePin(id: n.id)?.pinned, false)
        XCTAssertNil(store.togglePin(id: UUID()), "unknown id returns nil")
    }

    func testAppendToBody() throws {
        let store = NotesStore(storageURL: tempURL())
        let n = store.create(title: "Log")
        let once = store.appendToBody(id: n.id, text: "line one")
        XCTAssertEqual(once?.body, "line one")
        let twice = store.appendToBody(id: n.id, text: "line two")
        XCTAssertEqual(twice?.body, "line one\n\nline two")
        let noop = store.appendToBody(id: n.id, text: "   ")
        XCTAssertEqual(noop?.body, "line one\n\nline two", "blank append is a no-op")
    }

    func testResolveByIdTitleAndSubstring() throws {
        let store = NotesStore(storageURL: tempURL())
        let n = store.create(title: "Quarterly numbers", body: "revenue notes")
        XCTAssertEqual(store.resolve(n.id.uuidString)?.id, n.id, "uuid resolve")
        XCTAssertEqual(store.resolve("Quarterly numbers")?.id, n.id, "exact title resolve")
        XCTAssertEqual(store.resolve("quarterly")?.id, n.id, "substring resolve")
        XCTAssertNil(store.resolve("completely unrelated gibberish xyzzy"))
    }

    func testEditorTagFieldEchoGuard() throws {
        // NotesView's editTags onChange compares the raw field string against
        // tags.joined(separator: ", ") instead of the parsed tag list: the
        // comma-split parse is lossy for tags that contain commas, so a
        // parse-then-compare would treat a mere selection load as an edit
        // and rewrite (re-timestamp) the note. Pin both halves of that.
        XCTAssertEqual(NotesView.parseTags(" acme , ideas ,, "), ["acme", "ideas"])

        let store = NotesStore(storageURL: tempURL())
        // A comma-bearing tag can only arrive programmatically (create /
        // update_note tools); the editor field round trip splits it in two.
        let note = store.create(title: "Lossy", tags: ["a,b"])
        XCTAssertEqual(note.tags, ["a,b"])
        let echo = note.tags.joined(separator: ", ")
        XCTAssertNotEqual(NotesView.parseTags(echo), note.tags,
                          "parse round trip is lossy, which is why the guard compares strings")
        XCTAssertEqual(echo, "a,b", "the loaded field string always equals the join, so the echo guard skips")
    }

    func testDisplayTitleFallsBackToBody() throws {
        let note = GruxNote(title: "  ", body: "\n\nFirst real line\nsecond")
        XCTAssertEqual(note.displayTitle, "First real line")
        let empty = GruxNote()
        XCTAssertEqual(empty.displayTitle, "Untitled note")
    }
}
