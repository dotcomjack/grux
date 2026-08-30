import XCTest
@testable import GruxSetupCore

/// The picker, exercised without a finger on a key.
///
/// `Interactive.swift` splits byte-to-meaning (`Key.decode`) and key-to-state (`MultiSelect`)
/// away from the one part that touches a file descriptor, for exactly this reason: a
/// selection state machine that can only be driven by a human is a selection state machine
/// nobody has tested. These walk the same code a person's keystrokes walk.
final class KeyDecodeTests: XCTestCase {

    func testTheOrdinaryKeys() {
        XCTAssertEqual(Key.decode([0x20])?.key, .space)
        XCTAssertEqual(Key.decode([0x0A])?.key, .enter)
        XCTAssertEqual(Key.decode([0x0D])?.key, .enter, "carriage return is enter too")
        XCTAssertEqual(Key.decode([0x61])?.key, .char("a"))
        XCTAssertEqual(Key.decode([])?.key, nil)
    }

    /// AN ARROW IS THREE BYTES AND A BARE ESCAPE IS ONE, and the consumed count is the only
    /// thing that tells a buffered caller which it just read. Getting this wrong reads the
    /// `[` and the `A` of an up arrow as two more keypresses.
    func testArrowsConsumeThreeBytesAndBareEscapeConsumesOne() {
        let up = Key.decode([0x1B, 0x5B, 0x41])
        XCTAssertEqual(up?.key, .up)
        XCTAssertEqual(up?.consumed, 3)

        let down = Key.decode([0x1B, 0x5B, 0x42])
        XCTAssertEqual(down?.key, .down)
        XCTAssertEqual(down?.consumed, 3)

        let esc = Key.decode([0x1B])
        XCTAssertEqual(esc?.key, .escape)
        XCTAssertEqual(esc?.consumed, 1, "a bare escape must not eat the next two keys")
    }

    /// A partial sequence is not an arrow yet. Two bytes in, the caller has to keep reading
    /// rather than decide, and decoding it as `up` on a guess is how a paste of escape codes
    /// toggles rows nobody touched.
    func testAPartialSequenceIsNotAnArrow() {
        let partial = Key.decode([0x1B, 0x5B])
        XCTAssertEqual(partial?.key, .escape)
        XCTAssertEqual(partial?.consumed, 1)
    }

    /// Ctrl-C is LEAVE, never a crash and never a stray character. The terminal is in raw
    /// mode when this arrives, so nothing else is going to handle it.
    func testCtrlCIsLeave() {
        XCTAssertEqual(Key.decode([0x03])?.key, .escape)
    }

    /// A control byte below space is not a printable character. Mapping it to `.char` puts
    /// an unprintable scalar into a preset lookup.
    func testControlBytesAreNotCharacters() {
        for byte: UInt8 in [0x01, 0x07, 0x1F] {
            guard let decoded = Key.decode([byte]) else { return XCTFail("nothing decoded") }
            if case .char = decoded.key {
                XCTFail("byte \(byte) decoded as a printable character")
            }
        }
    }
}

final class MultiSelectTests: XCTestCase {

    private func sample() -> MultiSelect {
        MultiSelect(items: [
            .init(id: "a", label: "Alpha", group: "One"),
            .init(id: "b", label: "Bravo", group: "One"),
            .init(id: "c", label: "Charlie", group: "Two"),
        ], presets: [
            .init(key: "1", name: "minimal", ids: ["a"]),
            .init(key: "2", name: "everything", ids: ["a", "b", "c"]),
        ])
    }

    /// THE CURSOR CLAMPS, IT NEVER WRAPS. A list that jumps from the last row back to the
    /// first is how somebody toggles a feature they never saw, because their finger held the
    /// arrow one beat too long.
    func testTheCursorClampsAtBothEnds() {
        var s = sample()
        XCTAssertEqual(s.cursor, 0)
        s.apply(.up)
        XCTAssertEqual(s.cursor, 0, "up from the top wrapped to the bottom")
        for _ in 0..<10 { s.apply(.down) }
        XCTAssertEqual(s.cursor, 2, "down past the end wrapped to the top")
    }

    func testSpaceTogglesAndEnterConfirms() {
        var s = sample()
        s.apply(.space)
        XCTAssertEqual(s.chosen, ["a"])
        s.apply(.space)
        XCTAssertEqual(s.chosen, [], "the second space did not turn it back off")
        s.apply(.down); s.apply(.space)
        XCTAssertEqual(s.chosen, ["b"])
        s.apply(.enter)
        XCTAssertEqual(s.outcome, .confirmed)
    }

    /// Once it is over it is over. A key arriving after enter, from a held repeat or a
    /// paste, must not change what was just confirmed.
    func testKeysAfterTheOutcomeAreIgnored() {
        var s = sample()
        s.apply(.space)
        s.apply(.enter)
        let settled = s.chosen
        s.apply(.char("a"))
        s.apply(.down)
        s.apply(.space)
        XCTAssertEqual(s.chosen, settled, "a keypress after confirming changed the selection")
        XCTAssertEqual(s.cursor, 0)
    }

    func testEscapeCancelsAndCancelIsNotConfirm() {
        var s = sample()
        s.apply(.space)
        s.apply(.escape)
        XCTAssertEqual(s.outcome, .cancelled)
        XCTAssertNotEqual(s.outcome, .confirmed)
    }

    func testAllAndNone() {
        var s = sample()
        s.apply(.char("a"))
        XCTAssertEqual(s.chosen, ["a", "b", "c"])
        s.apply(.char("n"))
        XCTAssertEqual(s.chosen, [])
    }

    /// A PRESET REPLACES, IT DOES NOT ADD. Adding would make pressing two presets in a row
    /// produce a third selection nobody named and no label describes, so the screen would say
    /// "everything" while holding something else.
    func testAPresetReplacesRatherThanAdds() {
        var s = sample()
        s.apply(.char("2"))
        XCTAssertEqual(s.chosen, ["a", "b", "c"])
        s.apply(.char("1"))
        XCTAssertEqual(s.chosen, ["a"], "the second preset merged into the first")
    }

    /// A preset naming an id this list does not have contributes nothing. It cannot, or the
    /// count on the COST screen stops matching the rows above it.
    func testAPresetNamingAnUnknownIDContributesNothing() {
        var s = MultiSelect(items: [.init(id: "a", label: "Alpha", group: "One")],
                            presets: [.init(key: "1", name: "stale", ids: ["a", "gone"])])
        s.apply(.char("1"))
        XCTAssertEqual(s.chosen, ["a"])
    }

    func testAnUnboundCharacterDoesNothing() {
        var s = sample()
        s.apply(.char("z"))
        XCTAssertEqual(s.chosen, [])
        XCTAssertEqual(s.cursor, 0)
        XCTAssertEqual(s.outcome, .running)
    }

    func testVimKeysMoveTheCursorLikeArrows() {
        var s = sample()
        s.apply(.char("j"))
        XCTAssertEqual(s.cursor, 1)
        s.apply(.char("k"))
        XCTAssertEqual(s.cursor, 0)
    }

    /// An empty list must not crash on the key a person presses first.
    func testAnEmptyListSurvivesEveryKey() {
        var s = MultiSelect(items: [])
        s.apply(.down); s.apply(.up); s.apply(.space); s.apply(.char("a"))
        XCTAssertEqual(s.chosen, [])
        XCTAssertEqual(s.cursor, 0)
    }

    // MARK: - The window

    /// Thirty nine features do not fit in a terminal, so the list scrolls. The window has to
    /// keep the cursor visible or the highlight is somewhere off screen and the arrow keys
    /// appear to do nothing.
    func testTheWindowAlwaysContainsTheCursor() {
        let items = (0..<39).map { MultiSelect.Item(id: "f\($0)", label: "F\($0)", group: "G") }
        var s = MultiSelect(items: items)
        for step in 0..<39 {
            let w = s.window(height: 10)
            XCTAssertTrue(w.range.contains(s.cursor),
                "cursor \(s.cursor) fell outside the window \(w.range) at step \(step)")
            XCTAssertEqual(w.range.count, 10)
            XCTAssertEqual(w.above + w.range.count + w.below, 39,
                "the counts above and below do not add up to the list")
            s.apply(.down)
        }
    }

    /// A list shorter than the window is not scrolled, and reports nothing hidden. Printing
    /// "3 more above" over a list of three is the counts-must-match-the-list rule breaking.
    func testAShortListIsNotScrolled() {
        var s = sample()
        s.apply(.down)
        let w = s.window(height: 20)
        XCTAssertEqual(w.range, 0..<3)
        XCTAssertEqual(w.above, 0)
        XCTAssertEqual(w.below, 0)
    }
}
