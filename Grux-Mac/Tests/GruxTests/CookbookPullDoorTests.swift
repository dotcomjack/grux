import XCTest
@testable import Grux

// Operator note 10: the Pull button must work for a host-qualified id
// (`gruxai.com/grux/grux-local:4b`). `~/.grux/fire-cookbook-pull` is that
// button for a Mac nobody can click on, and it reaches only what the button can.
final class CookbookPullDoorTests: XCTestCase {

    func testAHostQualifiedCatalogIdIsAPullTarget() {
        XCTAssertEqual(OllamaManager.catalogPullTarget(token: "gruxai.com/grux/grux-local:2b\n"),
                       .success("gruxai.com/grux/grux-local:2b"))
        XCTAssertEqual(OllamaManager.catalogPullTarget(token: " qwen3.5:4b "), .success("qwen3.5:4b"))
    }

    func testAnythingTheButtonCannotReachIsRefusedWithTheReason() {
        for token in ["", "  \n", "grux-local:2b", "gruxai.com/grux/grux-local", "evil.example/x:1b"] {
            guard case .failure(let refusal) = OllamaManager.catalogPullTarget(token: token) else {
                return XCTFail("\(token) was accepted")
            }
            XCTAssertTrue(refusal.reason.hasPrefix("refused: "), refusal.reason)
        }
    }

    func testEveryCatalogIdIsReachable() {
        for model in Cookbook.catalog {
            XCTAssertEqual(OllamaManager.catalogPullTarget(token: model.id), .success(model.id))
        }
    }
}
