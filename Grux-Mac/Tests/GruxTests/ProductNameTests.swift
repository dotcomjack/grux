import XCTest

/// The product is "Grux AI" (name ruling, 2026-10-13). The 3.0 app said "Grux OS" in
/// the menu bar, the panel wordmark, the window title, About, permission prompts and
/// System Settings paths, while the site and the README said something else. This
/// fails if the old name comes back anywhere a person can read it: a string literal
/// in Sources, or the bundle names in Info.plist.
///
/// Comments are skipped on purpose. A few quote macOS dialogs exactly as they were
/// measured under the old name, and rewriting history in a comment helps nobody.
/// The bundle id, Grux.app and the executable keep the name "Grux" and are not checked.
final class ProductNameTests: XCTestCase {

    private var macRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Lines of code (not comments) that spell the retired name, as "file:line: text".
    static func retiredNameHits(in source: String, file: String) -> [String] {
        var hits: [String] = []
        for (i, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("*") || line.hasPrefix("/*") { continue }
            let code = line.components(separatedBy: " // ").first ?? line
            if code.range(of: "grux os", options: .caseInsensitive) != nil {
                hits.append("\(file):\(i + 1): \(line)")
            }
        }
        return hits
    }

    func test_noSourceStringSaysGruxOS() throws {
        let sources = macRoot.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            hits += Self.retiredNameHits(in: text, file: url.lastPathComponent)
        }
        XCTAssertGreaterThan(scanned, 500, "the walk found too few Swift files to be the real Sources tree")
        XCTAssertEqual(hits, [], "user-visible \"Grux OS\" is back; the product is \"Grux AI\":\n" + hits.joined(separator: "\n"))
    }

    func test_theBundleIsNamedGruxAI() throws {
        let data = try Data(contentsOf: macRoot.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleName"] as? String, "Grux AI")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Grux AI")
        // These three are load-bearing for installs, TCC grants and every link: they never move.
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.gruxai.grux")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Grux")
    }

    /// The scanner itself has to catch what it is for, or a green run means nothing.
    func test_theScannerCatchesALiteralAndSkipsAComment() {
        let sample = """
        // "Grux OS wants access" was the old prompt
        Text("GRUX OS")
        let ok = "Grux AI"
        """
        XCTAssertEqual(Self.retiredNameHits(in: sample, file: "x").count, 1)
    }
}
