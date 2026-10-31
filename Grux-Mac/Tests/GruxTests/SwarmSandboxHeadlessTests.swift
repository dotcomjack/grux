import XCTest
@testable import GruxAgentCore

// Headless mode reaches the agent CLIs' own Bash tool.
//
// A workflow's agent step runs its commands itself under `SwarmWorker.sandboxDecision`,
// so no Grux shell door sees an `open -a "Google Chrome"` or an `osascript ... activate`
// it runs (the `register-asc-app` phase asks for both). In headless mode the profile
// itself refuses every Apple event and the programs that open or script other apps.
//
// Proven without touching another app: inside the profile `osascript -e 'return 1'`
// (which sends no Apple event even when it runs) cannot even start.
final class SwarmSandboxHeadlessTests: XCTestCase {

    private let root = NSTemporaryDirectory() + "swarm-headless-root"

    func test_headlessProfile_deniesAppleEventsAndTheProgramsThatOpenApps() {
        let profile = SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: false, headless: true).profile
        XCTAssertTrue(profile.contains("(deny appleevent-send)"), profile)
        for program in SwarmWorker.appOpeningPrograms {
            XCTAssertTrue(profile.contains("(literal \"\(program)\")"), "headless profile must deny \(program)")
        }
        let shown = SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: false, headless: false).profile
        XCTAssertFalse(shown.contains("(deny appleevent-send)"))
        XCTAssertFalse(shown.contains("(deny process-exec"))
    }

    func test_defaultFollowsTheHeadlessHook() {
        let saved = SwarmWorker.isHeadless
        defer { SwarmWorker.isHeadless = saved }
        SwarmWorker.isHeadless = { true }
        XCTAssertTrue(SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: false).profile.contains("(deny process-exec"))
        SwarmWorker.isHeadless = { false }
        XCTAssertFalse(SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: false).profile.contains("(deny process-exec"))
    }

    func test_insideTheHeadlessSandbox_osascriptCannotStartAndEchoStillRuns() throws {
        let profile = SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: true, headless: true).profile
        let quiet = try run("/usr/bin/sandbox-exec", ["-p", profile, "/bin/echo", "quiet ok"])
        XCTAssertEqual(quiet.status, 0, "the headless profile must compile and run a quiet command")
        XCTAssertEqual(quiet.out.trimmingCharacters(in: .whitespacesAndNewlines), "quiet ok")

        let script = try run("/usr/bin/sandbox-exec", ["-p", profile, "/usr/bin/osascript", "-e", "return 1"])
        XCTAssertNotEqual(script.status, 0, "osascript ran inside the headless sandbox")
        XCTAssertNotEqual(script.out.trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    private func run(_ path: String, _ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
