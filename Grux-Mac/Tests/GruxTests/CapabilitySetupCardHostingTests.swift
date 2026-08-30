import XCTest
import SwiftUI
@testable import Grux

/// The setup card is the ONE surface every unconfigured feature renders, so
/// "can this be placed here" must never depend on what a particular window
/// happened to inject.
///
/// This exists because of a crash that was one commit from shipping. The card
/// declared `@EnvironmentObject private var state: AppState`, which is fine in
/// the main window because `LaunchRootView` injects it. The Empire dashboard is
/// a SEPARATE `NSHostingController` created in `GruxApp.openEmpireDashboardWindow`
/// with no environment at all. Putting the card in the domain tile there would
/// not have degraded or rendered oddly: SwiftUI traps on a missing
/// EnvironmentObject, so the first person without registrar credentials to open
/// that window would have crashed the app.
///
/// The bug is invisible to every other kind of test. It compiles, and it works
/// in the window that happens to inject the object. Only rendering it somewhere
/// bare finds it.
@MainActor
final class CapabilitySetupCardHostingTests: XCTestCase {

    /// Renders the card with NO environment whatsoever. A missing
    /// EnvironmentObject dependency trips SwiftUI's own fatal error here, so a
    /// test that returns at all is the assertion.
    private func renderBare<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 840, height: 560)

        // Body is lazy. Without forcing layout this test would pass by never
        // evaluating the thing it claims to evaluate, which is the vacuous shape
        // this project has already shipped once.
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0,
                             "the card produced no layout, so nothing was actually rendered",
                             file: file, line: line)
    }

    /// The domain monitor is the case that found this: a registry id rather than
    /// a tab, rendered inside a window that injects nothing.
    func testCardRendersWithNoEnvironmentObject() {
        renderBare(CapabilitySetupCard(featureKey: "domains"))
    }

    /// Every adopted tab key, because the gate places this card in all of them
    /// and a per-key difference would be a per-key crash.
    func testCardRendersForEveryRegistryRowWithNoEnvironment() {
        for row in FeatureRegistry.rows {
            renderBare(CapabilitySetupCard(featureKey: row.id))
        }
    }

    /// The gate itself carried the same unused dependency.
    func testGateRendersWithNoEnvironmentObject() {
        renderBare(Text("feature").capabilityGated("domains"))
    }

    /// An id with no registry row is a no-op, not a crash, so adopting a tab
    /// that needs nothing stays harmless.
    func testUnknownFeatureKeyRendersRatherThanTrapping() {
        renderBare(CapabilitySetupCard(featureKey: "no-such-feature-exists"))
        renderBare(Text("feature").capabilityGated("no-such-feature-exists"))
    }
}
