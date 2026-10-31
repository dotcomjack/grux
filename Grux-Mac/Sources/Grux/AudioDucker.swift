import AppKit
import Foundation

// Gentle audio ducker. While Grux speaks, Apple Music's volume drops to 50%
// (only if it was higher than that, keeps a quiet mix from getting an
// unexpected drop-then-restore-up). Restored on speech end. Apple-Music-only
// on purpose: system-wide volume control would also affect Zoom calls,
// browser audio, etc.
//
// Hooks into the existing .gruxSpeechDidStart / .gruxSpeechDidStop
// notifications posted by SpeechEngine. Install once at app boot.
//
// CRASH SAFETY (incident 2026-05-27):
// savedVolume is mirrored to UserDefaults along with a timestamp so a
// Grux quit / build relaunch / SIGKILL during the duck window leaves a
// breadcrumb. On the next install, if Music is sitting at the ducked
// level AND the breadcrumb is recent, we restore from the breadcrumb.
// Also wired to NSApplication.willTerminateNotification for clean cmd-Q.
// A 120s backup Timer catches missed gruxSpeechDidStop notifications
// (TTS error, network drop, segment cancellation) so Music does not stay
// ducked for the whole session waiting on a stop event that never fires.
// CLI escape hatch: touch ~/.grux/fire-audio-restore to force a restore
// from outside the notification flow.
@MainActor
final class AudioDucker {
    static let shared = AudioDucker()

    private static let savedVolumeKey = "AudioDucker.savedVolume"
    private static let savedAtKey = "AudioDucker.savedAt"
    // Stale-breadcrumb cutoff. Any persisted savedVolume older than this is
    // ignored on self-heal (the user has likely moved on from the previous
    // session's intent). 5 min covers a long agent speech or multi-segment
    // dictation.
    private static let staleAfter: TimeInterval = 300
    // Backup-timer window. If gruxSpeechDidStop never arrives, Music would
    // stay ducked for the rest of the session. Force-restore after 120s.
    private static let backupRestoreAfter: TimeInterval = 120

    // Max times the backstop timer will defer itself for an ongoing speech
    // before force-restoring anyway. Caps the worst case at
    // backupRestoreAfter * (1 + maxBackupDefers) = ~8 min for a genuinely
    // hung TTS thread.
    private static let maxBackupDefers = 3

    /// A restore that fails (Music busy, or the script gate busy behind an Automation
    /// prompt) tries again this often, up to `maxRestoreRetries` times, instead of
    /// leaving Music lowered for the rest of the session.
    static let restoreRetryAfter: TimeInterval = 10
    static let maxRestoreRetries = 6

    private let duckedVolume = 50

    private var startToken: NSObjectProtocol?
    private var stopToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?
    private var forceRestoreTimer: Timer?
    private var backupDeferCount = 0
    private var restoreRetries = 0

    /// Replaces the Music volume script under test, so no test ever reaches Music.
    var setVolumeUnderTest: ((Int) -> Bool)?
    /// True while a backstop or retry restore is scheduled.
    var restoreIsPending: Bool { forceRestoreTimer != nil }

    private var savedVolume: Int? {
        get { UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Int }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: Self.savedVolumeKey)
                UserDefaults.standard.set(Date(), forKey: Self.savedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
                UserDefaults.standard.removeObject(forKey: Self.savedAtKey)
            }
        }
    }

    private var savedAt: Date? {
        UserDefaults.standard.object(forKey: Self.savedAtKey) as? Date
    }

    func install() {
        guard startToken == nil else { return }   // idempotent
        startToken = NotificationCenter.default.addObserver(
            forName: .gruxSpeechDidStart, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.duck() }
        }
        stopToken = NotificationCenter.default.addObserver(
            forName: .gruxSpeechDidStop, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restore() }
        }
        terminateToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Synchronous restore. AppKit gives willTerminate ~1s before
            // tearing the app down; an AppleScript round-trip to Music fits.
            self?.restoreSync(reason: "willTerminate")
        }
        selfHealIfStuck()
        WakeLog.shared.log("audio-ducker: installed")
    }

    // Manual escape hatch invoked by the ~/.grux/fire-audio-restore watcher
    // in Triggers/AppTriggers.swift. Use when something has stranded Music at
    // the ducked level outside the ducker's normal notification flow.
    func forceRestoreNow() {
        forceRestoreTimer?.invalidate()
        forceRestoreTimer = nil
        backupDeferCount = 0
        if let saved = savedVolume {
            if setMusicVolume(saved) {
                self.savedVolume = nil
                WakeLog.shared.log("audio-ducker: force-restored Music → \(saved)")
            } else {
                WakeLog.shared.log("audio-ducker: force-restore FAILED, keeping breadcrumb")
            }
        } else if let current = readMusicVolume(), current <= duckedVolume {
            // No breadcrumb but Music looks ducked. Restore to a sane default
            // (80) rather than leaving the user stranded.
            _ = setMusicVolume(80)
            WakeLog.shared.log("audio-ducker: force-restored Music \(current) → 80 (no breadcrumb)")
        } else {
            WakeLog.shared.log("audio-ducker: force-restore no-op (Music not running or already above ducked)")
        }
    }

    private func duck() {
        guard let current = readMusicVolume(), current > duckedVolume else { return }
        savedVolume = current
        restoreRetries = 0
        _ = setMusicVolume(duckedVolume)
        WakeLog.shared.log("audio-ducker: ducked Music \(current) → \(duckedVolume)")
        backupDeferCount = 0
        scheduleBackupRestore()
    }

    private func scheduleBackupRestore(after interval: TimeInterval = AudioDucker.backupRestoreAfter) {
        forceRestoreTimer?.invalidate()
        forceRestoreTimer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.maybeBackupRestore() }
        }
    }

    // Backstop entry point. The 120s window is a guard against a missed
    // gruxSpeechDidStop, NOT a hard cap on legitimate long-form speech
    // (walkthroughs, multi-paragraph agent responses). If TTS is still
    // active when the timer fires, reschedule rather than yank Music to
    // 80 mid-sentence. Capped at maxBackupDefers reschedules so a
    // genuinely hung TTS thread can't keep Music ducked forever.
    private func maybeBackupRestore() {
        if SpeechEngine.shared.isSpeaking, backupDeferCount < Self.maxBackupDefers {
            backupDeferCount += 1
            WakeLog.shared.log("audio-ducker: backstop deferred (\(backupDeferCount)/\(Self.maxBackupDefers), speech still active)")
            scheduleBackupRestore()
            return
        }
        guard savedVolume != nil else { return }
        restore()
        WakeLog.shared.log("audio-ducker: backup-restored (gruxSpeechDidStop missed or speech hung)")
    }

    func restore() {
        forceRestoreTimer?.invalidate()
        forceRestoreTimer = nil
        backupDeferCount = 0
        guard let saved = savedVolume else { return }
        if setMusicVolume(saved) {
            savedVolume = nil
            restoreRetries = 0
            WakeLog.shared.log("audio-ducker: restored Music → \(saved)")
        } else if restoreRetries < Self.maxRestoreRetries {
            // Keep the breadcrumb (we never wrote the new value) and try again soon.
            restoreRetries += 1
            WakeLog.shared.log("audio-ducker: restore FAILED (AppleScript), trying again in \(Int(Self.restoreRetryAfter)) s (\(restoreRetries)/\(Self.maxRestoreRetries))")
            scheduleBackupRestore(after: Self.restoreRetryAfter)
        } else {
            // Keep the breadcrumb so the next launch's self-heal can recover.
            restoreRetries = 0
            WakeLog.shared.log("audio-ducker: restore FAILED (AppleScript), keeping breadcrumb for next launch")
        }
    }

    /// Records a duck from `saved` without touching Music. For tests.
    func stageDuckUnderTest(saved: Int?) { savedVolume = saved }

    // Synchronous restore used by the terminate observer. Avoids the Task
    // hop so the AppleScript completes before AppKit tears the app down.
    // Same conditional-clear contract as restore(): if the AppleScript
    // fails (Music app busy/quitting), the breadcrumb survives so
    // selfHealIfStuck() on the next launch can recover.
    private func restoreSync(reason: String) {
        forceRestoreTimer?.invalidate()
        forceRestoreTimer = nil
        backupDeferCount = 0
        guard let saved = savedVolume else { return }
        if setMusicVolume(saved) {
            savedVolume = nil
            WakeLog.shared.log("audio-ducker: restored Music → \(saved) (\(reason))")
        } else {
            WakeLog.shared.log("audio-ducker: restore FAILED at \(reason), keeping breadcrumb for next launch")
        }
    }

    // Self-heal: a prior Grux session may have quit mid-duck (build relaunch,
    // crash, hard SIGKILL). That leaves Music stranded at duckedVolume with
    // no record of the pre-duck level. We detect that by looking for a recent
    // savedVolume breadcrumb in UserDefaults AND a current Music volume that
    // matches the ducked level. Skip when the breadcrumb is stale (the user
    // has probably moved on and re-set the volume themselves).
    //
    // KNOWN FALSE POSITIVE (low frequency, accepted trade-off):
    // If the user manually sets Music to exactly 50 within `staleAfter`
    // seconds of a prior duck cycle, this restore "fixes" something that
    // wasn't broken and bumps Music back to the prior saved value. Mitigation
    // is heuristic-only (we can't distinguish "user chose 50" from "we set
    // 50 and forgot to restore"). The alternative (no self-heal) is worse:
    // the original bug stranded Music at 50 indefinitely.
    private func selfHealIfStuck() {
        guard let saved = savedVolume,
              let savedAt = savedAt else { return }
        let age = Date().timeIntervalSince(savedAt)
        if age > Self.staleAfter {
            self.savedVolume = nil
            WakeLog.shared.log("audio-ducker: cleared stale breadcrumb (age=\(Int(age))s)")
            return
        }
        guard let current = readMusicVolume(), current == duckedVolume else { return }
        setMusicVolume(saved)
        self.savedVolume = nil
        WakeLog.shared.log("audio-ducker: self-healed stuck Music \(current) → \(saved) (age=\(Int(age))s)")
    }

    /// The longest the main actor waits on Music: it must finish before Grux speaks or
    /// quits, so it waits here, but never macOS's own 2 min (D13).
    static let scriptTimeout: TimeInterval = 3

    // Returns nil when Music isn't running OR AppleScript fails. nil → no-op.
    private func readMusicVolume() -> Int? {
        // Silent mode (AudioOutput) leaves Music alone entirely: no read, no duck.
        guard !AudioOutput.isSilent else { return nil }
        let s = """
        tell application "Music"
            if it is running then return sound volume
            return -1
        end tell
        """
        guard let raw = ForeignAppScript.runWaiting(s, purpose: "AudioDucker.readMusicVolume",
                                                    timeout: Self.scriptTimeout).stringValue,
              let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              n >= 0 else { return nil }
        return n
    }

    @discardableResult
    private func setMusicVolume(_ v: Int) -> Bool {
        if let fake = setVolumeUnderTest { return fake(v) }
        guard !AudioOutput.isSilent else { return false }
        let clamped = max(0, min(100, v))
        let s = """
        tell application "Music"
            if it is running then set sound volume to \(clamped)
        end tell
        """
        let outcome = ForeignAppScript.runWaiting(s, purpose: "AudioDucker.setMusicVolume", timeout: Self.scriptTimeout)
        switch outcome {
        case .ok: return true
        case .refused: return false
        case .failed, .timedOut, .busy, .stopped, .behindLongerScript:
            WakeLog.shared.log("audio-ducker: setMusicVolume(\(clamped)) AppleScript failed: \(outcome.problem ?? "")")
            return false
        }
    }
}
