import XCTest
@testable import Grux

// DirectionEngine parse + fallback coverage. Parsing must read a well-formed set
// of five strict lines, skip malformed lines, and hand off to the deterministic
// fallback when too few survive. Palette extraction and the on-system-first rule
// are checked directly. No live model calls.
final class DirectionParseTests: XCTestCase {

    // MARK: Parsing

    func test_wellFormedFive_parseToFive() {
        let text = """
        DIRECTION | On-System | Your exact palette applied straight | #111111,#f5f5f5,#7c5cff | System | on-brand,consistent,trusted
        DIRECTION | High Contrast | Bold type, one accent | #000000,#ffffff,#ff3b30 | Inter Tight | bold,loud,focused
        DIRECTION | Editorial | Whitespace and a quiet scale | #1a1a1a,#fafafa,#c8a24a | Fraunces | calm,premium,quiet
        DIRECTION | Warm | Rounded and friendly | #2b2b2b,#fff7ed,#f97316 | Nunito | friendly,warm,open
        DIRECTION | Techno | Neon on near black | #0a0a0a,#e6e6e6,#00e5ff | Space Grotesk | sharp,modern,electric
        """
        let dirs = DirectionEngine.parseDirections(text)
        XCTAssertEqual(dirs.count, 5)
        XCTAssertEqual(dirs.first?.name, "On-System")
        XCTAssertEqual(dirs.first?.paletteHex, ["#111111", "#f5f5f5", "#7c5cff"])
        XCTAssertEqual(dirs.first?.vibeWords, ["on-brand", "consistent", "trusted"])
        XCTAssertEqual(dirs[1].headlineFont, "Inter Tight")
    }

    func test_malformedLines_areSkipped() {
        let text = """
        Here are some directions for you:
        DIRECTION | Good One | A real thesis | #112233,#445566 | Inter | clean,sharp
        DIRECTION | missing fields only two
        garbage line with no marker
        DIRECTION | Second Good | Another thesis | #778899 | Fraunces | warm
        """
        let dirs = DirectionEngine.parseDirections(text)
        XCTAssertEqual(dirs.count, 2, "only the two well-formed lines survive")
        XCTAssertEqual(dirs.map { $0.name }, ["Good One", "Second Good"])
    }

    // MARK: Fallback

    func test_fallback_whenParseYieldsTooFew() {
        // A garbage reply parses to fewer than two: the caller uses the fallback.
        let dirs = DirectionEngine.parseDirections("total nonsense, no directions here")
        XCTAssertLessThan(dirs.count, 2)

        let fallback = DirectionEngine.fallbackDirections(fromPalette: ["#112233", "#445566", "#778899"])
        XCTAssertGreaterThanOrEqual(fallback.count, 3)
        XCTAssertEqual(fallback.first?.name, "On-System",
                       "with a palette present the first fallback direction is on-system")
        XCTAssertEqual(fallback.first?.paletteHex, ["#112233", "#445566", "#778899"])
    }

    func test_fallback_noPalette_stillReturnsDirections() {
        let fallback = DirectionEngine.fallbackDirections(fromPalette: [])
        XCTAssertGreaterThanOrEqual(fallback.count, 3)
        // No palette means no on-system anchor; every direction explores.
        XCTAssertNotEqual(fallback.first?.name, "On-System")
    }

    // MARK: Palette extraction

    func test_extractPalette_pullsHexesInOrderDeduped() {
        let md = """
        # Brand
        Primary: #1A1A1A
        Accent: #7C5CFF
        Surface: #F5F5F5
        (repeat) #7c5cff
        """
        let palette = DirectionEngine.extractPalette(fromMarkdown: md)
        XCTAssertEqual(palette, ["#1a1a1a", "#7c5cff", "#f5f5f5"],
                       "hexes normalized to lowercase, in order, de-duplicated")
    }

    func test_extractPalette_emptyForNoHex() {
        XCTAssertTrue(DirectionEngine.extractPalette(fromMarkdown: "no colors here").isEmpty)
    }
}
