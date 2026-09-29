import XCTest
@testable import Grux

/// `~/.grux/rendered-now.txt` is what the panel's Now list last drew, so a
/// headless check can prove a Now row the way `rendered-tab.txt` proves a
/// pane (ledger A16c: the "Claude sign-in expired" row had no seam). Written
/// from a task keyed on the rows, after the list updates.
final class RenderedNowHookTests: XCTestCase {
    func test_oneLinePerRow_classTitleDetailAndAction() {
        let items = [
            PanelItem(id: "claude.signIn", cls: .needsYou, icon: "x", title: "Claude sign-in expired",
                      detail: "Agents cannot run until you sign in", action: .claudeSignIn),
            PanelItem(id: "jobs.running.j1", cls: .running, icon: "cpu", title: "Job",
                      detail: "Agent job", action: .openJob(id: "j1")),
        ]
        XCTAssertEqual(RenderedNow.text(items),
                       "needsYou | Claude sign-in expired | Agents cannot run until you sign in | claudeSignIn\n"
                       + "running | Job | Agent job | openJob(id: \"j1\")\n")
        XCTAssertEqual(RenderedNow.text([]), "", "an empty Now writes an empty file, not a stale one")
    }

    func test_theNowListReportsWhatRendered() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Shell/CommandPanel/PanelNowList.swift"),
                             encoding: .utf8)
        let flat = src.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains(".task(id: items) { await Task.yield() RenderedNow.note(items)"),
                      "the rendered-now hook moved or stopped keying on the rows")
    }
}
