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
        let copy = DecisionsSection.copy
        XCTAssertTrue(copy.body.contains("Optional"))
        XCTAssertTrue(copy.body.lowercased().contains("on device"))
    }
}
