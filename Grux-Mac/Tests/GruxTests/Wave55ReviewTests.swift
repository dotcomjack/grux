import XCTest
@testable import Grux

/// Wave 55 review round 1 (5dc5e453...66ec1cc9).
/// P2-1: W54-P3 item 4 renamed only the tool gate's own rows, so the approval
/// risk judgment's row ("Action: Run tool 'mcp__github__create_issue' ...",
/// built from the gate's action summary, never a person's words) read raw
/// again on the Usage card and in the menu bar.
/// P2-2: "Fill in OpenRouter sets the name and base URL for you" while the
/// button did nothing with both typed, and named a Together endpoint
/// "OpenRouter" when only another Base URL was typed.
/// P3s: the clip kept everything up to the next quote anywhere; the 24 hour
/// line said "more than a day" where Grux backs up at a day.
@MainActor
final class Wave55ReviewTests: XCTestCase {

    private func entry(_ surface: String, _ summary: String) -> DecisionLedgerEntry {
        DecisionLedgerEntry(surface: surface, provider: .jev, latencyMs: 900, inputTokens: 0,
                            outputTokens: 0, at: Date(), summary: summary)
    }

    func test_theRiskJudgmentsRowNamesTheTool() {
        let item = PendingApproval(action: ProposedAction(kind: .other,
                                                          summary: "Run tool 'mcp__github__create_issue' (unclassified side effect).",
                                                          target: "mcp__github__create_issue"),
                                   reason: DecisionGate.asksFirstReason)
        let state = ApprovalRiskJudgment.state(for: item)
        let result = DecisionResult(answers: ["risk": .score(1, confidence: 0.9)], latencyMs: 900,
                                    inputTokens: 0, outputTokens: 0, provider: .jev)
        let summary = DecisionEngine.summary(state: state, result: result)
        XCTAssertEqual(DecisionUsageSummary.lastLine(entry(ApprovalRiskJudgment.surface, summary)),
                       "Use the mcp github create issue tool, 900 ms")
        let named = PendingApproval(action: ProposedAction(kind: .other,
                                                           summary: "Run tool 'create_note' (unclassified side effect).",
                                                           target: "create_note"),
                                    reason: DecisionGate.asksFirstReason)
        let noteSummary = DecisionEngine.summary(state: ApprovalRiskJudgment.state(for: named), result: result)
        XCTAssertEqual(DecisionUsageSummary.lastLine(entry(ApprovalRiskJudgment.surface, noteSummary)),
                       "Save your note, 900 ms")
    }

    func test_onlyGateBuiltSurfacesAreRenamed() {
        XCTAssertEqual(DecisionUsageSummary.renamedSurfaces, [DecisionGate.surface, ApprovalRiskJudgment.surface])
        XCTAssertEqual(DecisionUsageSummary.lastLine(entry("voice", "Heard: Run tool 'create_note' please -> x=1.00")),
                       "Run tool 'create_note' please, 900 ms")
    }

    func test_fillInOpenRouterNeverNamesAnotherServiceOpenRouter() {
        let ex = ModelConfigSection.openRouterExample
        let other = ModelConfigSection.filledOpenRouter(name: "", baseURL: "https://api.together.xyz/v1")
        XCTAssertEqual(other.name, "", "a Together address is not named OpenRouter")
        XCTAssertEqual(other.baseURL, "https://api.together.xyz/v1")
        let same = ModelConfigSection.filledOpenRouter(name: "", baseURL: " " + ex.baseURL + " ")
        XCTAssertEqual(same.name, ex.name, "OpenRouter's own address typed: the name follows")
        let trailing = ModelConfigSection.filledOpenRouter(name: "", baseURL: ex.baseURL + "/")
        XCTAssertEqual(trailing.name, ex.name)
    }

    func test_theButtonIsOffWhenItWouldChangeNothing() {
        XCTAssertTrue(ModelConfigSection.fillChangesSomething(name: "", baseURL: ""))
        XCTAssertTrue(ModelConfigSection.fillChangesSomething(name: "Work", baseURL: ""))
        XCTAssertTrue(ModelConfigSection.fillChangesSomething(name: "", baseURL: ModelPaths.openRouterBase))
        XCTAssertFalse(ModelConfigSection.fillChangesSomething(name: "Work", baseURL: "https://api.together.xyz/v1"))
        XCTAssertFalse(ModelConfigSection.fillChangesSomething(name: "", baseURL: "https://api.together.xyz/v1"))
        XCTAssertFalse(ModelConfigSection.fillChangesSomething(name: "OpenRouter", baseURL: ModelPaths.openRouterBase))
    }

    func test_theLineSaysItFillsWhatIsEmpty() throws {
        let line = ModelConfigSection.noEndpointsLine
        XCTAssertTrue(line.contains("empty"), line)
        XCTAssertFalse(line.contains("sets the name and base URL for you"), line)
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Backend/ModelConfigView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(".disabled(!Self.fillChangesSomething(name: newName, baseURL: newBaseURL))"))
    }

    func test_theClipExtendsOnlyOverAToolId() {
        let long = "Heard: Run tool 'notes please, and then a lot more words that keep going well past the clip line\nGrux said: I'm on it"
        XCTAssertLessThanOrEqual(DecisionEngine.clipped(long).count, 60, "a quote far away is not an id's end")
        let id = String(repeating: "a", count: 70)
        let gate = "The action is: Run tool '\(id)' (unclassified side effect)."
        XCTAssertTrue(DecisionEngine.clipped(gate).contains("'\(id)'"), "a real id still keeps its closing quote")
        // A clip that would save fewer characters than the "..." it adds keeps the whole state.
        let near = "The action is: Run tool '" + String(repeating: "b", count: 38) + "'xy"
        XCTAssertEqual(DecisionEngine.clipped(near), near)
    }

    func test_theAutoBackupLineMatchesTheCadence() {
        XCTAssertTrue(BackupView.autoBackupLine.contains("a day old or older"), BackupView.autoBackupLine)
    }
}
