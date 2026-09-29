import XCTest
@testable import Grux

/// A macro action kind that shipped and was later removed must not take the
/// person's macro with it.
///
/// `VoiceMacroRegistry.load()` decodes the whole file, then falls back to one
/// macro at a time. Without a per-step skip, one retired step fails its whole
/// macro, and that macro silently disappears from the next save.
final class RetiredMacroKindTests: XCTestCase {

    private func decode(_ json: String) throws -> Macro {
        try JSONDecoder().decode(Macro.self, from: Data(json.utf8))
    }

    /// Anti-vacuity: with an empty list this suite proves nothing.
    func testTheRetiredListIsNotEmpty() {
        XCTAssertEqual(MacroAction.retiredKinds.count, 2)
        for kind in MacroAction.retiredKinds {
            XCTAssertNil(MacroAction.Kind(rawValue: kind), "\(kind) is retired but still decodes as a live kind")
        }
    }

    /// Both schemas: the wrapped step and the legacy bare action.
    func testARetiredStepIsDroppedAndTheRestOfTheMacroSurvives() throws {
        let retired = MacroAction.retiredKinds.sorted()
        let json = """
        {"name": "cockpit", "triggers": ["cockpit"], "description": "d", "actions": [
          {"action": {"kind": "launchApp", "name": "Notes"}, "enabled": true},
          {"action": {"kind": "\(retired[0])"}, "enabled": true},
          {"kind": "\(retired[1])"},
          {"kind": "openURL", "url": "https://example.com"}
        ]}
        """
        let macro = try decode(json)
        XCTAssertEqual(macro.name, "cockpit")
        XCTAssertEqual(macro.actions.map(\.action),
                       [.launchApp(name: "Notes"), .openURL(url: "https://example.com")])
    }

    /// THE CONTROL: a kind that never existed is corruption, not retirement, and
    /// still fails loudly rather than being skipped.
    func testAnUnknownKindStillFailsTheMacro() {
        let json = """
        {"name": "x", "triggers": [], "description": "", "actions": [{"kind": "noSuchKind"}]}
        """
        XCTAssertThrowsError(try decode(json))
    }
}
