import XCTest
@testable import Grux

/// `~/.grux` is built in ONE place, `Persistence.gruxDir`, so the suite's
/// isolation reaches every store in it (P-H-1).
///
/// Measured 2026-09-21: 107 sites in about 60 files built the path by hand,
/// and a full suite run changed five of the operator's real stores
/// (`support/drafts.json`, `support/filtered-mail.json`,
/// `support/muted-senders.json`, `jax/autonomy-ledger.json`,
/// `jax/correction-lessons.json`). A path built any other way goes straight
/// past `Persistence.isUnderTest`.
final class GruxDirIsBuiltOnceTests: XCTestCase {

    /// The shapes a hand-built home path took. `IOSDispatcherV2` builds a
    /// PROJECT's own `.grux` folder from a project root, which is not this
    /// folder, and none of these shapes match it.
    static let handBuilt: [NSRegularExpression] = [
        #"appendingPathComponent\("\.grux"#,
        #"NSHomeDirectory\(\)\s*\+\s*"/\.grux"#,
        #"NSHomeDirectory\(\)\)/\.grux"#,
        #""~/\.grux[^"]*"[^\n]*expandingTildeInPath"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func offences(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return nil }
            let range = NSRange(line.startIndex..., in: line)
            return handBuilt.contains { $0.firstMatch(in: line, range: range) != nil } ? line : nil
        }
    }

    func test_nothingButPersistenceBuildsTheDotGruxPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 500, "the scan found too few Swift files to mean anything")
        var found: [String] = []
        var persistenceHits = 0
        for f in files {
            let hits = Self.offences(in: try String(contentsOf: f, encoding: .utf8))
            if f.lastPathComponent == "Persistence.swift" { persistenceHits = hits.count; continue }
            found += hits.map { "\(f.lastPathComponent): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        // The positive control: the definition IS found (the real folder and
        // the suite's own `.grux` inside its scratch directory), so a scan that
        // matches nothing cannot pass by being broken.
        XCTAssertEqual(persistenceHits, 2, "the scan no longer recognises the definition it protects")
        XCTAssertEqual(found, [], "build these through Persistence.gruxDir")
    }

    func test_theShapesAreRecognised() {
        XCTAssertEqual(Self.offences(in: #"let p = NSHomeDirectory() + "/.grux/x.json""#).count, 1)
        XCTAssertEqual(Self.offences(in: #"    .appendingPathComponent(".grux", isDirectory: true)"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"let p = ("~/.grux/pitch.md" as NSString).expandingTildeInPath"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"// URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux")"#).count, 0,
                       "a comment is not a path")
        XCTAssertEqual(Self.offences(in: #"let cfgPath = root + "/.grux/ship-config.json""#).count, 0,
                       "a project's own .grux folder is not this one")
        XCTAssertEqual(Self.offences(in: #"unconfiguredDetail: "~/.grux/pr-digest-hosts.txt names no host","#).count, 0,
                       "copy that names the folder is not a path")
    }
}
