import XCTest
@testable import Grux

/// `legacyShell` keeps the 240pt sidebar for one release. A fresh install and
/// an install that predates the key both get the panel, so the decode fallback
/// and the init default AGREE here, unlike `developerSurfacesUnlocked`.
final class ConfigLegacyShellTests: XCTestCase {
    func test_aFreshConfigUsesThePanel() {
        XCTAssertFalse(GruxConfig.default.legacyShell)
    }

    func test_aConfigWrittenBeforeTheKeyExistedUsesThePanel() throws {
        var full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GruxConfig.default)) as! [String: Any]
        full.removeValue(forKey: "legacyShell")
        let data = try JSONSerialization.data(withJSONObject: full)
        XCTAssertFalse(try JSONDecoder().decode(GruxConfig.self, from: data).legacyShell)
    }

    func test_theKeyRoundTrips() throws {
        var c = GruxConfig.default
        c.legacyShell = true
        let back = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.legacyShell)
    }
}
