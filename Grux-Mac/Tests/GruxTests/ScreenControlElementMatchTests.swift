import CoreGraphics
import XCTest
@testable import Grux

/// WHICH ELEMENT `click_element` clicks, which is the second screen-control
/// decision whose wrongness is invisible.
///
/// `click_element label="Submit"` collapses the two-turn coordinate loop
/// (list_ui to learn a point, then click that point) into one engine-side step:
/// a fresh AX read, this pure match, a click at the match's center. The match is
/// the part that can silently pick the wrong control, so it is tested as a PURE
/// FUNCTION over hand-built element lists, headless, exactly like `pickTarget`.
///
/// The discipline under test is the same one the app-targeting bug was about: a
/// preference is a SCORE, never array position. An exact label beats a prefix
/// beats a substring, and only equal scores fall back to reading order.
final class ScreenControlElementMatchTests: XCTestCase {

    // MARK: - Builders

    private func el(_ role: String, _ title: String, value: String = "",
                    at x: Double = 10, _ y: Double = 10) -> ScreenControlEngine.UIElementInfo {
        ScreenControlEngine.UIElementInfo(
            role: role, title: title, value: value,
            frame: CGRect(x: x, y: y, width: 40, height: 20))
    }

    // MARK: - Score ordering

    /// The whole reason this is not `first(where:)`: an exact hit must win over a
    /// substring hit no matter where each sits in the list. If the exact match
    /// came last it would still be the answer.
    func testExactTitleBeatsASubstringMatchRegardlessOfOrder() {
        let elements = [
            el("AXButton", "Save As…"),   // #0 prefix hit
            el("AXButton", "Autosave"),   // #1 substring hit
            el("AXButton", "Save"),       // #2 exact
        ]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "Save", role: nil, nth: nil, among: elements), 2,
            "the button literally called Save is what \"Save\" means, even though a prefix and a substring come first")
    }

    /// Prefix sits between exact and substring: "Sign in" is a better answer to
    /// "sign" than "Please sign in below".
    func testPrefixBeatsSubstring() {
        let elements = [
            el("AXButton", "Please sign in below"),  // #0 substring
            el("AXButton", "Sign in"),               // #1 prefix
        ]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "sign", role: nil, nth: nil, among: elements), 1)
    }

    /// Case and surrounding whitespace are not part of the question, matching the
    /// verifier's own normalisation (the two share `normalizeMatch`).
    func testMatchIsCaseAndWhitespaceInsensitive() {
        let elements = [el("AXButton", "  Sign   In  ")]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "sign in", role: nil, nth: nil, among: elements), 0)
    }

    // MARK: - No match is nil, never a guess

    /// Nothing matched is an honest nil, which the tool turns into "here is what
    /// IS on screen" rather than clicking whatever sat first. A silent wrong
    /// click is the exact failure this action exists to remove.
    func testNoMatchResolvesToNothing() {
        let elements = [el("AXButton", "Cancel"), el("AXButton", "OK")]
        XCTAssertNil(
            ScreenControlEngine.matchElement(query: "Purchase", role: nil, nth: nil, among: elements))
    }

    func testEmptyElementListIsNil() {
        XCTAssertNil(ScreenControlEngine.matchElement(query: "Save", role: nil, nth: nil, among: []))
    }

    // MARK: - Role filter

    /// A role narrows the field: "the Search field", not the "Search" button
    /// next to it. Without the filter the button (a title hit) would win.
    func testRoleFilterNarrowsToTheRightKind() {
        let elements = [
            el("AXButton", "Search"),                    // #0
            el("AXTextField", "Search", value: "Search"), // #1
        ]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "Search", role: "field", nth: nil, among: elements), 1,
            "role=field must skip the Search button and land on the Search field")
    }

    /// An element outside the role family is not a match even on an exact label.
    func testRoleFilterExcludesOtherRolesEntirely() {
        let elements = [el("AXButton", "Submit")]
        XCTAssertNil(
            ScreenControlEngine.matchElement(query: "Submit", role: "link", nth: nil, among: elements),
            "there is no link called Submit, so role=link must not fall through to the button")
    }

    /// An UNRECOGNISED role is treated as no filter, not as match-nothing: a user
    /// saying "dropdown" should still reach a pop-up button by its text.
    func testUnknownRoleFallsBackToNoFilter() {
        let elements = [el("AXPopUpButton", "Country")]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "Country", role: "dropdown", nth: nil, among: elements), 0)
    }

    /// The role vocabulary the schema advertises actually resolves. A drift
    /// between the words the tool offers and the words the matcher understands
    /// would silently filter to nothing.
    func testAdvertisedRoleWordsAllResolve() {
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "button"))
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "link"))
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "field"))
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "checkbox"))
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "menu"))
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "tab"))
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "radio"))
        XCTAssertNotNil(ScreenControlEngine.roleFamily(for: "slider"))
        XCTAssertTrue(ScreenControlEngine.roleFamily(for: "button")?.contains("AXButton") ?? false)
    }

    // MARK: - nth disambiguation

    /// Two identical controls are broken by reading order (the AX-walk order the
    /// list is already in), and `nth` walks that order. "The second Save" is the
    /// later one in the list.
    func testNthPicksAmongEqualLabelsInReadingOrder() {
        let elements = [
            el("AXButton", "Delete", at: 10, 10),  // #0
            el("AXButton", "Delete", at: 10, 90),  // #1
        ]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "Delete", role: nil, nth: 1, among: elements), 0)
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "Delete", role: nil, nth: 2, among: elements), 1)
    }

    /// `nth` past the number of matches is nil, not a wrap-around to the first.
    /// Clicking "the third" when there are two is a mistake, and inventing a
    /// target for it is the wrong-click failure again.
    func testNthPastTheMatchesIsNil() {
        let elements = [el("AXButton", "Delete"), el("AXButton", "Delete")]
        XCTAssertNil(
            ScreenControlEngine.matchElement(query: "Delete", role: nil, nth: 3, among: elements))
    }

    /// An empty query with a role is the "the third link" case: no label to
    /// match, so every link is an equal candidate and `nth` selects in order.
    func testEmptyQueryWithRoleSelectsTheNthOfThatKind() {
        let elements = [
            el("AXButton", "Home"),        // #0 not a link
            el("AXLink", "Docs"),          // #1 link 1
            el("AXButton", "Search"),      // #2 not a link
            el("AXLink", "Pricing"),       // #3 link 2
            el("AXLink", "Blog"),          // #4 link 3
        ]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "", role: "link", nth: 3, among: elements), 4,
            "the third link in reading order is Blog at #4")
    }

    /// nth defaults to the single best match, and a nil / zero / negative nth all
    /// mean "the first", never a crash on a bad index.
    func testNthDefaultsAndClampsToTheFirst() {
        let elements = [el("AXLink", "A"), el("AXLink", "B")]
        XCTAssertEqual(ScreenControlEngine.matchElement(query: "", role: "link", nth: nil, among: elements), 0)
        XCTAssertEqual(ScreenControlEngine.matchElement(query: "", role: "link", nth: 0, among: elements), 0)
        XCTAssertEqual(ScreenControlEngine.matchElement(query: "", role: "link", nth: -5, among: elements), 0)
    }

    // MARK: - Value as a last resort

    /// A field with no title but current contents can still be found by those
    /// contents, and only as a last resort: a real title hit elsewhere outranks
    /// it.
    func testValueMatchesWhenNoTitleDoes() {
        let elements = [el("AXTextField", "", value: "you@example.com")]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "example", role: nil, nth: nil, among: elements), 0)
    }

    func testATitleHitOutranksAValueHit() {
        let elements = [
            el("AXTextField", "", value: "email address"),  // #0 value contains "email"
            el("AXButton", "Email"),                        // #1 exact title
        ]
        XCTAssertEqual(
            ScreenControlEngine.matchElement(query: "email", role: nil, nth: nil, among: elements), 1,
            "an exact title must beat a substring buried in another element's value")
    }

    // MARK: - Schema surface

    /// The tool has to actually advertise the inputs this action reads, or the
    /// model can never drive it. Guards against the schema and the dispatch
    /// drifting apart.
    func testSchemaAdvertisesLabelRoleAndNth() {
        guard let tool = ScreenControlTool.claudeTools().first(where: { $0.name == "control_screen" }),
              let props = tool.inputSchema["properties"] as? [String: Any] else {
            return XCTFail("control_screen tool or its properties are missing")
        }
        XCTAssertNotNil(props["label"], "click_element cannot be driven without a label parameter")
        XCTAssertNotNil(props["role"])
        XCTAssertNotNil(props["nth"])
    }

    // MARK: - Gate 1 still governs the new action

    /// Every acting path answers to the consent switch. A new action that skipped
    /// the gate would be a hole in it.
    @MainActor
    func testClickElementIsSkippedWhenScreenControlIsOff() async {
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = false

        let out = await ScreenControlTool.dispatch(
            name: "control_screen", input: ["action": "click_element", "label": "Submit"])
        XCTAssertTrue(out.hasPrefix("skipped:"),
                      "with the switch off click_element must skip, not act. Got: \(out)")
    }
}
