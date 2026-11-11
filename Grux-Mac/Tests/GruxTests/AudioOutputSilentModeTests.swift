import XCTest
import AppKit
import UserNotifications
import GruxShellCore
import GruxAgentCore
@testable import Grux

/// `~/.grux/SILENT` makes every sound a no-op and leaves a line saying what it was.
///
/// The silenced log is how a headless run checks what Grux would have said without a
/// speaker, so each entry must both stay quiet and record. Under test the sentinel and
/// the log live in the suite's own `.grux`, never the operator's.
@MainActor
final class AudioOutputSilentModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: WindowFacade.sentinelURL)
    }

    override func tearDown() {
        AudioOutput.soundAllowedUnderTest = false
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
        try? FileManager.default.removeItem(at: WindowFacade.sentinelURL)
        super.tearDown()
    }

    private func silence() throws {
        XCTAssertTrue(AudioOutput.sentinelURL.path.hasPrefix(Persistence.gruxDir.path))
        XCTAssertFalse(AudioOutput.sentinelURL.path.hasPrefix(NSHomeDirectory() + "/.grux"),
                       "the suite must never write the operator's own sentinel")
        try Data().write(to: AudioOutput.sentinelURL)
        XCTAssertTrue(AudioOutput.isSilent)
    }

    private func logged() throws -> [[String: String]] {
        guard FileManager.default.fileExists(atPath: AudioOutput.logURL.path) else { return [] }
        return try String(contentsOf: AudioOutput.logURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]) }
    }

    private func sounding(_ title: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        return content
    }

    /// A banner posted with no sound was never going to make one, so silent
    /// mode has nothing to record for it (review RV8). The silence log is the
    /// oracle for what Grux held back, and a line per quiet banner polluted it.
    func test_silentMode_aNotificationWithNoSoundWritesNoLine() throws {
        try silence()
        let quiet = UNMutableNotificationContent()
        quiet.title = "quiet banner"
        XCTAssertEqual(AudioOutput.foregroundPresentation(for: quiet, source: "unit.present"), [.banner])
        XCTAssertEqual(try logged().count, 0, "a notification with no sound was logged as silenced")
        XCTAssertEqual(AudioOutput.foregroundPresentation(for: sounding("loud banner"), source: "unit.present"), [.banner])
        XCTAssertEqual(try logged().map { $0["text"] ?? "" }, ["loud banner"])
    }

    func test_underTest_everySoundIsSilencedWithoutTheSentinel() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioOutput.sentinelURL.path))
        XCTAssertTrue(AudioOutput.isSilent, "a test run must never reach the speaker, sentinel or not")
        XCTAssertFalse(AudioOutput.permit(.speech, source: "unit", text: "under test"))
        XCTAssertNil(AudioOutput.notificationSound(source: "unit", text: "t"))
        XCTAssertEqual(try logged().map { $0["text"] ?? "" }, ["under test", "t"])
    }

    func test_withoutTheSentinel_soundIsPermittedAndNothingIsLogged() throws {
        AudioOutput.soundAllowedUnderTest = true
        XCTAssertFalse(AudioOutput.isSilent)
        XCTAssertTrue(AudioOutput.permit(.speech, source: "test", text: "hi"))
        XCTAssertNotNil(AudioOutput.notificationSound(source: "test", text: "t"))
        XCTAssertNil(AudioOutput.notificationSound(source: "test", text: "t", wanted: false))
        XCTAssertTrue(AudioOutput.foregroundPresentation(for: sounding("t"), source: "test").contains(.sound))
        XCTAssertEqual(try logged().count, 0)
    }

    /// Operator note 15: a MacBook run with `~/.grux/HEADLESS` and no SILENT file spoke a
    /// reply through the system voice ("system-tts -> The capital of France is Paris").
    /// A run nobody watches is a run nobody may hear, so HEADLESS alone silences every
    /// sound and records it like SILENT does. Only the pure `permit` is asked before the
    /// assertion that the door is shut, so a regression fails without reaching a speaker.
    func test_headlessAlone_silencesSpeechAndRecordsIt() async throws {
        AudioOutput.soundAllowedUnderTest = true
        XCTAssertTrue(WindowFacade.sentinelURL.path.hasPrefix(Persistence.gruxDir.path))
        XCTAssertFalse(WindowFacade.sentinelURL.path.hasPrefix(NSHomeDirectory() + "/.grux"),
                       "the suite must never write the operator's own HEADLESS")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioOutput.sentinelURL.path))
        try Data().write(to: WindowFacade.sentinelURL)

        XCTAssertTrue(AudioOutput.isSilent, "HEADLESS alone must silence Grux")
        XCTAssertFalse(AudioOutput.permit(.speech, source: "unit.headless", text: "The capital of France is Paris."))
        XCTAssertNil(AudioOutput.notificationSound(source: "unit.headless", text: "banner"))
        XCTAssertTrue(ShellSilence.refusal(for: "say hello", silent: AudioOutput.isSilent) != nil)

        // A chat reply read aloud goes through SpeechEngine; only once the door is shut.
        guard AudioOutput.isSilent else { return XCTFail("not silent, the speech path was not called") }
        let stopped = expectation(forNotification: .gruxSpeechDidStop, object: nil)
        SpeechEngine.shared.speak("A reply read aloud.")
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(SpeechEngine.shared.isSpeaking)
        XCTAssertFalse(SpeechEngine.shared.isBuffering, "a headless reply must not start the engine")

        // The shell refusal writes its own line once the shell doors are wired at launch,
        // which another test in the run may already have done; it is not this door's line.
        let lines = try logged().filter { $0["kind"] != "shell" }
        XCTAssertEqual(lines.map { $0["text"] ?? "" },
                       ["The capital of France is Paris.", "banner", "A reply read aloud."])
        XCTAssertEqual(lines.map { $0["kind"] ?? "" }, ["speech", "notification", "speech"])

        try FileManager.default.removeItem(at: WindowFacade.sentinelURL)
        XCTAssertFalse(AudioOutput.isSilent, "removing HEADLESS must lift it without a relaunch")
    }

    /// D109's P3: with HEADLESS alone silencing Grux, every refusal named `~/.grux/SILENT`,
    /// a file that is not there, so a person removing it changed nothing. Each refusal now
    /// names the file that silenced it. Every entry below refuses before any output.
    func test_headlessAlone_everyRefusalNamesHeadlessNotSilent() async throws {
        try Data().write(to: WindowFacade.sentinelURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioOutput.sentinelURL.path))
        XCTAssertTrue(AudioOutput.isSilent)

        let refusals = [
            await MusicTool.play(song: "Some Song"),
            await MusicTool.listLibraryTracks(artist: "Some Artist"),
            await MusicKitPlayer.probe(testStoreID: "1"),
            await BrowserTool.playOnYouTube("some video"),
            AudioOutput.shellRefusal(for: "say hello") ?? "",
            AudioOutput.appleScriptRefusal(for: "tell application \"Music\" to play") ?? "",
        ]
        for refusal in refusals {
            XCTAssertTrue(refusal.contains("(~/.grux/HEADLESS)"), refusal)
            XCTAssertFalse(refusal.contains("SILENT"), refusal)
        }

        try Data().write(to: AudioOutput.sentinelURL)
        let both = await MusicTool.play(song: "Some Song")
        XCTAssertTrue(both.contains("(~/.grux/SILENT and ~/.grux/HEADLESS)"), both)
        try FileManager.default.removeItem(at: WindowFacade.sentinelURL)
        let silentOnly = AudioOutput.shellRefusal(for: "say hello") ?? ""
        XCTAssertTrue(silentOnly.contains("(~/.grux/SILENT)"), silentOnly)
        XCTAssertFalse(silentOnly.contains("HEADLESS"), silentOnly)
    }

    /// The class guard: a refusal string never hard-codes which file silenced Grux, so a
    /// third sentinel or a HEADLESS-only run cannot be misnamed again. Any spelling of the
    /// SILENT path in source text counts (wave 30: "(~/.grux/SILENT or ~/.grux/HEADLESS)",
    /// "rm ~/.grux/SILENT", a line inside a multi-line literal with no quote on it), not
    /// only the two phrasings the first version matched; a comment line is not text a
    /// person reads.
    func test_noSourceHardCodesTheSilencingFile() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), Self.namesTheSilentFile(code) else { continue }
                offenders.append("\(url.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "name the file through ShellSilence.note or ShellSilence.remedy")
    }

    static func namesTheSilentFile(_ code: String) -> Bool {
        code.contains(".grux/SILENT")
    }

    /// The shapes the first guard let through, each one ordinary code.
    func test_theGuardCatchesEverySpellingOfTheSilentPath() {
        for line in [
            #"return "error: silent mode is on (~/.grux/SILENT or ~/.grux/HEADLESS), so Grux will not play '\(q)'""#,
            #"print("rm ~/.grux/SILENT to hear Grux again")"#,
            #"~/.grux/SILENT is on, so nothing plays."#,
            #"let s = "$HOME/.grux/SILENT""#,
            #"return "(~/.grux/SILENT)""#,
            #"Remove ~/.grux/SILENT to let Grux make sound again."#,
        ] {
            XCTAssertTrue(Self.namesTheSilentFile(line), line)
        }
        for line in [
            #"static let sentinelURL = gruxDir.appendingPathComponent("SILENT")"#,
            #"let names = ["SILENT", "HEADLESS"]"#,
            #"return "(~/.grux/HEADLESS), so Grux will not script another app""#,
        ] {
            XCTAssertFalse(Self.namesTheSilentFile(line), line)
        }
    }

    /// The shell doors and agent sandboxes read the sentinels themselves until Grux wires
    /// them at launch; HEADLESS counts there too.
    func test_shellAndSandboxDefaults_countHeadless() {
        let both = ShellSilence.sentinelNames
        XCTAssertEqual(both, ["SILENT", "HEADLESS"])
        XCTAssertEqual(SwarmWorker.silencingSentinelNames, both)
    }

    func test_theSentinelIsReadLive() throws {
        AudioOutput.soundAllowedUnderTest = true
        XCTAssertFalse(AudioOutput.isSilent)
        try silence()
        try FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        XCTAssertFalse(AudioOutput.isSilent, "removing the file must lift silent mode without a relaunch")
    }

    func test_silentMode_eachFacadeEntryIsANoOpAndWritesOneLine() async throws {
        try silence()

        XCTAssertFalse(AudioOutput.permit(.speech, source: "unit", text: "permit line"))
        AudioOutput.chime([.tink, .glass], source: "unit.chime")
        XCTAssertNil(AudioOutput.notificationSound(source: "unit.notify", text: "banner title"))
        XCTAssertEqual(AudioOutput.foregroundPresentation(for: sounding("front"), source: "unit.present"), [.banner])
        let video = AudioOutput.videoPlayer(url: URL(fileURLWithPath: "/nonexistent/clip.mp4"), source: "unit.video")
        XCTAssertTrue(video.isMuted)

        let stopped = expectation(forNotification: .gruxSpeechDidStop, object: nil)
        SpeechEngine.shared.speak("Grux would have said this.")
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(SpeechEngine.shared.isSpeaking)
        XCTAssertFalse(SpeechEngine.shared.isBuffering)
        SpeechEngine.shared.appendStreaming("A streamed sentence.")
        XCTAssertFalse(SpeechEngine.shared.isBuffering, "a silenced stream must not start the engine")

        let music = await MusicTool.play(song: "Some Song", artist: "Some Artist")
        XCTAssertTrue(music.hasPrefix("error: silent mode"), music)
        let listed = await MusicTool.listLibraryTracks(artist: "Some Artist")
        XCTAssertTrue(listed.hasPrefix("error: silent mode"), listed)
        let probe = await MusicKitPlayer.probe(testStoreID: "1")
        XCTAssertTrue(probe.hasPrefix("STOP: silent mode"), probe)

        let lines = try logged()
        XCTAssertEqual(lines.map { $0["kind"] ?? "" },
                       ["speech", "chime", "notification", "notification", "video", "speech", "speech", "music", "music"])
        XCTAssertEqual(lines.map { $0["text"] ?? "" },
                       ["permit line", "Tink", "banner title", "front", "clip.mp4",
                        "Grux would have said this.", "A streamed sentence.", "Some Song by Some Artist", "1"])
        for line in lines {
            XCTAssertEqual(Set(line.keys), ["ts", "kind", "source", "text"])
            XCTAssertNotNil(ISO8601DateFormatter().date(from: line["ts"] ?? ""))
        }
        // Spoken lines name the call site, so the log says who would have spoken.
        let spoken = try XCTUnwrap(lines.first { $0["text"] == "Grux would have said this." })
        XCTAssertTrue(spoken["source"]?.hasPrefix("GruxTests/AudioOutputSilentModeTests.swift:") == true,
                      spoken["source"] ?? "")
    }
}
