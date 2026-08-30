import CoreGraphics
import XCTest
@testable import Grux

// Screen agency: the actuation half of the loop (click / type / scroll / key)
// plus the AX-element reader. The event-posting paths need a real display and
// the Accessibility grant, so they are exercised by hand in the running app;
// what is covered HERE is everything deterministic: combo parsing, the keycode
// map, coordinate validation, element formatting, tool registration, and the
// two fail-closed gates.
@MainActor
final class ScreenControlTests: XCTestCase {

    // MARK: - Registration

    func testControlScreenToolIsRegistered() {
        let names = Set(ChatService.allTools().map { $0.name })
        XCTAssertTrue(names.contains("control_screen"),
                      "control_screen must be advertised by ChatService.allTools()")
    }

    func testToolSchemaExposesEveryAction() {
        guard let tool = ScreenControlTool.claudeTools().first(where: { $0.name == "control_screen" }) else {
            return XCTFail("control_screen tool missing")
        }
        let props = tool.inputSchema["properties"] as? [String: Any]
        let action = props?["action"] as? [String: Any]
        let cases = Set((action?["enum"] as? [String]) ?? [])
        XCTAssertEqual(cases, ["list_ui", "click_element", "click", "move", "scroll", "type", "key", "check_permission"],
                       "the action enum drifted from what dispatch handles")
        let required = Set((tool.inputSchema["required"] as? [String]) ?? [])
        XCTAssertTrue(required.contains("action"))
    }

    // MARK: - Gate 1: the consent switch

    func testDisabledFeatureIsSkippedNotRun() async {
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = false

        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "click", "x": 10, "y": 10])
        XCTAssertTrue(out.hasPrefix("skipped:"),
                      "with the switch off the tool must skip, not act. Got: \(out)")
    }

    // MARK: - Gate 2: the Accessibility grant

    func testEnabledButUngrantedSurfacesAccessibility() async throws {
        // The test binary is not Grux.app, so it is never AX-trusted; that makes
        // this a deterministic check of the second gate.
        guard !ScreenControlEngine.hasAccessibility() else {
            throw XCTSkip("test host unexpectedly has the Accessibility grant")
        }
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = true

        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "click", "x": 10, "y": 10])
        XCTAssertTrue(out.hasPrefix("error:"), "ungranted actuation must be an error. Got: \(out)")
        XCTAssertTrue(out.localizedCaseInsensitiveContains("accessibility"),
                      "the error must tell the user which permission is missing. Got: \(out)")
    }

    func testUnknownActionIsRejected() async {
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = true
        // check_permission answers without needing the grant; use it so the
        // second gate does not mask the action-validation path we want here.
        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "check_permission"])
        XCTAssertTrue(out.hasPrefix("ok:") || out.hasPrefix("error:"),
                      "check_permission should report status directly. Got: \(out)")
    }

    // MARK: - parseCombo

    func testParseComboSingleKey() {
        let r = ScreenControlEngine.parseCombo("return")
        XCTAssertEqual(r?.keyName, "return")
        XCTAssertEqual(r?.flags, [])
    }

    func testParseComboWithModifiers() {
        guard let r = ScreenControlEngine.parseCombo("cmd+shift+4") else { return XCTFail() }
        XCTAssertEqual(r.keyName, "4")
        XCTAssertTrue(r.flags.contains(.maskCommand))
        XCTAssertTrue(r.flags.contains(.maskShift))
        XCTAssertFalse(r.flags.contains(.maskControl))
    }

    func testParseComboNormalizesAliases() {
        let opt = ScreenControlEngine.parseCombo("option+tab")
        XCTAssertTrue(opt?.flags.contains(.maskAlternate) ?? false)
        let ctrl = ScreenControlEngine.parseCombo("control+a")
        XCTAssertTrue(ctrl?.flags.contains(.maskControl) ?? false)
    }

    func testParseComboEmptyIsNil() {
        XCTAssertNil(ScreenControlEngine.parseCombo("   "))
        XCTAssertNil(ScreenControlEngine.parseCombo(""))
    }

    // MARK: - keyCode

    func testKeyCodeKnownKeys() {
        XCTAssertEqual(ScreenControlEngine.keyCode(for: "c"), 0x08)
        XCTAssertEqual(ScreenControlEngine.keyCode(for: "return"), 0x24)
        XCTAssertEqual(ScreenControlEngine.keyCode(for: "esc"), 0x35)
        XCTAssertEqual(ScreenControlEngine.keyCode(for: "f5"), 0x60)
        XCTAssertEqual(ScreenControlEngine.keyCode(for: "5"), 0x17)
    }

    func testKeyCodeUnknownIsNil() {
        XCTAssertNil(ScreenControlEngine.keyCode(for: "zzz"))
        XCTAssertNil(ScreenControlEngine.keyCode(for: "hyperspace"))
    }

    // MARK: - "plus" has to be a plus

    /// `parseCombo`'s own doc says a literal "+" is expressed as "plus", and the
    /// keycode table maps BOTH "plus" and "equals" to 0x18 while `pressKey` sets
    /// flags only from the modifier tokens. 0x18 unshifted is "=", so
    /// `control_screen action="key" keys="plus"` pressed "=" and every zoom-in
    /// the model reached for did nothing at all.
    ///
    /// On the US layout this keycode table is built from, "+" IS shift-equals.
    /// The shift belongs to the key, not to something the caller has to know.
    func testPlusCarriesTheShiftThatMakesItAPlus() {
        guard let r = ScreenControlEngine.parseCombo("plus") else {
            return XCTFail("\"plus\" did not parse")
        }
        XCTAssertEqual(r.keyName, "plus")
        XCTAssertTrue(r.flags.contains(.maskShift),
                      "\"plus\" is shift-equals; without the shift this posts \"=\"")
        XCTAssertEqual(ScreenControlEngine.keyCode(for: r.keyName), 0x18)
    }

    /// The other half of the pair. "equals" still means "=", so the fix cannot
    /// have been "shift everything on 0x18".
    func testEqualsIsNotSilentlyShifted() {
        guard let r = ScreenControlEngine.parseCombo("equals") else {
            return XCTFail("\"equals\" did not parse")
        }
        XCTAssertFalse(r.flags.contains(.maskShift), "\"equals\" means =, not +")
        XCTAssertEqual(ScreenControlEngine.keyCode(for: r.keyName), 0x18)
    }

    /// The real call. "cmd+plus" is zoom in, and it needs BOTH the command the
    /// caller asked for and the shift the key implies.
    func testCmdPlusKeepsTheCallersModifierAndAddsTheImplicitOne() {
        guard let r = ScreenControlEngine.parseCombo("cmd+plus") else {
            return XCTFail("\"cmd+plus\" did not parse")
        }
        XCTAssertTrue(r.flags.contains(.maskCommand), "the caller's own modifier was dropped")
        XCTAssertTrue(r.flags.contains(.maskShift), "the shift that makes it a plus was not added")
    }

    /// Control: an ordinary key gains nothing. If this failed, the implicit
    /// shift would be leaking onto every combo and the two tests above would be
    /// passing for the wrong reason.
    func testAnOrdinaryKeyGainsNoImplicitModifier() {
        XCTAssertEqual(ScreenControlEngine.parseCombo("c")?.flags, [])
        XCTAssertEqual(ScreenControlEngine.parseCombo("minus")?.flags, [])
    }

    // MARK: - What the user is actually shown

    /// The skip message read "screen control is disabled
    /// (config.screenControlEnabled = false)", and ChatService's system prompt
    /// tells the model to relay that ONE line. So somebody who had simply left a
    /// switch off was shown the name of a Swift property.
    ///
    /// The same range strips ":3847" from CreativeEngine and "port 3857" from
    /// the Meta Ads subtitle on exactly this ground: internal plumbing is not a
    /// fact the reader has, and naming it teaches nothing and costs trust.
    func testTheDisabledMessageNamesTheSwitchAndNotTheField() async {
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = false

        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "click", "x": 10, "y": 10])

        XCTAssertTrue(out.hasPrefix("skipped:"), "got: \(out)")
        XCTAssertFalse(out.contains("config."),
                       "an internal config field reached user-facing copy: \(out)")
        XCTAssertFalse(out.contains("screenControlEnabled"),
                       "a Swift identifier reached user-facing copy: \(out)")
        // Removing the jargon is only half of it. The line still has to name the
        // switch and where it lives, or the user cannot act on it.
        XCTAssertTrue(out.contains("Screen control"), "it must name the switch: \(out)")
        XCTAssertTrue(out.contains("Settings"), "and where to find it: \(out)")
    }

    // MARK: - Coordinate + wheel guards

    func testValidPointRejectsNonFinite() {
        XCTAssertNil(ScreenControlEngine.validPoint(.nan, 10))
        XCTAssertNil(ScreenControlEngine.validPoint(10, .infinity))
        XCTAssertEqual(ScreenControlEngine.validPoint(12, 34), CGPoint(x: 12, y: 34))
    }

    func testClampWheelBounds() {
        XCTAssertEqual(ScreenControlEngine.clampWheel(9999), 3000)
        XCTAssertEqual(ScreenControlEngine.clampWheel(-9999), -3000)
        XCTAssertEqual(ScreenControlEngine.clampWheel(120), 120)
    }

    // MARK: - Element formatting

    func testElementLineIsClickReady() {
        let el = ScreenControlEngine.UIElementInfo(
            role: "AXButton", title: "Submit", value: "",
            frame: CGRect(x: 100, y: 200, width: 80, height: 30))
        let line = el.line(index: 3)
        XCTAssertTrue(line.contains("AXButton"))
        XCTAssertTrue(line.contains("\"Submit\""))
        // center of (100,200,80,30) is (140,215)
        XCTAssertTrue(line.contains("center=(140,215)"), "got: \(line)")
        XCTAssertTrue(line.contains("size=80x30"))
        XCTAssertTrue(line.hasPrefix("#3 "))
    }

    func testElementClipTruncates() {
        let long = String(repeating: "x", count: 200)
        XCTAssertLessThanOrEqual(ScreenControlEngine.UIElementInfo.clip(long, 60).count, 61)
        XCTAssertEqual(ScreenControlEngine.UIElementInfo.clip("short", 60), "short")
    }
}
