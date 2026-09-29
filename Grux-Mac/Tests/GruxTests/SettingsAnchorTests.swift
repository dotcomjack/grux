import XCTest
@testable import Grux

/// Every way into Settings lands where it says it does.
///
/// The deep links and the search results both carry an ANCHOR, and nothing
/// checked that the anchor exists. A dead one is silent by construction: the
/// pane opens, `scrollTo` addresses an id nothing draws, and the reader is left
/// at the top of a long pane with no sign that anything was meant to be there.
/// That is what the retired `fal` alias did (`data.fal`, an anchor no pane has
/// drawn since the vendor was replaced), and it is what a renamed section will
/// do the next time one is renamed.
@MainActor
final class SettingsAnchorTests: XCTestCase {

    private static func settingsSources() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        // Settings is drawn by its own file plus the sections it embeds, so
        // every file under Sources/Grux is read: an anchor may live in any of
        // them, and a scan that guesses which ones is a scan that lies.
        var out = ""
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        for case let url as URL in walker ?? .init() where url.pathExtension == "swift" {
            out += try String(contentsOf: url, encoding: .utf8)
        }
        return out
    }

    /// Control plus the rule: the scan can find a known-present anchor, and
    /// then every anchor in the registry and the alias table is drawn.
    func test_everyAnchorSomethingNavigatesToIsActuallyDrawn() throws {
        let src = try Self.settingsSources()
        XCTAssertTrue(src.contains(".id(\"general.about\")"),
                      "control: the scan cannot see a known-present anchor, so its zeros mean nothing")
        XCTAssertFalse(src.contains(".id(\"data.fal\")"), "control: this anchor was deleted and should not be found")

        var checked = 0
        for entry in SettingsSearchRegistry.entries {
            guard let anchor = entry.location.anchor else { continue }
            checked += 1
            XCTAssertTrue(src.contains(".id(\"\(anchor)\")"),
                          "search result \(entry.id) scrolls to \(anchor), which nothing draws")
        }
        for (tag, loc) in SettingsTabAliases.map {
            guard let anchor = loc.anchor else { continue }
            checked += 1
            XCTAssertTrue(src.contains(".id(\"\(anchor)\")"),
                          "the \(tag) deep link scrolls to \(anchor), which nothing draws")
        }
        XCTAssertGreaterThan(checked, 30, "the scan checked almost nothing, so it proved almost nothing")
    }

    /// A deep link's scroll is tried more than once, because the pane it lands
    /// in may not have built the row yet. One attempt at 80ms is what left
    /// `settings:memory` and `settings:brands` at the top of the pane.
    func test_theScrollIsAttemptedMoreThanOnce_andGivesUpEventually() {
        let attempts = SettingsView.anchorScrollAttempts
        XCTAssertGreaterThan(attempts.count, 1, "one attempt assumes the pane is already built")
        XCTAssertEqual(attempts, attempts.sorted(), "the attempts are out of order")
        XCTAssertLessThan(attempts.last ?? 0, 2.0, "an attempt this late would fight a person already scrolling")
        XCTAssertGreaterThan(attempts.last ?? 0, attempts.first ?? 0)
    }

    /// Every sub-pane that can be deep-linked wires the proxy, or its anchors
    /// are unreachable however many times the scroll is tried.
    func test_everyPaneWithAnchorsListensForTheScroll() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Grux/SettingsView.swift"),
                                  encoding: .utf8)
        // Two call sites per wired pane: onAppear and onChange.
        let wired = settings.components(separatedBy: "scrollToPendingAnchor(proxy)").count - 1
        let readers = settings.components(separatedBy: "ScrollViewReader { proxy in").count - 1
        XCTAssertEqual(wired % 2, 0, "a pane listens on appear and not on change, or the other way round")
        XCTAssertEqual(wired / 2, readers,
                       "\(readers) panes scroll and \(wired / 2) listen: one of them cannot honour a deep link")
        XCTAssertGreaterThanOrEqual(readers, 6, "a pane lost its scroll wiring entirely")

        // AND THE PANE IS REACHED THROUGH THE WRAPPER. Counting readers is not
        // enough: a wrapper can sit in the file, unused, while the switch
        // renders the bare view. That is exactly what Sessions did until
        // 2026-09-22, and swapping it back leaves every count above unchanged.
        // A wrapper is rendered from a switch arm (`case "x": xSub`, or the
        // `default:` arm for the pane's first tab), so an arm that names the
        // bare view instead is what this catches.
        for wrapper in ["sessionsSub", "voiceSub", "ambientSub", "modelsConfigSub"] {
            XCTAssertTrue(settings.contains(": \(wrapper)\n"),
                          "\(wrapper) is not rendered from a switch arm, so its pane cannot honour a deep link")
            XCTAssertGreaterThan(settings.components(separatedBy: wrapper).count - 1, 1,
                                 "\(wrapper) is defined and never used")
        }
    }
}
