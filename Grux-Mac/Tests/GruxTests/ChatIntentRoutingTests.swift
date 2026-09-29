import XCTest
@testable import Grux

/// THE ENGINE MAY VETO THE FAST PATH. IT MAY NEVER CREATE ONE.
///
/// The PIM fast path skips the model and then acts, with a spoken
/// acknowledgement and a 5 second undo. A wrong match puts a wrong event on
/// someone's calendar. The engine is the second opinion on that, and the
/// direction is one way on purpose: a person with no key must get exactly the
/// behaviour they had before, never a new refusal.
@MainActor
final class ChatIntentRoutingTests: XCTestCase {

    /// Answers a fixed probability to the noul question, standing in for a
    /// provider that can actually judge.
    private struct Judge: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        let probability: Double
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            var out: [String: DecisionAnswer] = [:]
            for (name, q) in questions {
                if case .noul = q { out[name] = .noul(probability) }
            }
            return DecisionResult(answers: out, latencyMs: 412, inputTokens: 300,
                                  outputTokens: 0, provider: .jev)
        }
    }

    private let utterance = "note that the printer needs filament"

    private func engine(judging probability: Double) -> DecisionEngine {
        DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil),
                       remote: { _ in Judge(probability: probability) })
    }

    private func confirm(_ engine: DecisionEngine, threshold: Double = 0.70) async throws
        -> ChatIntentClassifier.PIMRouteDecision {
        let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: utterance),
                                 "the pattern matcher no longer matches the fixture")
        return await ChatIntentClassifier.confirmPIMRoute(
            plan: plan, utterance: utterance, engine: engine, threshold: threshold)
    }

    // MARK: - The match happens first, and synchronously

    func test_noPatternMatchMeansThereIsNothingToConfirm() {
        XCTAssertNil(ChatIntentClassifier.pimRoute(utterance: "play a hype song"))
    }

    /// THE GUARD THAT REFUSES BEFORE SPENDING MUST NOT SIT BELOW A SUSPENSION.
    ///
    /// send() runs on the main actor, so an await above the readiness guard
    /// lets other main-actor work land before the guard is read. Measured
    /// 2026-09-20: awaiting a version of the PIM route that matched internally
    /// let a turn which should have been refused locally reach the network and
    /// come back with a provider error, which is the exact hole that guard was
    /// written to close. The confirm step takes an already-matched plan so
    /// ordinary prose never suspends.
    func test_ordinaryProseNeverSuspendsAboveTheReadinessGuard() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "ChatService did not load")
        let match = try XCTUnwrap(text.range(of: "let plan = ChatIntentClassifier.pimRoute(utterance: trimmed)"),
                                  "the PIM match is no longer synchronous, so ordinary prose suspends above the guard")
        let readiness = try XCTUnwrap(text.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertLessThan(match.lowerBound, readiness.lowerBound,
                          "the PIM fast path moved below the readiness guard, which breaks it on a keyless install")
    }

    // MARK: - What the engine may and may not do

    func test_onDeviceCannotJudgeSoTheOldBehaviourStands() async throws {
        // The local provider answers 0.5 to any yes or no question, which is
        // below every sane threshold. If that counted as a veto, everyone
        // without a key would silently lose the fast path.
        let noKey = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let decision = try await confirm(noKey)
        XCTAssertEqual(decision.provider, .local)
        XCTAssertTrue(decision.confirmed, "a keyless install lost the fast path")
    }

    func test_aProviderThatCanJudgeAndIsSureLetsItThrough() async throws {
        let decision = try await confirm(engine(judging: 0.93))
        XCTAssertTrue(decision.confirmed)
        XCTAssertEqual(decision.provider, .jev)
        XCTAssertEqual(decision.latencyMs, 412)
    }

    func test_aProviderThatCanJudgeAndIsNotSureSendsItToTheModelInstead() async throws {
        let decision = try await confirm(engine(judging: 0.31))
        XCTAssertFalse(decision.confirmed)
        XCTAssertEqual(decision.confidence, 0.31, accuracy: 1e-9)
    }

    func test_theThresholdIsTheBoundaryAndSittingOnItCounts() async throws {
        let at = try await confirm(engine(judging: 0.70))
        XCTAssertTrue(at.confirmed, "sitting exactly on the threshold was refused")
        let under = try await confirm(engine(judging: 0.699))
        XCTAssertFalse(under.confirmed, "a hair under the threshold still acted")
    }

    /// The question has to name the parts that are guessed rather than heard,
    /// because a wrong date is the failure mode that actually happens.
    func test_theQuestionAsksAboutTheSlotsAndNotJustTheVerb() {
        let q = ChatIntentClassifier.pimInstructions.lowercased()
        XCTAssertTrue(q.contains("date"))
        XCTAssertTrue(q.contains("time"))
        XCTAssertTrue(q.contains("question rather than"), "nothing stops it acting on a question")
    }

    // MARK: - Task actions on an existing task skip the judge (A28d, ruling 0t)

    /// Counts the calls so a skipped judge is provably not asked.
    private final class CountingJudge: DecisionProvider, @unchecked Sendable {
        let kind: DecisionProviderKind = .jev
        let probability: Double
        var calls = 0
        init(probability: Double) { self.probability = probability }
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            calls += 1
            return try await Judge(probability: probability).decide(state: state, questions: questions)
        }
    }

    /// Live 2026-09-28: the judge held back "focus on the task X" (0.49 to 0.62)
    /// and "check off X" (0.59), turning a clear ask into an offer. These tools
    /// change nothing without a matching task and carry the 5 s undo, so the
    /// judge adds friction and no safety. It is not asked, and a batched voice
    /// answer below the threshold does not count either.
    func test_taskActionsOnAnExistingTaskAreNotJudged() async throws {
        for u in ["check off water the office plants",
                  "focus on the task water the office plants",
                  "delete the task water the office plants",
                  "make water the office plants my top priority"] {
            let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: u), u)
            XCTAssertFalse(plan.kind.isJudged, u)
            let judge = CountingJudge(probability: 0.2)
            let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in judge })
            let vetoed = ChatIntentClassifier.PreDecidedPIM(
                utterance: u, planKind: plan.kind, cardTitle: plan.cardTitle,
                decision: .init(confidence: 0.2, latencyMs: 300, provider: .jev, confirmed: false))
            for pre in [nil, vetoed] {
                let d = await ChatIntentClassifier.resolvePIM(plan: plan, utterance: u, preDecided: pre,
                                                              engine: e, threshold: 0.70)
                XCTAssertTrue(d.confirmed, "\(u): the judge still vetoes a fail-closed task action")
            }
            XCTAssertEqual(judge.calls, 0, "\(u): a paid call was spent on a task action")
        }
    }

    /// Anything that CREATES keeps the judge: a false positive leaves junk.
    func test_creatingActionsKeepTheJudge() async throws {
        for u in ["add a task: water the office plants", "put lunch with Sarah on my calendar Friday at 1pm"] {
            let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: u), u)
            XCTAssertTrue(plan.kind.isJudged, u)
            let d = await ChatIntentClassifier.resolvePIM(plan: plan, utterance: u, preDecided: nil,
                                                          engine: engine(judging: 0.2), threshold: 0.70)
            XCTAssertFalse(d.confirmed, "\(u): a creating action lost its judge")
        }
        for kind in PIMIntentKind.allCases {
            XCTAssertEqual(kind.isJudged, ![.completeTask, .removeTask, .focusTask, .takeNote, .rememberFact].contains(kind),
                           kind.rawValue)
        }
    }

    // MARK: - Explicit note commands skip the judge (A34 part 2, ruling 0v)

    /// Live 2026-09-28 with the decision key: the judge held back every plain
    /// spoken note ask (0.16 to 0.56), so "take a note X" became an offer and
    /// no note was saved. A note the person named with an explicit verb has
    /// one reading, and a wrong one is harmless and undoable from the card.
    func test_explicitNoteCommandsAreNotJudged() async throws {
        for u in ["take a note the blue folder is in the top drawer",
                  "Grux, take a note: the sweep three ran tonight",
                  "note that the printer needs filament",
                  "add a note the gate code is on the fridge",
                  "add a note: the van is booked for Tuesday",
                  "make a note that the plumber comes at 9",
                  "write down the spare key is under the mat",
                  "jot down call the bank about the card"] {
            let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: u), u)
            XCTAssertEqual(plan.kind, .takeNote, u)
            XCTAssertTrue(plan.requiresUndoWindow, "\(u): a note must carry the 5 s undo")
            let judge = CountingJudge(probability: 0.16)
            let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in judge })
            let vetoed = ChatIntentClassifier.PreDecidedPIM(
                utterance: u, planKind: plan.kind, cardTitle: plan.cardTitle,
                decision: .init(confidence: 0.16, latencyMs: 300, provider: .jev, confirmed: false))
            for pre in [nil, vetoed] {
                let d = await ChatIntentClassifier.resolvePIM(plan: plan, utterance: u, preDecided: pre,
                                                              engine: e, threshold: 0.70)
                XCTAssertTrue(d.confirmed, "\(u): the judge still vetoes an explicit note")
            }
            XCTAssertEqual(judge.calls, 0, "\(u): a paid call was spent on an explicit note")
        }
    }

    /// Ruling 0t (RV11): a first-person fact statement takes the deterministic
    /// path to remember_fact with the card and its 5 s undo, so the judge is
    /// not asked and a batched veto does not count. Contractions and "I am"
    /// are the same statement said another way.
    func test_firstPersonFactsAreNotJudged() async throws {
        for u in ["remember that my dentist is Dr. Lee",
                  "remember my wifi password is on the router label",
                  "remember that I take my coffee black",
                  "remember that I'm allergic to penicillin",
                  "remember that I\u{2019}m allergic to penicillin",
                  "remember that I am allergic to penicillin",
                  "remember that I've moved to Ferndale"] {
            let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: u), u)
            XCTAssertEqual(plan.kind, .rememberFact, u)
            XCTAssertTrue(plan.requiresUndoWindow, "\(u): a saved fact must carry the 5 s undo")
            let judge = CountingJudge(probability: 0.16)
            let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in judge })
            let vetoed = ChatIntentClassifier.PreDecidedPIM(
                utterance: u, planKind: plan.kind, cardTitle: plan.cardTitle,
                decision: .init(confidence: 0.16, latencyMs: 300, provider: .jev, confirmed: false))
            for pre in [nil, vetoed] {
                let d = await ChatIntentClassifier.resolvePIM(plan: plan, utterance: u, preDecided: pre,
                                                              engine: e, threshold: 0.70)
                XCTAssertTrue(d.confirmed, "\(u): the judge still vetoes a first-person fact")
            }
            XCTAssertEqual(judge.calls, 0, "\(u): a paid call was spent on a first-person fact")
        }
    }

    /// Only an explicit note verb takes the card path. Talk that mentions
    /// writing or notes stays conversation, where the model decides.
    func test_talkAboutNotesIsNotANote() {
        for u in ["I should write down my thoughts sometime",
                  "noted, thanks",
                  "that is a good note",
                  "add a note to the invoice",
                  "add a note of caution",
                  "can you add a note?",
                  "I took a note yesterday"] {
            XCTAssertNotEqual(PIMIntents.match(u)?.kind, .takeNote, "should stay conversation: \(u)")
        }
    }

    func test_theDecisionIsRecordedUnderItsOwnSurface() async throws {
        let ledger = DecisionLedger(storeURL: nil)
        let e = DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in Judge(probability: 0.9) })
        _ = try await confirm(e)
        XCTAssertEqual(ledger.last?.surface, "chat.intent",
                       "the latency table cannot tell this gate apart from the voice one")
    }
}
