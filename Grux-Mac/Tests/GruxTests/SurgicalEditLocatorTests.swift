import XCTest
@testable import Grux

// SurgicalEditEngine locator + splice + fail-closed coverage. The locator is the
// heart of the surgical path: it must find an element from the three inspector
// selector shapes (id, tag.class chain, nth-child), return nil (so the engine
// degrades to full context) when nothing matches, and the splice must be exact.
// No live model calls: the model seam is stubbed.
final class SurgicalEditLocatorTests: XCTestCase {

    private struct StubModel: SurgicalModelCalling {
        let reply: String
        func patch(prompt: String, apiKey: String, model: String) async -> Result<String, Error> {
            .success(reply)
        }
    }

    // MARK: Locator shapes

    func test_idSelector_locatesElement() {
        let html = "<body><div id=\"hero\"><p>Hi</p></div></body>"
        guard let span = SurgicalEditEngine.locate(selector: "#hero", in: html) else {
            return XCTFail("id selector must locate")
        }
        let el = SurgicalEditEngine.extractSpan(span, from: html)
        XCTAssertEqual(el, "<div id=\"hero\"><p>Hi</p></div>")
    }

    func test_classChain_locatesLastSegment() {
        let html = "<section class=\"hero\"><h1 class=\"title\">Hi</h1><p>x</p></section>"
        guard let span = SurgicalEditEngine.locate(selector: "section.hero > h1.title", in: html) else {
            return XCTFail("tag.class chain must locate the last segment")
        }
        XCTAssertEqual(SurgicalEditEngine.extractSpan(span, from: html), "<h1 class=\"title\">Hi</h1>")
    }

    func test_nthChild_picksTheNthMatch() {
        let html = "<ul><li>one</li><li>two</li><li>three</li></ul>"
        guard let span = SurgicalEditEngine.locate(selector: "ul > li:nth-child(2)", in: html) else {
            return XCTFail("nth-child must locate")
        }
        XCTAssertEqual(SurgicalEditEngine.extractSpan(span, from: html), "<li>two</li>")
    }

    func test_notFound_locateReturnsNil() {
        let html = "<div id=\"hero\">Hi</div>"
        XCTAssertNil(SurgicalEditEngine.locate(selector: "#nope", in: html))
        XCTAssertNil(SurgicalEditEngine.locate(selector: "span.missing", in: html))
    }

    // MARK: Splice

    func test_spliceCorrectness() {
        let content = "<div><h1 id=\"t\">Old</h1></div>"
        guard let span = SurgicalEditEngine.locate(selector: "#t", in: content) else {
            return XCTFail("locate")
        }
        let out = SurgicalEditEngine.applyPatch(replacement: "<h1 id=\"t\">New</h1>", span: span, to: content)
        XCTAssertEqual(out, "<div><h1 id=\"t\">New</h1></div>")
    }

    // MARK: Patch parsing (fail-closed)

    func test_parsePatch_extractsBody() {
        let reply = "sure thing\nGRUX_PATCH_BEGIN\n<h1>New</h1>\nGRUX_PATCH_END\ndone"
        XCTAssertEqual(SurgicalEditEngine.parsePatch(reply), "<h1>New</h1>")
    }

    func test_parsePatch_failsClosed_onMissingMarkers() {
        XCTAssertNil(SurgicalEditEngine.parsePatch("no markers here"))
        XCTAssertNil(SurgicalEditEngine.parsePatch("GRUX_PATCH_BEGIN\n\nGRUX_PATCH_END"))
    }

    // MARK: Engine end-to-end (stubbed model)

    func test_edit_notFound_returnsNeedsFullContext() async {
        let content = "<div><p>Hi</p></div>"
        let req = SurgicalEditRequest(filePath: "x.html", selector: "#nope",
                                      instruction: "tighten it", fileContent: content)
        let result = await SurgicalEditEngine.edit(req, apiKey: "test-key", caller: StubModel(reply: ""))
        guard case .needsFullContext = result else {
            return XCTFail("a selector that does not locate must degrade to needsFullContext, got \(result)")
        }
    }

    func test_edit_splicesReturnedPatch() async {
        let content = "<div><h1 id=\"t\">Old</h1></div>"
        let req = SurgicalEditRequest(filePath: "x.html", selector: "#t",
                                      instruction: "make it new", fileContent: content)
        let stub = StubModel(reply: "GRUX_PATCH_BEGIN\n<h1 id=\"t\">New</h1>\nGRUX_PATCH_END")
        let result = await SurgicalEditEngine.edit(req, apiKey: "test-key", caller: stub)
        guard case .patched(let newContent) = result else {
            return XCTFail("expected .patched, got \(result)")
        }
        XCTAssertEqual(newContent, "<div><h1 id=\"t\">New</h1></div>")
    }

    func test_edit_failsClosed_onUnparseablePatch() async {
        let content = "<div><h1 id=\"t\">Old</h1></div>"
        let req = SurgicalEditRequest(filePath: "x.html", selector: "#t",
                                      instruction: "make it new", fileContent: content)
        let stub = StubModel(reply: "I could not do that")
        let result = await SurgicalEditEngine.edit(req, apiKey: "test-key", caller: stub)
        guard case .failed = result else {
            return XCTFail("an unparseable patch must fail closed, got \(result)")
        }
    }

    // MARK: Token accounting

    func test_estimatedTokens_surgicalIsCheaperThanFullFile() {
        // A big file with one small target: the surgical estimate must be far below
        // the whole-file estimate.
        let filler = String(repeating: "<p>filler line of body copy here</p>\n", count: 400)
        let content = "<body>\n" + filler + "<h1 id=\"t\">Old</h1>\n" + filler + "</body>"
        let req = SurgicalEditRequest(filePath: "x.html", selector: "#t",
                                      instruction: "tighten", fileContent: content)
        let fullEstimate = content.count / 4
        XCTAssertLessThan(req.estimatedTokens, fullEstimate,
                          "the surgical estimate must be cheaper than a full regeneration")
    }
}
