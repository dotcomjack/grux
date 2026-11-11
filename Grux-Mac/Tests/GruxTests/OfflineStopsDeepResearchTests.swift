import XCTest
@testable import Grux

/// Wave 66 round 1 P2: the README says "Offline mode also turns web search off,
/// because a search sends your question to Brave Search", and Settings says
/// "Not searching now: offline mode is on", but deep research (Studio, Research,
/// and the `deep_research` chat tool) read only the research switch and a Brave
/// key, so with offline mode on it still sent three to six queries to Brave.
/// Every search now stops at the one gate, `WebResearch.blocker`.
@MainActor
final class OfflineStopsDeepResearchTests: XCTestCase {

    func testOfflineModeRefusesDeepResearch() throws {
        let line = try XCTUnwrap(DeepResearchEngine.refusal(offline: true, enabled: true, hasSearchKey: true, chatMovesToClaude: true))
        XCTAssertTrue(line.contains("offline mode is on"), line)
        XCTAssertTrue(line.contains("Brave Search"), line)
        XCTAssertTrue(line.contains("Settings, Models"), line)
    }

    /// Every combination: the refusal is exactly where the shared gate stops a search.
    func testTheRefusalFollowsTheSharedGate() {
        for offline in [false, true] {
            for enabled in [false, true] {
                for key in [false, true] {
                    let gate = WebResearch.blocker(offline: offline, enabled: enabled, hasSearchKey: key)
                    let refusal = DeepResearchEngine.refusal(offline: offline, enabled: enabled, hasSearchKey: key, chatMovesToClaude: true)
                    XCTAssertEqual(refusal == nil, gate == nil, "offline \(offline) enabled \(enabled) key \(key)")
                }
            }
        }
        XCTAssertNil(DeepResearchEngine.refusal(offline: false, enabled: true, hasSearchKey: true, chatMovesToClaude: true))
        XCTAssertEqual(DeepResearchEngine.refusal(offline: false, enabled: false, hasSearchKey: true, chatMovesToClaude: true),
                       "Web research is disabled. Turn it on in Settings, Data & Security, Data & Capabilities, Real-time web research.")
        XCTAssertEqual(DeepResearchEngine.refusal(offline: false, enabled: true, hasSearchKey: false, chatMovesToClaude: true),
                       "Brave Search API key not set. Add it in Settings, Data & Security, Data & Capabilities, Credentials, Web search API key.")
    }

    /// Wave 66 round 2: with offline mode on and no Brave key, the refusal said
    /// turning offline mode off was enough; the person did, and was refused again
    /// for the key. The words name every blocker that applies, and only those.
    func testTheRefusalNamesEveryBlockerThatApplies() throws {
        for offline in [false, true] {
            for enabled in [false, true] {
                for key in [false, true] where offline || !enabled || !key {
                    let line = try XCTUnwrap(DeepResearchEngine.refusal(offline: offline, enabled: enabled, hasSearchKey: key, chatMovesToClaude: true))
                    let label = "offline \(offline) enabled \(enabled) key \(key): \(line)"
                    XCTAssertEqual(line.contains("offline mode"), offline, label)
                    XCTAssertEqual(line.contains("Real-time web research"), !enabled, label)
                    XCTAssertEqual(line.contains("API key"), !key, label)
                    // "Turn offline mode off ... to use it" promises that one step is enough.
                    if offline { XCTAssertEqual(line.contains("to use it"), enabled && key, label) }
                }
            }
        }
    }

    /// The job reads the refusal with the real offline switch before any search.
    func testTheJobChecksTheRefusalBeforeItSearches() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Research/DeepResearchEngine.swift"), encoding: .utf8)
        let check = try XCTUnwrap(src.range(of: "Self.refusal(offline: offline"))
        let read = try XCTUnwrap(src.range(of: "AppState.shared.offlineMode"))
        let search = try XCTUnwrap(src.range(of: "await plan(question:"))
        XCTAssertTrue(read.lowerBound < check.lowerBound && check.lowerBound < search.lowerBound)
    }
}
