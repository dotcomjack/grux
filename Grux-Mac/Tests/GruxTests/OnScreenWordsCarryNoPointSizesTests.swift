import XCTest
@testable import Grux

/// D166 item 6 (sense pass 20): Settings, General, Shell said "The 240pt
/// sidebar from before 3.0". A point size is a layout number, not something a
/// person can picture, so no string Grux puts on screen carries one.
///
/// W54-P3 item 7: the first scan read only a one-line `Text("...")`, `Label`,
/// `Toggle`, `Button` or `help` literal, so "pts" and "points", a multi-line
/// string, a quote inside an interpolation, `Text(verbatim:)`, a TextField
/// prompt, a Section title and `static let` copy drawn through `Text(Self.x)`
/// all walked past it. The rule is now wider and simpler: no source text
/// outside a comment carries a point size at all. A number with "pt" can only
/// be inside a string in Swift, so every string is covered wherever it is drawn.
final class OnScreenWordsCarryNoPointSizesTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// "240pt", "12 pts", "420 points", "1.5pt", "a 12 point font", "12-pt",
    /// "12  pt"; not "Part 2 pt 3" (a part number, then more numbering).
    static let pointSize = try! NSRegularExpression(
        pattern: #"\b[0-9]+(?:\.[0-9]+)?(?: +|-)?(?:pt|pts|point|points)\b(?! *[0-9])"#, options: [.caseInsensitive])

    func test_theScanSeesAPointSizeInAShownString() {
        let shown = [
            #"Text("The 240pt sidebar")"#,
            #".help("a 420 pt panel")"#,
            #"Toggle("Use 12pt text", isOn: $x)"#,
            #"Text("Use 12 pts")"#,
            #"Text("a 420 points panel")"#,
            #"Text(verbatim: "The 240pt sidebar")"#,
            #"TextField("Width", text: $w, prompt: Text("240pt"))"#,
            #"Section("Sidebar (240pt)") {"#,
            #"static let sidebarLine = "The 240pt sidebar""#,
            #"Text("\(wide ? "Wide" : "Narrow") 240pt sidebar")"#,
            "Text(\"\"\"\nThe classic\n240pt sidebar\n\"\"\")",
            #"Text("A 1.5pt border")"#,
            #"Text("a 12 point font")"#,
            #"Text("a 12-pt font")"#,
            #"Text("a 12  pt font")"#,
            ##"Text(#"Use "// 12pt" here"#)"##,
            "Text(#\"\"\"\nA \"quoted\" 240pt line\n\"\"\"#)",
        ]
        for source in shown {
            XCTAssertEqual(Self.findings(in: source).count, 1, source)
        }
        let quiet = [
            #"Text("Back up at 3 PM")"#,
            #"Text("Optional")"#,
            #".padding(12) // 12pt"#,
            "/* a 240pt sidebar */ let x = 1",
            "/// The 240pt sidebar.\nlet x = 1",
            #"Text("Part 2 pt 3")"#,
            #"Text("Open https://example.com // 240pt")"#.replacingOccurrences(of: "240pt", with: "is fine"),
            #"let r = 12.pt"#,
            ##"Text(#"a\"#) // 12pt"##,
            ##"let s = ##"a "# b"## // 12pt"##,
        ]
        for source in quiet {
            XCTAssertEqual(Self.findings(in: source), [], source)
        }
    }

    /// A `//` inside a string is not a comment, so what follows it is read.
    func test_aSlashSlashInsideAStringIsNotAComment() {
        XCTAssertEqual(Self.findings(in: #"Text("See https://x.com, the 240pt sidebar")"#).count, 1)
    }

    /// Line numbers survive a block comment, so a finding names its real line.
    func test_findingsNameTheirRealLine() {
        let source = "/* one\ntwo */\nlet a = 1\nText(\"240pt\")"
        XCTAssertEqual(Self.findings(in: source).map(\.line), [4])
    }

    func test_noShownStringCarriesAPointSize() throws {
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in e where url.pathExtension == "swift" {
            scanned += 1
            for hit in Self.findings(in: try String(contentsOf: url, encoding: .utf8)) {
                found.append("\(url.lastPathComponent):\(hit.line): \(hit.text)")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan read almost nothing")
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }

    struct Finding: Equatable { let line: Int; let text: String }

    static func findings(in source: String) -> [Finding] {
        stripComments(source).components(separatedBy: "\n").enumerated().compactMap { i, line in
            let hit = pointSize.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) > 0
            return hit ? Finding(line: i + 1, text: line.trimmingCharacters(in: .whitespaces)) : nil
        }
    }

    /// The source with every `//` and `/* */` comment blanked, newlines kept.
    /// Strings (one-line and `"""`) are walked so a `//` inside one stays.
    static func stripComments(_ source: String) -> String {
        let c = Array(source)
        var out = ""
        var i = 0
        var inString = false
        var multiLine = false
        // Compared in place: an array per character made this scan 15 s of the
        // suite (T1 part 4).
        func at(_ s: String) -> Bool {
            var k = i
            for ch in s {
                guard k < c.count, c[k] == ch else { return false }
                k += 1
            }
            return true
        }
        while i < c.count {
            // A raw string, #"..."# or #"""..."""#: no escapes, and a quote
            // inside it does not end it (wave 55 P3-5).
            if !inString && c[i] == "#" {
                var hashes = 0
                while i + hashes < c.count && c[i + hashes] == "#" { hashes += 1 }
                if i + hashes < c.count && c[i + hashes] == "\"" {
                    let pounds = String(repeating: "#", count: hashes)
                    let open = i + hashes
                    let multi = open + 2 < c.count && c[open + 1] == "\"" && c[open + 2] == "\""
                    let close = Array((multi ? "\"\"\"" : "\"") + pounds)
                    var j = open + (multi ? 3 : 1)
                    while j < c.count && !(j + close.count <= c.count && Array(c[j..<(j + close.count)]) == close) { j += 1 }
                    let end = min(c.count, j + close.count)
                    out += String(c[i..<end])
                    i = end
                    continue
                }
            }
            if !inString && at("/*") {
                var depth = 0
                while i < c.count {
                    if at("/*") { depth += 1; i += 2; continue }
                    if at("*/") { depth -= 1; i += 2; if depth == 0 { break }; continue }
                    if c[i] == "\n" { out.append("\n") }
                    i += 1
                }
                continue
            }
            if !inString && at("//") {
                while i < c.count && c[i] != "\n" { i += 1 }
                continue
            }
            if at("\"\"\"") && (!inString || multiLine) {
                inString.toggle()
                multiLine = inString
                out += "\"\"\""
                i += 3
                continue
            }
            if inString && c[i] == "\\" && i + 1 < c.count {
                out.append(c[i]); out.append(c[i + 1]); i += 2
                continue
            }
            if c[i] == "\"" && !multiLine { inString.toggle() }
            if c[i] == "\n" && inString && !multiLine { inString = false }
            out.append(c[i])
            i += 1
        }
        return out
    }
}
