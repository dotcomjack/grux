import XCTest
@testable import Grux

// Covers the deterministic parts of the Phase 2 corrections->learning loop: the
// cosmetic-edit pre-filter, the think-block stripper, and forget() removing a
// lesson from BOTH the store and the matching profile heuristic. The LLM lesson
// extraction itself is covered by the `learntest` end-to-end smoke.
@MainActor
final class CorrectionLearnerTests: XCTestCase {

    func testIsCosmeticTrueForDigitAndWhitespaceOnlyDiffs() {
        // Only an order number changed.
        XCTAssertTrue(CorrectionLearner.isCosmetic(
            "Your order 1001 is on its way.",
            "Your order 2487 is on its way."))
        // Only whitespace / casing.
        XCTAssertTrue(CorrectionLearner.isCosmetic(
            "Thanks for reaching out.",
            "thanks   for reaching out."))
    }

    func testIsCosmeticFalseForWordingChange() {
        XCTAssertFalse(CorrectionLearner.isCosmetic(
            "We are so sorry for any inconvenience and truly appreciate your patience.",
            "Looking into it now and will follow up shortly."))
    }

    func testStripThinkRemovesLeadingThinkBlock() {
        XCTAssertEqual(
            CorrectionLearner.stripThink("<think>reasoning here</think>\nKeep replies short."),
            "Keep replies short.")
        // No think block: returned unchanged.
        XCTAssertEqual(CorrectionLearner.stripThink("Keep replies short."), "Keep replies short.")
    }

    func testForgetRemovesFromStoreAndProfile() {
        let store = CorrectionLessonStore.shared
        let rule = "CorrectionLearnerTests: keep refund replies to two sentences."
        let id = "lesson-clt-forget"
        store.add(CorrectionLesson(
            id: id, learnedAt: Date(), brand: "acme", category: "refund",
            lesson: rule, subject: "s", beforeSnippet: "b", afterSnippet: "a"))
        JaxProfile.shared.addHeuristic(rule: rule, domain: CorrectionLearner.learnDomain("acme"))
        XCTAssertTrue(store.lessons.contains { $0.id == id })
        XCTAssertTrue(JaxProfile.shared.heuristics.contains { $0.rule == rule })

        CorrectionLearner.forget(id)

        XCTAssertFalse(store.lessons.contains { $0.id == id })
        XCTAssertFalse(JaxProfile.shared.heuristics.contains { $0.rule == rule })
    }
}
