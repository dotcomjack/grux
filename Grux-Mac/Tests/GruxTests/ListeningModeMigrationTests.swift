import XCTest
@testable import Grux

final class ListeningModeMigrationTests: XCTestCase {
    /// A saved 1.x config: the encoded default with the listening keys
    /// removed (they did not exist yet) and the old switches set as given.
    private func oldConfig(wake: Bool, ambient: Bool, consented: Bool = false) throws -> GruxConfig {
        let data = try JSONEncoder().encode(GruxConfig.default)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for k in ["listeningMode", "listeningThreshold", "listeningBannerExplained", "showLastDecision"] { dict.removeValue(forKey: k) }
        dict["wakeWordEnabled"] = wake
        dict["ambientEnabled"] = ambient
        dict["wakeWordConsentAcknowledged"] = consented
        let json = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(GruxConfig.self, from: json)
    }

    func test_freshInstall_isAlwaysOnWithDefaults() {
        let c = GruxConfig.default
        XCTAssertEqual(c.listeningMode, .alwaysOn)
        XCTAssertEqual(c.listeningThreshold, 0.70, accuracy: 1e-9)
        XCTAssertFalse(c.listeningBannerExplained)
        XCTAssertTrue(c.showLastDecision)
    }

    func test_savedConfigWithoutTheKeys_getsTheDefaultsForThreeOfThem() throws {
        let c = try oldConfig(wake: false, ambient: false)
        XCTAssertEqual(c.listeningThreshold, 0.70, accuracy: 1e-9)
        XCTAssertFalse(c.listeningBannerExplained)
        XCTAssertTrue(c.showLastDecision)
    }

    func test_oldWakeWordOnly_becomesWakeWord() throws {
        XCTAssertEqual(try oldConfig(wake: true, ambient: false).listeningMode, .wakeWord)
    }

    func test_oldAmbientOn_becomesAlwaysOn() throws {
        XCTAssertEqual(try oldConfig(wake: false, ambient: true).listeningMode, .alwaysOn)
    }

    func test_neverAsked_startsAlwaysOn() throws {
        XCTAssertEqual(try oldConfig(wake: false, ambient: false, consented: false).listeningMode, .alwaysOn)
    }

    func test_deliberatelyOff_staysOff() throws {
        XCTAssertEqual(try oldConfig(wake: false, ambient: false, consented: true).listeningMode, .off)
    }

    func test_explicitValue_wins() throws {
        let data = try JSONEncoder().encode(GruxConfig.default)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict["listeningMode"] = "off"
        dict["ambientEnabled"] = true
        let c = try JSONDecoder().decode(GruxConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(c.listeningMode, .off)
    }

    func test_labelsHaveNoJargon() {
        for m in ListeningMode.allCases {
            XCTAssertFalse(m.label.lowercased().contains("ambient"), m.label)
            XCTAssertFalse(m.explanation.lowercased().contains("whisper"), m.explanation)
        }
    }
}
