import XCTest
@testable import Grux

/// NO INTERNALS ON THE FACE.
///
/// Banned: HTTP status codes, raw model identifiers, and internal identifiers.
/// Allowed, deliberately: vendor names. The 3.0 design is explicit that they
/// stay, one size smaller; this test is about internals, not about pretending
/// Grux has no suppliers.
///
/// Exempt: Settings detail lines and the Developer and Labs surfaces, which
/// are where a person goes precisely to see internals. The list is a data file
/// beside this test rather than an array in it, and a second test fails the
/// day an entry stops matching anything.
final class JargonInTheFaceTests: XCTestCase {

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
    }

    private var exemptions: [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("jargon-exempt.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Every file that draws something a person looks at, minus the exempt
    /// surfaces.
    private func faceFiles() -> [URL] {
        let exempt = exemptions
        guard let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            if exempt.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { continue }
            // The face is what draws, plus the one place that writes the
            // words a failed turn puts in the thread. Network clients, config
            // defaults and the CLI trigger table are not the face: they hold
            // identifiers because identifiers are their job.
            guard rel.hasSuffix("View.swift")
                    || rel.hasPrefix("Chat/") || rel.hasPrefix("Home/") || rel.hasPrefix("Ambient/")
                    || rel.hasPrefix("DesignSystem/") || rel.hasPrefix("Shell/")
                    || rel == "ChatService.swift" else { continue }
            out.append(url)
        }
        return out
    }

    /// Line comments first: a comment that QUOTES a bad string in order to
    /// explain why it was removed is not that bad string on the face, and a
    /// scanner that cannot tell the difference makes the fix unrecordable.
    private func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            // Only strip when the // is outside a string literal.
            let before = line[line.startIndex..<r.lowerBound]
            return before.filter { $0 == "\"" }.count % 2 == 0 ? String(before) : String(line)
        }.joined(separator: "\n")
    }

    /// Double-quoted literals, which is what actually reaches a label.
    private func literals(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for ch in text {
            if escaped { if inString { current.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" {
                if inString { out.append(current); current = "" }
                inString.toggle()
                continue
            }
            if inString { current.append(ch) }
            if ch == "\n" && inString { inString = false; current = "" }
        }
        return out
    }

    private static let statusCode = try! NSRegularExpression(
        pattern: "(?i)\\b(http|status|error)\\b[^a-z0-9]{0,4}[1-5][0-9]{2}\\b")
    private static let modelIdentifier = try! NSRegularExpression(
        pattern: "^[a-z0-9._-]{2,}:[a-z0-9._-]{1,}$")
    /// An internal identifier has a SHAPE: a namespace, a colon, and a value
    /// with no space. "Open the Speakers tab: enroll a voice" is English and
    /// must survive; "tab:calendar" must not.
    private static let internalIdentifier = try! NSRegularExpression(
        pattern: "\\b(?:tab|macro):[a-z0-9_.]+|say:chat|not_a_command|__replay_(?:tool|input)")

    private func offences(in literal: String) -> [String] {
        let range = NSRange(literal.startIndex..<literal.endIndex, in: literal)
        var found: [String] = []
        if Self.statusCode.firstMatch(in: literal, range: range) != nil { found.append("status code") }
        if let m = Self.internalIdentifier.firstMatch(in: literal, range: range),
           let r = Range(m.range, in: literal) {
            found.append("internal identifier \(literal[r])")
        }
        // A namespaced internal id is shaped like a model id. Report it once,
        // as the more specific thing, or every "tab:" reads as two offences.
        if found.isEmpty, Self.modelIdentifier.firstMatch(in: literal, range: range) != nil {
            found.append("model identifier")
        }
        return found
    }

    func testTheScannerFindsFilesAtAll() {
        // A scan that reads nothing passes everything.
        XCTAssertGreaterThan(faceFiles().count, 10, "the face-file scan found almost nothing")
        XCTAssertGreaterThan(exemptions.count, 5, "the exemption list did not load")
    }

    /// The guard fails open unless it is proven to catch a planted offence.
    func testTheScannerActuallyCatchesEachKind() {
        XCTAssertEqual(offences(in: "That turn was rejected as malformed (HTTP 400)"), ["status code"])
        XCTAssertEqual(offences(in: "llama3.2:3b"), ["model identifier"])
        XCTAssertEqual(offences(in: "tab:calendar"), ["internal identifier tab:calendar"])
        XCTAssertEqual(offences(in: "not_a_command"), ["internal identifier not_a_command"])
        // And that it does NOT catch the things that are allowed.
        XCTAssertTrue(offences(in: "ElevenLabs").isEmpty, "a vendor name was banned")
        XCTAssertTrue(offences(in: "Plan for the 400 unit run").isEmpty)
        XCTAssertTrue(offences(in: "Llama 3.2").isEmpty)
        XCTAssertTrue(offences(in: "Open the Speakers tab: enroll a voice").isEmpty,
                      "English punctuation was read as an internal identifier")
    }

    func testNoInternalsOnTheFace() throws {
        var hits: [String] = []
        for url in faceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rel = url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            for literal in literals(in: stripComments(text)) {
                for offence in offences(in: literal) {
                    hits.append("\(rel): \(offence) in \"\(literal.prefix(70))\"")
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "internals on the face:\n" + hits.joined(separator: "\n"))
    }

    /// An exemption that matches nothing is a stale exemption, and a stale
    /// exemption is a hole nobody can see.
    func testEveryExemptionStillMatchesSomething() {
        for entry in exemptions {
            let path = sourcesRoot.appendingPathComponent(entry)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                          "jargon-exempt.txt lists \(entry), which no longer exists")
        }
    }
}
