import XCTest
import AVFoundation
@testable import Grux

/// D198 (wave 68 round 2): nothing in Grux deleted a meeting or its kept audio.
/// `MeetingStore` had no delete, Meetings offered none, and the kept WAV (about
/// 110 MB an hour) stayed until a person found the hidden folder in Finder.
/// A delete has to take the crash buffer too: `AudioWALRecovery` rebuilds a
/// meeting from a preserved buffer at launch, so a buffer left behind would
/// bring a deleted meeting back.
@MainActor
final class D198MeetingDeleteTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func walDir(_ id: UUID) -> URL {
        Persistence.audioWALDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func recordURL(_ id: UUID) -> URL {
        Persistence.meetingsDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// A saved meeting with kept audio and a preserved crash buffer.
    private func seedMeeting(title: String) throws -> MeetingRecord {
        let store = MeetingStore.shared
        let rec = store.create(title: title, sourceApp: nil, sourceAppName: nil)
        let wav = AudioExportStore.meetingAudioURL(for: rec.id)
        try Data(repeating: 1, count: 64).write(to: wav)
        let wal = walDir(rec.id)
        try FileManager.default.createDirectory(at: wal, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 16).write(to: wal.appendingPathComponent("seg-000.pcm"))
        return rec
    }

    func test_deleteRemovesTheRecordItsAudioAndItsCrashBuffer() throws {
        let store = MeetingStore.shared
        let rec = try seedMeeting(title: "D198 delete me")
        let other = try seedMeeting(title: "D198 keep me")
        defer { _ = store.delete(id: other.id, activeMeetingId: nil) }
        XCTAssertTrue(store.index.contains { $0.id == rec.id })

        let result = store.delete(id: rec.id, activeMeetingId: nil)

        XCTAssertEqual(result, MeetingDeletion(id: rec.id, removedAudio: true))
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: recordURL(rec.id).path), "the record is still on disk")
        XCTAssertFalse(fm.fileExists(atPath: AudioExportStore.meetingAudioURL(for: rec.id).path), "the kept audio is still on disk")
        XCTAssertFalse(fm.fileExists(atPath: walDir(rec.id).path), "a crash buffer left behind brings the meeting back at launch")
        XCTAssertNil(store.get(id: rec.id))
        XCTAssertFalse(store.index.contains { $0.id == rec.id }, "the list still shows a deleted meeting")
        XCTAssertFalse(store.list(limit: 500).contains { $0.id == rec.id })
        // The neighbour is untouched.
        XCTAssertNotNil(store.get(id: other.id))
        XCTAssertTrue(fm.fileExists(atPath: AudioExportStore.meetingAudioURL(for: other.id).path))
        XCTAssertTrue(fm.fileExists(atPath: walDir(other.id).path))
    }

    func test_aMeetingWithNoKeptAudioSaysSo() {
        let store = MeetingStore.shared
        let rec = store.create(title: "D198 transcript only", sourceApp: nil, sourceAppName: nil)
        XCTAssertEqual(store.delete(id: rec.id, activeMeetingId: nil),
                       MeetingDeletion(id: rec.id, removedAudio: false))
        XCTAssertNil(store.get(id: rec.id))
    }

    /// The meeting being recorded is still writing its record, audio and buffer;
    /// deleting under it would be undone by its next save.
    func test_theMeetingBeingRecordedIsNotDeleted() throws {
        let store = MeetingStore.shared
        let rec = try seedMeeting(title: "D198 live")
        defer { _ = store.delete(id: rec.id, activeMeetingId: nil) }
        XCTAssertNil(store.delete(id: rec.id, activeMeetingId: rec.id))
        XCTAssertNotNil(store.get(id: rec.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioExportStore.meetingAudioURL(for: rec.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walDir(rec.id).path))
    }

    func test_anUnknownMeetingDeletesNothing() {
        XCTAssertNil(MeetingStore.shared.delete(id: UUID(), activeMeetingId: nil))
    }

    /// Meetings offers the delete on each row, asks first, and passes the
    /// meeting being recorded so it cannot be deleted under itself.
    func test_meetingsOffersDeleteAndAsksFirst() throws {
        let view = try source("Sources/Grux/Meeting/MeetingsView.swift")
        XCTAssertTrue(view.contains("Button(MeetingDeleteCopy.menuItem, role: .destructive)"), "no Delete on a meeting row")
        XCTAssertTrue(view.contains(".confirmationDialog("), "a delete that cannot be undone asks first")
        XCTAssertTrue(view.contains("MeetingStore.shared.delete(id:"), "the row does not call the store's delete")
        XCTAssertTrue(view.contains("activeMeetingId: service.liveMeetingId"), "the live meeting is not passed in")
    }

    func test_deleteCopyIsPlainAndTrue() {
        let ask = MeetingDeleteCopy.message
        XCTAssertTrue(ask.contains("transcript"), ask)
        XCTAssertTrue(ask.contains("audio"), ask)
        XCTAssertTrue(ask.contains("cannot be undone"), ask)
        XCTAssertTrue(ask.contains("Export"), "exported copies are not deleted, so it says so: \(ask)")
        XCTAssertEqual(MeetingDeleteCopy.done(MeetingDeletion(id: UUID(), removedAudio: true)),
                       "Deleted the meeting and its audio")
        XCTAssertEqual(MeetingDeleteCopy.done(MeetingDeletion(id: UUID(), removedAudio: false)),
                       "Deleted the meeting")
        XCTAssertEqual(MeetingDeleteCopy.done(nil), "Grux could not delete that meeting.")
        for line in [MeetingDeleteCopy.menuItem, MeetingDeleteCopy.title, ask] {
            XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"), line)
        }
    }

    /// The Ambient caption said Grux could not delete kept audio; now it can,
    /// so both states name the delete in Meetings beside the folder button.
    func test_theAmbientCaptionNamesTheDelete() {
        for on in [true, false] {
            for status in [AVAuthorizationStatus.notDetermined, .denied, .authorized] {
                let line = CrashSafeAudioCaption.line(on: on, micStatus: status)
                XCTAssertFalse(line.contains("cannot delete"), line)
                XCTAssertTrue(line.contains("delete its meeting in Meetings"), line)
                XCTAssertTrue(line.contains(CrashSafeAudioCaption.showButton + ", below,"), line)
            }
        }
    }
}

/// W68-P3 round 4 item 1: with no kept WAV, the meeting panel said "Capture was
/// run with local recording off." and `export_audio` blamed `meetingAudioKeepWAV`,
/// a setting that does not exist, though the audio may have been removed since.
/// One copy names the real switch and both causes; a deleted meeting is named as
/// missing, not as a meeting with no audio.
@MainActor
final class MeetingAudioMissingCopyTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_theCopyNamesTheRealSwitchAndBothCauses() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("Toggle(\"\(MeetingAudioMissing.switchName)\""), "the switch was renamed; the copy names one that is not there")
        for line in [MeetingAudioMissing.panel, MeetingAudioMissing.tool] {
            XCTAssertTrue(line.contains("\"\(MeetingAudioMissing.switchName)\""), line)
            XCTAssertTrue(line.contains("Settings, Voice & Ambient"), line)
            XCTAssertTrue(line.contains("removed"), line)
            for wrong in ["local recording off", "meetingAudioKeepWAV", "audio export was enabled"] {
                XCTAssertFalse(line.contains(wrong), line)
            }
        }
        XCTAssertTrue(MeetingAudioMissing.tool.hasPrefix("error: "))
    }

    func test_thePanelAndTheToolUseIt() throws {
        let panel = try source("Sources/Grux/Meeting/MeetingPanelView.swift")
        XCTAssertTrue(panel.contains("Text(MeetingAudioMissing.panel)"))
        XCTAssertFalse(panel.contains("local recording off"))
    }

    func test_exportForAMeetingWithNoAudioSaysWhy() async {
        let rec = MeetingStore.shared.create(title: "W68 no audio", sourceApp: nil, sourceAppName: nil)
        defer { MeetingStore.shared.delete(id: rec.id, activeMeetingId: nil) }
        let out = await AudioExportTool.dispatch(name: "export_audio",
                                                 input: ["mode": "meeting", "meeting_id": rec.id.uuidString, "reveal": false])
        XCTAssertEqual(out, MeetingAudioMissing.tool)
    }

    func test_exportForADeletedMeetingSaysItIsGone() async {
        let rec = MeetingStore.shared.create(title: "W68 deleted", sourceApp: nil, sourceAppName: nil)
        MeetingStore.shared.delete(id: rec.id, activeMeetingId: nil)
        let out = await AudioExportTool.dispatch(name: "export_audio",
                                                 input: ["mode": "meeting", "meeting_id": rec.id.uuidString, "reveal": false])
        XCTAssertEqual(out, MeetingAudioMissing.noMeeting)
        XCTAssertTrue(out.contains("list_meetings"), out)
    }
}
