import XCTest
@testable import Grux

/// THE OFF SWITCH, AND THE ONE RULE THAT PROTECTS EXISTING INSTALLS.
///
/// CR-36 gave thirty nine features an off state so a permission queue can be derived from a
/// selection. The danger in that change is not the new behaviour, it is the upgrade: an
/// install that predates it has nothing stored, and reading that as "chose nothing" would
/// silently switch off every feature somebody uses.
@MainActor
final class FeatureSelectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
    }

    /// ALWAYS REMOVE, never restore.
    ///
    /// UserDefaults persists across `swift test` runs, so restoring whatever was there on
    /// entry preserves pollution from a previous run instead of clearing it. That is exactly
    /// what happened: one bad run wrote an empty selection into the xctest domain, every
    /// later run read it back, and thirty nine unrelated assertions failed with "notChosen"
    /// until the key was deleted by hand. The test process has no legitimate selection to
    /// preserve, so it leaves with none.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
        super.tearDown()
    }

    /// THE UPGRADE RULE. Nothing stored means everything on, and it is not the same as an
    /// empty selection. Getting this backwards turns an upgrade into thirty nine features
    /// vanishing with no action from the owner and nothing on screen to explain it.
    func testNothingStoredMeansEverythingIsOn() {
        XCTAssertFalse(FeatureSelection.hasChosen, "control: setUp left a selection behind")
        XCTAssertNil(FeatureSelection.stored())
        for row in FeatureRegistry.rows {
            XCTAssertTrue(FeatureSelection.isOn(row.id),
                          "\(row.id) is off on an install that has never chosen")
        }
        XCTAssertFalse(FeatureRegistry.rows.contains {
            FeatureRegistry.state(of: $0) == .notChosen
        }, "a feature reported notChosen before anybody chose anything")
    }

    /// And the other half: choosing nothing is a real answer that must be respected, or the
    /// website's "pick none and it asks for nothing" is a lie.
    func testChoosingNothingIsARealAnswerAndNotTheSameAsSilence() {
        FeatureSelection.choose([])
        XCTAssertTrue(FeatureSelection.hasChosen,
                      "an explicit empty choice was indistinguishable from never choosing")
        XCTAssertEqual(FeatureSelection.stored(), [])
        for row in FeatureRegistry.rows {
            XCTAssertFalse(FeatureSelection.isOn(row.id), "\(row.id) survived an empty choice")
            XCTAssertEqual(FeatureRegistry.state(of: row), .notChosen)
        }
    }

    func testAChosenFeatureGetsARealStateAndAnUnchosenOneDoesNot() {
        FeatureSelection.choose(["home", "chat"])
        XCTAssertTrue(FeatureSelection.isOn("home"))
        XCTAssertFalse(FeatureSelection.isOn("meetings"))

        let meetings = FeatureRegistry.row(id: "meetings")
        XCTAssertEqual(meetings.map(FeatureRegistry.state(of:)), .notChosen,
            "an unchosen feature must not report needs-setup, or it lands in every list of "
            + "things waiting on somebody who already answered")

        let home = FeatureRegistry.row(id: "home")
        XCTAssertNotEqual(home.map(FeatureRegistry.state(of:)), .notChosen)
    }

    /// A feature deleted in an upgrade would otherwise sit in this set forever, counting
    /// toward a total nothing can show.
    func testAnUnknownIdIsDroppedRatherThanKept() {
        FeatureSelection.choose(["home", "a-feature-that-was-deleted"])
        XCTAssertEqual(FeatureSelection.stored(), ["home"])
    }

    func testEnableAndDisableStartFromEverythingOnWhenNobodyHasChosen() {
        XCTAssertFalse(FeatureSelection.hasChosen)
        FeatureSelection.disable("meetings")
        // Disabling one thing must not be read as "chose only that one, inverted": every
        // other feature stays on.
        XCTAssertFalse(FeatureSelection.isOn("meetings"))
        XCTAssertTrue(FeatureSelection.isOn("home"))
        XCTAssertEqual(FeatureSelection.stored()?.count, FeatureRegistry.rows.count - 1)

        FeatureSelection.enable("meetings")
        XCTAssertTrue(FeatureSelection.isOn("meetings"))
        XCTAssertEqual(FeatureSelection.stored()?.count, FeatureRegistry.rows.count)
    }

    /// Clearing forgets that a choice was made, which is not the same as choosing all of
    /// them: a later first run asks again rather than assuming.
    func testClearingForgetsTheChoiceRatherThanSelectingEverything() {
        FeatureSelection.choose(["home"])
        XCTAssertTrue(FeatureSelection.hasChosen)
        FeatureSelection.clear()
        XCTAssertFalse(FeatureSelection.hasChosen)
        XCTAssertNil(FeatureSelection.stored())
        XCTAssertTrue(FeatureSelection.isOn("meetings"))
    }

    /// CR-35 meets CR-36. Speakers on with Meetings off is a selection that cannot do what
    /// was asked, and no capability expresses it.
    func testADependencyLeftOffIsReported() {
        FeatureSelection.choose(["speakers"])
        let unmet = FeatureSelection.unmetDependencies()
        XCTAssertEqual(unmet.map(\.feature.id), ["speakers"])
        XCTAssertEqual(unmet.first?.needs, ["meetings"])

        FeatureSelection.choose(["speakers", "meetings"])
        XCTAssertTrue(FeatureSelection.unmetDependencies().isEmpty,
                      "a satisfied dependency is still being reported")
    }

    /// The locked rule says nothing ships off and undiscoverable. An unchosen feature must
    /// still be enumerable, or "turn it back on" has no starting point.
    func testEveryFeatureStaysEnumerableWhileOff() {
        FeatureSelection.choose([])
        XCTAssertEqual(FeatureRegistry.rows.count, 39,
                       "the registry stopped listing every feature once they were all off")
        for row in FeatureRegistry.rows {
            XCTAssertFalse(row.label.isEmpty, "\(row.id) has no label to show in a list")
        }
    }
}
