import XCTest
import AppKit
import UserNotifications
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
    }

    override func tearDown() {
        AudioOutput.soundAllowedUnderTest = false
        try? FileManager.default.removeItem(at: AudioOutput.sentinelURL)
        try? FileManager.default.removeItem(at: AudioOutput.logURL)
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
        XCTAssertTrue(MusicTool.listLibraryTracks(artist: "Some Artist").hasPrefix("error: silent mode"))
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
