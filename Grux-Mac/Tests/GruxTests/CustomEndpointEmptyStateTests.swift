import XCTest
@testable import Grux

/// D166 item 7 (sense pass 20): Settings, Models, Custom endpoints said "for
/// example OpenRouter at https://openrouter.ai/api/" and wrapped "v1" onto the
/// next line, so the address read as two. The line names the example without
/// an address, and one button fills the name and base URL in for the person.
@MainActor
final class CustomEndpointEmptyStateTests: XCTestCase {

    func test_theEmptyLineCarriesNoAddressThatCanWrap() {
        let line = ModelConfigSection.noEndpointsLine
        XCTAssertFalse(line.contains("://"), line)
        XCTAssertFalse(line.contains("/"), line)
        XCTAssertTrue(line.contains("OpenRouter"), line)
        XCTAssertTrue(line.contains(ModelConfigSection.fillOpenRouterLabel), "the line points at the button: \(line)")
    }

    func test_theButtonFillsTheNameAndTheBaseURL() {
        let filled = ModelConfigSection.openRouterExample
        XCTAssertEqual(filled.name, "OpenRouter")
        XCTAssertEqual(filled.baseURL, ModelPaths.openRouterBase)
        XCTAssertNotNil(URL(string: filled.baseURL)?.host)
    }
}
