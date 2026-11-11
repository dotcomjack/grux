import XCTest
@testable import Grux

// D192 (4): Notes read "1mo ago" beside Jax HQ's "Queued 1 mo. ago" for the same
// age, because each pane built its own RelativeDateTimeFormatter in its own style
// (Notes, Social and Reactor abbreviated; Jax and Projects short). Every pane now
// asks one helper, so a person reads one way of saying how long ago.
@MainActor
final class RelativeStampOneStyleTests: XCTestCase {

    func testNotesAndJaxSayTheSameAgeTheSameWay() {
        for days in [0.01, 0.2, 3, 40, 400] {
            let date = Date().addingTimeInterval(-days * 86_400)
            XCTAssertEqual(JaxTime.ago(date), NotesView.relativeStamp(date), "\(days) days")
        }
    }

    func testTheOneStyleIsTheAbbreviatedOneTheHandWrittenLabelsUse() {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RelativeStamp.string(for: now.addingTimeInterval(-40 * 86_400), relativeTo: now, calendar: cal), "1mo ago")
        XCTAssertEqual(RelativeStamp.string(for: now.addingTimeInterval(-3 * 86_400), relativeTo: now, calendar: cal), "3d ago")
        XCTAssertEqual(RelativeStamp.string(for: now.addingTimeInterval(20 * 60), relativeTo: now, calendar: cal), "in 20m")
    }

    func testOnlyTheSharedHelperBuildsARelativeFormatter() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100)
        var builders: [String] = []
        for file in files where file.lastPathComponent != "RelativeStamp.swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            if src.contains("RelativeDateTimeFormatter()") { builders.append(file.lastPathComponent) }
        }
        XCTAssertEqual(builders, [], "build it through RelativeStamp instead")
    }
}
