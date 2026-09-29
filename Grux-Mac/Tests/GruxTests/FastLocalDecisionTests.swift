import XCTest
@testable import Grux

/// The on-device fast path: when the person has said a command outright, act
/// on it without the network round trip.
///
/// WHY, measured from `wake.log` on 2026-09-23 over 603 real decisions:
///
///     jev    n=581  median=368ms  p90=872ms  max=2369ms
///     local  n=22   median=3ms    p90=7ms    max=10ms
///
/// About 120 times faster. Every one of those 22 local answers was a
/// `not_a_command` fallback, because `DecisionEngine` sent every decision to
/// the provider whenever a key was present and only answered on device when
/// the call failed. So the fast path existed and no command had ever taken it.
///
/// The risk this file exists to pin down is the opposite one. Acting on a
/// local answer too eagerly is how "we should mute the group chat" mutes the
/// microphone. The bar is therefore an EXACT phrase covering at least half of
/// what was said, which is the same bar every keyless install already executes
/// on, AND at least the person's own listening threshold. Everything below it
/// still goes to the provider, so nothing that used to be judged on meaning
/// stops being judged on meaning.
@MainActor
final class FastLocalDecisionTests: XCTestCase {

    /// Counts calls so a test can prove the network was NOT reached.
    final class Counting: DecisionProvider, @unchecked Sendable {
        let kind: DecisionProviderKind = .jev
        var calls = 0
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            calls += 1
            var out: [String: DecisionAnswer] = [:]
            for (name, q) in questions {
                switch q {
                case .choice(_, let criteria):
                    let pick = criteria.keys.sorted().first ?? ""
                    out[name] = .choice(pick, confidence: 0.99, probabilities: [pick: 0.99])
                case .noul: out[name] = .noul(0.9)
                case .score: out[name] = .score(1, confidence: 0.9)
                }
            }
            return DecisionResult(answers: out, latencyMs: 368, inputTokens: 500, outputTokens: 40, provider: .jev)
        }
    }

    private let criteria = [
        "tab:calendar": "open calendar",
        "tab:notes": "open notes",
        LocalDecisionProvider.notACommand: "nothing for Grux to do",
    ]

    private func run(said: String,
                     minConfidence: Double = 0.95,
                     neverFast: Set<String> = [],
                     optIn: Bool = true) async -> (calls: Int, provider: DecisionProviderKind?, answer: DecisionAnswer?) {
        let p = Counting()
        let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in p })
        let event = e.open(origin: "t", state: "\(LocalDecisionProvider.heardPrefix)\(said)", covering: ["t"])
        defer { e.close(event) }
        if optIn {
            event.fastLocal = DecisionEvent.FastLocalPath(
                gate: "t", question: "intent", minConfidence: minConfidence, neverFast: neverFast)
        }
        event.ask("t", ["intent": .choice(instructions: "which command", criteria: criteria)])
        await e.resolve(event)
        return (p.calls, event.provider, event.answer("t", "intent"))
    }

    // MARK: - The win

    /// The headline: a command said outright never reaches the network.
    func test_aCommandSaidOutrightNeverReachesTheProvider() async {
        let r = await run(said: "open calendar")
        XCTAssertEqual(r.calls, 0, "the provider was called for a command the device had already recognised exactly. That is the 368ms this whole path exists to remove.")
        XCTAssertEqual(r.provider, .local)
        guard case .choice(let id, let conf, _)? = r.answer else { return XCTFail("no choice answer") }
        XCTAssertEqual(id, "tab:calendar")
        XCTAssertGreaterThanOrEqual(conf, 0.95)
    }

    // MARK: - Everything that must still go to the provider

    /// A paraphrase is exactly what a provider is FOR. The device cannot match
    /// it, so it must not get a vote.
    func test_aParaphraseStillReachesTheProvider() async {
        let r = await run(said: "could you bring up my schedule for me please")
        XCTAssertEqual(r.calls, 1, "a paraphrase settled on device. The device cannot judge meaning, so this is how a real request gets silently dropped.")
        XCTAssertEqual(r.provider, .jev)
    }

    /// Room talk must keep reaching the provider too. Short-circuiting the
    /// negative case would be faster still, but it would mean the device
    /// deciding on its own that something was not meant for Grux, and it is
    /// not good enough at that to be given the last word.
    func test_roomTalkStillReachesTheProvider() async {
        let r = await run(said: "I was thinking about the weather this morning")
        XCTAssertEqual(r.calls, 1, "the device settled a not_a_command on its own; a real request phrased unusually would be dropped the same way.")
    }

    /// The buried-phrase case, which is the one that mutes a microphone when
    /// it goes wrong. The phrase IS present but covers a fraction of the
    /// sentence, so the device scores it 0.4 and must defer.
    func test_aCommandPhraseBuriedInASentenceStillReachesTheProvider() async {
        let r = await run(said: "I told you that Grux can open calendar entries for me and it worked")
        XCTAssertEqual(r.calls, 1, "a buried command phrase settled on device. This is the 'we should mute the group chat' failure.")
    }

    /// An option named in `neverFast` is not a specific command and must never
    /// settle on device however certain the matcher is.
    func test_anOptionNamedNeverFastAlwaysReachesTheProvider() async {
        let r = await run(said: "open calendar", neverFast: ["tab:calendar"])
        XCTAssertEqual(r.calls, 1, "neverFast was ignored, so an option that only means something after the provider has judged it was acted on locally.")
    }

    /// The person's own listening threshold raises the bar. Settling at 0.95
    /// under a 0.99 threshold would turn a command Grux used to obey, after
    /// the provider returned 0.99, into one it ignores.
    func test_aHigherListeningThresholdRaisesTheBar() async {
        let r = await run(said: "open calendar", minConfidence: 0.99)
        XCTAssertEqual(r.calls, 1, "the fast path settled below the caller's own threshold, so it turned an executed command into an ignored one.")
    }

    /// Every other surface is untouched. An approval, an agent judgment or a
    /// meeting moment does not opt in and must behave exactly as before.
    func test_aSurfaceThatDidNotOptInAlwaysReachesTheProvider() async {
        let r = await run(said: "open calendar", optIn: false)
        XCTAssertEqual(r.calls, 1, "an event that never set fastLocal skipped the provider. The opt-in is what keeps this change confined to the voice path.")
        XCTAssertEqual(r.provider, .jev)
    }

    /// With no key nothing changes: the keyless install already answered on
    /// device and must not now be making calls or behaving differently.
    func test_aKeylessInstallIsUnchanged() async {
        let p = Counting()
        let e = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in p })
        let event = e.open(origin: "t", state: "\(LocalDecisionProvider.heardPrefix)open calendar", covering: ["t"])
        defer { e.close(event) }
        event.fastLocal = DecisionEvent.FastLocalPath(gate: "t", question: "intent", minConfidence: 0.95, neverFast: [])
        event.ask("t", ["intent": .choice(instructions: "which command", criteria: criteria)])
        await e.resolve(event)
        XCTAssertEqual(p.calls, 0)
        XCTAssertEqual(event.provider, .local)
    }

    // MARK: - Through the real router

    /// The integration, so the opt-in is proved to be wired and not just
    /// available. Uses the router's OWN vocabulary rather than a hardcoded
    /// phrase, so renaming a sidebar label cannot make this test lie.
    func test_theVoiceRouterActuallyOptsIn() async throws {
        let p = Counting()
        let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in p })
        let r = VoiceCommandRouter(engine: e, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        var navigated: String?
        r.navigate = { navigated = $0 }

        let cmd = try XCTUnwrap(r.vocabulary().first { $0.id == "tab:calendar" },
                                "the calendar tab command disappeared from the vocabulary")
        let phrase = try XCTUnwrap(cmd.phrases.first, "the calendar command has no phrases")

        let event = await r.consider(chunk: phrase)
        XCTAssertEqual(p.calls, 0, "saying \"\(phrase)\" still paid a provider round trip, so the router is not opted in.")
        XCTAssertEqual(event?.provider, .local)
        XCTAssertEqual(event?.commandId, "tab:calendar")
        XCTAssertEqual(navigated, "calendar", "the command was recognised on device but never ran")
    }

    /// The router must take the HIGHER of the exact-phrase floor and the
    /// person's own threshold. With the threshold above the floor, the same
    /// phrase has to go to the provider, or the fast path has quietly lowered
    /// a bar the person raised on purpose.
    func test_theRouterRespectsAListeningThresholdAboveTheFloor() async throws {
        let p = Counting()
        let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in p })
        let r = VoiceCommandRouter(engine: e, threshold: { 0.99 }, macros: { [] })
        r.recentReply = { nil }
        r.navigate = { _ in }
        let cmd = try XCTUnwrap(r.vocabulary().first { $0.id == "tab:calendar" })
        let phrase = try XCTUnwrap(cmd.phrases.first)
        _ = await r.consider(chunk: phrase)
        XCTAssertEqual(p.calls, 1, """
            the router settled on device at the 0.95 floor while the person's listening \
            threshold was 0.99, so it skipped a call that could have returned 0.99 and \
            turned a command Grux would have obeyed into one it ignores.
            """)
    }
}
