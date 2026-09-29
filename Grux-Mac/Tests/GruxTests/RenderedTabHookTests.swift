import XCTest
@testable import Grux

/// The Phase C gate fires all 35 locked keys and asserts what RENDERED
/// (`tools/grux-tab-keys-check.sh`). That rests on this hook: written from a
/// task keyed on the selection, after the pane updates, never from the path
/// that writes the ack.
final class RenderedTabHookTests: XCTestCase {
    func test_theDetailPaneReportsWhatRendered() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Shell/SurfacePane.swift"), encoding: .utf8)
        // Whitespace collapsed, so re-indenting the pane never fails this; the
        // order still has to be the task keyed on the selection, the yield, then the note.
        let flat = src.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains(".task(id: selection) { await Task.yield() RenderedTab.note(LaunchRootView.tabKey(for: selection))"),
                      "the rendered-tab hook moved or stopped keying on the selection")
        let triggers = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Triggers/AppTriggers.swift"), encoding: .utf8)
        XCTAssertFalse(triggers.contains("RenderedTab.note"), "the ack path writes the rendered tab, which is the lie this exists to avoid")
    }

    func test_everyLockedKeyNamesItselfWhenRendered() {
        for item in SidebarIA.allItems {
            let tab = LaunchRootView.tab(forKey: item.key)
            XCTAssertNotNil(tab, "\(item.key) does not resolve")
            if let tab { XCTAssertEqual(LaunchRootView.tabKey(for: tab), item.key, "\(item.key) renders as another key") }
        }
    }
}
