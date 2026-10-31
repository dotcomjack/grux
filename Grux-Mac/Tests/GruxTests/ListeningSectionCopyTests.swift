import XCTest
@testable import Grux

final class ListeningSectionCopyTests: XCTestCase {
    func test_sectionCopy_isPlainLanguage() {
        let copy = ListeningSection.copy
        XCTAssertEqual(copy.title, "Listening")
        for banned in ["Whisper", "ambient", "VP", "AEC", "wake word listener", "SFSpeech"] {
            XCTAssertFalse(copy.body.contains(banned), "jargon in Listening copy: \(banned)")
        }
    }

    func test_decisionsCardCopy_saysOptionalAndOnDevice() {
        for copy in [DecisionsSection.copy(jevTypicalMs: nil), DecisionsSection.copy(jevTypicalMs: 216)] {
            XCTAssertTrue(copy.body.contains("Optional"))
            XCTAssertTrue(copy.body.lowercased().contains("on device"))
        }
    }

    /// D87 (sense pass 7): Integrations promised Jev decides "in about half a second" while
    /// Settings, Usage measured "Typical speed 216 ms". The card quotes the measured typical speed
    /// of today's Jev decisions, and claims no number when there is none.
    func test_decisionsCardSpeedIsTheMeasuredOne() {
        let unmeasured = DecisionsSection.copy(jevTypicalMs: nil).body
        XCTAssertFalse(unmeasured.contains("second"), unmeasured)
        XCTAssertNil(unmeasured.range(of: #"\d"#, options: .regularExpression), unmeasured)
        XCTAssertTrue(unmeasured.hasPrefix("Jev by TypeSafe makes Grux's small decisions with a confidence attached."), unmeasured)
        for ms in [1, 216, 999, 1_500] {
            let body = DecisionsSection.copy(jevTypicalMs: ms).body
            XCTAssertTrue(body.contains("in a typical \(ms) ms today"), body)
            XCTAssertFalse(body.contains("second"), body)
        }
    }
}
