import SwiftUI
import XCTest
@testable import Grux

/// D57: a pane opened while its feature is not in the onboarding selection drew
/// no setup card. Meetings on a Mac that never chose it offered Start with the
/// microphone and screen recording both refused, because the gate asked
/// `state(forTab:)`, which answers `.notChosen` before it looks at a single
/// capability. The selection decides what the sidebar lists; a pane somebody
/// opened anyway still says what it needs.
@MainActor
final class UnchosenPaneGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
        super.tearDown()
    }

    /// A selection that leaves out every gated feature changes no pane's card.
    func testTheSelectionNeverDecidesAPanesCard() {
        FeatureSelection.choose(["home"])
        for row in FeatureRegistry.rows {
            XCTAssertEqual(CapabilityGate<EmptyView>.showsSetupCard(forTab: row.id),
                           !FeatureRegistry.missing(forTab: row.id).isEmpty,
                           "\(row.id), left out of the selection, decided its card from the selection")
        }
    }

    /// The live answer, on the selection this Mini's owner made: Meetings left out.
    func testMeetingsLeftOutOfTheSelectionStillNamesWhatItNeeds() {
        FeatureSelection.choose(["home", "chat", "settings"])
        XCTAssertEqual(FeatureRegistry.state(forTab: "meetings"), .notChosen,
                       "control: the selection did not leave Meetings out")
        let missing = FeatureRegistry.missing(forTab: "meetings")
        XCTAssertEqual(CapabilityGate<EmptyView>.showsSetupCard(forTab: "meetings"), !missing.isEmpty,
                       "Meetings left out of the selection and missing \(missing) drew no card")
    }

    func testATabWithNoRowStillShowsNoCard() {
        FeatureSelection.choose(["home"])
        XCTAssertFalse(CapabilityGate<EmptyView>.showsSetupCard(forTab: "roadmap"))
    }
}
