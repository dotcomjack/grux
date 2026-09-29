import XCTest
@testable import GruxAgentCore

// Silent mode reaches the agent CLIs' own Bash tool.
//
// A Claude (or ACP) agent runs its commands itself, under the sandbox-exec profile
// from `SwarmWorker.sandboxDecision`, so none of Grux's shell doors ever see a
// `say` or `afplay` it runs. In silent mode the profile itself takes the speaker
// away: the audio HAL, the system sound server and the speech daemon are denied,
// and so are Apple events to the music players.
//
// Proven without sound: `say -a ?` only LISTS output devices. Measured on the
// Mac mini 2026-09-27: two devices outside the sandbox, none inside a profile
// that denies `com.apple.audio.audiohald`.
final class SwarmSandboxSilenceTests: XCTestCase {

    private let root = NSTemporaryDirectory() + "swarm-silence-root"

    func test_silentProfile_deniesTheAudioServicesAndThePlayers() {
        let profile = SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: true).profile
        for service in SwarmWorker.soundServices {
            XCTAssertTrue(profile.contains("(global-name \"\(service)\")"), "silent profile must deny \(service)")
        }
        XCTAssertTrue(profile.contains("(deny mach-lookup"))
        XCTAssertTrue(profile.contains("(global-name \"com.apple.audio.audiohald\")"))
        XCTAssertTrue(profile.contains("(deny appleevent-send"))
        XCTAssertTrue(profile.contains("(appleevent-destination \"com.apple.Music\")"))
        XCTAssertTrue(profile.contains("(appleevent-destination \"com.spotify.client\")"))
    }

    func test_audibleProfile_leavesSoundAlone() {
        let profile = SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: false).profile
        XCTAssertFalse(profile.contains("(deny mach-lookup"))
        XCTAssertFalse(profile.contains("(deny appleevent-send"))
    }

    func test_defaultFollowsTheSilentHook() {
        let saved = SwarmWorker.isSilent
        defer { SwarmWorker.isSilent = saved }
        SwarmWorker.isSilent = { true }
        XCTAssertTrue(SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: []).profile.contains("(deny mach-lookup"))
        SwarmWorker.isSilent = { false }
        XCTAssertFalse(SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: []).profile.contains("(deny mach-lookup"))
    }

    // The real sandbox: the silent profile compiles, a quiet command still runs,
    // and a process inside it can see no output device at all.
    func test_insideTheSilentSandbox_noOutputDeviceIsVisible() throws {
        let profile = SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [], silent: true).profile
        let quiet = try run("/usr/bin/sandbox-exec", ["-p", profile, "/bin/echo", "quiet ok"])
        XCTAssertEqual(quiet.status, 0, "the silent profile must compile and run a quiet command")
        XCTAssertEqual(quiet.out.trimmingCharacters(in: .whitespacesAndNewlines), "quiet ok")

        let devices = try run("/usr/bin/sandbox-exec", ["-p", profile, "/usr/bin/say", "-a", "?"])
        XCTAssertEqual(devices.out.trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "inside the silent sandbox no audio output device may be reachable")
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
