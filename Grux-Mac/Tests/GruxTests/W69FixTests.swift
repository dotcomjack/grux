import XCTest
@testable import Grux

private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// Wave 69 review round 1 (`logs/wave69-review.txt`).
final class W69FixTests: XCTestCase {

    /// P1: `stop()` keeps the finished meeting in `activeMeeting`, so the
    /// meeting just recorded read as live and could not be deleted until
    /// relaunch. Only a meeting being recorded or being finished is live.
    func testOnlyARecordingOrFinishingMeetingIsLive() {
        let id = UUID()
        XCTAssertNil(MeetingCaptureService.liveMeetingId(active: id, capturing: false, finishing: false))
        XCTAssertEqual(MeetingCaptureService.liveMeetingId(active: id, capturing: true, finishing: false), id)
        XCTAssertEqual(MeetingCaptureService.liveMeetingId(active: id, capturing: false, finishing: true), id)
        XCTAssertEqual(MeetingCaptureService.liveMeetingId(active: id, capturing: true, finishing: true), id)
        XCTAssertNil(MeetingCaptureService.liveMeetingId(active: nil, capturing: true, finishing: true))
    }

    /// The row and the store read the live meeting, and the finish window
    /// (summary, then `finalize`) counts as live so a delete cannot be undone
    /// by the save that follows.
    func testMeetingsReadsTheLiveMeeting() throws {
        let view = try macSource("Sources/Grux/Meeting/MeetingsView.swift")
        XCTAssertTrue(view.contains(".disabled(entry.id == service.liveMeetingId)"))
        XCTAssertTrue(view.contains("activeMeetingId: service.liveMeetingId"))
        XCTAssertFalse(view.contains(".disabled(entry.id == service.activeMeeting?.id)"))
        let svc = try macSource("Sources/Grux/Meeting/MeetingCaptureService.swift")
        XCTAssertTrue(svc.contains("isFinishing = true\n        defer { isFinishing = false }"))
        XCTAssertTrue(svc.contains("var liveMeetingId: UUID?"))
    }

    /// P2: the stop summary is posted in chat and stays there after a delete.
    func testDeleteCopyNamesTheSummaryInChat() {
        XCTAssertEqual(MeetingDeleteCopy.message,
                       "Its transcript, notes and any audio Grux kept are removed from this Mac. The summary Grux posted in chat when it ended stays there, and so do copies you saved with Export WAV. This cannot be undone.")
    }

    /// Round 2 P1: a deleted meeting the service still held as finished came
    /// back in Meetings with its transcript (refresh re-adds `activeMeeting`),
    /// and Generate summary wrote it back to disk. A successful delete of the
    /// finished meeting lets go of it; a live one is never let go.
    func testADeletedFinishedMeetingIsLetGo() throws {
        let id = UUID(), other = UUID()
        XCTAssertTrue(MeetingCaptureService.forgets(activeId: id, deleted: id, capturing: false, finishing: false))
        XCTAssertFalse(MeetingCaptureService.forgets(activeId: id, deleted: id, capturing: true, finishing: false))
        XCTAssertFalse(MeetingCaptureService.forgets(activeId: id, deleted: id, capturing: false, finishing: true))
        XCTAssertFalse(MeetingCaptureService.forgets(activeId: other, deleted: id, capturing: false, finishing: false))
        XCTAssertFalse(MeetingCaptureService.forgets(activeId: nil, deleted: id, capturing: false, finishing: false))
        let view = try macSource("Sources/Grux/Meeting/MeetingsView.swift")
        XCTAssertTrue(view.contains("if result != nil { service.forgetFinished(id: entry.id) }\n        if result != nil, selection == entry.id { selection = nil }\n        refresh()"))
    }

    /// Round 2 P2: Start during the last meeting's summary began a second
    /// recording that the first stop() then overwrote as `activeMeeting`, so
    /// the meeting being recorded read as not live and could be deleted.
    func testStartWaitsForTheLastMeetingToFinish() throws {
        XCTAssertEqual(MeetingCaptureService.stillFinishing,
                       "Grux is still finishing the last meeting's notes. Start again in a moment.")
        let svc = try macSource("Sources/Grux/Meeting/MeetingCaptureService.swift")
        XCTAssertTrue(svc.contains("guard !isCapturing, !isInitializing else { return activeMeeting }\n        guard !isFinishing else {\n            lastError = Self.stillFinishing\n            return nil\n        }"))
    }
}
