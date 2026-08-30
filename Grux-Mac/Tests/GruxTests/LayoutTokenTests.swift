import XCTest
import CoreGraphics
@testable import Grux

/// Guards the width budget in `GruxLayout`, which is what stops a resized
/// window from clipping content off both edges. Settings shipped a hard
/// `.frame(width: 680)` inside a detail pane that can be 599pt, and because
/// SwiftUI centres an oversized child it bled off the left AND the right at
/// once: text cut mid-word, label columns over fields, a button below the
/// bottom edge.
///
/// These assertions are on the RELATIONSHIPS, not the numbers. `listColumnIdeal
/// == 280` would be a worthless test: it fails on a harmless retune and passes
/// on a fatal one. `listColumnMin + detailContentMin <= detailPaneFloor` fails
/// on exactly the edit that reintroduces the bug.
final class LayoutTokenTests: XCTestCase {

    // MARK: - The floor is derived, not typed

    /// If this ever has to be maintained by hand it will drift from the window
    /// it describes, and every budget below it inherits the lie.
    func testDetailPaneFloorIsDerivedFromTheWindowFloor() {
        XCTAssertEqual(GruxLayout.detailPaneFloor,
                       GruxLayout.windowFloorWidth - GruxLayout.navRail - GruxLayout.divider,
                       "detailPaneFloor must stay derived from the window floor, the nav rail and the divider")
    }

    /// The hairline is the whole difference between "600 fits" and "600 is one
    /// point too wide", so a budget that forgets it is off by exactly enough to
    /// clip. Assert it is counted rather than rounded away.
    func testTheDividerIsCountedAgainstThePane() {
        XCTAssertLessThan(GruxLayout.detailPaneFloor,
                          GruxLayout.windowFloorWidth - GruxLayout.navRail,
                          "the divider between rail and pane has to come out of the pane's budget")
    }

    // MARK: - The invariant that prevents clipping

    /// The one that matters. A list column at its floor, the scaffold's
    /// divider, and a detail pane still wide enough to read must all fit
    /// inside what the pane is handed at the smallest window we ship.
    func testListFloorPlusReadableDetailFitsThePaneFloor() {
        let demanded = GruxLayout.listColumnMin + GruxLayout.divider + GruxLayout.detailContentMin
        XCTAssertLessThanOrEqual(demanded, GruxLayout.detailPaneFloor,
                                 "a list+detail split would overflow its pane by \(demanded - GruxLayout.detailPaneFloor)pt at the window floor")
    }

    /// The same chain measured end to end against the window instead of the
    /// pane, so a change to the nav rail is caught by this file too. The rail
    /// is fixed on purpose, which makes it a hard subtraction: widening it
    /// takes its points straight out of the detail pane.
    func testTheWholeChainFitsTheWindowFloor() {
        let demanded = GruxLayout.navRail
            + GruxLayout.divider
            + GruxLayout.listColumnMin
            + GruxLayout.divider
            + GruxLayout.detailContentMin
        XCTAssertLessThanOrEqual(demanded, GruxLayout.windowFloorWidth,
                                 "rail + list floor + readable detail overflows the window floor by \(demanded - GruxLayout.windowFloorWidth)pt")
    }

    /// A ceiling wider than the pane it lives in is not a ceiling, and it would
    /// let the clamp hand a caller a width the pane cannot fit at the floor.
    ///
    /// Note this is deliberately weaker than the minimum tests above, because
    /// the ceiling is not where the safety comes from: a flexible column in an
    /// HStack is only ever handed its share of the pane, so at the floor it
    /// shrinks below its ceiling on its own. The minimums are the guarantee;
    /// the ceiling is an aesthetic bound that stops the index eating a wide
    /// window, and this only catches an absurd one.
    func testListCeilingFitsInsideThePaneFloor() {
        XCTAssertLessThanOrEqual(GruxLayout.listColumnMax + GruxLayout.divider,
                                 GruxLayout.detailPaneFloor,
                                 "a column ceiling this wide cannot fit its own pane at the window floor")
    }

    // MARK: - Triples are ordered

    func testListTripleIsOrdered() {
        XCTAssertLessThanOrEqual(GruxLayout.listColumnMin, GruxLayout.listColumnIdeal)
        XCTAssertLessThanOrEqual(GruxLayout.listColumnIdeal, GruxLayout.listColumnMax)
    }

    func testSheetTripleIsOrdered() {
        XCTAssertLessThanOrEqual(GruxLayout.sheetMin, GruxLayout.sheetIdeal)
        XCTAssertLessThanOrEqual(GruxLayout.sheetIdeal, GruxLayout.sheetMax)
    }

    // MARK: - Sheets fit the window they hang off

    /// A sheet is bounded by its window, so a ceiling above the window floor is
    /// a sheet that clips on a small display. The height half is the "button
    /// cut off the bottom" report: a sheet has no scroll of its own, so a row
    /// pushed below the edge is unreachable, not just ugly.
    func testSheetCeilingsFitTheWindowFloor() {
        XCTAssertLessThanOrEqual(GruxLayout.sheetMax, GruxLayout.windowFloorWidth)
        XCTAssertLessThanOrEqual(GruxLayout.sheetMaxHeight, GruxLayout.windowFloorHeight)
    }

    /// Room on both sides at the smallest window, so a sheet never renders edge
    /// to edge and stops reading as a sheet.
    func testSheetCeilingsLeaveBreathingRoom() {
        XCTAssertLessThan(GruxLayout.sheetMax, GruxLayout.windowFloorWidth - GruxSpacing.xl)
        XCTAssertLessThan(GruxLayout.sheetMaxHeight, GruxLayout.windowFloorHeight - GruxSpacing.xl)
    }

    // MARK: - The clamp

    func testClampHonoursAnythingInsideTheRange() {
        XCTAssertEqual(GruxLayout.listColumnWidth(GruxLayout.listColumnMin), GruxLayout.listColumnMin)
        XCTAssertEqual(GruxLayout.listColumnWidth(GruxLayout.listColumnMax), GruxLayout.listColumnMax)
        XCTAssertEqual(GruxLayout.listColumnWidth(GruxLayout.listColumnIdeal), GruxLayout.listColumnIdeal)
    }

    /// The 680pt-inside-a-599pt-pane shape, at column scale. A caller asking
    /// for more than the budget gets the budget, not the ask.
    func testClampRefusesToStarveTheDetailPane() {
        XCTAssertEqual(GruxLayout.listColumnWidth(500), GruxLayout.listColumnMax)
        XCTAssertEqual(GruxLayout.listColumnWidth(GruxLayout.windowFloorWidth), GruxLayout.listColumnMax)
    }

    func testClampRaisesAColumnTooNarrowToRead() {
        XCTAssertEqual(GruxLayout.listColumnWidth(0), GruxLayout.listColumnMin)
        XCTAssertEqual(GruxLayout.listColumnWidth(-40), GruxLayout.listColumnMin)
    }

    /// The five tabs already calling GruxListDetailScaffold pass these widths.
    /// Retuning the range so one of them silently moves is a visual change
    /// nobody asked for, and it would land on Contacts and Mailbox first.
    func testExistingCallerWidthsPassThroughUnchanged() {
        for width: CGFloat in [280, 320, 330] {
            XCTAssertEqual(GruxLayout.listColumnWidth(width), width,
                           "\(width)pt is a live call site; the range must not move it")
        }
    }

    // MARK: - The rail

    /// The rail is fixed because it is chrome, but fixed is only defensible
    /// while it stays a minority of the smallest window. If it ever crosses a
    /// third of the floor, the detail pane is the thing paying for it and the
    /// decision needs revisiting rather than silently absorbing.
    func testTheFixedRailStaysAMinorityOfTheWindowFloor() {
        XCTAssertLessThan(GruxLayout.navRail, GruxLayout.windowFloorWidth / 3,
                          "the fixed nav rail is now \(GruxLayout.navRail / GruxLayout.windowFloorWidth * 100)% of the window floor")
    }
}
