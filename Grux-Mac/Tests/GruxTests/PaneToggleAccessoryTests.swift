import XCTest
import AppKit
@testable import Grux

/// A title bar accessory takes its view's frame as its width. A hosting view
/// made without one is zero wide, and the button is there but invisible,
/// which is how it first shipped.
@MainActor
final class PaneToggleAccessoryTests: XCTestCase {
    func test_theAccessoryHasAWidthAndSitsTrailing() {
        let accessory = PaneToggleAccessory.make(hidden: false)
        XCTAssertGreaterThan(accessory.view.frame.width, 0, "a zero-wide accessory draws nothing")
        XCTAssertGreaterThan(accessory.view.frame.height, 0)
        XCTAssertEqual(accessory.layoutAttribute, .trailing)
        XCTAssertFalse(accessory.isHidden)
    }

    func test_theClassicShellHidesIt() {
        XCTAssertTrue(PaneToggleAccessory.make(hidden: true).isHidden)
    }
}
