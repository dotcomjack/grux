import XCTest
@testable import GruxAgentCore

final class FactoryFixtureTests: XCTestCase {

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixture(_ name: String) throws -> String {
        let url = packageRoot
            .appendingPathComponent("factory/fixtures/wave1")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testGoodDiffScoresZeroAndTheBadDiffsDoNot() throws {
        let good = try fixture("good.diff")
        let badApply = try fixture("bad-apply.diff")
        let badScore = try fixture("bad-score.diff")
        let score = try String(contentsOf: packageRoot.appendingPathComponent("factory/score.sh"), encoding: .utf8)

        let goodRoot = try makeRepo()
        try apply(good, in: goodRoot)
        try writeScore(score, in: goodRoot)
        XCTAssertEqual(try runScore(in: goodRoot), 0)

        let applyRoot = try makeRepo()
        XCTAssertNotEqual(try applyCheck(badApply, in: applyRoot), 0)

        let scoreRoot = try makeRepo()
        try apply(badScore, in: scoreRoot)
        try writeScore(score, in: scoreRoot)
        XCTAssertNotEqual(try runScore(in: scoreRoot), 0)
    }

    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("factory-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(try Self.git(root, ["init"]), 0)
        return root
    }

    private func apply(_ diff: String, in root: URL) throws {
        XCTAssertEqual(try Self.gitApply(root, ["apply"], diff: diff), 0)
    }

    private func applyCheck(_ diff: String, in root: URL) throws -> Int32 {
        try Self.gitApply(root, ["apply", "--check"], diff: diff)
    }

    private func writeScore(_ text: String, in root: URL) throws {
        let dir = root.appendingPathComponent("factory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("score.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func runScore(in root: URL) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["factory/score.sh"]
        proc.currentDirectoryURL = root
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    func testThreeDiffsAreAllowedAndThePrivateWorktreeIsRefused() throws {
        for name in ["good.diff", "bad-apply.diff", "bad-score.diff"] {
            let diff = try fixture(name)
            XCTAssertEqual(
                FactoryPrivacy.check(diff: diff, scoreCommand: "bash factory/score.sh", env: [:]),
                .allow,
                name
            )
        }
        let prefixed = "cd /tmp/x/.worktrees/grux-rc41 && bash factory/score.sh"
        guard case .refuse(let reason) = FactoryPrivacy.check(diff: "", scoreCommand: prefixed, env: [:]) else {
            return XCTFail("expected refuse")
        }
        XCTAssertEqual(reason, "banned-path")
        let command = DaytonaFactory.remoteCommand(diff: "wave")
        XCTAssertTrue(command.contains("https://github.com/dotcomjack/grux.git"))
        XCTAssertFalse(command.contains("grux-rc41"))
        XCTAssertFalse(command.contains(prefixed))
    }

    private static func git(_ root: URL, _ args: [String]) throws -> Int32 {
        try gitApply(root, args, diff: nil)
    }

    private static func gitApply(_ root: URL, _ args: [String], diff: String?) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = root
        if let diff {
            let pipe = Pipe()
            proc.standardInput = pipe
            try proc.run()
            try pipe.fileHandleForWriting.write(contentsOf: Data(diff.utf8))
            try pipe.fileHandleForWriting.close()
        } else {
            try proc.run()
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
