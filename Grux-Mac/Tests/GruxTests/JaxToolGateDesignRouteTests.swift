import XCTest
@testable import Grux

// Locks the critical fix: a chat-invoked design_generate may only run the
// ungated api route. Any non-api route (the subprocess-spawning subscriptionCLI
// or localModel) must NOT proceed straight through, it must be short-circuited
// into the approval queue. Read-only design tools stay ungated.
@MainActor
final class JaxToolGateDesignRouteTests: XCTestCase {

    private func proceeds(_ name: String, _ input: [String: Any]) -> Bool {
        if case .proceed = JaxToolGate.evaluate(name: name, input: input) { return true }
        return false
    }

    func testDesignGenerateApiRouteProceeds() {
        XCTAssertTrue(proceeds("design_generate", ["project": "x", "brief": "y"]))
        XCTAssertTrue(proceeds("design_generate", ["project": "x", "brief": "y", "route": "api"]))
        XCTAssertTrue(proceeds("design_generate", ["project": "x", "brief": "y", "route": ""]))
    }

    func testDesignGenerateSubprocessRouteDoesNotProceed() {
        XCTAssertFalse(proceeds("design_generate", ["project": "x", "brief": "y", "route": "subscriptionCLI"]))
        XCTAssertFalse(proceeds("design_generate", ["project": "x", "brief": "y", "route": "localModel"]))
    }

    func testReadOnlyDesignToolsProceed() {
        XCTAssertTrue(proceeds("design_list_projects", ["query": "z"]))
        XCTAssertTrue(proceeds("design_create_project", ["title": "z"]))
        XCTAssertTrue(proceeds("design_open_project", ["project": "z"]))
    }
}
