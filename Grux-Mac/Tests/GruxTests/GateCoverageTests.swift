import XCTest
@testable import Grux

/// EVERY TOOL IS TRIAGED, OR THE BUILD SAYS SO.
///
/// `JaxToolGate.evaluate` ends in a fallback that wraps anything it does not
/// recognise as "Run tool '<name>' (unclassified side effect)" and queues it for
/// approval. That is the right failure for an unknown tool and the wrong
/// experience for a known one, and nothing made the difference visible.
///
/// Measured 2026-09-23: 72 of 116 tools hit that fallback. The operator's
/// approval queue showed 11 waiting, including three identical cards for
/// `fs_list`, a sandboxed directory listing. "Open Chrome" spoken aloud queued
/// `open_app` and never ran, and Grux answered about an unrelated swarm job
/// because the tool it called returned nothing.
///
/// The same bug had already been fixed twice as individual instances, and the
/// comments in `safeReadOnlyTools` record both: `design_list_projects` queued so
/// the Design Studio never rendered, and `search_memory` queued so Grux said
/// nothing came back from memory. This test is the class.
@MainActor
final class GateCoverageTests: XCTestCase {

    private func classification(of name: String) -> String? {
        if JaxToolGate.safeReadOnlyTools.contains(name) { return "safe" }
        if JaxToolGate.selfGating.contains(name) { return "self-gating" }
        if JaxToolGate.knowinglyGated.contains(name) { return "knowingly gated" }
        if JaxToolGate.classify(name: name, input: [:]) != nil { return "classified" }
        return nil
    }

    func test_noToolFallsThroughToTheOpaqueFallback() {
        let all = ChatService.allTools().map(\.name)
        XCTAssertGreaterThan(all.count, 50, "control: the tool registry did not load, so this proves nothing")

        let orphans = all.filter { classification(of: $0) == nil }.sorted()
        XCTAssertTrue(orphans.isEmpty,
                      "\(orphans.count) tool(s) reach the gate with no decision behind them, so each one "
                      + "queues for approval as an 'unclassified side effect': \(orphans.joined(separator: ", "))")
    }

    /// A tool cannot be both waved through and deliberately gated. If it is in
    /// both lists the safe list wins silently, which is the dangerous direction.
    func test_aToolIsNeverBothSafeAndGated() {
        let both = JaxToolGate.safeReadOnlyTools.intersection(JaxToolGate.knowinglyGated).sorted()
        XCTAssertTrue(both.isEmpty,
                      "these are on both lists, and safe wins: \(both.joined(separator: ", "))")
    }

    /// The things that must never be waved through, whatever else changes.
    func test_theShellAndTheDestructiveToolsAreNeverSafe() {
        for name in ["shell_run", "shell_run_confirmed", "shell_start", "shell_undo",
                     "fs_write", "fs_write_outside_roots", "delete_folder", "delete_speaker",
                     "control_screen", "agent_swarm_start"] {
            XCTAssertFalse(JaxToolGate.safeReadOnlyTools.contains(name),
                           "\(name) was added to the safe list, which lets it run with no approval")
        }
    }

    /// The two the operator hit, named so a later edit cannot quietly undo them.
    func test_openingAnAppAndListingFilesDoNotNeedPermission() {
        for name in ["open_app", "open_url", "fs_list", "fs_read"] {
            XCTAssertEqual(classification(of: name), "safe",
                           "\(name) queues for approval again; spoken 'open Chrome' silently does nothing")
        }
    }

    /// Both lists are about tools that exist. An entry for a tool that is gone
    /// is a stale opinion, and it hides the real coverage number.
    func test_neitherListNamesAToolThatNoLongerExists() {
        let all = Set(ChatService.allTools().map(\.name))
        let staleSafe = JaxToolGate.safeReadOnlyTools.subtracting(all).sorted()
        let staleGated = JaxToolGate.knowinglyGated.subtracting(all).sorted()
        XCTAssertTrue(staleSafe.isEmpty, "safe list names tools that do not exist: \(staleSafe.joined(separator: ", "))")
        XCTAssertTrue(staleGated.isEmpty, "gated list names tools that do not exist: \(staleGated.joined(separator: ", "))")
    }
}
