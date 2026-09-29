import XCTest
@testable import Grux

// Locks the critical fix: a chat-invoked design_generate may only run the
// ungated api route. Any non-api route (the subprocess-spawning subscriptionCLI
// or localModel) must NOT proceed straight through, it must be short-circuited
// into the approval queue. Read-only design tools stay ungated.
//
// The gate became async when the decision engine was added as a second opinion
// on it. The assertions hoist the await out of XCTAssert's autoclosure rather
// than asserting inside it.
@MainActor
final class JaxToolGateDesignRouteTests: XCTestCase {

    private func proceeds(_ name: String, _ input: [String: Any]) async -> Bool {
        if case .proceed = await JaxToolGate.evaluate(name: name, input: input) { return true }
        return false
    }

    private func assertProceeds(_ name: String, _ input: [String: Any],
                                _ expected: Bool, line: UInt = #line) async {
        let actual = await proceeds(name, input)
        XCTAssertEqual(actual, expected, "\(name) \(input)", line: line)
    }

    func testDesignGenerateApiRouteProceeds() async {
        await assertProceeds("design_generate", ["project": "x", "brief": "y"], true)
        await assertProceeds("design_generate", ["project": "x", "brief": "y", "route": "api"], true)
        await assertProceeds("design_generate", ["project": "x", "brief": "y", "route": ""], true)
    }

    func testDesignGenerateSubprocessRouteDoesNotProceed() async {
        await assertProceeds("design_generate", ["project": "x", "brief": "y", "route": "subscriptionCLI"], false)
        await assertProceeds("design_generate", ["project": "x", "brief": "y", "route": "localModel"], false)
    }

    func testReadOnlyDesignToolsProceed() async {
        await assertProceeds("design_list_projects", ["query": "z"], true)
        await assertProceeds("design_create_project", ["title": "z"], true)
        await assertProceeds("design_open_project", ["project": "z"], true)
    }
}
