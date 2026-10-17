import Foundation
import AppKit
import AVFoundation
import AudioToolbox
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
    /// named sound, so callers pass fallbacks. Before the microphone question,
    /// the system sound server plays it, never Grux (`outputWouldAskForMic`).
    @MainActor
    static func chime(_ preferred: [Chime], source: String) {
        guard permit(.chime, source: source, text: preferred.first?.rawValue ?? "") else { return }
        let outside = outputWouldAskForMic
        for c in preferred {
            if outside {
                let url = URL(fileURLWithPath: "/System/Library/Sounds/\(c.rawValue).aiff")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                playSystemSound(url)
                return
            }
            if let s = NSSound(named: NSSound.Name(c.rawValue)) { s.play(); return }
        }
    }

    // MARK: - Sound before the microphone question

    /// True while the person has not been asked about the microphone. Then any sound
    /// Grux plays in its own process raises the microphone prompt on a Mac whose output
    /// device also has inputs (a USB or Bluetooth headset, a virtual machine): coreaudiod
    /// asks TCC for the microphone on behalf of an app holding the audio-input
    /// entitlement as soon as it starts audio on such a device. Measured 2026-10-14 on
    /// the clean VM (one virtual device, 2 in and 2 out), a signed probe with Grux's
    /// entitlements prompted for an output-only AVAudioEngine, AVSpeechSynthesizer.speak,
    /// NSSpeechSynthesizer, AVAudioPlayer, NSSound, an AudioQueue, and a child `say` or
    /// `afplay`. Two paths did not: a system sound, and a player started as its own
    /// responsible process. The first spoken reply on that VM prompted (W4 build 11).
    /// Once the person has answered either way, nothing prompts and sound plays in Grux.
    @MainActor
    static var outputWouldAskForMic: Bool { MicController.authorizationStatus() == .notDetermined }

    /// Seam for tests: plays a system sound file through the system sound server.
    nonisolated(unsafe) static var playSystemSound: (URL) -> Void = { url in
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return }
        AudioServicesPlaySystemSoundWithCompletion(sound) { AudioServicesDisposeSystemSoundID(sound) }
    }

    /// Plays a sound file in `afplay`, a process macOS holds responsible for itself, so a
    /// microphone check coreaudiod makes for it is not Grux's and prompts nobody.
    /// `ended` runs on the main queue when playback finishes or is stopped. Returns the
    /// stop, or nil when nothing could start (then `ended` never runs). The caller has
    /// already asked `permit`. A seam for tests.
    nonisolated(unsafe) static var playDetached: (_ file: URL, _ volume: Float, _ ended: @escaping @Sendable () -> Void) -> (() -> Void)? = { file, volume, ended in
        guard let pid = spawnOwnResponsibility(["/usr/bin/afplay", "-v", String(volume), file.path], ended: ended) else { return nil }
        return { _ = kill(pid, SIGTERM) }
    }

    /// Starts `argv` as its own responsible process (stdio on /dev/null, no inherited
    /// descriptors) and reaps it, calling `ended` on the main queue. Without the disclaim,
    /// macOS charges a child's privacy requests to the app that started it: a child `say`
    /// prompted for Grux on the VM. The disclaim is SPI with no header; Chromium, iTerm2
    /// and LLDB use it for the same reason. If it is missing, nothing starts.
    static func spawnOwnResponsibility(_ argv: [String], ended: @escaping @Sendable () -> Void) -> pid_t? {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            WakeLog.shared.log("audio: no responsibility disclaim on this macOS, not starting \(argv.first ?? "")")
            return nil
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        guard unsafeBitCast(sym, to: Disclaim.self)(&attr, 1) == 0 else { return nil }
        // After the disclaim on purpose; test_theDetachedProcessAnswersForItself proves it survives.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], &actions, &attr, &cargs, environ) == 0 else { return nil }
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            watch.cancel()
            ended()
        }
        watch.resume()
        return pid
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
    /// Before the microphone question it plays the picture alone: a muted player still
    /// starts audio output in Grux, which would raise the prompt (measured 2026-10-14 on
    /// a test Mac, a muted AVPlayer and one with its audio track disabled both started
    /// the output device; a video-only composition did not).
    @MainActor
    static func videoPlayer(url: URL, source: String) -> AVPlayer {
        let allowed = permit(.video, source: source, text: url.lastPathComponent)
        guard outputWouldAskForMic else {
            let player = AVPlayer(url: url)
            if !allowed { player.isMuted = true }
            return player
        }
        let player = AVPlayer()
        if !allowed { player.isMuted = true }
        Task { @MainActor in player.replaceCurrentItem(with: await pictureOnly(url)) }
        return player
    }

    /// The clip's video tracks with no audio track at all, or nil if it has none.
    static func pictureOnly(_ url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let picture = AVMutableComposition()
        for track in tracks {
            guard let copy = picture.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            copy.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        }
        return AVPlayerItem(asset: picture)
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
