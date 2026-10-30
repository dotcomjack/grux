import XCTest
@testable import Grux

/// `fileNamingEnabled` lets Grux rename new screenshots and downloads from what
/// they show. It is off on a fresh install and on an install that predates the
/// key, so the decode fallback and the init default agree, and a config written
/// before the feature existed never wakes up renaming files.
final class FileNamingConfigTests: XCTestCase {
    func test_aFreshConfigDoesNotNameFiles() {
        XCTAssertFalse(GruxConfig.default.fileNamingEnabled)
    }

    func test_aConfigWrittenBeforeTheKeyExistedDoesNotNameFiles() throws {
        var full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GruxConfig.default)) as! [String: Any]
        // Control: the key is really in what the encoder wrote, so removing it
        // below is removing something and the decode is a real fallback.
        XCTAssertNotNil(full["fileNamingEnabled"], "control: the encoder does not write fileNamingEnabled at all")
        full.removeValue(forKey: "fileNamingEnabled")
        let data = try JSONSerialization.data(withJSONObject: full)
        XCTAssertFalse(try JSONDecoder().decode(GruxConfig.self, from: data).fileNamingEnabled)
    }

    func test_theKeyRoundTrips() throws {
        var c = GruxConfig.default
        c.fileNamingEnabled = true
        let back = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.fileNamingEnabled)
    }
}
