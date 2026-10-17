import XCTest

/// The release leak gate (tools/leak-gate.py) refuses a bundle whose binary
/// contains "/Users/", because that is how a builder's home path leaks. It only
/// runs on a release build, so a string literal carrying "/Users/" passed every
/// suite run and stopped the 3.1.0 release build on 2026-10-13
/// (FactoryPrivacy's regex). This reads Sources so the suite catches it first.
/// Write a pattern as "/[U]sers/" when the text must be matched, not shipped.
final class NoBuilderPathLiteralTests: XCTestCase {
    static func offenders(in root: URL) throws -> [String] {
        var found: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            var inMultiline = false
            for (i, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Inside a """ string every line is text that ships, even one that starts with //.
                let isComment = !inMultiline && (code.hasPrefix("//") || code.hasPrefix("*") || code.hasPrefix("/*"))
                if !isComment, line.contains("/Users/") { found.append("\(url.lastPathComponent):\(i + 1)") }
                if line.components(separatedBy: "\"\"\"").count % 2 == 0 { inMultiline.toggle() }
            }
        }
        return found
    }

    func testNoSourceLiteralCarriesAHomeRoot() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.path), "Sources not found at \(sources.path)")
        let found = try Self.offenders(in: sources)
        XCTAssertEqual(found, [], "these lines put \"/Users/\" into the shipped binary: \(found)")
    }

    func testTheScannerFindsAPlantedLiteralAndSkipsComments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nbp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "// a comment about /Users/x is fine\nlet p = \"/Users/x\"\nlet doc = \"\"\"\n// shipped text with /Users/y\n\"\"\"\n// after the fence, a comment about /Users/z\n".write(
            to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.offenders(in: dir), ["A.swift:2", "A.swift:4"])
    }
}
