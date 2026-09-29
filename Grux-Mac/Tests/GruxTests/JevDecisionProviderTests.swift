import XCTest
@testable import Grux

final class JevDecisionProviderTests: XCTestCase {
    // The exact response shape observed from the provider on 2026-09-20.
    private let canned = """
    {"model":"jev-1.13.0","answers":{
      "is_destructive":{"type":"noul","noul":0.77},
      "intent":{"type":"choice","choice":"run_shell_command","confidence":0.99,
                "probabilities":{"send_email":0.0,"other":0.0,"answer_question":0.0,"write_code":0.0,"run_shell_command":1.0}},
      "severity":{"type":"score","score":1.43,"confidence":0.35,"probabilities":{"0":0.0,"1":0.57,"2":0.43}}
    },"usage":{"input_tokens":414,"output_tokens":78}}
    """.data(using: .utf8)!

    func test_parse_readsAllThreePrimitivesAndUsage() throws {
        let r = try JevDecisionProvider.parse(canned, latencyMs: 577)
        XCTAssertEqual(r.provider, .jev)
        XCTAssertEqual(r.latencyMs, 577)
        XCTAssertEqual(r.inputTokens, 414)
        XCTAssertEqual(r.outputTokens, 78)
        XCTAssertEqual(r.answers["is_destructive"], .noul(0.77))
        XCTAssertEqual(r.answers["intent"], .choice("run_shell_command", confidence: 0.99,
            probabilities: ["send_email": 0, "other": 0, "answer_question": 0, "write_code": 0, "run_shell_command": 1]))
        XCTAssertEqual(r.answers["severity"], .score(1.43, confidence: 0.35))
    }

    func test_requestBody_usesCriteriaMapForChoiceAndLevelsForScore() throws {
        let body = JevDecisionProvider.requestBody(state: "close everything", questions: [
            "intent": .choice(instructions: "What did they ask?", criteria: ["close_all": "close every window", "not_a_command": "talking to someone else"]),
            "urgent": .noul(instructions: "Is it urgent?"),
            "risk": .score(instructions: "How risky?", levels: ["harmless", "reversible", "irreversible"]),
        ])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        XCTAssertEqual(body["state"] as? String, "close everything")
        let qs = try XCTUnwrap(body["questions"] as? [String: Any])
        let intent = try XCTUnwrap(qs["intent"] as? [String: Any])
        XCTAssertEqual(intent["type"] as? String, "choice")
        XCTAssertEqual((intent["criteria"] as? [String: String])?["close_all"], "close every window")
        let risk = try XCTUnwrap(qs["risk"] as? [String: Any])
        XCTAssertEqual(risk["criteria"] as? [String], ["harmless", "reversible", "irreversible"])
        XCTAssertEqual((qs["urgent"] as? [String: Any])?["type"] as? String, "noul")
    }

    func test_parse_rejectsMissingAnswers() {
        XCTAssertThrowsError(try JevDecisionProvider.parse("{}".data(using: .utf8)!, latencyMs: 1))
    }

    func test_decide_withoutKeyThrowsBeforeAnyNetwork() async {
        let p = JevDecisionProvider(apiKey: "")
        do { _ = try await p.decide(state: "x", questions: ["q": .noul(instructions: "y")]); XCTFail("expected a throw") }
        catch let e as JevDecisionProvider.Failure { XCTAssertEqual(e, .noKey) }
        catch { XCTFail("wrong error \(error)") }
    }
}
