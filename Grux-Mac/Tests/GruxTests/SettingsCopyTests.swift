import XCTest
@testable import Grux

/// SETTINGS SPEAKS PLAINLY, WHICH IS NOT THE SAME AS SPEAKING VAGUELY.
///
/// Measured 2026-09-20: 214 user-facing strings in SettingsView, of which 20
/// carry technical vocabulary. Reading them back, 19 are the CORRECT word for
/// the thing the person is configuring: "API key" is what the vendor calls the
/// thing you paste, and renaming it to something friendlier would make Settings
/// harder to use, not easier. That is also why the jargon test exempts Settings.
///
/// The one genuine defect was a raw opaque voice identifier printed in prose,
/// which a person can neither read nor act on. This test keeps that kind out.
final class SettingsCopyTests: XCTestCase {

    private func settings() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/SettingsView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 1000, "SettingsView did not load")
        return t
    }

    /// An opaque handle is something a person can neither read, remember, nor
    /// do anything with. Naming a field is fine; printing its value is not.
    func testNoOpaqueIdentifierIsPrintedInProse() throws {
        // Comments stripped first: a comment explaining why an identifier was
        // removed is not that identifier in the copy, and a scanner that cannot
        // tell the difference makes the fix unrecordable.
        let text = try settings().split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                let before = line[line.startIndex..<r.lowerBound]
                return before.filter { $0 == "\"" }.count % 2 == 0 ? String(before) : String(line)
            }.joined(separator: "\n")
        // 20+ characters of unbroken alphanumerics is a handle, not a word.
        let handle = try NSRegularExpression(pattern: "`[A-Za-z0-9]{20,}`")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var hits: [String] = []
        handle.enumerateMatches(in: text, range: range) { m, _, _ in
            if let m, let r = Range(m.range, in: text) { hits.append(String(text[r])) }
        }
        XCTAssertTrue(hits.isEmpty, "opaque identifiers printed in Settings copy: \(hits)")
    }

    /// The scan is only meaningful if it can find one.
    func testTheScannerCatchesAPlantedHandle() throws {
        let handle = try NSRegularExpression(pattern: "`[A-Za-z0-9]{20,}`")
        let planted = "Default voice ID `RPJ8nnVtuTgG8McXwW6M`."
        XCTAssertNotNil(handle.firstMatch(in: planted,
                                          range: NSRange(planted.startIndex..<planted.endIndex, in: planted)))
    }

    /// Settings still NAMES what it is asking for. Plain does not mean vague:
    /// a field labelled "secret code" is worse than one labelled "API key".
    func testSettingsStillNamesWhatItAsksFor() throws {
        let text = try settings()
        for needed in ["API key", "Endpoint", "Base URL"] {
            XCTAssertTrue(text.contains(needed),
                          "Settings stopped naming \(needed), which is the word the vendor uses")
        }
    }
}
