import XCTest

/// Text a person reads is in US English, like the rest of the app ("color",
/// "behavior", "center"). 3.1's Tuning card said "from a colour to a new
/// surface", and the work orders Grux hands a coding agent said "Colours" and
/// "behaviour" (PR 35 review). This reads every string literal in Sources,
/// single and multi-line, and fails on the UK spellings.
///
/// Comments and identifiers are not read: only what can reach a screen, a
/// clipboard or a prompt. The exemptions are INPUT, words Grux has to accept
/// when a person or a document uses the UK spelling, keyed by file and word so
/// a new hit in the same file still fails.
final class USSpellingTests: XCTestCase {

    private static let uk = try! NSRegularExpression(
        pattern: #"\b(colour\w*|behaviour\w*|favourite\w*|organis\w*|licence\w*|centre\w*|grey\w*)\b"#,
        options: [.caseInsensitive])

    /// File (relative to Sources/) to the UK words it may hold, and why.
    static let acceptsUKInput: [String: Set<String>] = [
        // A search keyword: a person who types "behaviour" still finds Tuning.
        "Grux/Settings/SettingsSearchRegistry.swift": ["behaviour"],
        // Heading aliases: a DESIGN.md titled "Colour Palette" still parses.
        "Grux/DesignStudio/DesignSystems/DesignSystemModels.swift": ["colour", "colours", "colourpalette"],
    ]

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// The UK words in a file's string literals, as "line: word".
    static func hits(in text: String) -> [(line: Int, word: String)] {
        var out: [(Int, String)] = []
        var inMulti = false
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let fences = raw.components(separatedBy: "\"\"\"").count - 1
            var spans: [String] = []
            if inMulti {
                if !trimmed.hasPrefix("//") { spans.append(raw) }
            } else if !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*") {
                let code = raw.components(separatedBy: " // ").first ?? raw
                let lit = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
                let ns = code as NSString
                spans += lit.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
            }
            if fences % 2 == 1 { inMulti.toggle() }
            for span in spans {
                let ns = span as NSString
                for m in uk.matches(in: span, range: NSRange(location: 0, length: ns.length)) {
                    out.append((i + 1, ns.substring(with: m.range).lowercased()))
                }
            }
        }
        return out
    }

    func test_noUKSpellingInAStringAPersonReads() throws {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var found: [String] = []
        var exemptSeen: [String: Set<String>] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let rel = String(url.path.dropFirst(sources.path.count + 1))
            for hit in Self.hits(in: try String(contentsOf: url, encoding: .utf8)) {
                if Self.acceptsUKInput[rel]?.contains(hit.word) == true {
                    exemptSeen[rel, default: []].insert(hit.word)
                } else {
                    found.append("\(rel):\(hit.line) \(hit.word)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 500, "the walk found too few files to be Sources")
        XCTAssertEqual(found, [], "UK spelling in user-visible text; use US English:\n" + found.joined(separator: "\n"))
        XCTAssertEqual(exemptSeen, Self.acceptsUKInput,
                       "an input exemption no longer matches anything; remove it so it cannot hide a real hit")
    }

    func test_theScannerReadsLiteralsAndSkipsComments() {
        let sample = """
        // the colour of a comment is nobody's business
        let a = "a favourite colour"
        let colourName = 1
        let b = \"\"\"
            in the centre
            \"\"\"
        """
        XCTAssertEqual(Self.hits(in: sample).map(\.word), ["favourite", "colour", "centre"])
    }
}
