import XCTest
@testable import Grux

/// Phase R, P-R-1: one provider call per judged event.
///
/// Measured 2026-09-21: a spoken request that went on to Chat paid two
/// sequential Jev round trips on one utterance, the voice decision (p50 444 ms)
/// and then `chat.intent` inside `ChatService.send`. Six questions in one call
/// return as fast as one. Acceptance criterion 1 of the backend decision record:
/// a test fails if a gate opens its own round trip when a batched one was
/// available. That is `test_aSpokenRequestThatGoesToChatPaysOneCall`.
@MainActor
final class DecisionEventTests: XCTestCase {

    /// A provider that answers the questions it is ASKED, by name, and counts
    /// calls. `choice` picks `say:chat` when offered, `noul` answers 0.9.
    final class Counting: DecisionProvider, @unchecked Sendable {
        let kind: DecisionProviderKind = .jev
        var calls: [(state: String, names: [String], questions: [String: DecisionQuestion])] = []
        var fail = false
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            calls.append((state, questions.keys.sorted(), questions))
            if fail { throw JevDecisionProvider.Failure.http(503) }
            var out: [String: DecisionAnswer] = [:]
            for (name, q) in questions {
                switch q {
                case .choice(_, let criteria):
                    let pick = criteria[VoiceCommandRouter.sayToChat] != nil ? VoiceCommandRouter.sayToChat
                        : criteria.keys.sorted().first ?? ""
                    out[name] = .choice(pick, confidence: 0.95, probabilities: [pick: 0.95])
                case .noul: out[name] = .noul(0.9)
                case .score: out[name] = .score(1, confidence: 0.9)
                }
            }
            return DecisionResult(answers: out, latencyMs: 400, inputTokens: 500, outputTokens: 40, provider: .jev)
        }
    }

    private func engine(key: String = "k", provider: Counting, ledger: DecisionLedger) -> DecisionEngine {
        DecisionEngine(keyLookup: { key }, ledger: ledger, remote: { _ in provider })
    }

    /// The headline. A spoken calendar ask is addressed to Grux (so it goes
    /// to Chat) and Chat's pattern matcher finds a plan (so Chat's gate has a
    /// question). One call must answer both. (A note was the fixture until
    /// ruling 0v took notes off the judge: they no longer add a question.)
    func test_aSpokenRequestThatGoesToChatPaysOneCall() async throws {
        let provider = Counting()
        let ledger = DecisionLedger(storeURL: nil)
        let e = engine(provider: provider, ledger: ledger)
        let r = VoiceCommandRouter(engine: e, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        let words = "add lunch with Sarah to my calendar on Friday at 1 PM"
        let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: words), "the fixture phrase stopped matching")
        XCTAssertTrue(plan.kind.isJudged, "the fixture must be a kind Chat's gate still judges")
        var chatDecision: ChatIntentClassifier.PIMRouteDecision?
        // Chat's real gate logic, the function ChatService.send calls.
        r.sendToChatDecided = { text, pre in
            chatDecision = await ChatIntentClassifier.resolvePIM(plan: plan, utterance: text, preDecided: pre,
                                                                 engine: e, threshold: 0.70)
        }

        let event = await r.consider(chunk: "hey grux " + words)
        await r.chatHandOff?.value

        XCTAssertEqual(event?.outcome, .executed)
        XCTAssertEqual(provider.calls.count, 1, "a spoken request paid \(provider.calls.count) round trips")
        XCTAssertEqual(e.batchViolations, [], "a gate opened its own round trip while its event was open")
        XCTAssertEqual(chatDecision?.confirmed, true)
        XCTAssertEqual(chatDecision?.confidence ?? 0, 0.9, accuracy: 0.0001, "Chat did not get the event's answer")
        XCTAssertEqual(ledger.recent.map(\.surface), ["voice+chat.intent"],
                       "one ledger row per event, naming every gate on it")
        XCTAssertEqual(provider.calls.first?.names, ["chat_intent__meant", "voice__intent"])
    }

    /// The live finding this shape rests on. With Chat's "Grux is about to do
    /// this" inside the shared state, Jev read an unaddressed "note that ..."
    /// as addressed to Grux (`not_a_command 0.97` became `say:chat 0.66`). The
    /// shared state must be the voice gate's own state byte for byte, and
    /// Chat's context must reach Chat's question and no other.
    func test_aSecondGatesContextNeverEntersTheSharedState() async throws {
        let provider = Counting()
        let e = engine(provider: provider, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: e, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        r.sendToChatDecided = { _, _ in }
        let words = "add lunch with Sarah to my calendar on Friday at 1 PM"
        let plan = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: words))
        XCTAssertTrue(plan.kind.isJudged, "the fixture must be a kind Chat's gate still judges")
        _ = await r.consider(chunk: words)
        let call = try XCTUnwrap(provider.calls.first)
        XCTAssertEqual(call.state, "Heard: \(words)", "another gate's context leaked into the shared state")
        guard case .noul(let chatInstructions)? = call.questions["chat_intent__meant"],
              case .choice(let voiceInstructions, _)? = call.questions["voice__intent"] else {
            return XCTFail("the two questions are not on the call")
        }
        XCTAssertTrue(chatInstructions.hasPrefix(ChatIntentClassifier.pimState(plan: plan, utterance: words)),
                      "Chat's question lost its own context")
        XCTAssertEqual(voiceInstructions, VoiceCommandRouter.instructions,
                       "the voice question carries something other than its own instructions")
    }

    /// A34, live 2026-09-28 with a decision key: "Grux, take a note the blue
    /// folder is in the top drawer" came back `tab:notes 0.73` and only opened
    /// the Notes pane, so no note was taken. Words the PIM matcher turned into
    /// a plan ask for that action, never for a pane, so the voice question
    /// offers no pane to pick. A bare "open notes" still gets its pane.
    func test_aPIMAskIsNeverOfferedAPane() async throws {
        let provider = Counting()
        let e = engine(provider: provider, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: e, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        r.sendToChatDecided = { _, _ in }
        for words in ["take a note the blue folder is in the top drawer",
                      "add lunch with Sarah to my calendar on Friday at 1 PM"] {
            _ = try XCTUnwrap(ChatIntentClassifier.pimRoute(utterance: words), "\(words) stopped matching")
            provider.calls = []
            _ = await r.consider(chunk: "grux " + words)
            // A note carries no Chat question (ruling 0v), so the voice question
            // rides alone and is not namespaced.
            let questions = provider.calls.first?.questions ?? [:]
            guard case .choice(_, let criteria)? = questions["voice__intent"] ?? questions["intent"] else {
                return XCTFail("no voice question for \(words)")
            }
            XCTAssertEqual(criteria.keys.filter { $0.hasPrefix("tab:") }, [], "\(words) was offered a pane")
            XCTAssertNotNil(criteria[VoiceCommandRouter.sayToChat], "\(words) lost the way to Chat")
        }
        // The control, outside any `if let` (RV28): a bare "open notes" still decides
        // for its pane. It was guarded by `if let call = provider.calls.first`, and the
        // exact phrase settles on device without a provider call, so the assertion
        // never ran. The decision itself is what must name the pane.
        let decided = await r.consider(chunk: "grux open notes", dryRun: .everything)
        let open = try XCTUnwrap(decided, "open notes made no decision")
        XCTAssertEqual(open.commandId, "tab:notes", "a plain pane command lost its pane")
    }

    /// The detector itself: a covered surface deciding directly while its event
    /// is open is recorded; an uncovered one is not; after close, nothing is.
    func test_aGateThatOpensItsOwnCallInsideAnEventIsCaught() async {
        let e = engine(key: "", provider: Counting(), ledger: DecisionLedger(storeURL: nil))
        let event = e.open(origin: "test", state: "s", covering: ["x"])
        _ = await e.decide(surface: "x", state: "s", questions: ["q": .noul(instructions: "i")])
        _ = await e.decide(surface: "y", state: "s", questions: ["q": .noul(instructions: "i")])
        e.close(event)
        _ = await e.decide(surface: "x", state: "s", questions: ["q": .noul(instructions: "i")])
        XCTAssertEqual(e.batchViolations, ["x"])
    }

    func test_aBatchOfNQuestionsIsOneCallAndOneLedgerRowNamingEveryGate() async {
        let provider = Counting()
        let ledger = DecisionLedger(storeURL: nil)
        let e = engine(provider: provider, ledger: ledger)
        let event = e.open(origin: "test", state: "first", covering: ["a", "b.c", "d"])
        event.ask("a", ["q1": .noul(instructions: "i"), "q2": .score(instructions: "i", levels: ["lo", "hi"])])
        event.ask("b.c", context: "second", ["q1": .noul(instructions: "i")])
        event.ask("d", context: "third", ["pick": .choice(instructions: "i", criteria: ["one": "1", "two": "2"])])
        await e.resolve(event)
        e.close(event)
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(ledger.recent.count, 1)
        XCTAssertEqual(ledger.recent.first?.surface, "a+b.c+d")
        XCTAssertEqual(ledger.recent.first?.inputTokens, 500)
        // Each gate reads its own answers under its own names, and two gates
        // asking the same name do not collide.
        XCTAssertEqual(event.answer("a", "q1"), .noul(0.9))
        XCTAssertEqual(event.answer("b.c", "q1"), .noul(0.9))
        XCTAssertNotNil(event.answer("a", "q2"))
        XCTAssertNotNil(event.answer("d", "pick"))
        XCTAssertEqual(provider.calls[0].state, "first", "the shared state is the event's own, nothing added")
        XCTAssertEqual(provider.calls[0].questions["b_c__q1"], .noul(instructions: "second\ni"))
        XCTAssertEqual(provider.calls[0].questions["a__q1"], .noul(instructions: "i"))
    }

    /// Criterion 5: a keyless install behaves exactly as it does today. Every
    /// gate is answered on device against ITS OWN context, the same answer its
    /// direct call gives, never against a combined state.
    func test_keylessEventAnswersEveryGateAsItsDirectCallWould() async {
        let e = engine(key: "", provider: Counting(), ledger: DecisionLedger(storeURL: nil))
        let criteria = ["tab:calendar": "open my calendar | show calendar", "not_a_command": "nothing"]
        let voiceQ: [String: DecisionQuestion] = ["intent": .choice(instructions: "i", criteria: criteria)]
        let chatQ = ChatIntentClassifier.pimQuestions
        for heard in ["Heard: open my calendar", "Heard: so anyway lunch", "Heard: show calendar please"] {
            let direct = await e.decide(surface: "voice", state: heard, questions: voiceQ)
            let event = e.open(origin: "test", state: heard, covering: ["voice", "chat.intent"])
            event.ask("voice", voiceQ)
            event.ask("chat.intent", context: "The person said: open my calendar tomorrow", chatQ)
            await e.resolve(event)
            e.close(event)
            XCTAssertEqual(event.provider, .local)
            XCTAssertEqual(event.answer("voice", "intent"), direct.answers["intent"], "keyless answer changed for \(heard)")
            XCTAssertEqual(event.answer("chat.intent", "meant"), .noul(0.5), "on device a yes/no still cannot judge")
        }
    }

    /// A provider failure is not a refusal: every gate gets its on-device
    /// answer, the event still records one row.
    func test_aFailingProviderFallsBackPerGateOnDevice() async {
        let provider = Counting(); provider.fail = true
        let ledger = DecisionLedger(storeURL: nil)
        let e = engine(provider: provider, ledger: ledger)
        let event = e.open(origin: "test", state: "Heard: open my calendar", covering: ["a", "b"])
        event.ask("a", ["intent": .choice(instructions: "i", criteria: ["tab:calendar": "open my calendar"])])
        event.ask("b", context: "x", ["meant": .noul(instructions: "i")])
        await e.resolve(event)
        e.close(event)
        XCTAssertEqual(provider.calls.count, 1, "one attempt, never a retry loop")
        XCTAssertEqual(event.provider, .local)
        XCTAssertEqual(event.answer("b", "meant"), .noul(0.5))
        if case .choice(let id, _, _)? = event.answer("a", "intent") { XCTAssertEqual(id, "tab:calendar") }
        else { XCTFail("gate a got no on-device answer") }
        XCTAssertEqual(ledger.recent.map(\.surface), ["a+b"])
    }

    /// A lone gate on an event sends exactly what its old direct call sent.
    func test_aLoneGateIsIdenticalOnTheWire() async {
        let provider = Counting()
        let e = engine(provider: provider, ledger: DecisionLedger(storeURL: nil))
        let event = e.open(origin: "test", state: "Heard: open my calendar", covering: ["voice"])
        event.ask("voice", ["intent": .noul(instructions: "i")])
        await e.resolve(event)
        e.close(event)
        _ = await e.decide(surface: "voice", state: "Heard: open my calendar", questions: ["intent": .noul(instructions: "i")])
        XCTAssertEqual(provider.calls.count, 2)
        XCTAssertEqual(provider.calls[0].state, provider.calls[1].state)
        XCTAssertEqual(provider.calls[0].names, provider.calls[1].names)
    }
}
