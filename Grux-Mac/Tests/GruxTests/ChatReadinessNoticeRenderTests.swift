import XCTest
import SwiftUI
@testable import Grux

/// Renders the not-ready notice, and can write it out as a PNG.
///
///     GRUX_SHOT_DIR=/tmp/shots swift test --filter ChatReadinessNoticeRenderTests
///
/// This is the state that is hardest to see and easiest to ship broken: it only
/// appears on an install with no key and no local model, which is the one
/// configuration a developer never has. Rendering it from an injected state is
/// the only honest way to look at it without deleting somebody's credentials.
@MainActor
final class ChatReadinessNoticeRenderTests: XCTestCase {

    private let sizes: [(String, CGSize)] = [
        ("840x120", CGSize(width: 840, height: 120)),
        ("1400x120", CGSize(width: 1400, height: 120))
    ]

    private func render(_ readiness: ChatReadiness, name: String) {
        for (label, size) in sizes {
            let wrapped = ZStack {
                GruxTheme.base
                ChatReadinessNotice(readiness: readiness, openSettings: {})
            }
            .frame(width: size.width, height: size.height)
            .tint(GruxTheme.accentPrimary)

            let host = NSHostingView(rootView: wrapped)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(name) produced no layout at \(label)")

            guard let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"],
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(label).png"))
        }
    }

    func testNeedsModelRenders() { render(.needsModel, name: "chatNotice-needsModel") }

    func testOfflinePinnedRenders() { render(.offlinePinnedButNoLocalModel, name: "chatNotice-offlinePinned") }

    /// The ready state must render NOTHING. A zero-height bar is the difference
    /// between a quiet composer and a permanent scold above every chat.
    func testReadyRendersNothing() {
        let host = NSHostingView(rootView: ChatReadinessNotice(readiness: .ready, openSettings: {}))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 0,
                       "the ready state still occupies \(host.fittingSize.height)pt above the composer")
    }
}
