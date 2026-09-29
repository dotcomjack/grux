import CryptoKit
import Foundation

/// Uninstalls what Terminal Focus left on a Mac: at launch, and live on the settings
/// file until the job is done (`TerminalFocusHookState`).
///
/// Terminal Focus was removed on 2026-09-27. Its installer registered
/// `~/.claude/hooks/terminal-focus.sh` in `~/.claude/settings.json` under PostToolUse
/// with the matcher `.*`, so the script ran after EVERY tool call in every Claude Code
/// session on the Mac, writing into `~/.grux/focus/`. Deleting the feature's code did
/// not stop that. This does, and touches nothing it did not write:
///
/// - the settings edit removes a hook command only when the whole command is exactly
///   the script (quoted or not, as the absolute path, `~`, `$HOME` or `${HOME}`, after a
///   bare `bash`, `sh` or `zsh` with no other arguments). It never edits shell text: a
///   command that only mentions the script (a chain, `if`, a group, `bash -lc`, `eval`,
///   `HOOK=<script> dispatcher`) is left byte for byte, the person is told once (a Now
///   row and one wake.log line per entry) to remove it, and the job stays unfinished.
///   It writes nothing at all when there is nothing to remove, so the file stays byte
///   identical, and re-reads the file right before its atomic write so an edit made
///   meanwhile is never lost;
/// - the script is deleted only if it carries the installer's own header, and only once
///   the settings no longer point at it, because a registered hook whose script is gone
///   errors on every tool call;
/// - `~/.grux/focus/`, the old `terminal-focus.json` config and the retired step's
///   defaults key go. `grux.step.terminal_sessions_explained` stays: seven other
///   features read it.
enum TerminalFocusRemoval {

    static let doneKey = "grux.cleanup.terminal_focus_removed"
    static let retiredStepKey = "grux.step.terminal_focus_hook_installed"

    /// Lines every version of the installer's script carried. Both must be present.
    static let scriptMarkers = ["Registered by Grux Terminal Focus feature.", "GRUX_HOOK_VERSION="]

    struct Paths: Sendable {
        let home: URL
        let settings: URL
        let script: URL
        let focusDir: URL
        let legacyConfig: URL

        init(home: URL, gruxDir: URL, supportDir: URL) {
            self.home = home
            settings = home.appendingPathComponent(".claude/settings.json")
            script = home.appendingPathComponent(".claude/hooks/terminal-focus.sh")
            focusDir = gruxDir.appendingPathComponent("focus", isDirectory: true)
            legacyConfig = supportDir.appendingPathComponent("terminal-focus.json")
        }
    }

    /// Whether a hook command runs the script at `path`: the path as a whole word, bare
    /// or quoted, alone or after an interpreter (`bash <path>`), with the home folder
    /// written out, as `~` or as `$HOME`. A different file (`<path>.bak`, another home)
    /// is not a match.
    static func runs(_ command: String, script path: String, home: String) -> Bool {
        var c = command
        for alias in ["${HOME}/", "$HOME/"] { c = c.replacingOccurrences(of: alias, with: home + "/") }
        c = c.replacingOccurrences(of: #"(^|[\s"'`;&|(=])~/"#, with: "$1" + NSRegularExpression.escapedTemplate(for: home) + "/", options: .regularExpression)
        let escaped = pathPattern(path, onVolumeOf: path)
        return c.range(of: #"(^|[\s"'`;&|(=])"# + escaped + #"($|[\s"'`;&|)])"#, options: .regularExpression) != nil
    }

    /// `text` (a path, or its part below the home folder) as a pattern that matches it
    /// the way the volume holding `volumePath` does: on a case-insensitive volume (the
    /// default on a Mac) `~/.Claude/hooks/Terminal-Focus.sh` is the same file.
    static func pathPattern(_ text: String, onVolumeOf volumePath: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: text)
        return isCaseInsensitiveVolume(volumePath) ? "(?i:" + escaped + ")" : escaped
    }

    /// True when the volume holding `path` (or its nearest existing folder) ignores case.
    static func isCaseInsensitiveVolume(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames == false
    }

    /// Whether the whole of `command` is the script at `path` and nothing else: optional
    /// surrounding whitespace, optional quotes around the path, the path written out, with
    /// `~`, `$HOME` or `${HOME}`, and an optional leading `bash`, `sh` or `zsh` (bare or
    /// from `/bin` or `/usr/bin`) with no other arguments.
    static func isExactly(_ command: String, script path: String, home: String) -> Bool {
        var forms = [pathPattern(path, onVolumeOf: path)]
        if path.hasPrefix(home + "/") {
            let tail = pathPattern(String(path.dropFirst(home.count)), onVolumeOf: path)
            forms += ["~" + tail, #"\$HOME"# + tail, #"\$\{HOME\}"# + tail]
        }
        let shell = #"(?:(?:/usr/bin/|/bin/)?(?:bash|sh|zsh)[ \t]+)?"#
        let pattern = #"^\s*"# + shell + #"(["']?)(?:"# + forms.joined(separator: "|") + #")\1\s*$"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// The home a script path sits in: `<home>/.claude/hooks/terminal-focus.sh`.
    static func home(ofScript path: String) -> String {
        let suffix = "/.claude/hooks/terminal-focus.sh"
        return path.hasSuffix(suffix) ? String(path.dropLast(suffix.count)) : NSHomeDirectory()
    }

    /// The settings with every hook command that runs `command` (the script path) removed,
    /// or nil when there is none (or the file is not a JSON object), which means: do not write.
    ///
    /// A command that chains the script with others keeps the others. A command left
    /// empty goes, an entry left with no commands goes, an event left with no entries
    /// goes, and `hooks` goes if this emptied it. Nothing else is touched.
    static func removingGruxHook(from data: Data, command: String) -> Data? {
        edit(from: data, command: command).data
    }

    /// The settings edit, as `removingGruxHook`, plus every hook command that mentions
    /// the script without being exactly it. Those are never edited: each stays as written
    /// for the person to remove.
    static func edit(from data: Data, command: String) -> (data: Data?, manual: [String]) {
        let homePath = Self.home(ofScript: command)
        guard var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return (nil, []) }
        var removed = false
        var manual: [String] = []
        for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
            guard let entries = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            var changed = false
            for entry in entries {
                guard let subhooks = entry["hooks"] as? [[String: Any]] else { kept.append(entry); continue }
                var remaining: [[String: Any]] = []
                for hook in subhooks {
                    let line = (hook["command"] as? String) ?? ""
                    if isExactly(line, script: command, home: homePath) { continue }
                    if runs(line, script: command, home: homePath) { manual.append(line) }
                    remaining.append(hook)
                }
                if remaining.count == subhooks.count { kept.append(entry); continue }
                changed = true
                if !remaining.isEmpty {
                    var e = entry
                    e["hooks"] = remaining
                    kept.append(e)
                }
            }
            guard changed else { continue }
            removed = true
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard removed else { return (nil, manual) }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return (try? JSONSerialization.data(withJSONObject: settings,
                                            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), manual)
    }

    /// Where the hook commands left for the person are kept, so Now can say so and each
    /// is logged once, not on every launch.
    static let manualKey = "grux.cleanup.terminal_focus_manual"

    /// Returns true when the job is finished: no Grux hook entry is left in the settings,
    /// and the focus folder and old config are gone. Anything short of that retries next launch.
    ///
    /// `clearFocusWhileMentioned`: whether to delete `~/.grux/focus` while a hook still
    /// mentions the script. That script keeps recreating the folder, so the live watcher
    /// clears it once per launch and then leaves it until the mention is gone.
    @discardableResult
    static func run(_ paths: Paths, defaults: UserDefaults, clearFocusWhileMentioned: Bool = true) -> Bool {
        cleanup(paths, defaults: defaults, clearFocusWhileMentioned: clearFocusWhileMentioned).done
    }

    /// `run`, also saying which settings bytes it read or wrote (nil when it could not
    /// read them) and whether the file was missing. `missingIsClear`: only the launch
    /// run reads a missing settings.json as clear. On the live path a file that is
    /// missing for a moment (a dotfiles `ln -sf`, a checkout that unlinks and recreates)
    /// is unknown, so the run changes nothing: the script, the row and the watch stay.
    static func cleanup(_ paths: Paths, defaults: UserDefaults, clearFocusWhileMentioned: Bool = true,
                        missingIsClear: Bool = true) -> (done: Bool, seen: Data?, missing: Bool) {
        let fm = FileManager.default
        let entry = removeSettingsEntry(paths)
        if entry.missing, !missingIsClear { return (false, nil, true) }
        let settingsClear = entry.clear
        if let manual = entry.manual { record(manual, settings: paths.settings, defaults: defaults) }

        if settingsClear,
           let script = try? String(contentsOf: paths.script, encoding: .utf8),
           scriptMarkers.allSatisfy(script.contains) {
            try? fm.removeItem(at: paths.script)
        }
        if settingsClear || clearFocusWhileMentioned, fm.fileExists(atPath: paths.focusDir.path) {
            try? fm.removeItem(at: paths.focusDir)
        }
        if fm.fileExists(atPath: paths.legacyConfig.path) { try? fm.removeItem(at: paths.legacyConfig) }
        defaults.removeObject(forKey: retiredStepKey)
        let done = settingsClear
            && !fm.fileExists(atPath: paths.focusDir.path)
            && !fm.fileExists(atPath: paths.legacyConfig.path)
        return (done, entry.seen, entry.missing)
    }

    /// True while a hook the person has to remove by hand is still there (as of the
    /// last run). The panel's Now list shows a row from this.
    static func needsManualRemoval(defaults: UserDefaults) -> Bool {
        !(defaults.stringArray(forKey: manualKey) ?? []).isEmpty
    }

    /// Keeps the list of hook commands left for the person and logs each new one once.
    private static func record(_ manual: [String], settings: URL, defaults: UserDefaults) {
        let told = Set(defaults.stringArray(forKey: manualKey) ?? [])
        for line in manual where !told.contains(line) {
            let shown = line.replacingOccurrences(of: "\n", with: "\\n")
            WakeLog.shared.log("terminal focus removal: a Claude Code hook in \(settings.path) mentions the old Terminal Focus script without being exactly it; Grux does not edit shell text, so it needs a manual removal: \(shown)")
        }
        if manual.isEmpty { defaults.removeObject(forKey: manualKey) } else { defaults.set(manual, forKey: manualKey) }
    }

    /// Runs between the edit and the re-read, so a test can make a concurrent edit there.
    nonisolated(unsafe) static var beforeWriteForTest: (() -> Void)?

    /// `clear` is true when the settings hold no Grux entry afterwards, including when
    /// there is no file, and none is left for the person. `manual` is the hook commands
    /// left for the person, or nil when the settings could not be read. `seen` is the
    /// bytes read (or, after an edit, written), nil when none; `missing` says no file.
    ///
    /// Claude Code and the person edit this file too. The edit is computed from one read,
    /// the file is read again right before the atomic write, and if it changed meanwhile
    /// the edit is recomputed from the new bytes (three tries, then next launch).
    private static func removeSettingsEntry(_ paths: Paths)
        -> (clear: Bool, manual: [String]?, seen: Data?, missing: Bool) {
        let fm = FileManager.default
        // Resolve a symlink (a dotfiles repo) so the atomic write lands in its target
        // instead of replacing the link with a plain file.
        let target = paths.settings.resolvingSymlinksInPath()
        for _ in 0..<3 {
            guard fm.fileExists(atPath: target.path) else { return (true, [], nil, true) }
            guard let data = try? Data(contentsOf: target) else { return (false, nil, nil, false) }
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return (false, nil, data, false) }
            let change = edit(from: data, command: paths.script.path)
            guard let updated = change.data else { return (change.manual.isEmpty, change.manual, data, false) }
            let mode = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
            beforeWriteForTest?()
            guard (try? Data(contentsOf: target)) == data else { continue }
            do {
                try updated.write(to: target, options: .atomic)
            } catch {
                return (false, nil, nil, false)
            }
            if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path) }
            return (change.manual.isEmpty, change.manual, updated, false)
        }
        return (false, nil, nil, false)
    }

    /// Called from launch. Never under test, and never again once it has finished. Runs
    /// the cleanup now and keeps it live on the settings file until the job is done
    /// (`TerminalFocusHookState`).
    @MainActor
    static func runOnceAtLaunch() {
        guard !Persistence.isUnderTest, !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let paths = Paths(home: URL(fileURLWithPath: NSHomeDirectory()),
                          gruxDir: Persistence.gruxDir,
                          supportDir: Persistence.supportDir)
        TerminalFocusHookState.shared.start(paths: paths, defaults: .standard)
    }
}

/// Whether a Claude Code hook still runs the old Terminal Focus script in a way Grux
/// will not edit, kept live from `~/.claude/settings.json` (Grux-Mac CLAUDE.md, "live
/// state, never a manual refresh"). The panel's Now row reads `needsManualRemoval`.
///
/// It runs the cleanup when it starts and again whenever the settings file or its
/// folder changes, through `FileWatch` (the file and its folder, and a symlink's target
/// too, because an editor's atomic save fires on the folder). When the person removes
/// the entry, the change finishes the job there and then: the script goes, the row
/// clears, the job is marked done, and the watch stops. No relaunch.
///
/// Claude Code writes under `~/.claude` all the time, so most events are not about
/// the settings at all. The handler hashes the settings bytes and returns at once when
/// they are the ones it last ran on.
@MainActor
final class TerminalFocusHookState: ObservableObject {
    static let shared = TerminalFocusHookState()

    @Published private(set) var needsManualRemoval = false
    /// How many file events arrived, for tests.
    private(set) var events = 0
    /// How many times the cleanup actually ran, for tests.
    private(set) var cleanupRuns = 0

    private var paths: TerminalFocusRemoval.Paths?
    private var defaults: UserDefaults = .standard
    private var watch: FileWatch?
    /// The settings bytes the cleanup last ran on, hashed ("missing" for no file).
    private var lastDigest: String?
    /// Whether this launch already cleared `~/.grux/focus` while a mention remained.
    private var focusCleared = false
    /// Whether the settings file is being watched.
    var isWatching: Bool { watch != nil }
    /// Runs right after a cleanup run, so a test can land an edit there.
    var afterRunForTest: (() -> Void)?

    /// Runs the cleanup now and, unless that finished the job, keeps it running on
    /// every change to the settings file.
    func start(paths: TerminalFocusRemoval.Paths, defaults: UserDefaults) {
        stop()
        self.paths = paths
        self.defaults = defaults
        focusCleared = false
        watch = FileWatch { [weak self] in self?.fileChanged() }
        rewatch()
        refresh(atLaunch: true)
    }

    func stop() {
        watch?.stop()
        watch = nil
        paths = nil
        lastDigest = nil
        needsManualRemoval = false
    }

    private func fileChanged() {
        guard let paths else { return }
        events += 1
        rewatch()
        guard Self.digest(of: paths.settings) != lastDigest else { return }
        refresh(atLaunch: false)
    }

    /// A SHA-256 of the settings file's bytes, through a symlink, or "missing".
    static func digest(of settings: URL) -> String {
        guard let data = try? Data(contentsOf: settings.resolvingSymlinksInPath()) else { return "missing" }
        return digest(of: data)
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func rewatch() {
        guard let paths else { return }
        let target = paths.settings.resolvingSymlinksInPath()
        watch?.watch([paths.settings.deletingLastPathComponent(), paths.settings,
                      target.deletingLastPathComponent(), target])
    }

    /// `atLaunch`: the start's run, the only one that may read a missing settings file
    /// as clear. A live run that finds it missing changes nothing and keeps watching.
    private func refresh(atLaunch: Bool) {
        guard let paths else { return }
        cleanupRuns += 1
        let result = TerminalFocusRemoval.cleanup(paths, defaults: defaults,
                                                  clearFocusWhileMentioned: !focusCleared,
                                                  missingIsClear: atLaunch)
        let done = result.done
        if !result.missing { focusCleared = true }
        afterRunForTest?()
        // The bytes the run read or wrote, not a fresh read: an edit landing during the
        // run is then still a change, and the run's own edit is not.
        lastDigest = result.missing ? "missing" : result.seen.map { Self.digest(of: $0) }
        let needed = TerminalFocusRemoval.needsManualRemoval(defaults: defaults)
        if needsManualRemoval != needed { needsManualRemoval = needed }
        if done {
            defaults.set(true, forKey: TerminalFocusRemoval.doneKey)
            watch?.stop()
            watch = nil
        }
    }
}
