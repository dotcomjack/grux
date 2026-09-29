import Foundation
import AppKit
import AVFoundation
import UserNotifications
import GruxShellCore
import GruxAgentCore

/// The one door every sound Grux makes goes through.
///
/// WHY. Grux had no global mute. Spoken replies, workflow phase speech, macro speech,
/// wake chimes, workflow chimes, notification sounds, Music playback and Music ducking
/// each reached the speaker on their own, so there was no way to run Grux on a Mac whose
/// speakers belong to someone else (a test rig playing music, a shared office, a call)
/// and be sure it stays quiet. `ArchitectureAudioOutputTests` fails the build if any file
/// outside this one plays audio on its own.
///
/// SILENT MODE. The presence of `~/.grux/SILENT` turns every sound into a no-op. It is a
/// file, checked on every call, so it survives relaunches that do not pass environment
/// variables (`open`, `build.sh`) and can be flipped without restarting. Each suppressed
/// sound appends one JSON line `{ts, kind, source, text}` to `~/.grux/silenced.jsonl`,
/// which is the record of what Grux would have said.
///
/// The backends behind this door (SpeechEngine, Speaker, MusicTool, MusicKitPlayer,
/// AudioDucker) ask `permit` or `isSilent` before touching any output.
enum AudioOutput {
    enum Kind: String {
        case speech, chime, notification, music, video, shell
    }

    /// Named system sounds Grux uses as cues.
    enum Chime: String {
        case tink = "Tink", glass = "Glass", funk = "Funk", pop = "Pop"
    }

    static var sentinelURL: URL { Persistence.gruxDir.appendingPathComponent("SILENT") }
    static var logURL: URL { Persistence.gruxDir.appendingPathComponent("silenced.jsonl") }

    /// Only for tests that check the unsilenced decision itself (`permit`, the notification
    /// sound). They never call an entry that plays.
    nonisolated(unsafe) static var soundAllowedUnderTest = false

    /// A test run is always silent, sentinel or not: the suite runs on Macs whose speakers
    /// belong to someone else, and one stray chime from a test is enough.
    static var isSilent: Bool {
        if Persistence.isUnderTest && !soundAllowedUnderTest { return true }
        return FileManager.default.fileExists(atPath: sentinelURL.path)
    }

    /// True when the sound may play. In silent mode records it and returns false.
    @discardableResult
    static func permit(_ kind: Kind, source: String, text: String = "") -> Bool {
        guard isSilent else { return true }
        record(kind, source: source, text: text)
        return false
    }

    /// Plays the first of `preferred` this install has. Some installs lack a
    /// named sound, so callers pass fallbacks.
    static func chime(_ preferred: [Chime], source: String) {
        guard permit(.chime, source: source, text: preferred.first?.rawValue ?? "") else { return }
        for c in preferred {
            if let s = NSSound(named: NSSound.Name(c.rawValue)) { s.play(); return }
        }
    }

    /// The sound for a posted notification: nil (a silent banner) when silent
    /// or when the caller did not want one.
    static func notificationSound(source: String, text: String, wanted: Bool = true) -> UNNotificationSound? {
        guard wanted else { return nil }
        return permit(.notification, source: source, text: text) ? .default : nil
    }

    /// Presentation options for a notification arriving while Grux is frontmost.
    /// One posted with no sound has nothing to silence, so it writes no line:
    /// `silenced.jsonl` is the record of sounds Grux held back (review RV8).
    static func foregroundPresentation(for content: UNNotificationContent, source: String) -> UNNotificationPresentationOptions {
        guard content.sound != nil else { return [.banner] }
        return permit(.notification, source: source, text: content.title) ? [.banner, .sound] : [.banner]
    }

    /// A player for a video clip. Muted in silent mode so the picture still plays.
    static func videoPlayer(url: URL, source: String) -> AVPlayer {
        let player = AVPlayer(url: url)
        if !permit(.video, source: source, text: url.lastPathComponent) { player.isMuted = true }
        return player
    }

    /// Points the shell doors (`ShellSilence` in GruxShellCore) and the agent sandboxes
    /// (`SwarmWorker.isSilent`) at this door's silent mode and log. Runs once, at launch
    /// and on the first shell command, whichever is first.
    static let wireShellDoors: Void = {
        ShellSilence.isSilent = { AudioOutput.isSilent }
        SwarmWorker.isSilent = { AudioOutput.isSilent }
        ShellSilence.onRefused = { program, command in AudioOutput.record(.shell, source: program, text: command) }
    }()

    /// The reason a shell command may not run (it would make sound in silent mode), or nil.
    static func shellRefusal(for command: String) -> String? {
        _ = wireShellDoors
        return ShellSilence.refusal(for: command)
    }

    /// The reason AppleScript source may not run (it would make sound in silent mode), or nil.
    static func appleScriptRefusal(for source: String) -> String? {
        _ = wireShellDoors
        return ShellSilence.refusal(forAppleScript: source)
    }

    private static let lock = NSLock()

    private static func record(_ kind: Kind, source: String, text: String) {
        let line: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": kind.rawValue,
            "source": source,
            "text": text,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        let url = logURL
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
