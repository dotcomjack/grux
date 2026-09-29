import XCTest
@testable import Grux

/// A finished suite run's sandbox is removed by the next run.
///
/// `Persistence` gives each test process its own `Grux-tests-<pid>` folder and its comment
/// said the folder "disappears on its own". It did not: measured 2026-09-27, 71 of them
/// (38 GB) sat in this Mini's temporary folder until the disk was full.
final class TestSandboxSweepTests: XCTestCase {

    private var parent: URL!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    private func make(_ name: String) throws -> URL {
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("state.json"))
        return dir
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func test_aDeadRunsSandboxIsRemovedAndALiveOneKept() throws {
        let dead = try make("Grux-tests-4000001")
        let live = try make("Grux-tests-\(ProcessInfo.processInfo.processIdentifier)")
        let other = try make("Grux-tests-notapid")
        let unrelated = try make("SomethingElse-4000001")

        Persistence.sweepFinishedTestSandboxes(in: parent)

        XCTAssertFalse(exists(dead), "a sandbox whose process is gone must go")
        XCTAssertTrue(exists(live), "the running process's sandbox must stay")
        XCTAssertTrue(exists(other), "a name that is not ours is left alone")
        XCTAssertTrue(exists(unrelated), "a name that is not ours is left alone")
    }

    /// Another suite running at the same time keeps its sandbox.
    func test_anotherLiveProcessKeepsItsSandbox() throws {
        let launchd = try make("Grux-tests-1")
        Persistence.sweepFinishedTestSandboxes(in: parent)
        XCTAssertTrue(exists(launchd))
    }
}
