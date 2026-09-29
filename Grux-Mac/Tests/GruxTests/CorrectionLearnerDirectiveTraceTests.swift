import XCTest
@testable import Grux

// The Jax "directive" trace kind has exactly one writer: CorrectionLearner, when
// an edit to a drafted support reply becomes a standing lesson. These run
// `learn(from:)` end to end with only the model call swapped, and check the
// trace the Cognition Map reads, the lesson store and the profile heuristic
// agree, and that nothing is traced when no lesson was learned.
@MainActor
final class CorrectionLearnerDirectiveTraceTests: XCTestCase {

    private var savedAskModel: ((String, String) async throws -> String)!
    private var modelCalls = 0

    override func setUp() async throws {
        savedAskModel = CorrectionLearner.askModel
        modelCalls = 0
    }

    override func tearDown() async throws {
        CorrectionLearner.askModel = savedAskModel
    }

    private func answer(_ reply: String) {
        CorrectionLearner.askModel = { [unowned self] _, _ in
            self.modelCalls += 1
            return reply
        }
    }

    private func draft(id: String, before: String, after: String,
                       subject: String = "Where is my order") -> SupportDraft {
        SupportDraft(
            id: id, createdAt: Date(), inbox: SupportInbox(id: "acme"), brandVoice: "Acme",
            category: .shipping, fromName: "Test Customer", fromEmail: "t@example.com",
            subject: subject, incomingPreview: "where is my order",
            draftReply: after, originalReply: before, urgency: .normal,
            needsReview: false, reviewReason: nil, sourceMessageId: "", status: .sent)
    }

    private func directives(for id: String) -> [CognitionEvent] {
        CognitionTrace.shared.events.filter { $0.kind == .directive && $0.correlationId == id }
    }

    private let wordy = "Hi, thank you so much for reaching out. We are so sorry for any inconvenience and truly appreciate your patience."
    private let short = "Hi, looking into your order now and will follow up shortly."

    func test_aRealEditBecomesOneDirectiveTraceMatchingTheStoredLesson() async {
        let id = "clt-directive-\(UUID().uuidString)"
        answer("<think>shorter</think>\n- Keep replies short and skip the apology.")

        await CorrectionLearner.learn(from: draft(id: id, before: wordy, after: short))

        let traced = directives(for: id)
        XCTAssertEqual(traced.count, 1, "one lesson, one directive trace")
        guard let event = traced.first else { return }
        let rule = "Keep replies short and skip the apology."
        XCTAssertEqual(event.heuristicsFired, [rule])
        XCTAssertEqual(event.trigger, "Learned from your edit: Where is my order")
        XCTAssertEqual(event.brand, "acme")
        XCTAssertTrue(event.outcome.contains("future Acme replies"), event.outcome)

        let lesson = CorrectionLessonStore.shared.lessons.first { $0.id == "lesson-\(id)" }
        XCTAssertEqual(lesson?.lesson, rule)
        let heuristic = JaxProfile.shared.heuristics.first { $0.id == lesson?.heuristicID }
        XCTAssertEqual(heuristic?.rule, rule)
        XCTAssertEqual(heuristic?.domain, CorrectionLearner.learnDomain("Acme"))

        CorrectionLearner.forget("lesson-\(id)")
    }

    func test_aModelThatSaysNoneLeavesNoDirective() async {
        let id = "clt-none-\(UUID().uuidString)"
        answer("NONE")

        await CorrectionLearner.learn(from: draft(id: id, before: wordy, after: short))

        XCTAssertEqual(modelCalls, 1)
        XCTAssertTrue(directives(for: id).isEmpty)
        XCTAssertFalse(CorrectionLessonStore.shared.lessons.contains { $0.id == "lesson-\(id)" })
    }

    func test_aCosmeticOrMissingEditNeverAsksTheModelAndTracesNothing() async {
        answer("Always mention the order number.")
        let cosmetic = "clt-cosmetic-\(UUID().uuidString)"
        await CorrectionLearner.learn(from: draft(id: cosmetic,
            before: "Your order 1001 is on its way.", after: "Your order 2487 is on its way."))
        let unedited = "clt-unedited-\(UUID().uuidString)"
        await CorrectionLearner.learn(from: draft(id: unedited, before: short, after: short))

        XCTAssertEqual(modelCalls, 0)
        XCTAssertTrue(directives(for: cosmetic).isEmpty)
        XCTAssertTrue(directives(for: unedited).isEmpty)
    }

    func test_relearningTheSameDraftReplacesTheOldHeuristicAndTracesTheNewRule() async {
        let id = "clt-relearn-\(UUID().uuidString)"
        let first = "CLT relearn: open with the tracking link."
        let second = "CLT relearn: answer in two sentences at most."
        answer(first)
        await CorrectionLearner.learn(from: draft(id: id, before: wordy, after: short))
        answer(second)
        await CorrectionLearner.learn(from: draft(id: id, before: wordy, after: short + " Thanks."))

        XCTAssertFalse(JaxProfile.shared.heuristics.contains { $0.rule == first },
                       "the stale lesson must not keep firing")
        XCTAssertTrue(JaxProfile.shared.heuristics.contains { $0.rule == second })
        XCTAssertEqual(directives(for: id).first?.heuristicsFired, [second], "newest trace first")

        CorrectionLearner.forget("lesson-\(id)")
    }

    func test_dashesTheModelWritesNeverReachTheDirective() async {
        let id = "clt-dash-\(UUID().uuidString)"
        answer("Keep it brief \u{2014} one apology at most \u{2013} then the fix.")

        await CorrectionLearner.learn(from: draft(id: id, before: wordy, after: short))

        let rule = directives(for: id).first?.heuristicsFired.first ?? ""
        XCTAssertFalse(rule.isEmpty)
        XCTAssertFalse(rule.contains("\u{2014}") || rule.contains("\u{2013}"), rule)

        CorrectionLearner.forget("lesson-\(id)")
    }
}
