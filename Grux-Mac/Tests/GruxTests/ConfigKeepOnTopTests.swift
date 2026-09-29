import XCTest
@testable import Grux

/// `keepOnTop` floats the Command Panel above other windows. It is off on a
/// fresh install and on an install that predates the key, so the decode
/// fallback and the init default agree.
final class ConfigKeepOnTopTests: XCTestCase {
    func test_aFreshConfigIsNotOnTop() {
        XCTAssertFalse(GruxConfig.default.keepOnTop)
    }

    func test_aConfigWrittenBeforeTheKeyExistedIsNotOnTop() throws {
        var full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GruxConfig.default)) as! [String: Any]
        full.removeValue(forKey: "keepOnTop")
        let data = try JSONSerialization.data(withJSONObject: full)
        XCTAssertFalse(try JSONDecoder().decode(GruxConfig.self, from: data).keepOnTop)
    }

    func test_theKeyRoundTrips() throws {
        var c = GruxConfig.default
        c.keepOnTop = true
        let back = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.keepOnTop)
    }
}
