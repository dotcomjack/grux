import XCTest
@testable import Grux
import GruxSetupCore

/// THE DESIGN RULES, AS ASSERTIONS.
///
/// A style guide nobody checks is a style guide that drifts, and terminal output drifts
/// quietly because the person editing it is looking at their own terminal, in colour, at
/// their own width, with their own TERM.
final class TerminalStyleTests: XCTestCase {

    // MARK: - Colour is never the only carrier

    /// Every state must be distinguishable with the colour removed. A pipe, `NO_COLOR`, a
    /// screen reader and a monochrome terminal all land here.
    func testEveryStateIsDistinguishableWithoutColour() {
        let states: [RowState] = [.satisfied, .needed, .optional, .skipped, .attested]
        let glyphs = states.map(\.glyph)
        let words = states.map(\.word)

        XCTAssertEqual(Set(glyphs).count, states.count,
                       "two states share a glyph, so removing colour makes them identical: \(glyphs)")
        XCTAssertEqual(Set(words).count, states.count,
                       "two states share a word: \(words)")
        for g in glyphs {
            XCTAssertFalse(g.isEmpty, "a state with no glyph is a state that only colour carries")
            XCTAssertEqual(g.count, 1, "a multi-character glyph breaks the alignment grid: \(g)")
        }
    }

    /// The plain rendering of two different states must not be the same string.
    func testTwoStatesNeverRenderIdenticallyInPlainText() {
        let plain = TerminalStyle(isTTY: false, colour: false, width: 80)
        let r = Renderer(style: plain)
        let rendered = [RowState.satisfied, .needed, .optional, .skipped, .attested]
            .map { r.row(state: $0, label: "Microphone", detail: "perm.microphone") }
        XCTAssertEqual(Set(rendered).count, 5, "states collide once colour is gone")
        for line in rendered {
            XCTAssertFalse(line.contains("\u{1B}"), "an escape sequence leaked into plain output")
        }
    }

    // MARK: - Environment

    /// NO_COLOR is honoured on PRESENCE, not on value. `NO_COLOR=0` still means no colour,
    /// and reading it as a boolean is the single most common way tools get this wrong.
    func testNoColourIsHonouredOnPresenceEvenWhenSetToZero() {
        for value in ["1", "0", "", "false"] {
            let s = TerminalStyle.detect(environment: ["NO_COLOR": value], isatty: true, columns: 80)
            XCTAssertFalse(s.colour, "NO_COLOR=\(value) still produced colour")
        }
        let on = TerminalStyle.detect(environment: [:], isatty: true, columns: 80)
        XCTAssertTrue(on.colour, "control: colour never turns on, so the test above proves nothing")
    }

    func testAPipeAndADumbTerminalGetNoColour() {
        XCTAssertFalse(TerminalStyle.detect(environment: [:], isatty: false, columns: 80).colour,
                       "a pipe is a machine reading and got escape sequences")
        XCTAssertFalse(TerminalStyle.detect(environment: ["TERM": "dumb"], isatty: true,
                                            columns: 80).colour)
    }

    func testWidthIsClampedToSomethingDrawable() {
        XCTAssertEqual(TerminalStyle.detect(environment: [:], isatty: true, columns: 5).width, 40)
        XCTAssertEqual(TerminalStyle.detect(environment: [:], isatty: true, columns: 400).width, 100)
        XCTAssertEqual(TerminalStyle.detect(environment: ["COLUMNS": "72"], isatty: true).width, 72)
    }

    // MARK: - The grid

    /// Padding exists to line up the NEXT column. With no next column it is trailing
    /// whitespace on every row, which is what a narrow terminal got in the first version.
    func testARowNeverPadsWithNothingAfterIt() {
        let narrow = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 45))
        let line = narrow.row(state: .satisfied, label: "Grux.app", detail: "/Applications/Grux.app")
        XCTAssertEqual(line, line.replacingOccurrences(of: " +$", with: "", options: .regularExpression),
                       "trailing whitespace: \(line.debugDescription)")
        XCTAssertFalse(line.contains("/Applications"),
                       "a narrow terminal was given the detail column anyway")

        let wide = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 90))
        let wideLine = wide.row(state: .satisfied, label: "Grux.app",
                                detail: "/Applications/Grux.app", labelWidth: 22)
        XCTAssertTrue(wideLine.contains("/Applications/Grux.app"))
        XCTAssertTrue(wideLine.contains("Grux.app              "), "the label column stopped padding")
    }

    /// Six beat labels wrapped over three lines teaches nothing, so the rail collapses.
    func testTheRailCollapsesOnANarrowTerminal() {
        let wide = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 90))
        XCTAssertTrue(wide.rail(current: .look).contains("HAND OFF"),
                      "the full rail lost a beat")

        let narrow = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 45))
        let collapsed = narrow.rail(current: .cost)
        XCTAssertFalse(collapsed.contains("HAND OFF"))
        XCTAssertTrue(collapsed.contains("COST"), "the collapsed rail lost the beat you are on")
        XCTAssertTrue(collapsed.contains("3 of 6"), "the collapsed rail lost your position")
    }

    /// All six, in order, always. A command whose rail is missing COST looks like a command
    /// with something to hide.
    func testTheRailIsAlwaysAllSixInOrder() {
        XCTAssertEqual(Beat.allCases.map(\.rawValue),
                       ["LOOK", "CHOOSE", "COST", "GRANT", "HAND OFF", "PROVE"])
        let r = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 90))
        let rail = r.rail(current: .grant)
        var cursor = rail.startIndex
        for beat in Beat.allCases {
            guard let found = rail.range(of: beat.rawValue, range: cursor..<rail.endIndex) else {
                return XCTFail("\(beat.rawValue) is missing from the rail or out of order")
            }
            cursor = found.upperBound
        }
    }

    /// EVERY ELEMENT ON ONE SCREEN OBEYS ONE WIDTH.
    ///
    /// `prose` wrapped to a hard 76 whenever stdout was not a terminal while `rule` kept
    /// using the real width, so `COLUMNS=60 grux cost speakers` printed a 56 character rule
    /// underneath 76 character paragraphs. Found by looking at the output, not by a test.
    func testProseAndRuleAgreeOnTheWidth() {
        for width in [60, 80, 100] {
            let r = Renderer(style: TerminalStyle(isTTY: false, colour: false, width: width))
            let text = String(repeating: "alpha ", count: 60)
            let longest = r.prose(text).split(separator: "\n").map(\.count).max() ?? 0
            let rule = r.rule().count
            XCTAssertLessThanOrEqual(longest, width,
                "at \(width) columns a prose line ran to \(longest)")
            XCTAssertLessThanOrEqual(rule, width,
                "at \(width) columns the rule ran to \(rule)")
            XCTAssertLessThanOrEqual(abs(longest - rule), 8,
                "at \(width) columns prose wrapped at \(longest) and the rule drew "
                + "\(rule), so the two disagree about how wide the screen is")
        }
    }

    /// THE RAIL IS A STATE INDICATOR AND MUST NOT RELY ON COLOUR EITHER.
    ///
    /// It did. Every beat rendered as its bare name and only an escape sequence said which
    /// one you were on, so in a pipe LOOK and COST printed the identical header. Found by
    /// reading a dry run, not by a test, which is why there is one now.
    func testTheRailSaysWhereYouAreWithoutColour() {
        let plain = Renderer(style: TerminalStyle(isTTY: false, colour: false, width: 90))
        let atLook = plain.rail(current: .look)
        let atCost = plain.rail(current: .cost)

        XCTAssertNotEqual(atLook, atCost,
            "two different beats render the same rail once colour is gone, so the header "
            + "tells a reader nothing about which screen they are on")
        XCTAssertTrue(atLook.contains("[LOOK]"), "the active beat is not marked structurally")
        XCTAssertFalse(atLook.contains("[COST]"), "an inactive beat is marked as active")
        XCTAssertTrue(atCost.contains("[COST]"))

        // and every beat is still present and in order
        for beat in Beat.allCases {
            XCTAssertTrue(atLook.contains(beat.rawValue), "\(beat.rawValue) left the rail")
        }
    }

    func testTheNarrowRailAlsoMarksTheBeatStructurally() {
        let narrow = Renderer(style: TerminalStyle(isTTY: false, colour: false, width: 45))
        let r = narrow.rail(current: .grant)
        XCTAssertTrue(r.contains("[GRANT]"))
        XCTAssertTrue(r.contains("4 of 6"))
    }

    func testProseWrapsAndNeverExceedsTheWidth() {
        let r = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 60))
        let text = String(repeating: "word ", count: 60)
        for line in r.prose(text).split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.count, 60, "a wrapped line ran past the terminal")
        }
    }
}
