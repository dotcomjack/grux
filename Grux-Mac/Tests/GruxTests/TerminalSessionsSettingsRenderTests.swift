import XCTest
import SwiftUI
@testable import Grux

/// Renders the terminal sessions Settings pane, and can write it out as a PNG.
///
/// Same reasoning as `OnboardingRenderTests`: the honest way to look at this is
/// blocked, because photographing it in the running app means opening the
/// owner's Settings and toggling a consent switch that writes to their
/// UserDefaults. Their state is theirs. `NSHostingView` gives real layout at a
/// real size without touching a single file.
///
///     GRUX_SHOT_DIR=/tmp/shots swift test --filter TerminalSessionsSettingsRenderTests
///
/// Without the variable the view is still rendered and still has to lay out, so
/// the crash-and-layout half runs on every suite.
@MainActor
final class TerminalSessionsSettingsRenderTests: XCTestCase {

    /// The narrow floor and a wide window. A pane that only works at one width
    /// has repeatedly turned out to be broken at the other.
    private let sizes: [(String, CGSize)] = [
        ("840x560", CGSize(width: 840, height: 560)),
        ("1400x900", CGSize(width: 1400, height: 900))
    ]

    func testTheSettingsPaneLaysOutAndCanBePhotographed() {
        for (label, size) in sizes {
            let wrapped = ZStack {
                GruxTheme.base
                TerminalSessionsSettingsView()
            }
            .frame(width: size.width, height: size.height)
            .tint(GruxTheme.accentPrimary)

            let host = NSHostingView(rootView: wrapped)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(host.fittingSize.height, 0,
                                 "terminal sessions pane produced no layout at \(label)")

            guard let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"] else { continue }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? FileManager.default.createDirectory(atPath: dir,
                                                     withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("terminalSessions-\(label).png"))
        }
    }

    /// The pane reports which binary will actually run. If the resolver ever
    /// starts throwing or blocking on a slow disk probe, this is where it shows
    /// up, rather than as a hang the first time a user opens Settings.
    func testResolvingTheAgentBinaryIsCheapAndTotal() {
        let started = Date()
        let resolved = AccountSwitcher.resolveClaudeBinary()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                          "resolving the agent CLI took long enough to stall the Settings pane")
        // Either a path or empty. Never a crash, and never a partial token that
        // would render as a nonsense value in the pane.
        XCTAssertFalse(resolved.contains("\n"), "resolved binary contains a newline: \(resolved)")
    }
}
