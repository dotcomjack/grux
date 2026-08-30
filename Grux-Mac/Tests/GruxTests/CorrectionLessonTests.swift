import XCTest
@testable import Grux

// Covers CorrectionLessonStore: upsert-by-id ordering, the 60-lesson cap,
// removal, case-insensitive per-brand filtering, and promptBlock formatting.
// These tests touch the shared singleton and its on-disk file, so each test
// cleans up the ids it adds (remove / clear) and asserts on deltas rather than
// absolute counts wherever possible, to stay deterministic against any lessons
// already present from real usage.
@MainActor
final class CorrectionLessonTests: XCTestCase {

    private let store = CorrectionLessonStore.shared

    // A unique prefix per test run so ids never collide with real lessons.
    private func uid(_ suffix: String) -> String { "test-\(suffix)-\(UUID().uuidString)" }

    private func makeLesson(
        id: String,
        brand: String = "acme",
        learnedAt: Date = Date(),
        lesson: String = "Keep it short."
    ) -> CorrectionLesson {
        CorrectionLesson(
            id: id,
            learnedAt: learnedAt,
            brand: brand,
            category: nil,
            lesson: lesson,
            subject: "Re: order",
            beforeSnippet: "before",
            afterSnippet: "after"
        )
    }

    func testAddInsertsNewestFirst() {
        let a = uid("a")
        let b = uid("b")
        store.add(makeLesson(id: a, learnedAt: Date(timeIntervalSince1970: 1)))
        store.add(makeLesson(id: b, learnedAt: Date(timeIntervalSince1970: 2)))
        defer { store.remove(a); store.remove(b) }

        // Most recently added sits at the front regardless of learnedAt.
        XCTAssertEqual(store.lessons.first?.id, b)
        let idxA = store.lessons.firstIndex { $0.id == a }
        let idxB = store.lessons.firstIndex { $0.id == b }
        XCTAssertNotNil(idxA)
        XCTAssertNotNil(idxB)
        XCTAssertLessThan(idxB!, idxA!)
    }

    func testAddUpsertsById() {
        let id = uid("upsert")
        store.add(makeLesson(id: id, lesson: "First version."))
        let countAfterFirst = store.lessons.count
        store.add(makeLesson(id: id, lesson: "Second version."))
        defer { store.remove(id) }

        // Same id does not grow the list and refreshes the stored content.
        XCTAssertEqual(store.lessons.count, countAfterFirst)
        XCTAssertEqual(store.lessons.first(where: { $0.id == id })?.lesson, "Second version.")
        XCTAssertEqual(store.lessons.filter { $0.id == id }.count, 1)
    }

    func testCapAtSixtyKeepsNewest() {
        store.clear()
        defer { store.clear() }

        for i in 0..<65 {
            store.add(makeLesson(id: "cap-\(i)", lesson: "lesson \(i)"))
        }

        // Cap holds at 60, and the most recently added (id cap-64) is retained
        // while the oldest (cap-0 .. cap-4) fall off.
        XCTAssertEqual(store.lessons.count, 60)
        XCTAssertEqual(store.lessons.first?.id, "cap-64")
        XCTAssertTrue(store.lessons.contains { $0.id == "cap-64" })
        XCTAssertFalse(store.lessons.contains { $0.id == "cap-0" })
    }

    func testRemove() {
        let id = uid("remove")
        store.add(makeLesson(id: id))
        XCTAssertTrue(store.lessons.contains { $0.id == id })

        store.remove(id)
        XCTAssertFalse(store.lessons.contains { $0.id == id })
    }

    func testLessonsForBrandIsCaseInsensitive() {
        let a = uid("brand-a")
        let b = uid("brand-b")
        store.add(makeLesson(id: a, brand: "ACME"))
        store.add(makeLesson(id: b, brand: "acme"))
        defer { store.remove(a); store.remove(b) }

        let lower = store.lessons(forBrand: "acme").map { $0.id }
        let upper = store.lessons(forBrand: "ACME").map { $0.id }

        XCTAssertTrue(lower.contains(a), "uppercase-stored brand should match lowercase query")
        XCTAssertTrue(lower.contains(b))
        // Querying with different casing returns the same set.
        XCTAssertEqual(Set(lower), Set(upper))
        // A brand with no lessons added here yields none of our test ids.
        let other = store.lessons(forBrand: "other-brand").map { $0.id }
        XCTAssertFalse(other.contains(a))
        XCTAssertFalse(other.contains(b))
    }

    func testPromptBlockNilWhenNoLessonsForBrand() {
        store.clear()
        defer { store.clear() }

        XCTAssertNil(store.promptBlock(forBrand: "unknown-brand", limit: 5))
    }

    func testPromptBlockFormatAndLimit() {
        store.clear()
        defer { store.clear() }

        // Add three, newest last so order is deterministic.
        store.add(makeLesson(id: "pb-1", learnedAt: Date(timeIntervalSince1970: 1), lesson: "Lead with the answer."))
        store.add(makeLesson(id: "pb-2", learnedAt: Date(timeIntervalSince1970: 2), lesson: "Skip the apology."))
        store.add(makeLesson(id: "pb-3", learnedAt: Date(timeIntervalSince1970: 3), lesson: "Sign off with the brand name."))

        let block = store.promptBlock(forBrand: "acme", limit: 2)
        XCTAssertNotNil(block)
        let text = block!

        XCTAssertTrue(text.hasPrefix("LESSONS FROM THE USER'S EDITS (apply these to this reply):\n"))
        XCTAssertTrue(text.contains("LESSONS FROM THE USER'S EDITS"))

        // limit:2 takes the two newest (pb-3, pb-2) and skips the oldest (pb-1).
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3) // header + 2 bullets
        XCTAssertEqual(lines[1], "  - Sign off with the brand name.")
        XCTAssertEqual(lines[2], "  - Skip the apology.")
        XCTAssertFalse(text.contains("Lead with the answer."))
    }
}
