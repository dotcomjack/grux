import XCTest
import SwiftUI
@testable import Grux

/// C14: the first-run rail, in pixels. Renders the legacy shell's own
/// `LaunchRootView` on the suite's clean state (a fresh temporary support
/// directory: the default config, the Developer door locked, no brands) and
/// writes the capture that the evidence file cites. The legacy shell stays one
/// release behind `legacyShell`; the panel's capture is FirstRunPanelCaptureTests.
@MainActor
final class FirstRunRailCaptureTests: XCTestCase {
    func test_theLegacyRailIsFourteenRows_inPixels() throws {
        let state = AppState.shared
        XCTAssertFalse(state.config.developerSurfacesUnlocked, "the suite's state is not a first run")
        XCTAssertTrue(BrandRoster.labelsOnDisk().isEmpty, "the suite's state already has a brand")
        let rail = SidebarIA.rail(developerUnlocked: state.config.developerSurfacesUnlocked,
                                  brands: BrandRoster.brands.map(\.label))
        XCTAssertEqual(rail.count, 14, "rail: \(rail.map(\.label))")
        // Both doors shut on a fresh install, or the Labs door opens itself
        // and a first run shows 21 lines (measured on this render, 2026-09-21).
        XCTAssertFalse(SidebarStateStore.shared.isExpanded("door.labs"), "the Labs door opened itself on a first run")
        XCTAssertFalse(SidebarStateStore.shared.isExpanded("door.developer"))

        // The rail a new person sees is the one right after setup: finish the
        // flow in the suite's scratch state, never the operator's.
        OnboardingModel.shared.finish(skippedFirstLook: true)
        XCTAssertEqual(OnboardingModel.shared.stage, .done)

        let host = NSHostingView(rootView: LaunchRootView().environmentObject(state).frame(width: 1040, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 1040, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let out = ProcessInfo.processInfo.environment["GRUX_FIRST_RUN_CAPTURE"] {
            try png.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertGreaterThan(png.count, 10_000, "the render came out empty")
    }
}
