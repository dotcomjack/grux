import Foundation
import AppKit

// Central coordinator for "save audio as WAV" across Ambient + Meetings.
//
// Feature posture:
//   • 100% local. No network. No cloud. No telemetry beyond the WakeLog line.
//   • User-initiated only - there is no automatic export.
//   • One standard output dir (`audio-exports/`) so the user can find, share,
//     or delete exports without hunting through Grux's internals.
//   • Meeting exports that capture in real time ("full-session WAV") live
//     alongside the meeting JSON under `meeting-audio/<uuid>.wav` - keeping
//     the meeting audio tied to its record for downstream features like
//     "re-transcribe this meeting with a different model".
//
// We deliberately don't ship compression (Opus/AAC). WAV + 16 kHz mono is
// already tiny (~1.9 MB/min), universally playable, and doesn't require
// pulling in AVFoundation codecs (extra binary weight + sandbox gotchas).
enum AudioExportStore {

    // Place where user-initiated exports land. Shown with "Reveal in Finder".
    static var exportsDir: URL {
        let dir = Persistence.supportDir.appendingPathComponent("audio-exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Place where ongoing meeting captures stream their WAV. Persisted even
    // after meeting ends (until the user deletes the meeting record).
    static var meetingAudioDir: URL {
        let dir = Persistence.supportDir.appendingPathComponent("meeting-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func meetingAudioURL(for meetingId: UUID) -> URL {
        meetingAudioDir.appendingPathComponent("\(meetingId.uuidString).wav")
    }

    // Human-readable timestamp component in the local timezone. Used for
    // ambient exports where there's no obvious session id.
    private static var localTimestamp: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        df.timeZone = .current
        return df.string(from: Date())
    }

    // Build a distinct export URL in `exportsDir` with the given stem.
    static func exportURL(stem: String) -> URL {
        let safe = stem.replacingOccurrences(of: "/", with: "_")
                       .replacingOccurrences(of: ":", with: "-")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "grux-audio" : safe
        let url = exportsDir.appendingPathComponent("\(base).wav")
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        // Collision suffix
        for n in 2...999 {
            let alt = exportsDir.appendingPathComponent("\(base)-\(n).wav")
            if !FileManager.default.fileExists(atPath: alt.path) { return alt }
        }
        return url
    }

    // MARK: - Ambient tail export

    // Write up to the newest `seconds` of ambient audio to a WAV in
    // `exportsDir`. Returns the resulting URL, or nil if the ring is empty.
    @discardableResult
    static func exportAmbientTail(seconds: Double) -> URL? {
        let samples = AmbientAudioRing.shared.snapshotLast(seconds: seconds)
        guard !samples.isEmpty else { return nil }
        let approxSec = Double(samples.count) / Double(AmbientAudioRing.sampleRate)
        let mins = Int(approxSec / 60.0 + 0.5)
        let stem = "ambient-\(localTimestamp)-\(max(1, mins))min"
        let url = exportURL(stem: stem)
        do {
            try WAVWriter.write(samples: samples, to: url)
            WakeLog.shared.log("audio-export: ambient tail \(Int(approxSec))s → \(url.lastPathComponent)")
            return url
        } catch {
            WakeLog.shared.log("audio-export: ambient write failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Meeting export

    // Copy / symlink the in-progress or completed meeting WAV into the
    // public exports dir so the user can share it without exposing the
    // meeting-audio internal folder. If no audio exists for this meeting,
    // returns nil.
    static func exportMeetingAudio(meetingId: UUID, title: String?) -> URL? {
        let src = meetingAudioURL(for: meetingId)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let stem: String = {
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return "meeting-\(t)-\(localTimestamp)"
            }
            return "meeting-\(meetingId.uuidString.prefix(8))-\(localTimestamp)"
        }()
        let dst = exportURL(stem: stem)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            WakeLog.shared.log("audio-export: meeting \(meetingId.uuidString.prefix(8))… → \(dst.lastPathComponent)")
            return dst
        } catch {
            WakeLog.shared.log("audio-export: meeting copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - UX helpers

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // Ball-park size for UI preview before the file is written.
    static func approxKilobytes(seconds: Double) -> Int {
        // 16 kHz × 16-bit × mono = 32_000 bytes/sec → ~31.25 KB/sec.
        Int((seconds * 32_000.0) / 1024.0)
    }
}
