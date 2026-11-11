import XCTest
@testable import Grux

/// KILL waits until there is an engine Grux has reached.
///
/// Sense pass 8 (D95, `metaAds-1.png`): with no ad engine ever reached on this Mac the
/// command bar read "Not connected · OBSERVE" with a live KILL chip beside it, a stop for
/// something that was never running. `store.snapshot` is nil only when no live pull has
/// ever succeeded AND there is no cached snapshot on disk (`MetaAdsStore` loads the cache
/// at start), so a press could only post to a service Grux has never reached. Once any
/// snapshot exists, live or cached, the chip is there and is never disabled.
final class MetaAdsKillWaitsForAnEngineTests: XCTestCase {

    func testNoEngineEverReachedOffersNoKill() {
        XCTAssertFalse(MetaAdsView.offersKill(nil))
    }

    func testAnySnapshotOffersKill() throws {
        let json = #"{"generatedAt":"","mode":"OBSERVE","killSwitchOn":false,"brands":[],"#
            + #""journal":[],"attention":[]}"#
        let snapshot = try JSONDecoder().decode(MetaAdsSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(MetaAdsView.offersKill(snapshot))
        var halted = snapshot
        halted.killSwitchOn = true
        XCTAssertTrue(MetaAdsView.offersKill(halted), "a halted engine keeps its resume chip")
    }

    func testTheCommandBarShowsKillOnlyThroughTheRule() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/MetaAds/MetaAdsView.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let uses = code.components(separatedBy: "killButton").count - 1
        XCTAssertGreaterThanOrEqual(uses, 2, "Reader is broken: no killButton declaration and use")
        XCTAssertTrue(code.contains("if Self.offersKill(store.snapshot) { killButton }"),
            "the command bar mounts KILL without asking whether an engine was ever reached")
        XCTAssertEqual(uses, 2, "killButton is mounted somewhere besides the guarded command bar")
    }
}
