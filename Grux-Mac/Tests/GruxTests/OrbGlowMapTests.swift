import XCTest
@testable import Grux

// Shell motion spec: OrbGlowMap is the single static table mapping every
// GruxOrbState to its orb colors AND glow-border hue. These tests pin the
// contract: the table is exhaustive (no orb state without a hue), hues are
// valid, the glow's speaking mode reads the same hue as the orb's speaking
// entry (the two surfaces can never disagree), and the MotionTokens duration
// scale stays ordered.
final class OrbGlowMapTests: XCTestCase {

    // Every GruxOrbState must have a table entry. A new case added without
    // a row fails here before it ships with the silent fallback colors.
    func testEveryOrbStateHasATableEntry() {
        for state in GruxOrbState.allCases {
            XCTAssertNotNil(
                OrbGlowMap.table[state],
                "OrbGlowMap.table is missing an entry for .\(state.label)"
            )
        }
    }

    func testEveryGlowHueIsValid() {
        for state in GruxOrbState.allCases {
            guard let entry = OrbGlowMap.table[state] else { continue }
            XCTAssertTrue(
                (0.0...1.0).contains(entry.glowHue),
                "Glow hue for .\(state.label) is out of the 0...1 range: \(entry.glowHue)"
            )
        }
    }

    // GlowColorMode.speaking routes through the map, so the glow border and
    // the orb agree on what "speaking" looks like by construction.
    func testSpeakingGlowHueMatchesOrbMap() {
        XCTAssertEqual(
            GlowColorMode.speaking.baseHue,
            OrbGlowMap.entry(for: .speaking).glowHue,
            "GlowColorMode.speaking must read its hue from OrbGlowMap"
        )
    }

    // entry(for:) must return the table row, not the defensive fallback.
    func testEntryForStateReturnsTableRow() {
        for state in GruxOrbState.allCases {
            guard let row = OrbGlowMap.table[state] else {
                XCTFail("No table row for .\(state.label)"); continue
            }
            XCTAssertEqual(OrbGlowMap.entry(for: state).glowHue, row.glowHue)
        }
    }

    // MotionTokens duration scale: fast < base < slow < ambient, all positive.
    func testMotionTokenScaleIsOrdered() {
        XCTAssertGreaterThan(MotionTokens.fast, 0)
        XCTAssertLessThan(MotionTokens.fast, MotionTokens.base)
        XCTAssertLessThan(MotionTokens.base, MotionTokens.slow)
        XCTAssertLessThan(MotionTokens.slow, MotionTokens.ambient)
    }
}
