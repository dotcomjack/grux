import XCTest
@testable import Grux

/// `fire-cookbook-pull` fetches only what the Cookbook offers.
@MainActor
final class CookbookTriggersTests: XCTestCase {
    func test_anIdOutsideTheCatalogIsRefusedAndNothingStarts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cookbook-trigger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "evil.example/x/model:1b"
        await CookbookTriggers.fire(id: id, dir: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent(CookbookTriggers.pullFile))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["refused"] as? String, "notInCatalog")
        XCTAssertFalse(OllamaManager.shared.isPulling(id))
        XCTAssertTrue(Cookbook.catalog.contains { $0.id == "gruxai.com/grux/grux-local:2b" },
                      "control: the id the live proof pulls is a catalog id")
    }
}
