import XCTest
@testable import Grux

/// D59: Design Studio's route chip started on "API key" on a Mac with no
/// Anthropic key and a running local model, so its first run could only fail.
final class DesignStudioStartingRouteTests: XCTestCase {

    func test_aKeyKeepsTheAPIRoute() {
        XCTAssertEqual(ExecutionRoute.startingRoute(hasAnthropicKey: true, localModelUsable: false), .api)
        XCTAssertEqual(ExecutionRoute.startingRoute(hasAnthropicKey: true, localModelUsable: true), .api)
    }

    func test_noKeyAndALocalModelStartsOnTheLocalModel() {
        XCTAssertEqual(ExecutionRoute.startingRoute(hasAnthropicKey: false, localModelUsable: true), .localModel)
    }

    func test_neitherStaysOnTheAPIRouteWhoseRunSaysToAddAKey() {
        XCTAssertEqual(ExecutionRoute.startingRoute(hasAnthropicKey: false, localModelUsable: false), .api)
    }

    /// The view's route follows the rule until the person picks one; a fixed
    /// `= .api` default is the defect.
    func test_theViewStartsOnTheRuleNotOnAFixedRoute() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/DesignStudio/DesignStudioView.swift"),
                             encoding: .utf8)
        XCTAssertFalse(src.contains("@State private var route: ExecutionRoute = .api"),
                       "Design Studio starts on the API route whatever this Mac can run")
        XCTAssertTrue(src.contains("ExecutionRoute.startingRoute("), "the view does not ask the starting route rule")
        XCTAssertTrue(src.contains("localModelUsable: registry.localUsable"),
                      "the starting route does not read whether a local model can serve")
    }
}
