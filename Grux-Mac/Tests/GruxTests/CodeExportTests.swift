import XCTest
@testable import Grux

// Coverage for the design-to-code export string transforms. Pure functions, so
// no WebKit, no store, no UI.
final class CodeExportTests: XCTestCase {

    // MARK: - Astro

    func testAstroWrapsBodyAndScopesStyle() {
        let html = "<html><body><h1>Welcome</h1><p>Hello there</p></body></html>"
        let css = ".hero { color: #B8842E; }"
        let out = CodeExport.astroComponent(html: html, css: css, name: "Landing Page")

        XCTAssertTrue(out.contains("// Generated Astro component: LandingPage"))
        XCTAssertTrue(out.contains("<div class=\"landing-page-root\">"))
        XCTAssertTrue(out.contains("<h1>Welcome</h1>"))
        XCTAssertTrue(out.contains("<style>"))
        XCTAssertTrue(out.contains(".hero { color: #B8842E; }"))
        XCTAssertTrue(out.contains("</style>"))
    }

    func testAstroOmitsEmptyStyleBlock() {
        let out = CodeExport.astroComponent(html: "<body><p>x</p></body>", css: "   ", name: "Bare")
        XCTAssertFalse(out.contains("<style>"), "an empty CSS string must not emit a style block")
    }

    // MARK: - SwiftUI

    func testSwiftUITranslatesKnownElements() {
        let html = """
        <body>
          <h1>Big Title</h1>
          <p>A paragraph of copy.</p>
          <img src="hero.png" alt="hero">
          <button>Get started</button>
        </body>
        """
        let out = CodeExport.swiftUIView(html: html, name: "Hero")

        XCTAssertTrue(out.contains("struct HeroView: View"))
        XCTAssertTrue(out.contains("Text(\"Big Title\")"))
        XCTAssertTrue(out.contains(".font(.largeTitle)"))
        XCTAssertTrue(out.contains("Text(\"A paragraph of copy.\")"))
        XCTAssertTrue(out.contains("AsyncImage(url: URL(string: \"hero.png\"))"))
        XCTAssertTrue(out.contains("Button(\"Get started\") { }"))
    }

    func testSwiftUIInfersHorizontalStackFromFlexRow() {
        let html = "<body><div style=\"display:flex; flex-direction:row\"><p>Left</p><p>Right</p></div></body>"
        let out = CodeExport.swiftUIView(html: html, name: "Row")
        XCTAssertTrue(out.contains("HStack("), "a flex-direction:row div must become an HStack")
        XCTAssertTrue(out.contains("Text(\"Left\")"))
        XCTAssertTrue(out.contains("Text(\"Right\")"))
    }

    func testSwiftUIMarksUnrecognizedElementsInAComment() {
        let html = "<body><h2>Chart</h2><canvas id=\"c\">fallback</canvas></body>"
        let out = CodeExport.swiftUIView(html: html, name: "Dash")
        XCTAssertTrue(out.contains("// TODO: unsupported <canvas> element"))
        XCTAssertTrue(out.contains("Unsupported elements were skipped: canvas"))
    }

    func testSwiftUIEscapesQuotesInText() {
        let html = "<body><p>She said \"hi\"</p></body>"
        let out = CodeExport.swiftUIView(html: html, name: "Quote")
        XCTAssertTrue(out.contains("Text(\"She said \\\"hi\\\"\")"), "double quotes must be escaped for the Swift literal")
    }

    // MARK: - Deep nesting (stack-overflow guard)

    func testDeeplyNestedInputDoesNotCrash() {
        // Pathologically deep nesting (thousands of open tags) must not overflow
        // the stack. The parser caps tree depth, so this returns a normal view
        // instead of crashing the whole app.
        let depth = 5000
        let html = "<body>"
            + String(repeating: "<div>", count: depth)
            + "deep"
            + String(repeating: "</div>", count: depth)
            + "</body>"
        let out = CodeExport.swiftUIView(html: html, name: "Deep")
        XCTAssertTrue(out.contains("struct DeepView: View"))
        XCTAssertTrue(out.contains("Text(\"deep\")"), "the deepest text node must still survive the depth cap")
    }
}
