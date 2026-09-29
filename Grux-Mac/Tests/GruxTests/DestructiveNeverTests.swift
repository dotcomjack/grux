import XCTest
@testable import Grux

@MainActor
final class DestructiveNeverTests: XCTestCase {
    /// A provider that is certain the chunk is a shell command. The router must
    /// still refuse, because shell is a `never` class, not a confidence question.
    private struct Certain: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            DecisionResult(answers: ["intent": .choice("macro:wipe", confidence: 0.99, probabilities: ["macro:wipe": 0.99])],
                           latencyMs: 1, inputTokens: 1, outputTokens: 1, provider: .jev)
        }
    }

    func test_certainShellCommand_isRefusedNotExecuted() async {
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in Certain() })
        let wipe = Macro(name: "wipe", triggers: ["wipe it"], description: "", rawActions: [.runShell(command: "rm -rf ~")])
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [wipe] })
        var ran = false
        r.runMacro = { _ in ran = true; return "" }
        let e = await r.consider(chunk: "wipe it")
        XCTAssertEqual(e?.outcome, .refused)
        XCTAssertFalse(ran)
    }
}
