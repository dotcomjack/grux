import Foundation
import GruxMCPCore

// MARK: - grux_meeting

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
///
/// ## Two of the three actions put a microphone into a room
///
/// `MeetingCaptureService.start()` is the choke point every path goes through, and it
/// already holds the gates that matter: the recording consent prompt, the microphone
/// authorisation, and the "one capture at a time" guard. Nothing here re-implements any of
/// them, because a second copy of a consent gate is a second chance to get one wrong. What
/// this file does is turn the service's three no-answers into three DIFFERENT replies, since
/// they need different things from whoever called:
///
///   declined  a person was asked and said no. An answer, not a failure, and not retryable.
///   blocked   macOS is holding it. Nothing succeeds until somebody clicks something here.
///   already   a capture is running, and reporting it beats starting a second one.
///
/// The old shape returned all three as one failure string, which is how an agent ends up
/// retrying a consent prompt that a person has already declined.
extension GruxControlTools {

    static func meeting(action: String, id: String?) async -> [String: Any] {
        let wanted = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantedId = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch wanted {
        case "start": return await meetingStart()
        case "stop": return await meetingStop()
        case "list": return meetingList(id: wantedId)
        default:
            // A REFUSAL, NOT A GUESS. Two of the three actions change what the microphone is
            // doing, so an action this does not recognise must never be narrowed to the
            // nearest one.
            return MCPWire.textFailure(wanted.isEmpty
                ? "grux_meeting needs an action and will not pick one: start, stop or list."
                : "No meeting action called \(action). There are three: start, stop and list.")
        }
    }

    // MARK: - start

    private static func meetingStart() async -> [String: Any] {
        let service = MeetingCaptureService.shared

        // ALREADY RUNNING IS AN ANSWER, NOT AN ERROR, and it is checked here as well as
        // inside `start()` so the reply can name the meeting that is running. The service
        // returns the active record for a repeat call, which is indistinguishable from a
        // fresh start unless the caller is told which one it got.
        if service.isCapturing || service.isInitializing {
            var out: [String: Any] = ["action": "start", "outcome": "already"]
            if let live = service.activeMeeting {
                out["id"] = live.id.uuidString
                out["title"] = live.displayTitle
                out["startedAt"] = meetingStamp(live.startedAt)
                out["elapsed"] = service.elapsedDisplay
                out["transcript"] = meetingTranscriptPath(live.id)
            } else {
                out["note"] = "A recording is still starting up, so it has nothing written "
                            + "down yet. Nothing new was started."
            }
            return MCPWire.textResult(jsonText(out))
        }

        guard let record = await service.start() else {
            let why = service.lastError ?? ""

            // THE SENTENCE IS THE CONTRACT, and it is the same one MeetingTool keys off:
            // `start()` sets exactly this string when the consent prompt is declined or
            // dismissed. A person answering no is an answer, so it comes back as a result
            // rather than a failure, and it says not to retry, because the next call would
            // put the same dialog in front of the same person.
            if why.hasPrefix("Recording needs your confirmation") {
                return MCPWire.textResult(jsonText([
                    "action": "start",
                    "outcome": "declined",
                    "why": "Nothing was recorded. Grux asked whether you will tell the other "
                         + "people on the call that it is being recorded, and that was not "
                         + "answered yes. Start it again when you are ready to say so.",
                ]))
            }

            // Held by macOS or by the mute switch: a person has to act on this Mac, and no
            // amount of calling again will change it.
            if why.hasPrefix("Microphone denied") || why.lowercased().contains("muted") {
                return MCPWire.textResult(jsonText([
                    "action": "start", "outcome": "blocked", "why": why,
                ]))
            }

            return MCPWire.textFailure(why.isEmpty
                ? "Grux could not start the recording and did not say why. Open Meetings in "
                  + "Grux and start one there, which shows the failure as it happens."
                : why)
        }

        var out: [String: Any] = [
            "action": "start",
            "outcome": "started",
            "id": record.id.uuidString,
            "title": record.displayTitle,
            "startedAt": meetingStamp(record.startedAt),
            "transcript": meetingTranscriptPath(record.id),
            // The caller needs to be able to say where the audio is NOT, as plainly as where
            // it is. Meeting audio is a setting somebody can turn off, and a reply that just
            // omits the path reads as "we forgot" rather than "there will not be one".
            "audioKept": AppState.shared.config.crashSafeAudioEnabled,
        ]
        if let app = record.sourceAppName, !app.isEmpty { out["sourceApp"] = app }
        if let audio = meetingAudioPath(record.id) { out["audio"] = audio }
        return MCPWire.textResult(jsonText(out))
    }

    // MARK: - stop

    private static func meetingStop() async -> [String: Any] {
        let service = MeetingCaptureService.shared

        // NOTHING TO DO HERE IS A GOOD OUTCOME. `stop()` returns silently when nothing is
        // capturing, so without this the caller cannot tell "ended it" from "there was
        // nothing to end", and those want opposite words in front of a person.
        guard service.isCapturing else {
            if service.isInitializing {
                return MCPWire.textResult(jsonText([
                    "action": "stop",
                    "outcome": "starting",
                    "why": "A recording is still starting up, so there is nothing to stop "
                         + "yet. Run this again in a moment.",
                ]))
            }
            return MCPWire.textResult(jsonText(["action": "stop",
                                                "outcome": "nothing-running"]))
        }

        await service.stop()

        // `stop()` leaves the finalized record on `activeMeeting`, and returns early without
        // one only if the capture flag was live while the record was not. Saying so beats
        // reporting a duration nothing measured.
        guard let record = service.activeMeeting else {
            return MCPWire.textFailure("The recording stopped, and Grux has no record of "
                + "what it was recording, so there is nothing to show for it. Anything it "
                + "did write is in Meetings.")
        }

        var out: [String: Any] = [
            "action": "stop",
            "outcome": "stopped",
            "id": record.id.uuidString,
            "title": record.displayTitle,
            "startedAt": meetingStamp(record.startedAt),
            "durationSeconds": Int(record.durationSeconds),
            "utterances": record.utterances.count,
            "transcript": meetingTranscriptPath(record.id),
        ]
        if let ended = record.endedAt { out["endedAt"] = meetingStamp(ended) }
        if let summary = record.summary, !summary.isEmpty { out["summary"] = summary }
        if !record.actionItems.isEmpty { out["actionItems"] = record.actionItems }
        let voices = record.distinctSpeakers.map { $0.label }
        if !voices.isEmpty { out["speakers"] = voices }
        if let audio = meetingAudioPath(record.id) { out["audio"] = audio }
        return MCPWire.textResult(jsonText(out))
    }

    // MARK: - list

    private static func meetingList(id: String?) -> [String: Any] {
        if let id, !id.isEmpty {
            guard let uuid = UUID(uuidString: id) else {
                return MCPWire.textFailure("\(id) is not a meeting id. An id is the uuid this "
                    + "tool returns for every meeting. Call it with no id to see them.")
            }
            guard let record = MeetingStore.shared.loadRecord(id: uuid) else {
                return MCPWire.textFailure("No meeting with that id. Call this with no id to "
                    + "see what is recorded.")
            }
            var out: [String: Any] = [
                "action": "list",
                "id": record.id.uuidString,
                "title": record.displayTitle,
                "startedAt": meetingStamp(record.startedAt),
                "durationSeconds": Int(record.durationSeconds),
                "utterances": record.utterances.count,
                "transcript": meetingTranscriptPath(record.id),
                "text": record.flatText(),
            ]
            if let ended = record.endedAt { out["endedAt"] = meetingStamp(ended) }
            if let app = record.sourceAppName, !app.isEmpty { out["sourceApp"] = app }
            if let summary = record.summary, !summary.isEmpty { out["summary"] = summary }
            if !record.actionItems.isEmpty { out["actionItems"] = record.actionItems }
            let voices = record.distinctSpeakers.map { $0.label }
            if !voices.isEmpty { out["speakers"] = voices }
            if let audio = meetingAudioPath(record.id) { out["audio"] = audio }
            return MCPWire.textResult(jsonText(out))
        }

        let service = MeetingCaptureService.shared
        let liveId: UUID? = service.isCapturing ? service.activeMeeting?.id : nil
        // THE WINDOW IS NOT THE STORE, AND `count` MEANS THE STORE. It is the same key
        // grux_agent puts beside its 25 row window, where it carries the full job total, and
        // it read the other way here: fifty rows next to `count: 50` with nothing anywhere in
        // the reply to recover the real number from, so an agent that had learned the key
        // from grux_agent presented one page as the whole history. Read off the index rather
        // than counted after clipping, and this call passes no filter, so the index IS what
        // was clipped.
        let total = MeetingStore.shared.index.count
        let entries = MeetingStore.shared.list(limit: 50)
        let rows: [[String: Any]] = entries.map { entry in
            var row: [String: Any] = [
                "id": entry.id.uuidString,
                "startedAt": meetingStamp(entry.startedAt),
                "utterances": entry.utteranceCount,
            ]
            if let ended = entry.endedAt {
                row["endedAt"] = meetingStamp(ended)
                row["durationSeconds"] = Int(ended.timeIntervalSince(entry.startedAt))
            }
            if let title = entry.title, !title.isEmpty { row["title"] = title }
            if let app = entry.sourceAppName, !app.isEmpty { row["sourceApp"] = app }
            if let excerpt = entry.summaryExcerpt, !excerpt.isEmpty { row["summary"] = excerpt }
            // A ROW WITH NO END TIME IS TWO DIFFERENT FACTS: one is recording right now, the
            // rest were left behind by a Grux that quit mid capture. Only the app knows
            // which, so it says, rather than leaving the reader to infer it from a gap.
            if entry.id == liveId { row["recording"] = true }
            return row
        }
        var out: [String: Any] = [
            "action": "list",
            "count": total,
            "showing": rows.count,
            "meetings": rows,
        ]
        // SAY SO WHEN THERE IS MORE, and say what to do about it, because the answer is not
        // "call again with an offset": this tool takes an action and an id and nothing else,
        // so there is no page two of it. The terminal reads the same files straight off disk
        // and has the flag, which is why it can be named as the way through.
        if rows.count < total {
            out["note"] = "The newest \(rows.count) of \(total). This tool has no way to "
                        + "reach the older ones. grux meeting list --limit \(total) in a "
                        + "terminal reads them all, from the files, with Grux closed or open."
        }
        if let liveId { out["recordingNow"] = liveId.uuidString }
        return MCPWire.textResult(jsonText(out))
    }

    // MARK: - Where things land

    private static func meetingTranscriptPath(_ id: UUID) -> String {
        Persistence.meetingsDir.appendingPathComponent("\(id.uuidString).json").path
    }

    /// The WAV, only when there actually is one.
    ///
    /// Checked on disk rather than derived from the setting, because the stream can fail to
    /// open after the setting says yes, and a path in a reply is read as a promise that the
    /// file is there.
    private static func meetingAudioPath(_ id: UUID) -> String? {
        let url = AudioExportStore.meetingAudioURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// Dates on the wire are ISO, because the caller is a program. Turning one into "27 Aug
    /// 2:14 PM" is the reader's side of the socket, and doing it here would send a string
    /// nothing can sort.
    private static func meetingStamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
