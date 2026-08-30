import XCTest

/// A published document must not deny that it is published.
///
/// Five docs shipped in 1.2.1 saying this repository was private and that
/// nothing in them was implemented, including the CLI grammar the README links
/// to as the full command surface. A reader following that link landed on
/// "Nothing below, including the command names, is public", about a command
/// line that had just shipped. Every one was found by a person clicking a link.
///
/// `extract-oss.py` now refuses to extract a tree containing these sentences,
/// which is the stronger guard because it reads the tree that would actually
/// publish. This test exists beside it for one reason: that script is excluded
/// from the published tree, deliberately, because it holds the labelled patterns
/// it hunts for. So in the public repository nothing checks this at all, and the
/// public repository is the one where being wrong is visible to strangers.
///
/// Two guards, two trees, one rule.
final class ShippedDocsTellTheTruthTests: XCTestCase {

    /// Split so this file does not trip the very scan it is about.
    private var deniesPublication: String { "THIS REPOSITORY" + " IS PRIVATE" }
    private var deniesImplementation: String { "Nothing here" + " is implemented" }

    private func shippedDocs() throws -> [(name: String, text: String)] {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs")
        guard let walker = FileManager.default.enumerator(
            at: docs, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "md" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                out.append((url.lastPathComponent, text))
            }
        }
        return out
    }

    /// Anti-vacuity. A scan that opens nothing reports nothing wrong.
    func testTheScanActuallyReadsDocuments() throws {
        let docs = try shippedDocs()
        XCTAssertGreaterThan(docs.count, 10,
                             "Only \(docs.count) documents were read, so this scan proves "
                                + "close to nothing. The path is probably wrong.")
    }

    /// The claim that stopped being true the moment the tree was published.
    func testNoShippedDocumentSaysThisRepositoryIsPrivate() throws {
        let offenders = try shippedDocs()
            .filter { $0.text.range(of: deniesPublication, options: .caseInsensitive) != nil }
            .map(\.name)
        XCTAssertTrue(offenders.isEmpty,
                      // Worded around the pattern rather than exempted from it. The
                      // first draft of this message contained the phrase itself,
                      // and the extractor correctly refused the tree.
                      "These shipped documents deny that this tree is published, which is "
                        + "false wherever a reader can see it: \(offenders)")
    }

    /// And the claim that sends a reader away from something that exists.
    func testNoShippedDocumentSaysNothingIsImplemented() throws {
        let offenders = try shippedDocs()
            .filter { $0.text.range(of: deniesImplementation, options: .caseInsensitive) != nil }
            .map(\.name)
        XCTAssertTrue(offenders.isEmpty,
                      "These shipped documents say nothing in them is implemented, next to "
                        + "code that implements it: \(offenders)")
    }
}
