import XCTest
@testable import Grux

// The see -> act -> CONFIRM loop. The actuation and the live screenshot need a
// display + two grants, so they are exercised by hand in the running app. What
// is proven HERE, deterministically and headlessly, is the part that decides
// whether an action WORKED: the pure verdict over before/after OCR text, every
// branch, plus the tool-layer invariants that the confirmation path must never
// weaken (the two fail-closed gates, and the never-echo-typed-text privacy rule).
@MainActor
final class ScreenControlVerifierTests: XCTestCase {

    typealias V = ScreenControlVerifier

    // MARK: - appears

    func testAppearsConfirmedWhenTextIsNewlyPresent() {
        let r = V.evaluate(before: "Compose\nNew Message",
                           after: "Compose\nNew Message\nMessage sent",
                           expectation: .appears("Message sent"))
        XCTAssertTrue(r.confirmed, r.message)
    }

    func testAppearsUnconfirmedWhenTextNeverShows() {
        let r = V.evaluate(before: "Compose", after: "Compose",
                           expectation: .appears("Message sent"))
        XCTAssertFalse(r.confirmed)
        XCTAssertTrue(r.message.localizedCaseInsensitiveContains("did not appear"), r.message)
    }

    /// Text that was ALREADY on screen is not evidence the action did anything.
    /// This is the trap an exact "is the text there now" check falls into.
    func testAppearsUnconfirmedWhenTextWasAlreadyThere() {
        let r = V.evaluate(before: "Draft saved", after: "Draft saved",
                           expectation: .appears("Draft saved"))
        XCTAssertFalse(r.confirmed)
        XCTAssertTrue(r.message.localizedCaseInsensitiveContains("already"), r.message)
    }

    func testAppearsIsCaseAndWhitespaceInsensitive() {
        let r = V.evaluate(before: "home",
                           after: "Order   #123    CONFIRMED\n\n",
                           expectation: .appears("order #123 confirmed"))
        XCTAssertTrue(r.confirmed, r.message)
    }

    /// An empty target cannot be looked for, so it degrades to the change check
    /// rather than assert a meaningless confirmation.
    func testAppearsWithEmptyTextFallsBackToChangeCheck() {
        let hit = V.evaluate(before: "a", after: "a b c d", expectation: .appears("   "))
        XCTAssertTrue(hit.confirmed, "an empty expect on a changed screen should read as changed")
        let miss = V.evaluate(before: "a", after: "a", expectation: .appears(""))
        XCTAssertFalse(miss.confirmed, "an empty expect on an unchanged screen is not a confirmation")
    }

    // MARK: - disappears

    func testDisappearsConfirmedWhenTextIsGone() {
        let r = V.evaluate(before: "Delete this item? Cancel Delete",
                           after: "Home  Inbox  Sent",
                           expectation: .disappears("Delete this item?"))
        XCTAssertTrue(r.confirmed, r.message)
    }

    func testDisappearsUnconfirmedWhenTextRemains() {
        let r = V.evaluate(before: "Really delete? Cancel Delete",
                           after: "Really delete? Cancel Delete",
                           expectation: .disappears("Really delete?"))
        XCTAssertFalse(r.confirmed)
        XCTAssertTrue(r.message.localizedCaseInsensitiveContains("still"), r.message)
    }

    /// Something never on screen cannot be confirmed as removed. The honest
    /// answer is "unprovable", not "confirmed gone".
    func testDisappearsUnconfirmedWhenTextWasNeverThere() {
        let r = V.evaluate(before: "Home", after: "Home",
                           expectation: .disappears("Delete this item?"))
        XCTAssertFalse(r.confirmed)
        XCTAssertTrue(r.message.localizedCaseInsensitiveContains("cannot be confirmed"), r.message)
    }

    // MARK: - changes (the weak fallback)

    func testChangesConfirmedWhenScreenMovesMeaningfully() {
        let r = V.evaluate(before: "one two three",
                           after: "one two three four five six",
                           expectation: .changes)
        XCTAssertTrue(r.confirmed, r.message)
    }

    /// The reason `.changes` is not exact-inequality: a menu-bar clock ticking
    /// from 12:03 to 12:04 makes two shots of a STATIC screen differ, and must
    /// not be read as "the action worked".
    func testChangesIgnoresAClockTick() {
        let r = V.evaluate(before: "File  Edit  View     12:03 PM",
                           after: "File  Edit  View     12:04 PM",
                           expectation: .changes)
        XCTAssertFalse(r.confirmed, "a one-digit clock change must not count as the action landing")
    }

    func testChangesUnconfirmedWhenIdentical() {
        let r = V.evaluate(before: "steady state", after: "steady state", expectation: .changes)
        XCTAssertFalse(r.confirmed)
    }

    func testChangesUnconfirmedWhenBothBlank() {
        XCTAssertFalse(V.evaluate(before: "", after: "", expectation: .changes).confirmed)
    }

    // MARK: - pure helpers

    func testNormalizeCollapsesWhitespaceAndLowercases() {
        XCTAssertEqual(V.normalize("  Hello \n\t WORLD  "), "hello world")
    }

    func testTokensSplitsPunctuationSoAClockIsTwoTokens() {
        XCTAssertEqual(V.tokens("12:03"), ["12", "03"])
        XCTAssertTrue(V.tokens("Send!  now.").isSuperset(of: ["send", "now"]))
    }

    func testContainsUsesNormalizedForms() {
        XCTAssertTrue(V.contains("The ORDER   was  Confirmed", V.normalize("order was confirmed")))
        XCTAssertFalse(V.contains("nothing here", V.normalize("missing")))
        XCTAssertFalse(V.contains("anything", ""))
    }

    func testChangedEnoughRespectsFloor() {
        // symmetric diff of exactly 2 tokens is below the default floor of 3.
        XCTAssertFalse(V.changedEnough(before: "a b c", after: "a b d"))          // {c} vs {d} = 2
        XCTAssertTrue(V.changedEnough(before: "a b c", after: "a x y z"))          // {b,c} + {x,y,z} = 5
        XCTAssertTrue(V.changedEnough(before: "a b c", after: "a b d", floor: 2)) // tunable
    }

    // MARK: - Tool layer: the confirmation params must never weaken a gate

    func testSchemaAdvertisesTheConfirmationParams() {
        guard let tool = ScreenControlTool.claudeTools().first(where: { $0.name == "control_screen" }),
              let props = tool.inputSchema["properties"] as? [String: Any] else {
            return XCTFail("control_screen tool or its properties are missing")
        }
        for key in ["expect", "expect_gone", "settle_ms", "polls"] {
            XCTAssertNotNil(props[key], "the schema does not advertise \(key)")
        }
    }

    func testExpectDoesNotBypassTheConsentSwitch() async {
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = false

        let out = await ScreenControlTool.dispatch(
            name: "control_screen",
            input: ["action": "click", "x": 10, "y": 10, "expect": "Sent"])
        XCTAssertTrue(out.hasPrefix("skipped:"),
                      "an expectation must not let a click past the OFF switch. Got: \(out)")
    }

    func testExpectDoesNotBypassTheAccessibilityGate() async throws {
        try XCTSkipIf(ScreenControlEngine.hasAccessibility(),
                      "test host unexpectedly holds the Accessibility grant")
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = true

        let out = await ScreenControlTool.dispatch(
            name: "control_screen",
            input: ["action": "click", "x": 10, "y": 10, "expect": "Sent"])
        XCTAssertTrue(out.hasPrefix("error:"), "ungranted actuation must be an error even with expect. Got: \(out)")
        XCTAssertTrue(out.localizedCaseInsensitiveContains("accessibility"), "must name the missing grant. Got: \(out)")
    }

    /// The privacy invariant, held on the confirmation path too: a `type` with a
    /// secret in both text and expect must never surface the secret, no matter
    /// where it exits. Here it exits at the consent gate, so the check is
    /// deterministic on any host.
    func testTypeConfirmationNeverEchoesTypedText() async {
        let secret = "hunter2-correct-horse"
        let saved = AppState.shared.config.screenControlEnabled
        defer { AppState.shared.config.screenControlEnabled = saved }
        AppState.shared.config.screenControlEnabled = false

        let out = await ScreenControlTool.dispatch(
            name: "control_screen",
            input: ["action": "type", "text": secret, "expect": secret])
        XCTAssertFalse(out.contains(secret), "the typed/expected secret leaked into the tool result: \(out)")
    }
}
