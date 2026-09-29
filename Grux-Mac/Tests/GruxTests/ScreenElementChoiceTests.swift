import XCTest
@testable import Grux

/// P-R-4: which of several equally good matches a click means. The engine
/// chooses among the tied matches only, and only when told which one is meant.
final class ScreenElementChoiceTests: XCTestCase {
    private func el(_ role: String, _ title: String, _ x: CGFloat, _ y: CGFloat) -> ScreenControlEngine.UIElementInfo {
        ScreenControlEngine.UIElementInfo(role: role, title: title, value: "", frame: CGRect(x: x, y: y, width: 60, height: 24))
    }

    private lazy var screen = [
        el("AXButton", "Save", 900, 40),       // toolbar, top right
        el("AXButton", "Save As", 960, 40),
        el("AXTextField", "Name", 500, 500),
        el("AXButton", "Save", 700, 760),      // dialog, bottom
        el("AXButton", "Cancel", 600, 760),
    ]

    func test_onlyTheTiedBestMatchesAreCandidates() {
        XCTAssertEqual(ScreenElementChoice.tiedAtTop(query: "Save", role: nil, among: screen), [0, 3],
                       "Save As is a weaker match and must not be offered")
        XCTAssertEqual(ScreenElementChoice.tiedAtTop(query: "Cancel", role: nil, among: screen), [4])
        XCTAssertEqual(ScreenElementChoice.tiedAtTop(query: "Save", role: "field", among: screen), [])
    }

    func test_theQuestionDescribesEachCandidateAndWhereItIs() {
        let tied = [0, 3].map { screen[$0] }
        let q = ScreenElementChoice.question(label: "Save", which: "the one in the dialog", app: "Pages", candidates: tied)
        guard case .choice(_, let criteria)? = q.questions["which"] else { return XCTFail("no choice question") }
        XCTAssertEqual(Set(criteria.keys), ["1", "2"])
        XCTAssertTrue(criteria["1"]?.contains("top") == true, criteria["1"] ?? "")
        XCTAssertTrue(criteria["2"]?.contains("bottom") == true, criteria["2"] ?? "")
        XCTAssertTrue(q.state.contains("the one in the dialog"))
    }

    func test_thePickNeverLeavesTheTiedSet() {
        let tied = [0, 3]
        let two = DecisionAnswer.choice("2", confidence: 0.9, probabilities: [:])
        XCTAssertEqual(ScreenElementChoice.pick(two, provider: .jev, threshold: 0.7, tied: tied), 3)
        XCTAssertNil(ScreenElementChoice.pick(two, provider: .local, threshold: 0.7, tied: tied), "on device cannot judge")
        XCTAssertNil(ScreenElementChoice.pick(.choice("2", confidence: 0.6, probabilities: [:]),
                                              provider: .jev, threshold: 0.7, tied: tied), "unsure keeps reading order")
        XCTAssertNil(ScreenElementChoice.pick(.choice("3", confidence: 0.99, probabilities: [:]),
                                              provider: .jev, threshold: 0.7, tied: tied), "outside the tied set")
        XCTAssertNil(ScreenElementChoice.pick(.choice("the dialog one", confidence: 0.99, probabilities: [:]),
                                              provider: .jev, threshold: 0.7, tied: tied))
    }

    /// The tool asks only with a description, only when no explicit nth was
    /// given, and hands the pick ONLY the tied indices.
    func test_theToolAsksOnlyWhenItCanHelp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ScreenControl/ScreenControlTool.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("if nth == nil, !which.isEmpty {"))
        XCTAssertTrue(src.contains("if tied.count > 1, await MainActor.run(body: { engine.hasRemoteKey }) {"))
        XCTAssertTrue(src.contains("threshold: threshold, tied: tied)"))
    }
}
