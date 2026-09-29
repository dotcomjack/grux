import XCTest
@testable import Grux

final class FocusOverlayPlacementTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 2560, height: 1415)
    let card = NSSize(width: 332, height: 180)
    let orb = NSSize(width: 64, height: 64)

    func test_side_isByTheCardsCentre() {
        XCTAssertEqual(FocusOverlayPlacement.side(of: NSRect(x: 100, y: 100, width: 332, height: 180), in: screen), .left)
        XCTAssertEqual(FocusOverlayPlacement.side(of: NSRect(x: 2000, y: 100, width: 332, height: 180), in: screen), .right)
        XCTAssertEqual(FocusOverlayPlacement.verticalHalf(of: NSRect(x: 100, y: 1200, width: 332, height: 180), in: screen), .top)
    }

    func test_collapseOnTheRight_keepsTheTopRightCorner() {
        let old = NSRect(x: 2212, y: 1219, width: 332, height: 180) // top right, at the inset
        let f = FocusOverlayPlacement.frame(for: orb, keepingAnchorOf: old, in: screen)
        XCTAssertEqual(f.maxX, old.maxX); XCTAssertEqual(f.maxY, old.maxY)
        XCTAssertEqual(f.size, orb)
    }

    func test_expandOnTheLeftBottom_keepsTheBottomLeftCorner() {
        let old = NSRect(x: 16, y: 16, width: 64, height: 64)
        let f = FocusOverlayPlacement.frame(for: card, keepingAnchorOf: old, in: screen)
        XCTAssertEqual(f.minX, 16); XCTAssertEqual(f.minY, 16)
        XCTAssertEqual(f.size, card)
    }

    func test_expandNearTheEdge_neverLeavesTheScreen() {
        let old = NSRect(x: 2500, y: 1380, width: 64, height: 64) // orb pushed past the inset
        let f = FocusOverlayPlacement.frame(for: card, keepingAnchorOf: old, in: screen)
        XCTAssertLessThanOrEqual(f.maxX, screen.maxX - FocusOverlayPlacement.inset)
        XCTAssertLessThanOrEqual(f.maxY, screen.maxY - FocusOverlayPlacement.inset)
    }

    func test_snap_settlesOntoTheInsetOnlyWhenClose() {
        let near = NSRect(x: 2200, y: 700, width: 332, height: 180) // 28pt from the right inset
        let s = FocusOverlayPlacement.snapped(near, in: screen)
        XCTAssertEqual(s.maxX, screen.maxX - FocusOverlayPlacement.inset)
        XCTAssertEqual(s.minY, 700, "the vertical axis was not near an edge and stays put")
        let far = NSRect(x: 1200, y: 700, width: 332, height: 180)
        XCTAssertEqual(FocusOverlayPlacement.snapped(far, in: screen), far)
    }

    func test_cornerFrame_placesAtTheInset() {
        let f = FocusOverlayPlacement.frame(for: card, side: .left, vertical: .top, in: screen)
        XCTAssertEqual(f.minX, 16); XCTAssertEqual(f.maxY, screen.maxY - 16)
    }
}
