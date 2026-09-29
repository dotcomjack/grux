import XCTest
@testable import Grux
import GruxShellCore

/// In silent mode a shell command that would make sound is refused, not run.
///
/// The commands these tests run are fakes: executable scripts named `afplay` and `say` that only
/// touches a marker file. If the gate ever breaks, the marker appears and the test fails,
/// and nothing reaches a speaker either way.
final class ShellSilenceTests: XCTestCase {

    private var dir: URL!
    private var marker: URL { dir.appendingPathComponent("ran") }
    private var fakePlayer: String { dir.appendingPathComponent("bin/afplay").path }
    private var fakeSay: String { dir.appendingPathComponent("bin/say").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-silence-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for fake in [fakePlayer, fakeSay] {
            try "#!/bin/sh\ntouch '\(marker.path)'\n".write(toFile: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        }
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
    }

    override func tearDown() {
        AudioOutput.soundAllowedUnderTest = false
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        super.tearDown()
    }

    private func loggedShellLines() throws -> [[String: String]] {
        guard FileManager.default.fileExists(atPath: AudioOutput.logURL.path) else { return [] }
        return try String(contentsOf: AudioOutput.logURL, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
            .filter { $0["kind"] == "shell" }
    }

    func test_theMatcherFindsCommandsThatMakeSound() {
        let sounding: [(String, String)] = [
            ("say hello", "say"),
            ("/usr/bin/say hi there", "say"),
            ("cd /tmp && say done", "say"),
            ("echo hi | say", "say"),
            ("echo $(say hi)", "say"),
            ("VOL=1 afplay ~/chime.aiff", "afplay"),
            ("nohup afplay x.aiff &", "afplay"),
            ("nice -n 5 afplay x.aiff", "afplay"),
            ("mpv song.mp3", "mpv"),
            ("SwitchAudioSource -s Speakers", "SwitchAudioSource"),
            ("osascript -e 'tell application \"Music\" to play'", "osascript"),
            ("osascript -e \"set volume output volume 80\"", "osascript"),
            ("open -a Music", "open"),
            ("open -a Spotify", "open"),
            ("open ~/Downloads/track.mp3", "open"),
        ]
        for (command, program) in sounding {
            XCTAssertEqual(SoundingCommand.program(in: command), program, command)
        }
        let quiet = [
            "say -o /tmp/a.aiff hello",
            "say --output-file=/tmp/a.aiff hello",
            "ls -la",
            "echo say hello",
            "grep afplay notes.txt",
            "cat essay.txt",
            "git commit -m 'play the tape'",
            "open -a Safari https://example.com",
            "osascript -e 'tell application \"Finder\" to get name of front window'",
            "",
        ]
        for command in quiet {
            XCTAssertNil(SoundingCommand.program(in: command), command)
        }
    }

    /// A shell handed a string runs that string: `bash -c "say hi"` is `say`,
    /// at any depth (review RV6).
    func test_theMatcherJudgesTheStringAShellRuns() {
        let sounding: [(String, String)] = [
            ("bash -c \"say hi\"", "say"),
            ("sh -c 'afplay x.aiff'", "afplay"),
            ("/bin/zsh -c \"say done\"", "say"),
            ("bash -lc 'say hi'", "say"),
            ("zsh -c \"bash -c 'say hi'\"", "say"),
            ("sudo sh -c 'osascript -e \"set volume output volume 80\"'", "osascript"),
            ("eval say hi", "say"),
            ("bash -c 'open ~/Movies/clip.mp4'", "open"),
        ]
        for (command, program) in sounding {
            XCTAssertEqual(SoundingCommand.program(in: command), program, command)
        }
        for command in ["bash -c 'ls -la'", "sh -c 'echo play'", "bash script.sh", "zsh -c 'git status'"] {
            XCTAssertNil(SoundingCommand.program(in: command), command)
        }
    }

    /// `open` of a video file or a page that plays on load starts a player
    /// just as an audio file does (review RV6).
    func test_openingAVideoOrAMediaPageMakesSound() {
        for command in ["open ~/Movies/clip.mp4", "open movie.mov", "open -a \"QuickTime Player\" clip.m4v",
                        "open https://www.youtube.com/watch?v=abc", "open https://youtu.be/abc",
                        "open https://open.spotify.com/track/x", "open https://music.apple.com/us/album/x",
                        "open -a Safari https://vimeo.com/123", "open podcasts://"] {
            XCTAssertEqual(SoundingCommand.program(in: command), "open", command)
        }
        for command in ["open README.md", "open .", "open https://github.com", "open -a Safari https://example.com",
                        "open ~/Documents/report.pdf"] {
            XCTAssertNil(SoundingCommand.program(in: command), command)
        }
    }

    /// AppleScript that only shows something is not refused for containing
    /// `play` inside `display` (review RV9). One that makes a sound still is.
    func test_harmlessAppleScriptIsNotReadAsSound() {
        for source in ["display notification \"Build done\" with title \"Grux\"",
                       "display dialog \"Continue?\"", "display alert \"Saved\"",
                       "tell application \"Finder\" to get name of front window", "return \"essay\"",
                       "display dialog \"Replay the last step?\""] {
            XCTAssertFalse(SoundingCommand.appleScriptSounds(source), source)
        }
        for source in ["display notification \"done\" sound name \"Glass\"", "set volume output volume 20",
                       "tell application \"Music\" to play", "beep", "say \"hi\"",
                       "tell application \"Spotify\" to playpause", "SAY \"loud\""] {
            XCTAssertTrue(SoundingCommand.appleScriptSounds(source), source)
        }
        XCTAssertNil(SoundingCommand.program(in: "osascript -e 'display notification \"done\"'"))
        XCTAssertNil(ShellSilence.refusal(forAppleScript: "display dialog \"Continue?\"", silent: true))
    }

    func test_shellRunner_refusesASoundingCommandInSilentMode_andLogsIt() async throws {
        XCTAssertTrue(AudioOutput.isSilent)
        let raw = await ShellRunner.runRaw(command: "\(fakePlayer) chime.aiff")
        XCTAssertEqual(raw.status, -1)
        XCTAssertTrue(raw.stdout.contains("silent mode"), raw.stdout)
        let args = await ShellRunner.runArgs(fakePlayer, ["chime.aiff"])
        XCTAssertEqual(args.status, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the player ran in silent mode")

        let lines = try loggedShellLines()
        XCTAssertEqual(lines.map { $0["source"] ?? "" }, ["afplay", "afplay"])
        XCTAssertEqual(lines.first?["text"], "\(fakePlayer) chime.aiff")
    }

    func test_shellRunner_runsTheSameCommandWhenNotSilent() async throws {
        AudioOutput.soundAllowedUnderTest = true
        XCTAssertFalse(AudioOutput.isSilent)
        let raw = await ShellRunner.runRaw(command: "\(fakePlayer) chime.aiff")
        XCTAssertEqual(raw.status, 0, raw.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try loggedShellLines().count, 0)
    }

    func test_shellSession_refusesASoundingCommandInSilentMode_evenConfirmed() async throws {
        _ = AudioOutput.wireShellDoors
        XCTAssertTrue(AudioOutput.isSilent)
        // Never started: the refusal comes before anything a started session needs.
        let session = ShellSession(id: "silence-\(UUID().uuidString.prefix(8))", rootDir: dir.path,
                                   mode: .trust, undoMode: .perTurn)
        let ran = try await session.run(command: "\(fakePlayer) chime.aiff")
        let confirmed = try await session.runConfirmed(command: "cd \(dir.path) && \(fakeSay) hello")

        for result in [ran, confirmed] {
            XCTAssertTrue(result.blocked, result.command)
            XCTAssertTrue(result.blockedReason?.contains("silent mode") == true, result.blockedReason ?? "")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the player ran in silent mode")
        XCTAssertEqual(try loggedShellLines().map { $0["source"] ?? "" }, ["afplay", "say"])
    }
}

/// A refusal tells the reader which gate it was: the CLI answers each kind differently,
/// and a silent-mode refusal read as containment sent people to move a folder.
final class ShellBlockedKindTests: XCTestCase {
    func test_eachRefusalNamesItsOwnKind() {
        XCTAssertEqual(GruxControlTools.shellBlockedKind(reason: "strict mode: 'curl' not on allowlist"), "allowlist")
        XCTAssertEqual(GruxControlTools.shellBlockedKind(reason: "cd would leave rootDir"), "containment")
        let silent = ShellSilence.refusal(for: "afplay x.aiff", silent: true)
        XCTAssertEqual(GruxControlTools.shellBlockedKind(reason: silent ?? ""), "silent")
    }
}

/// A macro's AppleScript step runs in-process, not through a shell, so it is asked too.
/// The script here only returns a string, so a broken gate still makes no sound.
final class AppleScriptSilenceTests: XCTestCase {
    override func tearDown() {
        AudioOutput.soundAllowedUnderTest = false
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        super.tearDown()
    }

    func test_anAppleScriptThatWouldMakeSoundIsRefusedInSilentMode() throws {
        XCTAssertTrue(AudioOutput.isSilent)
        let answer = AppleScriptRunner.run(source: "return \"play the sound\"")
        XCTAssertTrue(answer.contains("silent mode"), answer)
        let lines = try String(contentsOf: AudioOutput.logURL, encoding: .utf8)
        XCTAssertTrue(lines.contains("\"kind\":\"shell\""), lines)
        XCTAssertTrue(lines.contains("\"source\":\"applescript\""), lines)
    }

    func test_aQuietAppleScriptStillRuns() {
        XCTAssertEqual(AppleScriptRunner.run(source: "return \"hello\""), "ok: hello")
    }
}
