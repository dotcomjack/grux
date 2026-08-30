import XCTest
@testable import Grux

/// The sidebar dot and the central count.
///
/// Both read from `FeatureRegistry`, which is the point: before this, the
/// sidebar's status bar carried two hardcoded prompts, a "Grant screen
/// recording" button and an "Add Anthropic API key in Settings" line. Each spoke
/// for exactly one capability, so the other 38 had no central representation at
/// all, and both were orange, which reads as a warning for something the
/// contract defines as a state rather than a failure.
@MainActor
final class SidebarNeedsSetupTests: XCTestCase {

    /// The count and the dots have to agree, or the sidebar says two different
    /// things at once. Every tab showing a dot must be counted, and the count
    /// must not exceed what the registry knows about.
    func testTheCountMatchesTheTabsThatShowADot() {
        let counted = FeatureRegistry.featuresNeedingSetup.count

        var dotted = 0
        for row in FeatureRegistry.rows where FeatureRegistry.state(of: row) == .needsSetup {
            dotted += 1
        }

        XCTAssertEqual(counted, dotted)
        XCTAssertLessThanOrEqual(counted, FeatureRegistry.rows.count)
    }

    /// Only two CAPABILITY states are ever rendered. `degraded` collapses to ready and
    /// `unavailable` to needs-setup, so a row must never report a third thing to a surface
    /// that can only draw two.
    ///
    /// Asks `capabilityState`, not `state`, since CR-36. Selection is now part of the full
    /// answer and this test is about capabilities: reading `state` here would make it depend
    /// on whatever the last test left in UserDefaults, which it did, and thirty nine
    /// assertions failed because an unrelated test had chosen nothing.
    func testOnlyReadyAndNeedsSetupAreEverReported() {
        for row in FeatureRegistry.rows {
            let state = FeatureRegistry.capabilityState(of: row)
            XCTAssertTrue(state == .ready || state == .needsSetup,
                          "\(row.id) reported \(state), which no surface renders")
        }
    }

    /// The selection-aware answer may additionally be `notChosen`, and nothing else. A
    /// fifth state that leaked a sixth would reach a sidebar that cannot draw it.
    func testTheSelectionAwareStateAddsExactlyOneMorePossibility() {
        let allowed: Set<FeatureState> = [.ready, .needsSetup, .notChosen]
        for row in FeatureRegistry.rows {
            XCTAssertTrue(allowed.contains(FeatureRegistry.state(of: row)),
                          "\(row.id) reported \(FeatureRegistry.state(of: row))")
        }
    }

    /// The count is a link and it has to arrive somewhere real. Resolving to the
    /// General pane, which is what the unmatched fallback returns, would open the
    /// one pane that mentions no capabilities at all.
    func testTheCountDeepLinksToTheCredentialsList() {
        let location = SettingsTabAliases.resolve("capabilities")

        XCTAssertEqual(location.pane, .dataSecurity,
                       "the count resolved to \(location.pane), which is the unmatched fallback")
        XCTAssertEqual(location.sub, "capabilities")
        XCTAssertEqual(location.anchor, "data.credentials")
    }

    /// The words somebody would actually type to find the same list.
    func testSearchFindsTheCapabilitiesList() {
        for query in ["capabilities", "credentials", "api keys", "keys", "needs setup"] {
            let location = SettingsTabAliases.resolve(query)
            XCTAssertEqual(location.anchor, "data.credentials",
                           "searching \"\(query)\" does not reach the credentials list")
        }
    }

    /// A tab with no registry row is ready, so adopting a tab that needs nothing
    /// never puts a dot on it.
    func testATabWithNoRowShowsNoDot() {
        XCTAssertEqual(FeatureRegistry.state(forTab: "no-such-tab-exists"), .ready)
    }

    /// The two prompts this replaced are gone from the sidebar. A source scan,
    /// because the failure mode is somebody adding a third one beside the count
    /// rather than the count itself breaking.
    func testTheSidebarHasNoHardcodedSetupPrompts() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Grux/LaunchRootView.swift"),
            encoding: .utf8)

        // Comments are excluded, and the first run of this test is why: it
        // failed on the comment that explains what was removed, which is exactly
        // the note a future reader most needs. A guard that forbids describing
        // the bug it guards against makes the code worse.
        let live = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")

        for gone in ["Grant screen recording", "Add Anthropic API key in Settings"] {
            XCTAssertFalse(live.contains(gone),
                           "'\(gone)' is a hardcoded prompt for one capability; the registry "
                           + "count speaks for all of them")
        }
    }
}
