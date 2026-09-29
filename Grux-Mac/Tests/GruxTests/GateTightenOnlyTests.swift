import XCTest
@testable import Grux

/// THE SNIFFERS ARE THE FLOOR. A PROVIDER MAY ONLY RAISE THE VERDICT.
///
/// The gate's keyword sniffers are the part that keeps working when the
/// network is down, the key is wrong, or the provider has been talked into
/// something by the very content it is judging. A model that is certain a wire
/// transfer is routine must change nothing.
@MainActor
final class GateTightenOnlyTests: XCTestCase {

    private struct Says: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        let rule: String
        let confidence: Double
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            DecisionResult(answers: ["rule": .choice(rule, confidence: confidence, probabilities: [rule: confidence])],
                           latencyMs: 380, inputTokens: 200, outputTokens: 0, provider: .jev)
        }
    }

    private func engine(_ rule: String, _ confidence: Double) -> DecisionEngine {
        DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in Says(rule: rule, confidence: confidence) })
    }

    private var ordinary: ProposedAction {
        ProposedAction(kind: .other, summary: "File a note about the printer", target: "notes")
    }

    // MARK: - The ordering that makes tighten-only mean something

    func test_theHoldScaleOrdersTheVerdicts() {
        XCTAssertLessThan(GateHold.proceed, GateHold.queue)
        XCTAssertLessThan(GateHold.queue, GateHold.refuse)
        XCTAssertEqual(DecisionGate.hold(of: .proceed), .proceed)
        XCTAssertEqual(DecisionGate.hold(of: .refuse(reason: "x")), .refuse)
        XCTAssertEqual(DecisionGate.hold(of: .queueForApproval(
            PendingApproval(action: ordinary, urgent: false, persona: .none, reason: "r"))), .queue)
    }

    func test_raisingNeverLowersAnything() {
        let refusal = GateVerdict.refuse(reason: "the original reason")
        let out = DecisionGate.raisedToRefusal(refusal, reason: "a different reason")
        XCTAssertEqual(out, refusal, "a refusal was rewritten by a second opinion")
    }

    // MARK: - What the engine may and may not do

    func test_aConfidentProviderRaisesAMissedPublicPostToARefusal() async {
        // A surface nobody put on the keyword list. The sniffers let it queue,
        // which is a card the user can tap through, and GUARDRAIL 3 says there
        // is deliberately no one-tap path to publishing as them at all.
        let action = ProposedAction(kind: .other, summary: "Share the launch note on Bluesky", target: "bluesky")
        let sniffed = DecisionGate.shared.evaluate(action)
        XCTAssertEqual(DecisionGate.hold(of: sniffed), .queue, "the sniffers changed and this is no longer the gap")
        let tightened = await DecisionGate.shared.tightened(
            sniffed, for: action, engine: engine(DecisionGate.publicPostOption, 0.95), threshold: 0.70)
        XCTAssertEqual(DecisionGate.hold(of: tightened), .refuse)
    }

    func test_aProviderCertainSomethingIsFineCannotLoosenTheGate() async {
        let wire = ProposedAction(kind: .spend, summary: "Wire the deposit", target: "vendor",
                                  isSpend: true, detail: ["amount_cents": "500000"])
        let sniffed = DecisionGate.shared.evaluate(wire)
        XCTAssertEqual(DecisionGate.hold(of: sniffed), .queue)
        // The provider answers "neither of the two never-rules", at full
        // confidence. That is true and it is also not permission to proceed.
        let tightened = await DecisionGate.shared.tightened(
            sniffed, for: wire, engine: engine(DecisionGate.neitherOption, 1.0), threshold: 0.70)
        XCTAssertEqual(tightened, sniffed, "a confident provider loosened a spend")
    }

    func test_anUnsureProviderChangesNothing() async {
        let action = ProposedAction(kind: .other, summary: "Share the launch note on Bluesky", target: "bluesky")
        let sniffed = DecisionGate.shared.evaluate(action)
        let tightened = await DecisionGate.shared.tightened(
            sniffed, for: action, engine: engine(DecisionGate.publicPostOption, 0.42), threshold: 0.70)
        XCTAssertEqual(tightened, sniffed)
    }

    func test_onDeviceCannotInvokeAHardRefusal() async {
        // The local provider scores keyword overlap on the very text it is
        // judging. That is not a basis for a rule with no one-tap path.
        let action = ProposedAction(kind: .other, summary: "publishing publicly as the user", target: "bluesky")
        let sniffed = DecisionGate.shared.evaluate(action)
        let local = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let tightened = await DecisionGate.shared.tightened(sniffed, for: action, engine: local, threshold: 0.70)
        XCTAssertEqual(tightened, sniffed, "the on-device matcher raised a hard refusal")
    }

    func test_anAlreadyRefusedActionIsNotPaidForAgain() async {
        var asked = false
        struct Spy: DecisionProvider {
            let kind: DecisionProviderKind = .jev
            let onAsk: @Sendable () -> Void
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
                onAsk()
                return DecisionResult(answers: [:], latencyMs: 0, inputTokens: 0, outputTokens: 0, provider: .jev)
            }
        }
        let e = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil),
                               remote: { _ in Spy(onAsk: { asked = true }) })
        _ = await DecisionGate.shared.tightened(.refuse(reason: "already refused"), for: ordinary,
                                                engine: e, threshold: 0.70)
        XCTAssertFalse(asked, "a decision was paid for on a verdict with nothing left to raise")
    }

    func test_theQuestionDescribesTheSurfacesRatherThanListingThem() {
        let q = DecisionGate.secondOpinionInstructions.lowercased()
        XCTAssertTrue(q.contains("whatever that surface is called"),
                      "the question hands back the same keyword problem it exists to cover")
        XCTAssertTrue(q.contains("credential"))
    }

    // MARK: - The suite's own boundary

    func test_theSharedEngineNeverReachesAKeyFromATest() {
        XCTAssertTrue(DecisionEngine.isUnderTest, "the test-process check does not fire inside the suite")
        XCTAssertFalse(DecisionEngine.shared.hasRemoteKey,
                       "the suite can read the operator's Keychain and call a remote provider")
    }
}
