import XCTest
@testable import Grux

/// Where the Foundry finds Grux's source.
///
/// `GRUX_REPO_ROOT` was the one answer, and a GUI launch from /Applications
/// never carries it, so Build it silently did nothing on every install built
/// with `build.sh`, which had ALREADY written the checkout it built from to
/// `~/.grux/source.json`. The env var still wins when it is set and valid; the
/// recorded source is the fallback, validated the same way.
final class FoundryRepoRootTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-repo-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A checkout the validator accepts: Grux-Mac/Package.swift and .git present.
    private func makeCheckout(_ name: String, valid: Bool = true) throws -> URL {
        let root = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Grux-Mac"), withIntermediateDirectories: true)
        if valid {
            try "// swift-tools-version:5.9".write(to: root.appendingPathComponent("Grux-Mac/Package.swift"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        return root
    }

    private func writeSource(path: String) throws -> URL {
        let file = scratch.appendingPathComponent("source.json")
        let source = WorkOrderSource(path: path, commit: "abc1234", binaryMtime: 1)
        try JSONEncoder().encode(source).write(to: file)
        return file
    }

    func testTheEnvironmentVariableWinsWhenItIsValid() throws {
        let env = try makeCheckout("env")
        let recorded = try makeCheckout("recorded")
        let file = try writeSource(path: recorded.path)
        let resolved = FoundryEngine.resolveRepoRoot(environment: ["GRUX_REPO_ROOT": env.path], sourceFile: file)
        XCTAssertEqual(resolved?.standardizedFileURL, env.standardizedFileURL)
    }

    func testTheRecordedSourceIsTheFallbackWhenTheEnvironmentIsUnset() throws {
        let recorded = try makeCheckout("recorded")
        let file = try writeSource(path: recorded.path)
        let resolved = FoundryEngine.resolveRepoRoot(environment: [:], sourceFile: file)
        XCTAssertEqual(resolved?.standardizedFileURL, recorded.standardizedFileURL)
    }

    func testAnInvalidEnvironmentValueFallsThroughToTheRecordedSource() throws {
        let recorded = try makeCheckout("recorded")
        let file = try writeSource(path: recorded.path)
        let resolved = FoundryEngine.resolveRepoRoot(
            environment: ["GRUX_REPO_ROOT": scratch.appendingPathComponent("nowhere").path],
            sourceFile: file
        )
        XCTAssertEqual(resolved?.standardizedFileURL, recorded.standardizedFileURL,
                       "a stale env value must not beat a valid recorded checkout")
    }

    func testARecordedSourceThatIsNotACheckoutIsRefused() throws {
        let notACheckout = try makeCheckout("gone", valid: false)
        let file = try writeSource(path: notACheckout.path)
        XCTAssertNil(FoundryEngine.resolveRepoRoot(environment: [:], sourceFile: file),
                     "a folder with no Package.swift and no .git is not a source checkout")
    }

    /// build.sh runs from Grux-Mac (`cd "$(dirname "$0")"`) and records
    /// `$(pwd)`, so source.json holds the package folder, not the repo root.
    /// The resolver demanded `<path>/Grux-Mac/Package.swift` and refused it,
    /// so every card on a build.sh install read "Grux cannot build this here".
    func testWhatBuildShRecordsResolvesToTheRepoRoot() throws {
        let root = try makeCheckout("built")
        let file = try writeSource(path: root.appendingPathComponent("Grux-Mac").path)
        let resolved = FoundryEngine.resolveRepoRoot(environment: [:], sourceFile: file)
        XCTAssertEqual(resolved?.standardizedFileURL, root.standardizedFileURL)
        let fromEnv = FoundryEngine.resolveRepoRoot(
            environment: ["GRUX_REPO_ROOT": root.appendingPathComponent("Grux-Mac").path],
            sourceFile: scratch.appendingPathComponent("absent.json"))
        XCTAssertEqual(fromEnv?.standardizedFileURL, root.standardizedFileURL)
    }

    /// The other half of that contract, read from build.sh itself so the two
    /// cannot drift apart again.
    func testBuildShRecordsThePackageFolder() throws {
        let buildSh = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build.sh")
        let text = try String(contentsOf: buildSh, encoding: .utf8)
        XCTAssertTrue(text.contains("cd \"$(dirname \"$0\")\""), "build.sh runs from Grux-Mac")
        XCTAssertTrue(text.contains("python3 -I - \"$(pwd)\""), "build.sh records the folder it runs from")
    }

    func testAPackageFolderOutsideACheckoutIsRefused() throws {
        let loose = scratch.appendingPathComponent("loose/Grux-Mac", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9".write(to: loose.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = try writeSource(path: loose.path)
        XCTAssertNil(FoundryEngine.resolveRepoRoot(environment: [:], sourceFile: file),
                     "a package folder whose parent has no .git is not a checkout")
    }

    func testNothingRecordedAndNothingSetResolvesToNil() {
        let missing = scratch.appendingPathComponent("absent.json")
        XCTAssertNil(FoundryEngine.resolveRepoRoot(environment: [:], sourceFile: missing))
    }

    func testTheDefaultSourceFileIsTheOneBuildShWrites() {
        XCTAssertEqual(FoundryEngine.recordedSourceFile, WorkOrderContext.sourceFile,
                       "two readers of one file must agree on where it is")
    }
}
