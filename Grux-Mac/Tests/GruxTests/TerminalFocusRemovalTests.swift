import XCTest
@testable import Grux

/// Terminal Focus left, and the Claude Code hook it installed must leave with it.
///
/// The installer registered `~/.claude/hooks/terminal-focus.sh` under PostToolUse with
/// the matcher `.*`, so it ran after EVERY tool call in every Claude Code session on the
/// Mac. Deleting the code without this would leave that running forever.
///
/// Everything here runs against a scratch home. Nothing touches the real
/// `~/.claude/settings.json`, and the defaults are a throwaway suite.
final class TerminalFocusRemovalTests: XCTestCase {

    private var home: URL!
    private var paths: TerminalFocusRemoval.Paths!
    private var defaults: UserDefaults!
    private var suite = ""

    private var command: String { paths.script.path }
    private let foreign = "/usr/local/bin/somebody-elses-hook.sh"

    /// The header the installer wrote, version 5, as measured on a real install.
    private let gruxScript = """
        #!/bin/bash
        # Terminal Focus hook - fires on every PostToolUse and writes session context
        # to ~/.grux/focus/{tty}.*. Registered by Grux Terminal Focus feature.
        # GRUX_HOOK_VERSION=5

        set -euo pipefail
        """

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/hooks"),
                                                withIntermediateDirectories: true)
        paths = TerminalFocusRemoval.Paths(home: home,
                                           gruxDir: home.appendingPathComponent(".grux"),
                                           supportDir: home.appendingPathComponent("support"))
        suite = "tf-removal-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: fixtures

    private func entry(_ matcher: String, _ commands: [String]) -> [String: Any] {
        ["matcher": matcher, "hooks": commands.map { ["type": "command", "command": $0] }]
    }

    private func json(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    private func object(_ data: Data?) throws -> NSDictionary {
        let d = try XCTUnwrap(data, "expected rewritten settings, got none")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? NSDictionary)
    }

    // MARK: the settings edit

    /// Present, alongside a foreign hook in the same event and another event entirely,
    /// plus unrelated top-level settings. Only Grux's entry goes.
    func testGruxEntryIsRemovedAndEverythingElseIsKept() throws {
        let before: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "PostToolUse": [entry(".*", [command]), entry("Bash", [foreign])],
                "PreToolUse": [entry("Edit", [foreign])],
            ],
        ]
        let after = try object(TerminalFocusRemoval.removingGruxHook(from: try json(before), command: command))
        let expected: NSDictionary = [
            "model": "opus",
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "PostToolUse": [entry("Bash", [foreign])],
                "PreToolUse": [entry("Edit", [foreign])],
            ],
        ]
        XCTAssertEqual(after, expected)
    }

    /// One entry carrying both commands keeps the foreign one.
    func testASharedEntryKeepsTheForeignCommand() throws {
        let before: [String: Any] = ["hooks": ["PostToolUse": [entry(".*", [foreign, command])]]]
        let after = try object(TerminalFocusRemoval.removingGruxHook(from: try json(before), command: command))
        XCTAssertEqual(after, ["hooks": ["PostToolUse": [entry(".*", [foreign])]]] as NSDictionary)
    }

    /// Grux's entry alone: the event it emptied goes, nothing is left dangling.
    func testTheOnlyEntryLeavesNoEmptyEvent() throws {
        let before: [String: Any] = ["model": "opus", "hooks": ["PostToolUse": [entry(".*", [command])]]]
        let after = try object(TerminalFocusRemoval.removingGruxHook(from: try json(before), command: command))
        XCTAssertEqual(after, ["model": "opus"] as NSDictionary)
    }

    /// Absent: nothing to write. A near miss is somebody else's file, not ours.
    func testAbsentOrNearMissMeansNoEdit() throws {
        let nearMiss: [String: Any] = ["hooks": ["PostToolUse": [
            entry(".*", [command + ".bak"]),
            entry(".*", ["bash /Users/someone/.claude/hooks/terminal-focus.sh"]),
            entry(".*", [command.replacingOccurrences(of: "terminal-focus.sh", with: "my-terminal-focus.sh")]),
            entry("Bash", [foreign]),
        ]]]
        XCTAssertNil(TerminalFocusRemoval.removingGruxHook(from: try json(nearMiss), command: command))
        XCTAssertNil(TerminalFocusRemoval.removingGruxHook(from: Data("{ not json".utf8), command: command))
    }

    /// RV21, narrowed by the follow-up review: a hook whose whole command is the script,
    /// written another plain way (quoted, through `~`, `$HOME` or `${HOME}`, after a bare
    /// `bash`, `sh` or `zsh` with no other arguments), is still the Grux hook and goes.
    func testEveryCommandThatIsExactlyTheScriptIsRemoved() throws {
        let tail = ".claude/hooks/terminal-focus.sh"
        let variants = [
            command,
            "  " + command + "\n",
            "bash " + command,
            "/bin/bash \"" + command + "\"",
            "zsh '" + command + "'",
            "~/" + tail,
            "bash $HOME/" + tail,
            "sh ${HOME}/" + tail,
            "\"$HOME/" + tail + "\"",
        ]
        for v in variants {
            let before: [String: Any] = ["model": "opus", "hooks": ["PostToolUse": [entry(".*", [v, foreign])]]]
            let edit = TerminalFocusRemoval.edit(from: try json(before), command: command)
            XCTAssertEqual(edit.manual, [], v)
            XCTAssertEqual(try object(edit.data), ["model": "opus", "hooks": ["PostToolUse": [entry(".*", [foreign])]]] as NSDictionary, v)
        }
    }

    /// Follow-up review P2: editing shell text is not safe. `if ...; then\n S\nfi` lost
    /// the `S` line and left a broken `if`, `bash -lc "S; other"` and `eval "S; other"`
    /// lost `other`, `HOOK=S dispatcher` lost the dispatcher. Any command that mentions
    /// the script and is not exactly the script is left exactly as it was, and named
    /// for the person to remove.
    func testACommandThatOnlyMentionsTheScriptIsLeftUntouched() throws {
        let s = command
        let mentions = [
            "if [ -t 1 ]; then\n " + s + "\nfi",
            "{ echo a; " + s + "; }",
            "bash -lc \"" + s + "; other\"",
            "eval \"" + s + "; other\"",
            "HOOK=" + s + " dispatcher",
            "zsh -ic '" + s + "'",
            "sh -ec " + s,
            "[ -x " + s + " ] && /usr/local/bin/other",
            s + "; echo done",
            s + " --verbose",
            s + " 2>/dev/null",
            s + " | tee /tmp/focus.log",
            "(cd /tmp && " + s + ")",
            "for i in 1; do " + s + "; done",
            "cat <<EOF | sh\n" + s + "\nEOF",
        ]
        for line in mentions {
            let alone: [String: Any] = ["hooks": ["PostToolUse": [entry(".*", [line, foreign])]]]
            let edit = TerminalFocusRemoval.edit(from: try json(alone), command: command)
            XCTAssertNil(edit.data, "\(line): the settings were edited")
            XCTAssertEqual(edit.manual, [line], line)

            // Beside an exact entry, the exact one goes and this one is kept as written.
            let mixed: [String: Any] = ["hooks": ["PostToolUse": [entry(".*", [line, foreign]), entry("Bash", [command])]]]
            let both = TerminalFocusRemoval.edit(from: try json(mixed), command: command)
            XCTAssertEqual(both.manual, [line], line)
            XCTAssertEqual(try object(both.data), ["hooks": ["PostToolUse": [entry(".*", [line, foreign])]]] as NSDictionary, line)
        }
    }

    /// The whole run with a mention left: the settings stay byte for byte, the script
    /// stays (a registered hook whose script is gone errors on every tool call), the job
    /// stays unfinished, the person is told once in Now, and wake.log says it once per
    /// entry, not once per launch.
    func testAMentionIsToldOnceAndTheScriptIsKept() throws {
        let line = "if [ -t 1 ]; then\n " + command + "\nfi"
        try json(["hooks": ["PostToolUse": [entry(".*", [line])]]]).write(to: paths.settings)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: paths.settings)

        XCTAssertFalse(TerminalFocusRemoval.run(paths, defaults: defaults))
        XCTAssertFalse(TerminalFocusRemoval.run(paths, defaults: defaults), "a second launch finished the job")
        XCTAssertEqual(try Data(contentsOf: paths.settings), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.script.path), "the script went while a hook still runs it")
        XCTAssertTrue(TerminalFocusRemoval.needsManualRemoval(defaults: defaults))

        var s = RelevanceState()
        s.oldHookNeedsRemoval = true
        let row = try XCTUnwrap(Relevance.now(s).first, "Now does not tell the person")
        XCTAssertEqual(row.action, .revealClaudeSettings)
        XCTAssertTrue(row.detail.contains("~/.claude/settings.json"), row.detail)
        XCTAssertTrue(row.title.contains("hook"), row.title)

        // One wake.log line for the entry over both launches.
        let marker = "needs a manual removal"
        func count() -> Int {
            let text = (try? String(contentsOf: WakeLog.shared.fileURL, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "\n").filter { $0.contains(marker) && $0.contains(home.lastPathComponent) }.count
        }
        var deadline = Date().addingTimeInterval(3)
        while count() == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(count(), 1, "the entry was not logged once")
        deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            XCTAssertLessThanOrEqual(count(), 1, "the entry was logged again on the next launch")
            Thread.sleep(forTimeInterval: 0.05)
        }

        // The person removes it: the next launch finishes and Now clears.
        try json(["hooks": [:] as [String: Any]]).write(to: paths.settings)
        XCTAssertTrue(TerminalFocusRemoval.run(paths, defaults: defaults))
        XCTAssertFalse(TerminalFocusRemoval.needsManualRemoval(defaults: defaults))
    }

    /// Round-3 review P2: the Now row read a key only the launch run wrote, so removing
    /// the entry by hand left the row up until a relaunch. The row now follows the live
    /// settings file: the person's edit reaches it through the file watcher, which
    /// finishes the job (the script goes, the row clears) with no relaunch.
    @MainActor
    func testRemovingTheEntryOnDiskClearsTheRowThroughTheWatcher() async throws {
        let line = "HOOK=" + command + " dispatcher"
        try json(["model": "opus", "hooks": ["PostToolUse": [entry(".*", [line])]]]).write(to: paths.settings)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        let state = TerminalFocusHookState.shared
        state.start(paths: paths, defaults: defaults)
        defer { state.stop() }
        XCTAssertTrue(state.needsManualRemoval, "control: the mention was not found")
        XCTAssertTrue(RelevanceState.live(now: Date(), slow: .init()).oldHookNeedsRemoval, "Now does not read the live state")
        let events = state.events

        // The person removes the entry in an editor (an atomic save).
        try json(["model": "opus"]).write(to: paths.settings, options: .atomic)
        let deadline = Date().addingTimeInterval(5)
        while state.needsManualRemoval, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }

        XCTAssertFalse(state.needsManualRemoval, "the row stayed up after the entry was removed")
        XCTAssertGreaterThan(state.events, events, "the change did not arrive through the watcher")
        XCTAssertFalse(RelevanceState.live(now: Date(), slow: .init()).oldHookNeedsRemoval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.script.path), "the job was not finished")
        XCTAssertTrue(defaults.bool(forKey: TerminalFocusRemoval.doneKey))
    }

    /// Round-4 review P3: Claude Code writes under `~/.claude` all the time, and each
    /// folder event re-ran the whole cleanup on the main actor, deleting `~/.grux/focus`
    /// each time while the still-registered script recreated it. The handler now returns
    /// at once when the settings bytes are unchanged, and while a mention remains the
    /// focus folder goes at most once per launch.
    @MainActor
    func testFolderEventsWithUnchangedSettingsRunNoCleanup() async throws {
        let line = "HOOK=" + command + " dispatcher"
        try json(["hooks": ["PostToolUse": [entry(".*", [line])]]]).write(to: paths.settings)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: paths.focusDir, withIntermediateDirectories: true)
        let state = TerminalFocusHookState.shared
        state.start(paths: paths, defaults: defaults)
        defer { state.stop() }
        XCTAssertTrue(state.needsManualRemoval, "control: the mention was not found")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focusDir.path), "the first run clears the focus folder")
        let firstRuns = state.cleanupRuns

        // The still-live script recreates its folder; Claude Code writes beside settings.json.
        try FileManager.default.createDirectory(at: paths.focusDir, withIntermediateDirectories: true)
        let folder = paths.settings.deletingLastPathComponent()
        for i in 0..<10 {
            let events = state.events
            try Data("session \(i)".utf8).write(to: folder.appendingPathComponent("session-\(i).jsonl"))
            let deadline = Date().addingTimeInterval(3)
            while state.events == events, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertGreaterThan(state.events, events, "control: folder write \(i) raised no event")
        }
        XCTAssertEqual(state.cleanupRuns, firstRuns, "unchanged settings bytes ran the cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.focusDir.path), "the focus folder was cleared again")

        // A real edit that keeps the mention runs the cleanup, and leaves the focus folder.
        try json(["model": "opus", "hooks": ["PostToolUse": [entry(".*", [line])]]]).write(to: paths.settings, options: .atomic)
        var deadline = Date().addingTimeInterval(5)
        while state.cleanupRuns == firstRuns, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(state.cleanupRuns, firstRuns + 1, "a real edit did not run the cleanup")
        XCTAssertTrue(state.needsManualRemoval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.focusDir.path), "the focus folder was cleared twice in one launch")

        // Removing the mention finishes the job, focus folder included.
        try json(["model": "opus"]).write(to: paths.settings, options: .atomic)
        deadline = Date().addingTimeInterval(5)
        while state.needsManualRemoval, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(state.needsManualRemoval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focusDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.script.path))
        XCTAssertTrue(defaults.bool(forKey: TerminalFocusRemoval.doneKey))
    }

    /// Round-5 review P2: a settings.json that went missing for a moment (a dotfiles
    /// `ln -sf`, a git checkout that unlinks and recreates) read as clear on the live
    /// path, so the script was deleted and the watch stopped; when the file came back
    /// with the hook, it ran a deleted script on every tool call. Live, missing is
    /// unknown: the script, the watch and the row stay as they were.
    @MainActor
    func testASettingsFileThatGoesMissingLiveFinishesNothing() async throws {
        let line = "HOOK=" + command + " dispatcher"
        let withMention = try json(["hooks": ["PostToolUse": [entry(".*", [line])]]])
        try withMention.write(to: paths.settings)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        let state = TerminalFocusHookState.shared
        state.start(paths: paths, defaults: defaults)
        defer { state.stop() }
        XCTAssertTrue(state.needsManualRemoval, "control: the mention was not found")

        func waitFor(_ what: String, _ done: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(done(), what)
        }
        var events = state.events
        try FileManager.default.removeItem(at: paths.settings)
        try await waitFor("the unlink raised no event") { state.events > events }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.script.path), "a missing settings file deleted the script")
        XCTAssertTrue(state.isWatching, "a missing settings file stopped the watch")
        XCTAssertTrue(state.needsManualRemoval, "a missing settings file cleared the row")
        XCTAssertFalse(defaults.bool(forKey: TerminalFocusRemoval.doneKey))

        // The file comes back with the hook: the row is still there.
        events = state.events
        try withMention.write(to: paths.settings, options: .atomic)
        try await waitFor("the recreate raised no event") { state.events > events }
        XCTAssertTrue(state.needsManualRemoval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.script.path))

        // The person removes the mention: the job finishes.
        try json(["model": "opus"]).write(to: paths.settings, options: .atomic)
        try await waitFor("the row did not clear") { !state.needsManualRemoval }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.script.path))
        XCTAssertTrue(defaults.bool(forKey: TerminalFocusRemoval.doneKey))
        XCTAssertFalse(state.isWatching)
    }

    /// Only the launch run may read a missing settings.json as clear.
    @MainActor
    func testAtLaunchAMissingSettingsFileIsClear() {
        try? gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        let state = TerminalFocusHookState.shared
        state.start(paths: paths, defaults: defaults)
        defer { state.stop() }
        XCTAssertFalse(state.needsManualRemoval)
        XCTAssertTrue(defaults.bool(forKey: TerminalFocusRemoval.doneKey))
        XCTAssertFalse(state.isWatching)
    }

    /// Round-5 review P3: the hash recorded after a run was taken from a fresh read, so
    /// an edit landing during the cleanup was recorded as seen and never acted on. The
    /// hash is now of the bytes the cleanup read, so that edit still runs it.
    @MainActor
    func testAnEditLandingDuringTheCleanupIsStillActedOn() async throws {
        let line = "HOOK=" + command + " dispatcher"
        try json(["hooks": ["PostToolUse": [entry(".*", [line])]]]).write(to: paths.settings)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        let state = TerminalFocusHookState.shared
        let settings: URL = paths.settings
        let cleared = try json(["model": "opus"])
        state.afterRunForTest = {
            state.afterRunForTest = nil
            try? cleared.write(to: settings, options: .atomic)
        }
        defer { state.afterRunForTest = nil; state.stop() }
        state.start(paths: paths, defaults: defaults)
        let deadline = Date().addingTimeInterval(5)
        while state.needsManualRemoval, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(state.needsManualRemoval, "the edit made during the cleanup was recorded as seen")
        XCTAssertTrue(defaults.bool(forKey: TerminalFocusRemoval.doneKey))
    }

    /// Round-3 review P3: on a case-insensitive disk `~/.Claude/hooks/Terminal-Focus.sh`
    /// is the same file, but it was neither removed nor listed, the job read as clear,
    /// and the script was deleted under a live hook.
    func testADifferentlyCasedPathIsTheSameScriptOnACaseInsensitiveDisk() throws {
        let probe = home.appendingPathComponent("CaseProbe")
        try Data().write(to: probe)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: home.appendingPathComponent("caseprobe").path),
                          "this volume is case-sensitive, where the differently cased path is another file")
        let upperHome = "~/.Claude/hooks/Terminal-Focus.sh"
        let upperAbsolute = home.path + "/.CLAUDE/hooks/TERMINAL-FOCUS.sh"
        let mention = "HOOK=" + upperAbsolute + " dispatcher"
        let before: [String: Any] = ["hooks": ["PostToolUse": [entry(".*", [upperHome, foreign]), entry("Bash", [mention])]]]
        let edit = TerminalFocusRemoval.edit(from: try json(before), command: command)
        XCTAssertEqual(edit.manual, [mention])
        XCTAssertEqual(try object(edit.data),
                       ["hooks": ["PostToolUse": [entry(".*", [foreign]), entry("Bash", [mention])]]] as NSDictionary)

        // The whole run never deletes the script while the cased mention is there.
        try json(["hooks": ["PostToolUse": [entry("Bash", [mention])]]]).write(to: paths.settings)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        XCTAssertFalse(TerminalFocusRemoval.run(paths, defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.script.path), "the script went under a live hook")
    }

    /// RV21: an edit made to settings.json between the read and the write survives.
    func testAConcurrentEditIsNotLost() throws {
        let before: [String: Any] = ["model": "opus", "hooks": ["PostToolUse": [entry(".*", [command])]]]
        try json(before).write(to: paths.settings)
        let meanwhile: [String: Any] = ["model": "opus", "theme": "dark",
                                        "hooks": ["PostToolUse": [entry(".*", [command])]]]
        let settings: URL = paths.settings
        let concurrent = try json(meanwhile)
        TerminalFocusRemoval.beforeWriteForTest = {
            TerminalFocusRemoval.beforeWriteForTest = nil
            try? concurrent.write(to: settings)
        }
        defer { TerminalFocusRemoval.beforeWriteForTest = nil }

        XCTAssertTrue(TerminalFocusRemoval.run(paths, defaults: defaults))

        XCTAssertEqual(try object(try Data(contentsOf: paths.settings)),
                       ["model": "opus", "theme": "dark"] as NSDictionary)
    }

    // MARK: the whole run, on disk

    func testNoGruxEntryLeavesSettingsByteIdentical() throws {
        let original = Data("{\n    \"model\" : \"opus\",\n    \"hooks\": {\"PostToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"/usr/local/bin/x\"}]}]}\n}\n".utf8)
        try original.write(to: paths.settings)
        let stamp = try FileManager.default.attributesOfItem(atPath: paths.settings.path)[.modificationDate] as? Date

        XCTAssertTrue(TerminalFocusRemoval.run(paths, defaults: defaults))

        XCTAssertEqual(try Data(contentsOf: paths.settings), original, "settings changed with no Grux entry in them")
        let after = try FileManager.default.attributesOfItem(atPath: paths.settings.path)[.modificationDate] as? Date
        XCTAssertEqual(stamp, after, "settings were rewritten with no Grux entry in them")
    }

    func testTheRunRemovesTheHookScriptFocusDirConfigAndStep() throws {
        try json(["hooks": ["PostToolUse": [entry(".*", [command]), entry("Bash", [foreign])]]])
            .write(to: paths.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.settings.path)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: paths.focusDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.focusDir.appendingPathComponent("grux-focus-config.json"))
        try FileManager.default.createDirectory(at: paths.legacyConfig.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.legacyConfig)
        defaults.set(true, forKey: TerminalFocusRemoval.retiredStepKey)
        defaults.set(true, forKey: "grux.step.terminal_sessions_explained")

        XCTAssertTrue(TerminalFocusRemoval.run(paths, defaults: defaults))

        XCTAssertEqual(try object(Data(contentsOf: paths.settings)),
                       ["hooks": ["PostToolUse": [entry("Bash", [foreign])]]] as NSDictionary)
        // A parse cannot see `\/`, so read the bytes: the rewrite keeps paths readable.
        let raw = try String(contentsOf: paths.settings, encoding: .utf8)
        XCTAssertTrue(raw.contains(foreign), "the foreign command's path was escaped in the rewrite")
        XCTAssertFalse(raw.contains("\\/"), "the rewrite escaped slashes")
        let mode = try FileManager.default.attributesOfItem(atPath: paths.settings.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the rewrite loosened the settings file's permissions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.script.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focusDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyConfig.path))
        XCTAssertNil(defaults.object(forKey: TerminalFocusRemoval.retiredStepKey))
        XCTAssertTrue(defaults.bool(forKey: "grux.step.terminal_sessions_explained"),
                      "the sessions step gates seven other features and must survive")
    }

    /// A script at that path that Grux did not write is not Grux's to delete.
    func testAForeignScriptAtTheSamePathIsKept() throws {
        try "#!/bin/sh\necho mine\n".write(to: paths.script, atomically: true, encoding: .utf8)
        XCTAssertTrue(TerminalFocusRemoval.run(paths, defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.script.path))
    }

    /// If the settings cannot be read, the entry may still point at the script, and a
    /// registered hook whose script is gone errors on every tool call. Keep both, retry.
    func testUnreadableSettingsKeepTheScriptAndReportIncomplete() throws {
        let broken = Data("{ \"hooks\": ".utf8)
        try broken.write(to: paths.settings)
        try gruxScript.write(to: paths.script, atomically: true, encoding: .utf8)

        XCTAssertFalse(TerminalFocusRemoval.run(paths, defaults: defaults))

        XCTAssertEqual(try Data(contentsOf: paths.settings), broken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.script.path))
    }

    /// A symlinked settings file (a dotfiles repo) stays a symlink; the edit lands in its target.
    func testASymlinkedSettingsFileStaysASymlink() throws {
        let target = home.appendingPathComponent("dotfiles-settings.json")
        try json(["hooks": ["PostToolUse": [entry(".*", [command])]]]).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.settings, withDestinationURL: target)

        XCTAssertTrue(TerminalFocusRemoval.run(paths, defaults: defaults))

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.settings.path), target.path)
        XCTAssertEqual(try object(Data(contentsOf: target)), [:] as NSDictionary)
    }

    /// A focus folder that could not be removed is not a finished job, so it retries.
    func testAFolderThatCannotBeRemovedReportsIncomplete() throws {
        let grux = paths.focusDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: paths.focusDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: grux.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grux.path) }

        XCTAssertFalse(TerminalFocusRemoval.run(paths, defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.focusDir.path), "control: the folder was removable")
    }

    /// No settings file at all is a finished job, not a failure.
    func testNoSettingsFileIsComplete() {
        XCTAssertTrue(TerminalFocusRemoval.run(paths, defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.settings.path), "the run created a settings file")
    }
}
