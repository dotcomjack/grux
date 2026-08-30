import XCTest
@testable import Grux

// Pins the dynamic-studio prompt compiler contract. The compiler is a pure
// function, so these tests assert exact, stable, imperative output and the
// load-bearing invariants:
//  - leads with the proven "Change the white background." imperative
//  - never appends the product-preservation sentence (the pipeline does that)
//  - is deterministic (same inputs -> identical directive)
//  - strict brand mode injects palette + style cues
//  - contains no em dashes or en dashes
final class PromptCompilerTests: XCTestCase {

    private func directive(
        _ controls: SceneControls,
        freeform: String = "",
        brand: String = "unconfigured-brand"
    ) -> String {
        PromptCompiler.compileDirective(controls: controls, freeform: freeform, brandSlug: brand)
    }

    func test_leadsWithChangeTheWhiteBackground() {
        let d = directive(SceneControls(setting: "a sunlit loft"))
        XCTAssertTrue(d.hasPrefix("Change the white background."),
                      "directive must lead with the proven imperative; got: \(d)")
    }

    func test_doesNotAppendPreservationSuffix() {
        // The pipeline (core/pipeline.render_dynamic) appends preservation +
        // "Photorealistic editorial product photography." The compiler must NOT,
        // or the prompt doubles up and drifts to soft bokeh.
        let d = directive(SceneControls(surface: "reclaimed oak"))
        XCTAssertFalse(d.contains("Keep the product exactly"),
                       "compiler must not add the preservation sentence")
        XCTAssertFalse(d.contains("Photorealistic editorial product photography"),
                       "compiler must not add the pipeline suffix")
    }

    func test_isDeterministic() {
        let c = SceneControls(
            setting: "a sunlit kitchen",
            surface: "a marble ledge",
            lighting: "golden hour",
            timeOfDay: "morning",
            mood: "calm and editorial",
            lens: "shallow depth of field",
            props: ["a ceramic mug", "a eucalyptus sprig"],
            strictBrand: true
        )
        let a = directive(c, freeform: "a little steam rising")
        let b = directive(c, freeform: "a little steam rising")
        XCTAssertEqual(a, b, "same inputs must yield identical directives")
    }

    func test_composesStructuredKnobsInOrder() {
        let c = SceneControls(
            setting: "a sunlit loft",
            surface: "a reclaimed oak counter",
            lighting: "a morning sunbeam",
            timeOfDay: "morning",
            props: ["a stoneware mug"]
        )
        let d = directive(c)
        XCTAssertTrue(d.contains("rests on a reclaimed oak counter in a sunlit loft"))
        XCTAssertTrue(d.contains("Lit by a morning sunbeam in the morning"))
        XCTAssertTrue(d.contains("Include a stoneware mug"))
        // surface placement must come before lighting
        let surfaceIdx = d.range(of: "rests on")!.lowerBound
        let lightIdx = d.range(of: "Lit by")!.lowerBound
        XCTAssertLessThan(surfaceIdx, lightIdx)
    }

    // Strict mode injects whatever palette and style notes the CALLER supplies.
    // The style is built here rather than looked up, because the shipped style
    // registry is empty by design (see test_unconfiguredBrandGetsNoPalette).
    func test_strictBrandInjectsPaletteAndStyle() {
        let style = BrandStyle(
            slug: "demo-brand",
            paletteWords: ["paper cream", "warm black"],
            styleNotes: "brutalist, high contrast, flat frontal lighting"
        )
        let strict = PromptCompiler.compileDirective(
            controls: SceneControls(setting: "a loft", strictBrand: true),
            freeform: "",
            style: style
        )
        XCTAssertTrue(strict.contains("brand palette"),
                      "strict mode must enforce the palette; got: \(strict)")
        XCTAssertTrue(strict.lowercased().contains("brutalist"),
                      "the supplied strict style notes must appear")
        let loose = PromptCompiler.compileDirective(
            controls: SceneControls(setting: "a loft", strictBrand: false),
            freeform: "",
            style: style
        )
        XCTAssertFalse(loose.contains("brand palette"),
                       "non-strict mode must not inject palette")
    }

    func test_freeformIsAppendedLast() {
        let d = directive(SceneControls(setting: "a loft"), freeform: "make it feel like a gift")
        XCTAssertTrue(d.contains("Make it feel like a gift."),
                      "freeform should be sentence-cased and appended")
        XCTAssertTrue(d.hasSuffix("Make it feel like a gift."),
                      "freeform must be last so explicit words win; got: \(d)")
    }

    func test_emptyInputsStillProduceUsableDirective() {
        let d = directive(SceneControls.empty)
        XCTAssertTrue(d.hasPrefix("Change the white background."))
        XCTAssertTrue(d.contains("clean neutral surface"),
                      "empty input should fall back to a safe neutral scene")
    }

    func test_noEmOrEnDashesAnywhere() {
        let c = SceneControls(
            setting: "a loft",
            surface: "oak",
            lighting: "golden hour",
            timeOfDay: "morning",
            mood: "warm",
            lens: "macro",
            props: ["a mug", "a sprig", "a candle"],
            strictBrand: true
        )
        let d = directive(c, freeform: "cozy and inviting")
        XCTAssertFalse(d.contains("\u{2014}"), "no em dashes allowed")
        XCTAssertFalse(d.contains("\u{2013}"), "no en dashes allowed")
    }

    func test_aspectPresetRawValuesMatchEndpointContract() {
        XCTAssertEqual(AspectPreset.square.rawValue, "1:1")
        XCTAssertEqual(AspectPreset.portrait45.rawValue, "4:5")
        XCTAssertEqual(AspectPreset.vertical.rawValue, "9:16")
        XCTAssertEqual(AspectPreset.landscape.rawValue, "16:9")
    }

    func test_unconfiguredBrandGetsNoPaletteButStillWorks() {
        let d = PromptCompiler.compileDirective(
            controls: SceneControls(setting: "a studio", strictBrand: true),
            freeform: "",
            brandSlug: "some-registry-brand"
        )
        XCTAssertTrue(d.hasPrefix("Change the white background."))
        XCTAssertTrue(d.lowercased().contains("editorial product photography"),
                      "generic strict style still enforces clean photography")
        // The shipped registry carries nobody's brand book, so an unknown slug
        // must fall back to the neutral profile rather than invent a palette.
        XCTAssertFalse(d.contains("brand palette"),
                       "an unconfigured brand slug must not conjure a palette; got: \(d)")
    }
}
