import XCTest
@testable import Grux

/// D5: Home is Today everywhere it is named. The key stays `home`, because
/// scripts, the CLI and every saved sidebar state use it; only the word a
/// person reads changes, and it changes in every place at once.
@MainActor
final class TodayIsNamedTodayTests: XCTestCase {
    func test_everyLabelForTheHomeKeyReadsToday() {
        XCTAssertEqual(SidebarIA.item(forKey: "home")?.label, "Today")
        XCTAssertEqual(SidebarIA.rail(developerUnlocked: false, brands: []).first?.label, "Today")
        XCTAssertEqual(FeatureRegistry.rows.first { $0.id == "home" }?.label, "Today")
        XCTAssertNotNil(LaunchRootView.tab(forKey: "home"), "the key moved; it must not")
    }

    /// No shipped string still sends a person to "Home".
    func test_noShippedStringSaysHomeForToday() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 500)
        var hits: [String] = []
        for f in files {
            for line in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("label: \"Home\"") || line.contains("\"Home tab\"") || line.contains("Text(\"Home\")") {
                    hits.append("\(f.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(hits, [])
    }
}
