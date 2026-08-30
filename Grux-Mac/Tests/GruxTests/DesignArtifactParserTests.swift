import XCTest
@testable import Grux

// Unit tests for DesignArtifactParser: the streaming extractor that pulls
// <grux-artifact path="site/..."> ... </grux-artifact> blocks out of model text
// deltas. Focus areas: chunk boundaries that split tags mid-stream, multiple
// files in one stream, traversal-path rejection, and clean passthrough.
final class DesignArtifactParserTests: XCTestCase {

    // MARK: - Harness

    private func run(_ chunks: [String]) -> [DesignArtifactEvent] {
        let parser = DesignArtifactParser()
        var out: [DesignArtifactEvent] = []
        for chunk in chunks { out += parser.parse(chunk) }
        out += parser.finish()
        return out
    }

    private func passthrough(_ events: [DesignArtifactEvent]) -> String {
        events.compactMap {
            if case .passthroughText(let t) = $0 { return t } else { return nil }
        }.joined()
    }

    private func completedFiles(_ events: [DesignArtifactEvent]) -> [(path: String, text: String)] {
        events.compactMap {
            if case .fileCompleted(let p, let f) = $0 { return (p, f) } else { return nil }
        }
    }

    private func startedPaths(_ events: [DesignArtifactEvent]) -> [String] {
        events.compactMap {
            if case .fileStarted(let p) = $0 { return p } else { return nil }
        }
    }

    private func chunkedFullText(_ events: [DesignArtifactEvent], path: String) -> String {
        events.compactMap {
            if case .fileChunk(let p, let t) = $0, p == path { return t } else { return nil }
        }.joined()
    }

    // MARK: - Passthrough only

    func testPlainTextIsAllPassthrough() {
        let events = run(["Here is some ", "plain prose with no artifacts."])
        XCTAssertEqual(passthrough(events), "Here is some plain prose with no artifacts.")
        XCTAssertTrue(completedFiles(events).isEmpty)
    }

    func testLiteralLessThanStaysPassthrough() {
        // A "<" that never becomes an artifact tag must survive as prose.
        let events = run(["price < $50 and a < b"])
        XCTAssertEqual(passthrough(events), "price < $50 and a < b")
        XCTAssertTrue(completedFiles(events).isEmpty)
    }

    // MARK: - Single clean file

    func testSingleFileWholeChunk() {
        let stream = "Building it.\n<grux-artifact path=\"site/index.html\"><h1>Hi</h1></grux-artifact>\nDone."
        let events = run([stream])
        XCTAssertEqual(startedPaths(events), ["site/index.html"])
        let files = completedFiles(events)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, "site/index.html")
        XCTAssertEqual(files.first?.text, "<h1>Hi</h1>")
        // Prose before and after the block survives.
        XCTAssertEqual(passthrough(events), "Building it.\n\nDone.")
        // fileChunk pieces reassemble to the same content.
        XCTAssertEqual(chunkedFullText(events, path: "site/index.html"), "<h1>Hi</h1>")
    }

    // MARK: - Chunk boundaries

    func testOneCharacterAtATime() {
        // The most brutal chunking: every single character is its own delta.
        // Tags, path, and content are all split at every boundary.
        let stream = "pre <grux-artifact path=\"site/app.js\">console.log(1);</grux-artifact> post"
        let chunks = stream.map { String($0) }
        let events = run(chunks)
        let files = completedFiles(events)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, "site/app.js")
        XCTAssertEqual(files.first?.text, "console.log(1);")
        XCTAssertEqual(passthrough(events), "pre  post")
    }

    func testCloseTagSplitAcrossChunks() {
        // The close tag is split as "</grux-" | "artifact>". The parser must
        // hold the partial back and never emit it as content.
        let events = run([
            "<grux-artifact path=\"site/index.html\">body</grux-",
            "artifact>tail"
        ])
        let files = completedFiles(events)
        XCTAssertEqual(files.first?.path, "site/index.html")
        XCTAssertEqual(files.first?.text, "body")
        XCTAssertEqual(passthrough(events), "tail")
    }

    func testOpenTagSplitAcrossChunks() {
        let events = run([
            "<grux-art",
            "ifact path=\"site/styles",
            ".css\">.a{color:red}</grux-artifact>"
        ])
        let files = completedFiles(events)
        XCTAssertEqual(files.first?.path, "site/styles.css")
        XCTAssertEqual(files.first?.text, ".a{color:red}")
    }

    // MARK: - Multiple files

    func testMultipleFilesBackToBack() {
        let stream = "<grux-artifact path=\"site/index.html\">A</grux-artifact>"
            + "middle"
            + "<grux-artifact path=\"site/app.js\">B</grux-artifact>"
        let events = run([stream])
        let files = completedFiles(events)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "site/index.html")
        XCTAssertEqual(files[0].text, "A")
        XCTAssertEqual(files[1].path, "site/app.js")
        XCTAssertEqual(files[1].text, "B")
        XCTAssertEqual(passthrough(events), "middle")
    }

    // MARK: - Traversal / bad path rejection

    func testTraversalPathRejected() {
        let events = run(["<grux-artifact path=\"site/../secret.txt\">STEAL</grux-artifact>"])
        // No file events, and the swallowed content never leaks into passthrough.
        XCTAssertTrue(completedFiles(events).isEmpty)
        XCTAssertTrue(startedPaths(events).isEmpty)
        XCTAssertFalse(passthrough(events).contains("STEAL"))
    }

    func testAbsoluteAndOutsideSitePathsRejected() {
        let abs = run(["<grux-artifact path=\"/etc/passwd\">X</grux-artifact>"])
        XCTAssertTrue(completedFiles(abs).isEmpty)

        let outside = run(["<grux-artifact path=\"assets/x.js\">X</grux-artifact>"])
        XCTAssertTrue(completedFiles(outside).isEmpty)

        // A valid path following a rejected one still works (state recovers).
        let mixed = run([
            "<grux-artifact path=\"../evil\">NO</grux-artifact>",
            "<grux-artifact path=\"site/ok.html\">YES</grux-artifact>"
        ])
        let files = completedFiles(mixed)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, "site/ok.html")
        XCTAssertEqual(files.first?.text, "YES")
    }

    func testValidatePathRules() {
        XCTAssertEqual(DesignArtifactParser.validate(path: "site/index.html"), "site/index.html")
        XCTAssertEqual(DesignArtifactParser.validate(path: "site/css/app.css"), "site/css/app.css")
        XCTAssertNil(DesignArtifactParser.validate(path: "site/../x"))
        XCTAssertNil(DesignArtifactParser.validate(path: "/site/x"))
        XCTAssertNil(DesignArtifactParser.validate(path: "notsite/x"))
        XCTAssertNil(DesignArtifactParser.validate(path: "site/"))
        XCTAssertNil(DesignArtifactParser.validate(path: "site//x"))
        XCTAssertNil(DesignArtifactParser.validate(path: ""))
    }

    // MARK: - Truncated stream

    func testUnterminatedArtifactSalvagesContent() {
        // Stream ends before the close tag. finish() should salvage the bytes
        // as a completed file so a truncated-but-usable draft still lands.
        let events = run(["<grux-artifact path=\"site/index.html\">partial content"])
        let files = completedFiles(events)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.text, "partial content")
    }
}
