import XCTest

/// The ratchet only lets hardcode counts fall. These tests run the script the
/// way CI does, against a temp tree and a temp baseline (never the tracked
/// baseline), and prove a rise fails, a fall passes without writing, and only
/// `--write-baseline` moves the floor.
final class DesignRatchetTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var tmp: URL!
    private var feature: URL { tmp.appendingPathComponent("Sources/Grux/Feature/A.swift") }
    private var baseline: URL { tmp.appendingPathComponent("baseline.json") }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ratchet-\(UUID().uuidString.prefix(8))")
        for dir in ["Sources/Grux/Feature", "Sources/Grux/DesignSystem"] {
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent(dir),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func run(_ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [repo.appendingPathComponent("scripts/design-ratchet.py").path]
            + args + ["--root", tmp.path, "--baseline", baseline.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func baselineCounts() throws -> [String: Int] {
        let data = try Data(contentsOf: baseline)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
    }

    /// Each hardcode counts once in its pattern, including a named system color
    /// beyond the first eight, and the same lines inside DesignSystem/ count
    /// nothing: that folder is where tokens live.
    func test_eachPatternCountsOnce_andDesignSystemIsExempt() throws {
        let oneOfEach = """
        Text("x").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.5))
            .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(GruxTheme.base))
        Circle().fill(Color.teal)

        """
        try write(oneOfEach, to: feature)
        try write(oneOfEach, to: tmp.appendingPathComponent("Sources/Grux/DesignSystem/Tokens.swift"))
        let r = try run(["--write-baseline"])
        XCTAssertEqual(r.status, 0, r.out)
        // Colors is 2: `Color.white.opacity(` and the named system color `Color.teal`.
        XCTAssertEqual(try baselineCounts(), ["fonts": 1, "colors": 2, "paddings": 1, "radii": 1], r.out)
    }

    /// The control on the zero: a planted `.font(.system(size: 13))` above the
    /// floor exits 1 and names the pattern that rose.
    func test_aPlantedFontRiseFails() throws {
        try write("Text(\"x\").font(.system(size: 12)).padding(8)\n", to: feature)
        var r = try run(["--write-baseline"])
        XCTAssertEqual(r.status, 0, r.out)
        try write("Text(\"x\").font(.system(size: 12)).font(.system(size: 13)).padding(8)\n", to: feature)
        r = try run(["--check"])
        XCTAssertEqual(r.status, 1, "a rise passed: \(r.out)")
        XCTAssertTrue(r.out.contains("fonts: 2 > 1"), r.out)
        XCTAssertTrue(r.out.contains("design-ratchet: fonts 2/1 colors 0/0 paddings 1/1 radii 0/0 rose exit 1"), r.out)
    }

    /// A fall passes and says how to lower the floor, but `--check` never
    /// writes: the baseline bytes are identical until `--write-baseline` runs.
    func test_aFallPassesWithoutWriting_andOnlyWriteBaselineLowersTheFloor() throws {
        try write("Text(\"x\").font(.system(size: 12)).padding(8)\n", to: feature)
        var r = try run(["--write-baseline"])
        XCTAssertEqual(r.status, 0, r.out)
        let before = try Data(contentsOf: baseline)
        try write("Text(\"x\").font(GruxType.body).padding(8)\n", to: feature)
        r = try run(["--check"])
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("design-ratchet: fonts 0/1 colors 0/0 paddings 1/1 radii 0/0 ok exit 0"), r.out)
        XCTAssertTrue(r.out.contains("--write-baseline"), "a fall printed no hint: \(r.out)")
        XCTAssertEqual(try Data(contentsOf: baseline), before, "--check wrote the baseline")
        r = try run(["--write-baseline"])
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertEqual(try baselineCounts()["fonts"], 0, "--write-baseline did not lower the floor")
    }

    /// CI runs the check in the "Build and test" job, after the contract check,
    /// from the package folder. Comment lines are dropped first, so a step that
    /// is commented out, moved to another job or put before the contract check
    /// fails here.
    func test_ciRunsTheCheck() throws {
        let ci = try String(contentsOf: repo.deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let lines = ci.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let start = try XCTUnwrap(lines.firstIndex(of: "  build-and-test:"), "no build-and-test job")
        let end = lines[(start + 1)...].firstIndex { line in
            line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(":")
        } ?? lines.endIndex
        let job = lines[start..<end].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let contract = try XCTUnwrap(job.firstIndex(of: "- name: Contract check"), "no contract check in the job")
        let step = try XCTUnwrap(job.firstIndex(of: "- name: Design token ratchet"), "no ratchet step in the build-and-test job")
        XCTAssertGreaterThan(step, contract, "the ratchet runs before the contract check")
        XCTAssertEqual(Array(job[(step + 1)...].prefix(2)),
                       ["working-directory: Grux-Mac", "run: python3 scripts/design-ratchet.py --check"])
    }
}
