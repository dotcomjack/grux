import XCTest
@testable import Grux

// DesignSystem parse / render round-trip and the Open Design DESIGN.md
// compatibility surface: alias mapping, unknown-section preservation, missing
// sections, and the derived palette / type-scale tokens.
@MainActor
final class DesignSystemParserTests: XCTestCase {

    // An Open-Design-style DESIGN.md: an H1 title, a lead paragraph, a colour
    // TABLE, foreign heading spellings (Colour Palette, Voice & Tone, Don'ts),
    // and an unknown section that must survive.
    private let openDesignFixture = """
    # Acme Design System

    A calm, high-contrast system for Acme.

    ## Colour Palette

    | Token | Hex |
    | --- | --- |
    | ink | #0A0A0A |
    | gold | #B8842E |

    ## Typography

    - Body 16px
    - Heading 32px

    ## Voice & Tone

    Direct and warm. Prices always read $N, never spelled out.

    ## Don'ts

    - No chunky buttons.

    ## Field Notes

    An unknown section that must survive a round-trip.
    """

    func test_parse_mapsAliasHeadingsOntoCanonicalSections() {
        let system = DesignSystem.parse(markdown: openDesignFixture)

        XCTAssertEqual(system.name, "Acme Design System")
        XCTAssertEqual(system.slug, "acme-design-system", "slug is derived from the title")
        XCTAssertTrue(system.lead.contains("calm"), "the lead paragraph is captured")

        XCTAssertNotNil(system.sections[.color], "Colour Palette maps to color")
        XCTAssertNotNil(system.sections[.typography])
        XCTAssertNotNil(system.sections[.voice], "Voice & Tone maps to voice")
        XCTAssertNotNil(system.sections[.antiPatterns], "Don'ts maps to anti-patterns")

        XCTAssertNil(system.sections[.spacing], "a missing section is simply absent")
        XCTAssertNil(system.sections[.motion])
    }

    func test_parse_preservesUnknownSections() {
        let system = DesignSystem.parse(markdown: openDesignFixture)
        XCTAssertEqual(system.extras.count, 1)
        XCTAssertTrue(system.extras["Field Notes"]?.contains("must survive") == true)
    }

    func test_parse_derivesPaletteHexFromTable() {
        let system = DesignSystem.parse(markdown: openDesignFixture)
        XCTAssertEqual(system.paletteHex["ink"], "#0A0A0A")
        XCTAssertEqual(system.paletteHex["gold"], "#B8842E")
    }

    func test_parse_derivesTypeScaleInOrder() {
        let system = DesignSystem.parse(markdown: openDesignFixture)
        XCTAssertEqual(system.typeScale, ["16px", "32px"])
    }

    func test_roundTrip_isLosslessIncludingUnknownSections() {
        let a = DesignSystem.parse(markdown: openDesignFixture)
        let b = DesignSystem.parse(markdown: a.render(), slug: a.slug)
        XCTAssertEqual(a, b, "parse(render(x)) must recover x exactly")
        // And explicitly: the unknown section and derived tokens survive.
        XCTAssertEqual(b.extras["Field Notes"], a.extras["Field Notes"])
        XCTAssertEqual(b.paletteHex, a.paletteHex)
        XCTAssertEqual(b.typeScale, a.typeScale)
    }

    func test_parse_fromFixtureFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-designsys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("DESIGN.md")
        try openDesignFixture.write(to: fileURL, atomically: true, encoding: .utf8)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let system = DesignSystem.parse(markdown: text, slug: "acme")
        XCTAssertEqual(system.slug, "acme", "an explicit slug wins over the title-derived one")
        XCTAssertEqual(system.name, "Acme Design System")
        XCTAssertNotNil(system.sections[.color])
    }

    func test_parse_toleratesMissingSectionsAndNoTitle() {
        let sparse = """
        ## Components

        Buttons are tight.

        ## Voice

        No em dash ever.
        """
        let system = DesignSystem.parse(markdown: sparse, slug: "sparse")
        XCTAssertEqual(system.name, "", "no H1 is tolerated")
        XCTAssertEqual(system.sections.count, 2)
        XCTAssertNotNil(system.sections[.components])
        XCTAssertNotNil(system.sections[.voice])
        XCTAssertTrue(system.paletteHex.isEmpty, "no color section means no palette")
        XCTAssertTrue(system.typeScale.isEmpty)
    }

    func test_systemPromptBlock_isCompactAndCarriesTokens() {
        let system = DesignSystem.parse(markdown: openDesignFixture)
        let block = system.systemPromptBlock()
        XCTAssertTrue(block.hasPrefix("DESIGN SYSTEM: Acme Design System (acme-design-system)"))
        XCTAssertTrue(block.contains("ink=#0A0A0A"))
        XCTAssertTrue(block.contains("16px"))
    }

    // MARK: - Store import collisions

    // Two imports whose titles derive the same base slug must land side by side
    // (slug and slug-2), neither overwriting the other; a byte-identical
    // re-import of the first is a no-op rather than a numbered duplicate.
    func test_importFile_collidingSlugsDoNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-dsstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-dssrc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: src)
        }

        let store = DesignSystemStore(rootDir: root)

        // Same H1 title (so the same base slug) but different bodies.
        let first = "# Acme\n\n## Voice\n\nFirst import body.\n"
        let second = "# Acme\n\n## Voice\n\nSecond import body, totally different.\n"
        let firstURL = src.appendingPathComponent("first.md")
        let secondURL = src.appendingPathComponent("second.md")
        try first.write(to: firstURL, atomically: true, encoding: .utf8)
        try second.write(to: secondURL, atomically: true, encoding: .utf8)

        let a = store.importFile(url: firstURL)
        let b = store.importFile(url: secondURL)

        XCTAssertEqual(a?.slug, "acme", "first import lands at the base slug")
        XCTAssertEqual(b?.slug, "acme-2", "a colliding import is suffixed, not overwritten")
        XCTAssertEqual(store.list().count, 2)

        // Both systems survive on disk with their own bodies, unmixed.
        XCTAssertTrue(store.markdown(slug: "acme")?.contains("First import body") == true)
        XCTAssertTrue(store.markdown(slug: "acme-2")?.contains("Second import body") == true)
        XCTAssertFalse(store.markdown(slug: "acme")?.contains("Second import body") == true,
                       "the first system was not clobbered by the second import")

        // A byte-identical re-import of the first file is a no-op.
        let again = store.importFile(url: firstURL)
        XCTAssertEqual(again?.slug, "acme", "an identical re-import returns the existing slug")
        XCTAssertEqual(store.list().count, 2, "no numbered duplicate is created on identical re-import")
    }
}
