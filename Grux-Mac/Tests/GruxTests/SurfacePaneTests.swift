import XCTest
import SwiftUI
@testable import Grux

/// The 36-case switch lives in one place and both shells host it.
@MainActor
final class SurfacePaneTests: XCTestCase {
    private func sources(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_theSwitchLeftLaunchRootView() throws {
        let root = try sources("Sources/Grux/LaunchRootView.swift")
        XCTAssertFalse(root.contains("case .reactor: ReactorView()"), "the surface switch is still in LaunchRootView")
        XCTAssertTrue(root.contains("SurfacePane(selection: $selection)"), "the legacy shell does not host SurfacePane")
    }

    func test_everyTabCaseIsRenderedBySurfacePane() throws {
        let pane = try sources("Sources/Grux/Shell/SurfacePane.swift")
        for item in SidebarIA.allItems {
            let tab = try XCTUnwrap(LaunchRootView.tab(forKey: item.key))
            let name = LaunchRootView.tabKey(for: tab)
            XCTAssertTrue(pane.contains(".\(name)"), "SurfacePane never mentions .\(name)")
        }
        XCTAssertTrue(pane.contains("case .labs"))
        XCTAssertTrue(pane.contains("case .tuning"))
    }

    /// Renders in a bare hosting view, and the rendered-tab hook reports the
    /// surface that drew: the file the tab-keys gate reads says `reactor`.
    func test_itRendersWithoutAWindow() throws {
        var sel = LaunchRootView.Tab.settings
        let binding = Binding(get: { sel }, set: { sel = $0 })
        let host = NSHostingView(rootView: SurfacePane(selection: binding).environmentObject(AppState.shared)
            .frame(width: 680, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 500)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0, "the pane has no width")
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the pane has no height")

        // The hook writes under the suite's scratch gruxDir, never the operator's.
        XCTAssertTrue(RenderedTab.fileURL.path.hasPrefix(Persistence.gruxDir.path))
        try? FileManager.default.removeItem(at: RenderedTab.fileURL)
        var reactor = LaunchRootView.Tab.reactor
        let reactorBinding = Binding(get: { reactor }, set: { reactor = $0 })
        let reactorHost = NSHostingView(rootView: SurfacePane(selection: reactorBinding).environmentObject(AppState.shared)
            .frame(width: 680, height: 500))
        reactorHost.frame = NSRect(x: 0, y: 0, width: 680, height: 500)
        let window = NSWindow(contentRect: reactorHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reactorHost
        reactorHost.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2.0)
        while (try? String(contentsOf: RenderedTab.fileURL, encoding: .utf8)) != "reactor", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(try? String(contentsOf: RenderedTab.fileURL, encoding: .utf8), "reactor",
                       "the rendered-tab hook did not report the surface that drew")
        window.contentView = nil
    }
}
