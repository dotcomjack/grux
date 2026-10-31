import XCTest
@testable import Grux

// D20. A revert or a crash-loop restore relaunched Grux with
// `NSWorkspace.shared.open(appURL)` and then quit: on a headless Mac that put
// Grux on the person's screen, and since the old process was still running it
// mostly re-activated it instead of starting the restored build. The relaunch
// now waits for this process to end, then opens the bundle the way build.sh
// does: hidden and in the background (`open -g -j`) on a headless Mac.
final class FoundryRelaunchHeadlessTests: XCTestCase {

    func testAHeadlessRelaunchOpensHiddenInTheBackgroundAfterThisProcessEnds() throws {
        let args = GruxUpdater.relaunchArguments(appPath: "/Applications/Grux.app", pid: 4242, headless: true)
        XCTAssertEqual(args.first, "-c")
        let script = try XCTUnwrap(args.dropFirst().first)
        XCTAssertTrue(script.contains("kill -0 \"$2\""), "the relaunch does not wait for this process: \(script)")
        XCTAssertTrue(script.contains("/usr/bin/open -g -j \"$1\""), "a headless relaunch takes the screen: \(script)")
        // Paths and pid arrive as arguments, never inside the script text.
        XCTAssertFalse(script.contains("/Applications/Grux.app"))
        XCTAssertEqual(Array(args.suffix(2)), ["/Applications/Grux.app", "4242"])
    }

    func testAVisibleRelaunchOpensNormally() throws {
        let args = GruxUpdater.relaunchArguments(appPath: "/Applications/Grux.app", pid: 4242, headless: false)
        let script = try XCTUnwrap(args.dropFirst().first)
        XCTAssertTrue(script.contains("/usr/bin/open \"$1\""), script)
        XCTAssertFalse(script.contains("-j"), script)
    }

    func testTheInstallScriptsRevertHonorsHeadless() {
        let template = GruxUpdater.installScriptTemplate
        XCTAssertTrue(template.contains("if [ -e \"$HOME/.grux/HEADLESS\" ]; then open -g -j \"$APP\"; else open \"$APP\"; fi"),
                      "the install script's revert opens Grux on a headless Mac's screen")
    }

    func testNoFoundrySourceOpensAnAppThroughTheWorkspace() throws {
        let foundry = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Foundry")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: foundry, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let code = try String(contentsOf: url, encoding: .utf8)
            if code.contains("NSWorkspace.shared.open(") || code.contains("openApplication(") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scanned, 10, "the scan found no Foundry sources")
        XCTAssertEqual(offenders, [], "these relaunch Grux without the headless rule")
    }
}
