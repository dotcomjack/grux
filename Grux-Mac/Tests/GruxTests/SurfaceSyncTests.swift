import XCTest
@testable import Grux

// Wire-level tests for the SurfaceEnvelope continuity protocol (items 25+28).
// Covers encode/decode round-trips for every case, coexistence with
// ChatEnvelope on the shared 0x40 frame, and digest stability.
final class SurfaceSyncTests: XCTestCase {

    private func sampleSnapshot(generatedAt: Date = Date(timeIntervalSince1970: 1_750_000_000)) -> SurfacesSnapshotDTO {
        SurfacesSnapshotDTO(
            generatedAt: generatedAt,
            reminders: [
                SurfaceReminderDTO(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    kind: "commitment",
                    title: "Ship auth by 3pm",
                    body: "You said you'd ship auth by 3pm.",
                    createdAt: Date(timeIntervalSince1970: 1_749_990_000),
                    scheduledFor: Date(timeIntervalSince1970: 1_750_001_000),
                    firedAt: nil,
                    accepted: false,
                    dismissed: false,
                    snoozedUntil: nil
                )
            ],
            meetings: [
                SurfaceMeetingDTO(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    title: "Roadmap sync",
                    startedAt: Date(timeIntervalSince1970: 1_749_900_000),
                    endedAt: Date(timeIntervalSince1970: 1_749_903_600),
                    sourceAppName: "zoom.us",
                    summaryExcerpt: "Agreed to land items 25 and 28 this week.",
                    utteranceCount: 42
                )
            ],
            notes: [
                SurfaceNoteDTO(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    title: "Packaging review",
                    preview: "Check kraft labels and inserts",
                    tags: ["packaging", "ideas"],
                    pinned: true,
                    updatedAt: Date(timeIntervalSince1970: 1_749_950_000)
                )
            ],
            agenda: [
                SurfaceAgendaEventDTO(
                    id: "ek-event-1",
                    title: "Founder call",
                    start: Date(timeIntervalSince1970: 1_750_050_000),
                    end: Date(timeIntervalSince1970: 1_750_053_600),
                    isAllDay: false,
                    location: "Room 2",
                    calendarName: "Work"
                )
            ]
        )
    }

    // MARK: - Round trips

    func testSubscribeRoundTrip() throws {
        let data = try SurfaceEnvelope.surfacesSubscribe(version: 1).encode()
        let decoded = try SurfaceEnvelope.decode(data)
        guard case .surfacesSubscribe(let v) = decoded else {
            return XCTFail("wrong case: \(decoded)")
        }
        XCTAssertEqual(v, 1)
    }

    func testRequestRoundTrip() throws {
        let data = try SurfaceEnvelope.surfacesRequest.encode()
        let decoded = try SurfaceEnvelope.decode(data)
        guard case .surfacesRequest = decoded else {
            return XCTFail("wrong case: \(decoded)")
        }
    }

    func testSnapshotRoundTripPreservesEveryField() throws {
        let snap = sampleSnapshot()
        let data = try SurfaceEnvelope.surfacesSnapshot(version: 1, snapshot: snap).encode()
        let decoded = try SurfaceEnvelope.decode(data)
        guard case .surfacesSnapshot(let version, let out) = decoded else {
            return XCTFail("wrong case: \(decoded)")
        }
        XCTAssertEqual(version, 1)

        XCTAssertEqual(out.reminders.count, 1)
        let r = out.reminders[0]
        XCTAssertEqual(r.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(r.kind, "commitment")
        XCTAssertEqual(r.title, "Ship auth by 3pm")
        XCTAssertNotNil(r.scheduledFor)
        XCTAssertNil(r.firedAt)
        XCTAssertFalse(r.accepted)
        XCTAssertFalse(r.dismissed)

        XCTAssertEqual(out.meetings.count, 1)
        let m = out.meetings[0]
        XCTAssertEqual(m.title, "Roadmap sync")
        XCTAssertEqual(m.sourceAppName, "zoom.us")
        XCTAssertEqual(m.utteranceCount, 42)
        XCTAssertNotNil(m.endedAt)

        XCTAssertEqual(out.notes.count, 1)
        let n = out.notes[0]
        XCTAssertEqual(n.title, "Packaging review")
        XCTAssertEqual(n.tags, ["packaging", "ideas"])
        XCTAssertTrue(n.pinned)

        XCTAssertEqual(out.agenda.count, 1)
        let a = out.agenda[0]
        XCTAssertEqual(a.id, "ek-event-1")
        XCTAssertEqual(a.title, "Founder call")
        XCTAssertEqual(a.location, "Room 2")
        XCTAssertEqual(a.calendarName, "Work")
        XCTAssertFalse(a.isAllDay)
    }

    // Dates ride millisecondsSince1970, same as ChatEnvelope. Verify the
    // strategy survives a round trip to sub-second precision.
    func testDateStrategyMatchesChatEnvelope() throws {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000.123)
        let snap = sampleSnapshot(generatedAt: stamp)
        let data = try SurfaceEnvelope.surfacesSnapshot(version: 1, snapshot: snap).encode()
        guard case .surfacesSnapshot(_, let out) = try SurfaceEnvelope.decode(data) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(out.generatedAt.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.005)
    }

    // MARK: - Coexistence on the 0x40 frame (the compatibility gate)

    // A surface payload must NOT decode as a ChatEnvelope: that is exactly
    // how old builds (which only know ChatEnvelope and use try?) skip it.
    func testSurfacePayloadIsIgnoredByChatEnvelopeDecoder() throws {
        let data = try SurfaceEnvelope.surfacesSubscribe(version: 1).encode()
        XCTAssertNil(try? ChatEnvelope.decode(data),
                     "old builds must silently ignore surface envelopes")
        let snapData = try SurfaceEnvelope.surfacesSnapshot(version: 1, snapshot: sampleSnapshot()).encode()
        XCTAssertNil(try? ChatEnvelope.decode(snapData))
    }

    // And a chat payload must not decode as a SurfaceEnvelope, so the
    // fall-back chain on both sides never double-handles a message.
    func testChatPayloadIsIgnoredBySurfaceDecoder() throws {
        let chat = try ChatEnvelope.requestSync.encode()
        XCTAssertNil(try? SurfaceEnvelope.decode(chat))
        let thinking = try ChatEnvelope.thinking(isThinking: true).encode()
        XCTAssertNil(try? SurfaceEnvelope.decode(thinking))
    }

    // MARK: - Inbound dispatch

    @MainActor
    func testInboundDispatchRecognizesSurfaceAndRejectsChat() throws {
        defer { SurfaceSyncEngine.shared.deactivate() }
        var sent: [Data] = []
        // surfacesRequest with no active engine: recognized, no crash.
        let req = try SurfaceEnvelope.surfacesRequest.encode()
        XCTAssertTrue(SurfaceSyncInbound.handle(req) { sent.append($0) })
        // Chat payload: not ours.
        let chat = try ChatEnvelope.requestSync.encode()
        XCTAssertFalse(SurfaceSyncInbound.handle(chat) { sent.append($0) })
        // Garbage: not ours.
        XCTAssertFalse(SurfaceSyncInbound.handle(Data([0x00, 0x01])) { sent.append($0) })
    }

    @MainActor
    func testSubscribeActivatesEngineAndPushesSnapshot() throws {
        defer { SurfaceSyncEngine.shared.deactivate() }
        var sent: [Data] = []
        let sub = try SurfaceEnvelope.surfacesSubscribe(version: 1).encode()
        XCTAssertTrue(SurfaceSyncInbound.handle(sub) { sent.append($0) })
        XCTAssertTrue(SurfaceSyncEngine.shared.isActive)
        XCTAssertEqual(SurfaceSyncEngine.shared.peerVersion, 1)
        XCTAssertEqual(sent.count, 1, "activation pushes an initial snapshot")
        guard case .surfacesSnapshot(let v, _) = try SurfaceEnvelope.decode(sent[0]) else {
            return XCTFail("expected a snapshot push")
        }
        XCTAssertEqual(v, 1)
    }

    // MARK: - Digest

    func testDigestIgnoresGeneratedAtButTracksContent() {
        let a = sampleSnapshot(generatedAt: Date(timeIntervalSince1970: 1))
        let b = sampleSnapshot(generatedAt: Date(timeIntervalSince1970: 99_999))
        XCTAssertEqual(SurfaceSyncEngine.digest(of: a), SurfaceSyncEngine.digest(of: b),
                       "generatedAt alone must not trigger a re-push")

        let changed = SurfacesSnapshotDTO(
            generatedAt: a.generatedAt,
            reminders: [],
            meetings: a.meetings,
            notes: a.notes,
            agenda: a.agenda
        )
        XCTAssertNotEqual(SurfaceSyncEngine.digest(of: a), SurfaceSyncEngine.digest(of: changed))
    }
}
