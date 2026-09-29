import XCTest
@testable import Grux

/// LAUNCH MUST NOT READ A FOLDER MACOS PROTECTS.
///
/// Measured 2026-09-22 on a wiped Mac, walking the shipping 3.0.0 build as a
/// stranger: Grux launched and showed NO window, NO menu bar item, and never
/// armed its trigger watcher. It stayed that way. A sample of the process put
/// 100% of samples in one stack:
///
///     applicationDidFinishLaunching
///       -> DesignStudioIntegration.wireSeams()
///         -> DesignProjectStore.init()
///           -> Persistence.load
///             -> readDataFromFile        (blocked)
///
/// The store's library lives in `~/Documents/Grux/design`, and `~/Documents` is
/// TCC protected. Wiring one seam touched `.shared`, which built the store,
/// which read that folder on the main thread before the app had a window, so
/// the permission answer it was waiting for could never be given.
///
/// It was invisible on a Mac that had already granted Documents access, which
/// is every machine this app was ever developed on.
@MainActor
final class LaunchTouchesNoProtectedFolderTests: XCTestCase {

    /// The property this whole class exists to hold: wiring the integration
    /// builds nothing.
    func test_wiringTheStudioSeamsDoesNotBuildTheDocumentsBackedStore() {
        XCTAssertFalse(DesignProjectStore.wasInstantiated,
                       "control: something built the store before this test ran, so it proves nothing")
        DesignStudioIntegration.wireSeams()
        XCTAssertFalse(DesignProjectStore.wasInstantiated,
                       "wiring the seams built DesignProjectStore, which reads ~/Documents at launch")
        XCTAssertNotNil(DesignProjectStore.isProjectRunning, "the seam was not wired at all")
    }

    /// And the seam still works: the store asks the type-level closure.
    func test_theSeamStillAnswers() {
        var asked: UUID?
        DesignProjectStore.isProjectRunning = { id in asked = id; return true }
        defer { DesignProjectStore.isProjectRunning = nil }
        let id = UUID()
        XCTAssertEqual(DesignProjectStore.isProjectRunning?(id), true)
        XCTAssertEqual(asked, id)
    }

    /// No launch path may name a protected folder. The store's own file is
    /// allowed to; `applicationDidFinishLaunching` and the seams it calls are
    /// not, because a read there happens before there is a window to explain
    /// it, which the first-run rule forbids in the app's own surfaces too.
    func test_noLaunchPathNamesAProtectedFolder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Grux/GruxApp.swift"), encoding: .utf8)
        let integration = try String(
            contentsOf: root.appendingPathComponent("Sources/Grux/DesignStudio/DesignStudioIntegration.swift"),
            encoding: .utf8)

        // Control: the scan can see a string that IS there.
        XCTAssertTrue(app.contains("applicationDidFinishLaunching"), "control: this is not GruxApp.swift")

        // To the function's own closing brace, not to the next `func`: a
        // `private func` after it would otherwise be swept in and read as part
        // of launch.
        let launch = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(app.range(of: "\n    }\n", range: launch.upperBound..<app.endIndex))
        let body = String(app[launch.upperBound..<end.lowerBound])
        for stores in ["DesignProjectStore.shared", "DocumentStore.shared"] {
            XCTAssertFalse(body.contains(stores),
                           "applicationDidFinishLaunching builds \(stores), whose library is under ~/Documents")
        }
        // wireSeams runs AT launch, so the same rule applies to the one line
        // in it that used to do this.
        let wire = try XCTUnwrap(integration.range(of: "static func wireSeams() {"))
        let wireEnd = try XCTUnwrap(integration.range(of: "\n    }", range: wire.upperBound..<integration.endIndex))
        let wireBody = String(integration[wire.upperBound..<wireEnd.lowerBound])
        XCTAssertFalse(wireBody.contains("DesignProjectStore.shared"),
                       "wireSeams builds the Documents-backed store at launch again")
    }
}
