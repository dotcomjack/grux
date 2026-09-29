import XCTest
import SwiftUI
@testable import Grux

/// Chat is one column beside the panel: the threads sidebar folds behind a
/// button when hosted in a pane, and stays a column in the legacy shell.
@MainActor
final class ChatPaneFoldTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)
    }

    /// Runs of whitespace collapsed to one space, so the pins below hold the
    /// order of the code and not its indentation (the R4.1 rule).
    private func collapsedSource() throws -> String {
        try source().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Where `needle` starts in the collapsed source, failing when absent.
    private func position(of needle: String, in src: String,
                          file: StaticString = #filePath, line: UInt = #line) -> String.Index? {
        let r = src.range(of: needle)
        XCTAssertNotNil(r, "missing: \(needle)", file: file, line: line)
        return r?.lowerBound
    }

    private let foldedButton = "if hostedInPane { Button { threadsPopover.toggle() }"

    func test_chatReadsHostedInPane() throws {
        XCTAssertTrue(try source().contains("@Environment(\\.hostedInPane)"))
    }

    func test_theThreadsColumnIsConditional() throws {
        let src = try collapsedSource()
        XCTAssertTrue(src.contains("if !hostedInPane { ChatThreadsSidebar()"),
                      "the threads sidebar must be a column only outside a pane")
        XCTAssertTrue(src.contains("threadsPopover"), "no folded threads control")
    }

    func test_theFoldedButtonPresentsTheThreadsList() throws {
        let src = try collapsedSource()
        let button = position(of: foldedButton, in: src)
        let popover = position(
            of: ".popover(isPresented: $threadsPopover, arrowEdge: .bottom) { ChatThreadsSidebar()", in: src)
        if let button, let popover {
            XCTAssertLessThan(button, popover, "the popover must hang off the folded button")
        }
    }

    func test_pickingAThreadClosesTheFoldedList() throws {
        // The folded branch watches the active thread and the list together
        // and closes the popover on a pick, without touching
        // ChatThreadsSidebar (R7.3, R7.4).
        let src = try collapsedSource()
        let button = position(of: foldedButton, in: src)
        let dismiss = position(
            of: ".onChange(of: ThreadsSnapshot(active: state.activeThreadId, ids: state.threads.map(\\.id))) { old, new in if Self.pickClosesThreads(from: old, to: new) { threadsPopover = false } }",
            in: src)
        if let button, let dismiss {
            XCTAssertLessThan(button, dismiss, "the dismiss must sit on the folded button")
        }
    }

    func test_onlyAPickOfAnExistingThreadCloses() {
        let a = UUID(), b = UUID(), c = UUID()
        let before = ChatView.ThreadsSnapshot(active: a, ids: [a, b])
        // A pick: b already existed, the list is the same threads (re-sorted
        // by switchThread's refresh).
        XCTAssertTrue(ChatView.pickClosesThreads(
            from: before, to: .init(active: b, ids: [b, a])), "a pick closes the list")
        // "+": a new thread becomes active; the list stays open for its rename.
        XCTAssertFalse(ChatView.pickClosesThreads(
            from: before, to: .init(active: c, ids: [c, a, b])), "\"+\" keeps the list open")
        // Deleting the active thread hops to the next one; the list stays open.
        XCTAssertFalse(ChatView.pickClosesThreads(
            from: before, to: .init(active: b, ids: [b])), "a delete keeps the list open")
        // Deleting another thread leaves the active one; nothing to close.
        XCTAssertFalse(ChatView.pickClosesThreads(
            from: before, to: .init(active: a, ids: [a])), "no pick, no close")
    }

    func test_thePaneMinimumIsBelowThePaneWidth() throws {
        // 560 was threads 210 + conversation 350. Folded, the conversation
        // alone must fit the pane budget with room to spare.
        XCTAssertEqual(ChatView.paneMinWidth, 350)
        XCTAssertLessThanOrEqual(ChatView.paneMinWidth, GruxLayout.paneWidth - GruxSpacing.xl)
        XCTAssertTrue(try collapsedSource().contains(".frame(minWidth: hostedInPane ? Self.paneMinWidth : 560"),
                      "the frame floor must drop to paneMinWidth in a pane")
    }
}
