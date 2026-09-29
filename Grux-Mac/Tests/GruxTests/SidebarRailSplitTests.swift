import XCTest
@testable import Grux

/// The rail is rendered in two pieces: a scrolling list and a pinned tail.
/// These tests exist for ONE risk: that splitting it silently loses a row.
///
/// WHY THE SPLIT. `SidebarIA` defines Settings to be last, which makes it the
/// row most likely to fall off the bottom of a scrolling list. Measured
/// 2026-09-24 in a 1040x732 window: the rail ended visibly at the Developer
/// door, with the Labs door AND Settings both below the fold and a band of
/// dead space under the last visible row, which reads as the end of a list
/// rather than the middle of one. Proven by resizing to 1083pt, where the Labs
/// door appeared, then scrolling, where Settings appeared last exactly as the
/// model says. Raising the window floor does not fix it: the floor is 560pt,
/// far below the 732pt that already failed.
///
/// WHY THESE TESTS. A view that renders a subset of what the model returns is
/// exactly the model/view divergence that was suspected (and ruled out) when
/// the Labs door appeared to be missing. Splitting the rail by hand creates
/// that risk for real. So the invariant held here is not "Settings is pinned",
/// it is "the two halves rebuild the model's rail EXACTLY", which no amount of
/// future editing can satisfy while dropping something.
@MainActor
final class SidebarRailSplitTests: XCTestCase {

    /// Every shape of rail a person can actually have.
    private var allRails: [(label: String, rail: [SidebarRow])] {
        var out: [(String, [SidebarRow])] = []
        for dev in [false, true] {
            for brands in [[], ["Acme"], ["Acme", "Beta Corp"]] {
                out.append(("dev=\(dev) brands=\(brands.count)",
                            SidebarIA.rail(developerUnlocked: dev, brands: brands)))
            }
        }
        return out
    }

    /// THE INVARIANT. Nothing added, nothing lost, order preserved.
    func testTheTwoHalvesRebuildTheRailExactly() {
        for (label, rail) in allRails {
            let split = LaunchRootView.splitRail(rail)
            let rebuilt = split.scrolling + split.pinned
            XCTAssertEqual(rebuilt.map(\.id), rail.map(\.id), """
                the rail split lost or reordered a row for \(label). A row that exists in \
                SidebarIA.rail and renders nowhere is invisible to the person and invisible \
                to every test that only reads the model.
                """)
        }
    }

    /// The point of the exercise: the tail that gets pinned is Settings.
    func testSettingsIsThePinnedTail() {
        for (label, rail) in allRails {
            let split = LaunchRootView.splitRail(rail)
            XCTAssertEqual(split.pinned.count, 1, "expected exactly one pinned row for \(label)")
            XCTAssertEqual(split.pinned.first?.id, "settings",
                           "the pinned tail is not Settings for \(label)")
            XCTAssertFalse(split.scrolling.contains { $0.id == "settings" },
                           "Settings is pinned AND still in the scrolling list for \(label), so it renders twice")
        }
    }

    /// The safety valve. If Settings ever stops being last, the split must
    /// degrade to the OLD behaviour (everything scrolls) rather than pin the
    /// wrong row or drop one. The worst case has to be "as before", never
    /// "a row vanished".
    func testARailNotEndingInSettingsPinsNothingAndLosesNothing() {
        let scrambled = Array(SidebarIA.rail(developerUnlocked: true, brands: []).reversed())
        XCTAssertNotEqual(scrambled.last?.id, "settings", "fixture no longer exercises the guard")
        let split = LaunchRootView.splitRail(scrambled)
        XCTAssertTrue(split.pinned.isEmpty, "pinned a row that is not the designated tail")
        XCTAssertEqual(split.scrolling.map(\.id), scrambled.map(\.id),
                       "the degraded path dropped a row instead of scrolling all of them")
    }

    /// An empty rail cannot crash the split. `dropLast` and `suffix` are safe
    /// on an empty array, but a future rewrite using indices would not be.
    func testAnEmptyRailIsSafe() {
        let split = LaunchRootView.splitRail([])
        XCTAssertTrue(split.scrolling.isEmpty)
        XCTAssertTrue(split.pinned.isEmpty)
    }
}
