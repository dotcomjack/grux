import XCTest
@testable import Grux

// Phase R, P-R-5: attention. Four judgments move onto the decision engine:
// mail needs-you, notification interrupt/batch/silent, the email triage
// classify step, and the coach's drift and "good moment" pair.
//
// The rules every test here holds each judgment to:
// - A keyless install behaves exactly as today: nothing is asked, no call, no
//   ledger row, the floor decides.
// - One provider call per judged item, cached, never re-asked.
// - On device (or on a provider failure) an answer never gets a vote.
//
// Every engine here is built with a stub provider and an in-memory ledger, so
// nothing reaches the Keychain, the network or the operator's real state.

/// Answers each question it is asked with whatever `answer` says, and counts
/// calls. `fail` makes it throw like a provider outage.
final class ScriptedProvider: DecisionProvider, @unchecked Sendable {
    let kind: DecisionProviderKind = .jev
    var calls: [(state: String, questions: [String: DecisionQuestion])] = []
    var fail = false
    private let answer: (_ state: String, _ name: String, _ question: DecisionQuestion) -> DecisionAnswer

    init(_ answer: @escaping (_ state: String, _ name: String, _ question: DecisionQuestion) -> DecisionAnswer) {
        self.answer = answer
    }

    func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
        calls.append((state, questions))
        if fail { throw JevDecisionProvider.Failure.http(503) }
        var out: [String: DecisionAnswer] = [:]
        for (name, q) in questions { out[name] = answer(state, name, q) }
        return DecisionResult(answers: out, latencyMs: 400, inputTokens: 420, outputTokens: 20, provider: .jev)
    }
}

@MainActor
private func engine(key: String = "k", _ provider: ScriptedProvider, _ ledger: DecisionLedger) -> DecisionEngine {
    DecisionEngine(keyLookup: { key }, ledger: ledger, remote: { _ in provider })
}

// MARK: - mail.needsYou

@MainActor
final class MailNeedsYouEngineTests: XCTestCase {

    private func message(from: String = "dana@northwind-labs.com", subject: String = "Q3 budget",
                         body: String = "Can you sign off on the budget draft by Thursday?",
                         unread: Bool = true) -> EmailMessage {
        EmailMessage(id: UUID().uuidString, accountId: UUID(), sequenceNumber: 1, messageId: "",
                     fromName: "Someone", fromEmail: from, to: "me@example.com", subject: subject,
                     date: Date(), snippet: String(body.prefix(160)), bodyText: body,
                     isUnread: unread, fetchedAt: Date(), triageDraftId: nil)
    }

    /// A receipt reads low, anything else high.
    private func provider() -> ScriptedProvider {
        ScriptedProvider { state, _, _ in .noul(state.contains("has shipped") ? 0.08 : 0.97) }
    }

    func test_keylessAsksNothingAndTheBadgeIsTheFloor() async {
        let p = provider(), ledger = DecisionLedger(storeURL: nil)
        let store = MailStore(inMemory: [message(), message(subject: "Your order has shipped",
                                                            body: "Your order #4821 has shipped."),
                                         message(from: "noreply@shop.example"), message(unread: false)])
        let judged = await store.judgeNeedsYou(engine: engine(key: "", p, ledger))
        XCTAssertEqual(judged, 0)
        XCTAssertEqual(p.calls.count, 0, "a keyless install asked the provider")
        XCTAssertEqual(ledger.recent.count, 0, "a keyless install wrote a ledger row")
        XCTAssertTrue(store.messages.allSatisfy { $0.needsYouProbability == nil })
        XCTAssertEqual(store.needsYouCount, store.messages.filter(MailNeedsYou.needsYou).count,
                       "the keyless badge is no longer the floor")
        XCTAssertEqual(store.needsYouCount, 2)
    }

    func test_eachMessageTheFloorCountsIsAskedOnceAndCachedById() async {
        let p = provider(), ledger = DecisionLedger(storeURL: nil)
        let e = engine(p, ledger)
        let store = MailStore(inMemory: [message(), message(subject: "Your order has shipped",
                                                            body: "Your order #4821 has shipped."),
                                         message(from: "noreply@shop.example"), message(unread: false)])
        XCTAssertEqual(store.needsYouCount, 2, "floor before judging")

        let first = await store.judgeNeedsYou(engine: e)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(p.calls.count, 2, "bulk or read mail the floor excludes was asked about")
        XCTAssertEqual(ledger.recent.map(\.surface), ["mail.needsYou", "mail.needsYou"])
        XCTAssertEqual(store.needsYouCount, 1, "the receipt the engine read as asking nothing still counts")

        _ = await store.judgeNeedsYou(engine: e)
        XCTAssertEqual(p.calls.count, 2, "a judged message was asked about again")

        store.upsert([message(from: "marco@example.com", subject: "Saturday",
                              body: "Are we still on for dinner Saturday?")])
        _ = await store.judgeNeedsYou(engine: e)
        XCTAssertEqual(p.calls.count, 3, "a new message was not judged exactly once")
        XCTAssertEqual(store.needsYouCount, 2)
        XCTAssertEqual(store.needsYouCount, MailNeedsYou.count(store.messages), "the memo drifted from the count")
    }

    func test_aProviderThatCannotJudgeLeavesTheFloorAndIsNotRetried() async {
        let p = provider(); p.fail = true
        let e = engine(p, DecisionLedger(storeURL: nil))
        let store = MailStore(inMemory: [message(subject: "Your order has shipped",
                                                 body: "Your order #4821 has shipped.")])
        _ = await store.judgeNeedsYou(engine: e)
        XCTAssertEqual(store.messages.first?.needsYouProbability, 0.5, "on device must read as cannot judge")
        XCTAssertEqual(store.needsYouCount, 1, "an unjudgeable message left the badge")
        _ = await store.judgeNeedsYou(engine: e)
        XCTAssertEqual(p.calls.count, 1, "one attempt per message, never a retry loop")
    }

    func test_onlyAConfidentNoTakesAMessageOutAndNothingPutsOneIn() {
        func with(_ p: Double?, unread: Bool = true) -> EmailMessage {
            var m = message(unread: unread); m.needsYouProbability = p; return m
        }
        XCTAssertTrue(MailNeedsYou.counts(with(nil)))
        XCTAssertTrue(MailNeedsYou.counts(with(0.5)), "cannot judge must count")
        XCTAssertTrue(MailNeedsYou.counts(with(MailNeedsYou.dropBelow)))
        XCTAssertFalse(MailNeedsYou.counts(with(0.08)))
        XCTAssertFalse(MailNeedsYou.counts(with(0.99, unread: false)), "the engine raised mail the floor excludes")
    }
}

// MARK: - notify.triage

@MainActor
final class NotificationTriageEngineTests: XCTestCase {

    private func classifier() -> TriageClassifier {
        TriageClassifier(cacheURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-cache-\(UUID().uuidString).json"))
    }

    private func policies() -> TriagePolicyStore {
        TriagePolicyStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-policy-\(UUID().uuidString).json"))
    }

    /// "API key OK" reads silent and sure; a domain check reads interrupt but
    /// unsure, the two shapes measured live.
    private func provider() -> ScriptedProvider {
        ScriptedProvider { state, _, _ in
            state.contains("API key OK")
                ? .choice("silent", confidence: 0.87, probabilities: ["silent": 0.92])
                : .choice("interrupt", confidence: 0.62, probabilities: ["interrupt": 0.75])
        }
    }

    func test_keylessNeverLeavesTheSynchronousPathAndTheTableIsUnchanged() async {
        let p = provider(), ledger = DecisionLedger(storeURL: nil)
        let e = engine(key: "", p, ledger)
        let c = classifier()
        XCTAssertFalse(c.judgesContent(engine: e, enabled: true), "keyless would defer delivery into a Task")
        let judged = await c.judge(title: "API key OK", body: "Got reply: hi", engine: e)
        XCTAssertNil(judged)
        XCTAssertEqual(p.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0)
        let store = policies()
        for category in TriageCategory.allCases {
            for required in [false, true] {
                XCTAssertEqual(store.resolve(category: category, actionRequired: required, judged: nil),
                               TriagePolicyStore.resolve(base: store.action(for: category),
                                                         actionRequired: required, inQuietHours: false),
                               "\(category) required=\(required) changed without a judgment")
            }
        }
    }

    func test_oneCallPerDistinctNotificationAndAnUnsureAnswerIsTheFloor() async {
        let p = provider(), ledger = DecisionLedger(storeURL: nil)
        let e = engine(p, ledger)
        let c = classifier()
        XCTAssertTrue(c.judgesContent(engine: e, enabled: true))
        XCTAssertFalse(c.judgesContent(engine: e, enabled: false), "the person's switch is ignored")

        let ok = await c.judge(title: "API key OK", body: "Got reply: hi", engine: e)
        XCTAssertEqual(ok, .silent)
        let again = await c.judge(title: "API  key ok", body: "got reply: HI", engine: e)
        XCTAssertEqual(again, .silent)
        XCTAssertEqual(p.calls.count, 1, "the same words were judged twice")

        let unsure = await c.judge(title: "Domain check: example-shop.com", body: "12 days. Auto-renew is on.", engine: e)
        XCTAssertNil(unsure, "an answer under the confidence floor was used")
        _ = await c.judge(title: "Domain check: example-shop.com", body: "12 days. Auto-renew is on.", engine: e)
        XCTAssertEqual(p.calls.count, 2, "an unsure notification was asked about again")
        XCTAssertEqual(ledger.recent.map(\.surface), ["notify.triage", "notify.triage"])
        guard case .choice(_, let criteria)? = p.calls.first?.questions["action"] else {
            return XCTFail("the triage question is not a choice")
        }
        XCTAssertEqual(Set(criteria.keys), Set(TriageAction.allCases.map(\.rawValue)),
                       "the answers are not the three actions route consumes")
    }

    /// Two schedules failing on the same tick send the same words twice before
    /// the first answer is back. The second waits for the first call.
    func test_theSameWordsSentTwiceInOneRoundTripPayOneCall() async {
        let p = provider()
        let e = engine(p, DecisionLedger(storeURL: nil))
        let c = classifier()
        async let first = c.judge(title: "API key OK", body: "Got reply: hi", engine: e)
        async let second = c.judge(title: "API key OK", body: "Got reply: hi", engine: e)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, .silent)
        XCTAssertEqual(b, .silent)
        XCTAssertEqual(p.calls.count, 1, "two identical notifications in flight paid \(p.calls.count) calls")
    }

    func test_aLocalAnswerNeverGetsAVote() async {
        let p = provider(); p.fail = true
        let judged = await classifier().judge(title: "API key OK", body: "Got reply: hi",
                                              engine: engine(p, DecisionLedger(storeURL: nil)))
        XCTAssertNil(judged)
        XCTAssertEqual(p.calls.count, 1)
    }

    /// The judgment replaces the category row for one notification, and
    /// nothing else in the table: a blocker still interrupts, quiet hours
    /// still hold.
    func test_aJudgmentReplacesTheRowButNotTheBlockerOrQuietHours() {
        let store = policies()
        XCTAssertEqual(store.resolve(category: .reminders, actionRequired: false, judged: .silent), .silent)
        XCTAssertEqual(store.resolve(category: .system, actionRequired: false, judged: .interrupt), .interrupt)
        XCTAssertEqual(store.resolve(category: .system, actionRequired: true, judged: .silent), .interrupt,
                       "a judged silent swallowed a blocker the rules caught")
        store.quietHours = TriageQuietHours(enabled: true, startMinute: 0, endMinute: 24 * 60 - 1)
        let midday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(store.resolve(category: .system, actionRequired: false, judged: .interrupt, at: midday), .batch,
                       "a judged interrupt broke quiet hours")
    }
}

// MARK: - email.classify

@MainActor
final class EmailClassifyEngineTests: XCTestCase {

    private let msg = InboxMessage(fromName: "Drew Hall", fromEmail: "drew.hall@inboxmail.com",
                                   subject: "Final notice",
                                   preview: "If I don't hear back today I'm filing a chargeback with my bank.",
                                   messageId: "")

    private func provider(category: String = "refund", categoryConfidence: Double = 0.86,
                          urgency: String = "high", urgencyConfidence: Double = 1.0,
                          review: Double = 0.97) -> ScriptedProvider {
        ScriptedProvider { _, name, _ in
            switch name {
            case "category": return .choice(category, confidence: categoryConfidence, probabilities: [:])
            case "urgency": return .choice(urgency, confidence: urgencyConfidence, probabilities: [:])
            default: return .noul(review)
            }
        }
    }

    func test_keylessAsksNothingSoTheCombinedCallRunsAsBefore() async {
        let p = provider(), ledger = DecisionLedger(storeURL: nil)
        let c = await EmailTriageEngine.classifyOnEngine(msg: msg, engine: engine(key: "", p, ledger))
        XCTAssertNil(c, "keyless must fall through to the combined text-model call")
        XCTAssertEqual(p.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0)
    }

    func test_oneCallCarriesAllThreeQuestions() async {
        let p = provider(), ledger = DecisionLedger(storeURL: nil)
        let c = await EmailTriageEngine.classifyOnEngine(msg: msg, engine: engine(p, ledger))
        XCTAssertEqual(c, EmailTriageEngine.EngineClassification(category: .refund, urgency: .high, needsReview: true))
        XCTAssertEqual(p.calls.count, 1)
        XCTAssertEqual(p.calls.first?.questions.keys.sorted(), ["category", "review", "urgency"])
        XCTAssertEqual(ledger.recent.map(\.surface), ["email.classify"])
        XCTAssertTrue(p.calls.first?.state.contains("chargeback") == true, "the email never reached the question")
    }

    func test_anUnsureCategoryOrALocalAnswerFallsBackToTheCombinedCall() async {
        let unsure = provider(category: "shipping", categoryConfidence: 0.37)
        let a = await EmailTriageEngine.classifyOnEngine(msg: msg, engine: engine(unsure, DecisionLedger(storeURL: nil)))
        XCTAssertNil(a, "a 0.37 category was trusted")
        let down = provider(); down.fail = true
        let b = await EmailTriageEngine.classifyOnEngine(msg: msg, engine: engine(down, DecisionLedger(storeURL: nil)))
        XCTAssertNil(b, "keyword overlap on the email was taken as a classification")
    }

    /// A message stays unread, and every hourly sweep sees it again, when its
    /// category is filtered or its draft failed. It is asked about once. The
    /// cache is in memory on the triage engine and keyed by a subject made
    /// unique here, so this test touches no operator state.
    func test_aMessageASweepSeesAgainIsAskedOnce() async {
        let fresh = InboxMessage(fromName: "Avery Cole", fromEmail: "avery.cole@inboxmail.com",
                                 subject: "Says delivered but it's not here \(UUID().uuidString)",
                                 preview: "Tracking says delivered yesterday but it is not at my door.", messageId: "")
        let keyless = provider()
        let none = await EmailTriageEngine.shared.classifyOnce(msg: fresh,
                                                               engine: engine(key: "", keyless, DecisionLedger(storeURL: nil)))
        XCTAssertNil(none)
        XCTAssertEqual(keyless.calls.count, 0)

        let p = provider(category: "shipping", categoryConfidence: 1.0)
        let e = engine(p, DecisionLedger(storeURL: nil))
        let first = await EmailTriageEngine.shared.classifyOnce(msg: fresh, engine: e)
        let again = await EmailTriageEngine.shared.classifyOnce(msg: fresh, engine: e)
        XCTAssertEqual(first?.category, .shipping, "a keyless miss was cached and hid the key added later")
        XCTAssertEqual(again, first)
        XCTAssertEqual(p.calls.count, 1, "a message the sweep saw again was asked again")

        var followUp = fresh
        followUp.preview = "Still nothing. I want my money back or I'm filing a chargeback."
        _ = await EmailTriageEngine.shared.classifyOnce(msg: followUp, engine: e)
        XCTAssertEqual(p.calls.count, 2, "a follow-up with new words reused the old answer")
    }

    func test_theOutputContractAndTheRefundRuleHold() async {
        let p = provider(category: "shipping", categoryConfidence: 1.0, urgency: "high", urgencyConfidence: 0.25,
                         review: 0.35)
        let c = await EmailTriageEngine.classifyOnEngine(msg: msg, engine: engine(p, DecisionLedger(storeURL: nil)))
        XCTAssertEqual(c?.urgency, .normal, "an unsure urgency must be the ordinary default")
        XCTAssertEqual(c?.needsReview, false)

        let refund = EmailTriageEngine.EngineClassification(category: .refund, urgency: .low, needsReview: false)
        XCTAssertEqual(EmailTriageEngine.merged(refund, reply: "Hi", draftNeedsReview: false),
                       EmailTriageEngine.TriageResult(category: .refund, urgency: .normal, needsReview: true, reply: "Hi"),
                       "a refund went out without a human read")
        let calm = EmailTriageEngine.EngineClassification(category: .shipping, urgency: .normal, needsReview: false)
        XCTAssertTrue(EmailTriageEngine.merged(calm, reply: "Hi", draftNeedsReview: true).needsReview,
                      "the drafter's own review flag was dropped")
    }
}

// MARK: - focus.drift + focus.interrupt

@MainActor
final class CoachEngineTests: XCTestCase {

    private let context = AmbientCoach.CoachContext(
        task: "Quarterly revenue report", project: "Finance",
        intents: ["finish the revenue report before lunch"],
        heard: "", heardJustNow: "",
        onScreen: "Safari - YouTube - Funniest cat compilation 2026",
        before: ["2 min ago: Safari - YouTube - Cats vs cucumbers", "6 min ago: Microsoft Excel - Q3 revenue.xlsx"],
        minutesSinceSpoke: 40)

    private func provider(drift: Double, moment: Double) -> ScriptedProvider {
        ScriptedProvider { _, name, _ in .noul(name.hasSuffix("drifted") ? drift : moment) }
    }

    func test_keylessAsksNothingAndTheNudgeGoesAhead() async {
        let p = provider(drift: 0.0, moment: 0.0), ledger = DecisionLedger(storeURL: nil)
        let hold = await AmbientCoach.judge(context, engine: engine(key: "", p, ledger))
        XCTAssertEqual(hold, .none, "a keyless install held back a nudge it used to speak")
        XCTAssertEqual(p.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0)
    }

    /// Both questions fire on the same tick, so they share one event: one call,
    /// one ledger row naming both gates, the drift gate's state byte for byte,
    /// and the moment gate's context in front of its own instructions only.
    func test_bothQuestionsShareOneEventAndOneCall() async throws {
        let p = provider(drift: 0.85, moment: 0.62), ledger = DecisionLedger(storeURL: nil)
        let e = engine(p, ledger)
        let hold = await AmbientCoach.judge(context, engine: e)
        XCTAssertEqual(hold, .none)
        XCTAssertEqual(p.calls.count, 1, "the tick paid \(p.calls.count) round trips")
        XCTAssertEqual(e.batchViolations, [])
        XCTAssertEqual(ledger.recent.map(\.surface), ["focus.drift+focus.interrupt"])
        let call = try XCTUnwrap(p.calls.first)
        XCTAssertEqual(call.state, AmbientCoach.driftState(context), "another gate's context leaked into the state")
        guard case .noul(let driftI)? = call.questions["focus_drift__drifted"],
              case .noul(let momentI)? = call.questions["focus_interrupt__good_moment"] else {
            return XCTFail("the two questions are not on the call")
        }
        XCTAssertEqual(driftI, AmbientCoach.driftInstructions)
        XCTAssertTrue(momentI.hasPrefix(AmbientCoach.momentContext(context)), "the moment gate lost its own context")
        XCTAssertFalse(call.state.contains("Grux last spoke up"), "the moment context entered the shared state")
    }

    func test_theEngineMayOnlyHoldANudgeBack() async {
        let onTask = await AmbientCoach.judge(context, engine: engine(provider(drift: 0.09, moment: 0.7),
                                                                     DecisionLedger(storeURL: nil)))
        XCTAssertEqual(onTask, .onTask(0.09))
        let onACall = await AmbientCoach.judge(context, engine: engine(provider(drift: 0.85, moment: 0.10),
                                                                      DecisionLedger(storeURL: nil)))
        XCTAssertEqual(onACall, .badMoment(0.10))
        XCTAssertEqual(AmbientCoach.hold(drift: .noul(0.0), moment: .noul(0.0), provider: .local), .none,
                       "an on-device answer held a nudge")
        XCTAssertEqual(AmbientCoach.hold(drift: nil, moment: nil, provider: nil), .none)
    }

    func test_aFailingProviderIsTheFloor() async {
        let p = provider(drift: 0.0, moment: 0.0); p.fail = true
        let hold = await AmbientCoach.judge(context, engine: engine(p, DecisionLedger(storeURL: nil)))
        XCTAssertEqual(hold, .none)
        XCTAssertEqual(p.calls.count, 1, "one attempt, never a retry loop")
    }

    func test_recentActivityIsTheLastFifteenMinutesWithRepeatsFolded() {
        let now = Date()
        func ev(_ app: String, _ window: String, minutesAgo: Double) -> FocusEvent {
            FocusEvent(timestamp: now.addingTimeInterval(-minutesAgo * 60), currentTaskId: nil,
                       currentTaskTitle: "t", activeApp: app, windowTitle: window, verdict: .drifting,
                       confidence: 0.9, rationale: "", suggestedTaskId: nil, suggestedTaskTitle: nil,
                       screenTextSnippet: "")
        }
        let current = ev("Safari", "YouTube", minutesAgo: 0)
        let events = [current, ev("Safari", "YouTube", minutesAgo: 1), ev("Safari", "YouTube", minutesAgo: 2),
                      ev("Excel", "", minutesAgo: 6), ev("Xcode", "Old.swift", minutesAgo: 20)]
        XCTAssertEqual(AmbientCoach.recentScreens(events, excluding: current.id, now: now),
                       ["1 min ago: Safari - YouTube", "6 min ago: Excel"])
    }
}
