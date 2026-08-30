import XCTest
@testable import Grux

/// THE STATUS FILE EXISTS SO A CALLER CAN ASSERT INSTEAD OF SLEEPING AND HOPING.
///
/// It was written for exactly that reason: this app's owner has limited
/// mobility, so "click the orb and look" is not a test plan. A file that reports
/// the state from BEFORE the change it was asked about is worse than no file,
/// because a caller trusts it.
///
/// Two defects, both measured here rather than described.
@MainActor
final class MicStatusFileTests: XCTestCase {

    private var savedConfig: GruxConfig!
    private var savedMuted = false
    private var savedEnabled = false
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        savedConfig = AppState.shared.config
        savedMuted = AppState.shared.micMuted
        savedEnabled = AmbientState.shared.isEnabled
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-mic-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        AppState.shared.config = savedConfig
        AppState.shared.micMuted = savedMuted
        AmbientState.shared.isEnabled = savedEnabled
        try await super.tearDown()
    }

    private func read() throws -> [String: Any] {
        let url = dir.appendingPathComponent("mic-status.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                             "mic-status.json did not parse as an object")
    }

    /// THE PREFERENCE AND THE RUNTIME STATE ARE DIFFERENT QUESTIONS, and the
    /// file answered the second under the name of the first.
    ///
    /// `mute()` pulls `AmbientState.isEnabled` down while deliberately leaving
    /// `config.ambientEnabled` alone, because that persisted preference is what
    /// unmute restores from. So after a mute the old file reported
    /// `ambientEnabled: false` for a user whose ambient mode is switched ON.
    func testTheFileDistinguishesThePreferenceFromWhatIsRunning() async throws {
        AppState.shared.config.ambientEnabled = true
        AmbientState.shared.isEnabled = false      // the state after a mute
        AmbientState.shared.isCapturing = false

        await MicController.writeMicStatus(dir: dir)
        let json = try read()

        XCTAssertEqual(json["ambientEnabledPreference"] as? Bool, true,
                       "the persisted preference is on and the file says it is off")
        XCTAssertEqual(json["ambientListening"] as? Bool, false,
                       "the file claims ambient is listening while it is muted")
        XCTAssertEqual(json["ambientCapturing"] as? Bool, false)
    }

    /// And the mute it reports on must be the one that finished.
    func testItReportsTheStateMuteReachedNotTheOneItStartedFrom() async throws {
        AppState.shared.micMuted = false
        MicController.mute()
        await MicController.writeMicStatus(dir: dir)

        let json = try read()
        XCTAssertEqual(json["micMuted"] as? Bool, true,
                       "the file was written before the mute it is reporting on landed")
        XCTAssertEqual(json["meetingCapturing"] as? Bool, false,
                       "meetingCapturing is true immediately after a successful mute, which is the stale read")
        XCTAssertEqual(json["ambientListening"] as? Bool, false)
    }

    /// Every field a caller needs to distinguish "released" from "still held".
    /// The old file named three of the four microphone owners not at all, so a
    /// caller could read a clean status while dictation held the device.
    func testEveryMicrophoneOwnerIsReported() async throws {
        await MicController.writeMicStatus(dir: dir)
        let json = try read()
        for key in ["micMuted", "ambientCapturing", "meetingCapturing",
                    "voiceInputRecording", "wakeWordListening", "at"] {
            XCTAssertNotNil(json[key], "mic-status.json says nothing about \(key)")
        }
    }

    /// IT WAITS FOR THE WORK, WHICH IS THE WHOLE CONTRACT.
    ///
    /// Found by walking a live build rather than by reading code: unmute, read
    /// the file, `ambientCapturing` false; read it again three seconds later,
    /// true. The mute side had already been fixed and the unmute side had the
    /// identical defect, because starting a listener loads a Whisper model and
    /// the file was written the instant `unmute()` returned.
    ///
    /// A probe task stands in for that work, so the property is asserted
    /// directly instead of by racing a real model load.
    func testItWaitsForOutstandingWorkBeforeWriting() async throws {
        final class Box: @unchecked Sendable { var landed = false }
        let box = Box()
        MicController.pendingWork = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            box.landed = true
        }

        await MicController.writeMicStatus(dir: dir)

        XCTAssertTrue(box.landed,
                      "the file was written before the work it describes had finished, which is the stale read")
        _ = try read()
        XCTAssertNil(MicController.pendingWork, "the finished work was not cleared, so the next write waits on it again")
    }

    /// Both directions hand their work over, or only half the file is trustworthy.
    func testMuteAndUnmuteBothHandTheirWorkOver() throws {
        let src = MicMuteReleasesDeviceTests.stripComments(
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Grux/MicController.swift"), encoding: .utf8))
        for (function, what) in [("static func mute()", "stopping a live meeting"),
                                 ("static func unmute()", "restarting a listener")] {
            let r = try XCTUnwrap(src.range(of: function), "\(function) was renamed")
            let rest = String(src[r.upperBound...])
            let end = rest.range(of: "\n    static ")?.lowerBound ?? rest.endIndex
            let body = String(rest[rest.startIndex..<end])
            // EVERY detached task, not "at least one". The first version of
            // this asserted only that the string appeared somewhere in the
            // body, and mutation testing walked straight through it: unmute
            // starts TWO tasks, so dropping the ambient one left the wake-word
            // one matching and the test green.
            let started = body.components(separatedBy: "Task {").count - 1
            let handed = body.components(separatedBy: "pendingWork = Task {").count - 1
            XCTAssertEqual(handed, started,
                           "\(function) starts \(started) detached tasks for \(what) and hands "
                         + "\(handed) over, so the status file reports the state from before the dropped one.")
        }
    }

    /// A reader polling this file in a loop is the intended use, so a plain
    /// truncating write hands the poll that lands in the gap an unparseable
    /// file. Rewriting must never leave a partial one behind.
    func testRewritingLeavesAWholeFileEveryTime() async throws {
        for _ in 0..<12 {
            await MicController.writeMicStatus(dir: dir)
            _ = try read()   // throws if a partial or empty file is ever observed
        }
    }
}

/// A MEETING THAT NEVER STARTED MUST NOT BE IN THE LIST.
///
/// `MeetingCaptureService.start()` created and SAVED the record before mic
/// authorization, before ScreenCaptureKit, and before the mute re-check. Every
/// one of those can fail, and each failure left a permanent zero-length meeting
/// with no summary, no audio and no explanation. Pressing Start while muted was
/// the reported case: the only feedback the user got was a junk row appearing.
@MainActor
final class MeetingRecordPersistenceTests: XCTestCase {

    /// `make` builds; `commit` persists. The split is the whole fix.
    func testMakeDoesNotPersistAnything() throws {
        let rec = MeetingStore.shared.make(title: "never started", sourceApp: nil, sourceAppName: nil)
        XCTAssertNil(MeetingStore.shared.get(id: rec.id),
                     "a record that was only made is already on disk, so a failed start still leaves one")
        XCTAssertFalse(MeetingStore.shared.index.contains { $0.id == rec.id },
                       "a record that was only made is already in the index")
    }

    /// Control: committing DOES persist, or the test above passes because
    /// persistence is broken rather than because `make` is restrained.
    func testCommitPersists() throws {
        let rec = MeetingStore.shared.make(title: "grux test, safe to delete",
                                           sourceApp: nil, sourceAppName: nil)
        MeetingStore.shared.commit(rec)
        defer {
            try? FileManager.default.removeItem(
                at: Persistence.meetingsDir.appendingPathComponent("\(rec.id.uuidString).json"))
            MeetingStore.shared.reindex()
        }
        XCTAssertNotNil(MeetingStore.shared.get(id: rec.id),
                        "commit did not persist, so the control is broken and the test above proves nothing")
    }

    /// AND THE ORDER IS THE POINT. Committing before capture is live is exactly
    /// the defect; the record must be written only once there is something real
    /// to write about.
    func testStartCommitsOnlyAfterCaptureIsLive() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Meeting/MeetingCaptureService.swift"), encoding: .utf8)
        let text = MicMuteReleasesDeviceTests.stripComments(src)
        let sig = try XCTUnwrap(text.range(of: "func start(title: String?"), "start() was renamed")
        let body = String(text[sig.upperBound...])

        XCTAssertFalse(body.prefix(6000).contains("MeetingStore.shared.create("),
                       "start() still calls create(), which writes the record before capture can fail")
        let live = try XCTUnwrap(body.range(of: "self.isCapturing = true"), "the capture-live line moved")
        let commit = try XCTUnwrap(body.range(of: "MeetingStore.shared.commit("), "start() never commits the record")
        XCTAssertTrue(commit.lowerBound > live.lowerBound,
                      "the record is committed before capture is live, so every failure below it leaves an empty meeting")
    }

    /// The Meetings tab was the one call site that discarded the failure.
    /// `MeetingTool` and the menu bar both surface it; this one dropped it on
    /// the floor, so pressing Start while muted did nothing visible at all.
    func testTheMeetingsTabSurfacesAFailedStart() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Meeting/MeetingsView.swift"), encoding: .utf8)
        let text = MicMuteReleasesDeviceTests.stripComments(src)
        XCTAssertFalse(text.contains("_ = await service.start()"),
                       "the Meetings tab still discards the result of start(), so a failure is silent")
        XCTAssertTrue(text.contains("service.lastError"),
                      "the Meetings tab never reads lastError, so it cannot say why capture did not start")
        // THE EXACT BRANCH, and the exactness is the point. Mutation testing
        // showed the two assertions above survive `== nil, false`, which keeps
        // both strings present while making the toast unreachable. Asserting the
        // whole condition is what kills that, at the cost of being sensitive to
        // reformatting, which is a trade worth making for a branch whose only
        // job is to not be silent.
        XCTAssertTrue(text.contains("} else if await service.start() == nil {"),
                      "the failure branch has grown an extra condition, so the toast may be unreachable")
    }
}
