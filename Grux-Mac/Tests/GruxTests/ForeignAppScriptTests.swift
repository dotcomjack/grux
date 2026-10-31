import XCTest
@testable import Grux
import GruxShellCore
@testable import GruxAgentCore

/// No AppleScript reaches another app except through `ForeignAppScript`, and in
/// headless mode none does.
///
/// Measured 2026-10-22 on a headless Mac mini: a small local model answered "what is
/// two plus two" by calling `play_on_youtube`, and Grux ran `tell application "Google
/// Chrome" to activate` (wake.log: `Chrome scripting failed (-1712): ... AppleEvent
/// timed out`) on a screen that belonged to someone else. Twenty call sites built
/// their own `NSAppleScript`, so a headless gate could only hold if every one of them
/// was found by hand, and the next one added would not be. This scans every source file.
final class ForeignAppScriptTests: XCTestCase {

    /// The two gates: Grux's, and GruxShellCore's (which cannot see Grux) for the shell
    /// doors. Nothing else in Sources may build a script or open another app.
    private static let gates: Set<String> = [
        "Sources/Grux/Shell/ForeignAppScript.swift",
        "Sources/GruxShellCore/ShellAppleEvents.swift",
    ]
    /// Each line that may open an app outside a gate, with why. Matched by exact line, so a
    /// second `open` in the same file is still caught.
    private static let allowedLines: [String: String] = [
        "Sources/Grux/Backup/BackupView.swift|        task.executableURL = URL(fileURLWithPath: \"/usr/bin/open\")":
            "relaunches Grux itself after a restore, not another app",
        "Sources/GruxAgentCore/SwarmWorker.swift|        \"/usr/bin/open\", \"/usr/bin/osascript\", \"/usr/bin/shortcuts\", \"/usr/bin/automator\",":
            "the programs the headless agent sandbox refuses to start",
    ]
    /// Ways to script or open another app: an AppleScript built in-process, `osascript`
    /// run directly or through `env`, `/usr/bin/open`, and LaunchServices' own launch.
    private static let reaches = [
        "NSAppleScript(source", "\"/usr/bin/osascript\"", "[\"osascript\"", "\"/usr/bin/open\"",
        "openApplication(", ".launchApplication(", "OSAScript(", "[\"open\"", "\"/usr/bin/shortcuts\"",
        "\"/usr/bin/automator\"", "SBApplication(", "NSUserAppleScriptTask", "withApplicationAt:",
    ]

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func tearDown() {
        WindowFacade.headlessUnderTest = nil
        super.tearDown()
    }

    func testNoAppleScriptIsBuiltOutsideTheGate() throws {
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            scanned += 1
            if Self.gates.contains(rel) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                if Self.allowedLines["\(rel)|\(raw)"] != nil { continue }
                if Self.reaches.contains(where: { raw.contains($0) }) {
                    offenders.append("\(rel):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 500, "the scan read too few files to prove anything")
        XCTAssertEqual(offenders, [], "a script to another app, or an app opened, skips the headless gate")
        for (key, _) in Self.allowedLines {
            let parts = key.components(separatedBy: "|")
            let text = try String(contentsOf: root.appendingPathComponent(parts[0]), encoding: .utf8)
            XCTAssertTrue(text.components(separatedBy: "\n").contains(parts[1]), "a stale allowance: \(key)")
        }
        let wiring = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Audio/AudioOutput.swift"), encoding: .utf8)
        XCTAssertTrue(wiring.contains("ShellAppleEvents.refusal = "), "Grux must point the shell doors at its gate")
    }

    /// Files that may wait for a script on the calling thread, with why. Everything else
    /// asks `ForeignAppScript.run`, which never runs a script on the caller's thread.
    private static let waitingCallers: [String: String] = [
        "Sources/Grux/Ambient/ChromeTabWatcher.swift": "ticks on its own background queue, never the main thread",
        "Sources/Grux/Ambient/MusicWatcher.swift": "ticks on its own background queue, never the main thread",
        "Sources/Grux/AudioDucker.swift": "must finish before Grux speaks or quits; waits at most AudioDucker's own 3 s",
    ]

    /// D13 (P1): every caller ran its script on its own thread, most of them the main
    /// actor (`MainActor.run { BrowserTool.playOnYouTube(q) }`), so while macOS held the
    /// Apple Event for an Automation prompt (measured: answered at +153.94 s) the whole of
    /// Grux was frozen. Only the gate may execute a script, so none can again.
    func testOnlyTheGateRunsAScriptAndNoCallerWaitsOnTheMainThread() throws {
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var runs: [String] = []
        var waits: [String] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if Self.gates.contains(rel) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                if raw.contains("executeAndReturnError") || raw.contains("ForeignAppScript.make(") {
                    runs.append("\(rel):\(i + 1)")
                }
                if raw.contains("ForeignAppScript.runWaiting("), Self.waitingCallers[rel] == nil {
                    waits.append("\(rel):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(runs, [], "a script runs outside the gate, on whatever thread called it")
        XCTAssertEqual(waits, [], "a caller waits for another app on its own thread without a reason here")
    }

    // MARK: - Wave 3 review: the doors around the gate

    private func fakeBinaries() throws -> (dir: URL, marker: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreign-app-\(UUID().uuidString)").resolvingSymlinksInPath()
        let marker = dir.appendingPathComponent("ran")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        // Fakes named like the real programs: they only touch a marker, so a broken gate
        // shows as the marker and nothing reaches another app either way.
        for name in ["osascript", "open", "shortcuts", "automator"] {
            let path = dir.appendingPathComponent("bin/\(name)").path
            try "#!/bin/sh\ntouch '\(marker.path)'\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return (dir, marker)
    }

    /// P1 (wave 3): `shell_run "osascript -e 'tell application \"Google Chrome\" to activate'"`
    /// ran in headless mode; only a SOUNDING osascript was refused.
    func testAShellCommandThatReachesAnotherAppIsRefusedInHeadlessMode() async throws {
        _ = AudioOutput.wireShellDoors
        WindowFacade.headlessUnderTest = true
        let (dir, marker) = try fakeBinaries()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin").path
        let commands = [
            "\(bin)/osascript -e 'tell application \"Google Chrome\" to activate'",
            "\(bin)/open -a 'Google Chrome' https://example.com",
            "cd /tmp && FOO=1 env \(bin)/osascript -e 'return 1'",
            "bash -c \"\(bin)/open -a Finder\"",
            "\(bin)/shortcuts run Something",
            "\(bin)/automator x.workflow",
        ]
        for command in commands {
            let why = try XCTUnwrap(AudioOutput.shellRefusal(for: command), "ran in headless mode: \(command)")
            XCTAssertTrue(why.hasPrefix(ForeignAppScript.refusalPrefix), why)
            XCTAssertEqual(GruxControlTools.shellBlockedKind(reason: why), "headless")
        }
        let session = ShellSession(id: "headless-\(UUID().uuidString.prefix(8))", rootDir: dir.path,
                                   mode: .trust, undoMode: .perTurn)
        let ran = try await session.run(command: commands[0])
        let confirmed = try await session.runConfirmed(command: commands[1])
        for result in [ran, confirmed] {
            XCTAssertTrue(result.blocked, result.command)
            XCTAssertTrue(result.blockedReason?.hasPrefix(ForeignAppScript.refusalPrefix) == true, result.blockedReason ?? "")
        }
        let args = await ShellRunner.runArgs("\(bin)/open", ["-a", "Google Chrome", "https://example.com"])
        XCTAssertEqual(args.status, -1, args.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a door ran a command that reaches another app")

        // Commands that reach no app still run, and so does every one with headless off.
        for harmless in ["ls -la", "echo open the door", "git log --oneline", "cat osascript.txt"] {
            XCTAssertNil(AudioOutput.shellRefusal(for: harmless), harmless)
        }
        WindowFacade.headlessUnderTest = false
        XCTAssertNil(AudioOutput.shellRefusal(for: commands[0]))
    }

    /// Wave 3 re-review: Python's `open(` split on `(` left a bare `open`, so the App Store
    /// Connect health probe was refused and read as healthy; shell keywords and a script
    /// piped into a shell walked past. Judged only, nothing runs.
    func testTheShellMatcherReadsCommandPositionNotAnyWord() {
        let reaches = [
            "for f in *.pdf; do open \"$f\"; done",
            "if true; then open -a Safari; fi",
            "while true; do osascript -e 'return 1'; done",
            "! open -a Safari",
            "echo 'open -a Safari' | sh",
            "bash <<< 'open -a Safari'",
            "echo 'tell application \"Finder\" to activate' | osascript",
            "OPEN -a Safari",
            "arch -arm64 open -a Safari",
            "(open -a Safari)",
            "$(open -a Safari)",
            // Third review: an argument the shell supplies at run time is still an argument.
            "open \"$(pbpaste)\"",
            "open `cat url.txt`",
            "open $(ls *.app | head -1)",
            "open <(echo x)",
            "open {a,b}.html",
            "find . -name '*.html' -print0 | xargs -0 open",
            "ls | xargs open",
            "xargs -n 1 open",
            "ls | xargs -I{} open {}",
            "arch -arch x86_64 open -a Safari",
            "fish --command 'open -a Safari'",
            "bash <<EOF\nopen -a Safari\nEOF",
            "\\open -a Safari",
            "{ open -a Safari; }",
            "echo hi 2>&1; open -a Safari",
            // Fourth review: wrappers that run a quoted command, or take a value.
            "eval 'open -a Safari'",
            "eval \"osascript -e 'return 1'\"",
            "env -S 'open -a Safari'",
            "sudo -u bob open x",
            "env -u VAR open x",
            "xargs -I {} open {}",
            "xargs -I % open %",
            "exec -a name open x",
            "find . -name '*.html' -exec open {} \\;",
            "find . -execdir osascript -e 'return 1' \\;",
            // P3-W3c: every -exec runs, not only the first.
            "find . -exec echo {} \\; -exec open {} \\;",
            "find . -ok true {} \\; -execdir osascript -e 'return 1' \\;",
            ">/dev/null open -a Safari",
            "2>/dev/null osascript -e 'return 1'",
            "> out open x",
            "(( m = 1 << 3 ))\nopen -a Safari",
            "echo hi\r\nosascript -e 'return 1'",
            "echo \"x\"\u{301}; open -a Safari",
            "coproc open x",
            "function f { open x; }",
            "timeout 5 open x",
        ]
        for command in reaches {
            XCTAssertNotNil(ShellAppleEvents.refusal(for: command, headless: true), command)
        }
        let quiet = [
            "/opt/homebrew/bin/python3 - <<'PYEOF' 2>&1\nimport json\nCFG = json.load(open('/tmp/cfg.json'))\nwith open('/tmp/x') as f: pk = f.read()\nPYEOF",
            "python3 -c \"print(open('f').read())\"",
            "git commit -m \"fix (open) bug\"",
            "git commit -m \"fix (open the file) bug\"",
            "git commit -m \"wip; open questions remain\"",
            "grep -E \"close|open\" file.py",
            "rg 'TODO|open' Sources",
            "# open the file later\nls",
            "echo hi 2>&1 | cat",
            "curl -fsSL https://example.com/open-tool/install.sh | bash",
            "command -v open",
            "type open",
            "which osascript",
            "echo open the door",
            "grep -rn open Sources",
            "openssl rand 4",
            "sh run.sh",
            "bash build.sh --open",
        ]
        for command in quiet {
            XCTAssertNil(ShellAppleEvents.refusal(for: command, headless: true), command)
        }
        // `ShellRunner.runArgs` has no shell: its arguments are judged as an argv, never
        // re-parsed, so a commit message is not a command.
        XCTAssertNil(ShellAppleEvents.refusal(argv: ["/usr/bin/git", "commit", "-m", "fix (open) bug"], headless: true))
        XCTAssertNil(ShellAppleEvents.refusal(argv: ["/usr/bin/git", "commit", "-m", "wip; open the file"], headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(argv: ["/usr/bin/open", "-a", "Google Chrome", "https://example.com"], headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(argv: ["/usr/bin/env", "osascript", "-e", "return 1"], headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(argv: ["/bin/zsh", "-lc", "open -a Safari"], headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(argv: ["/usr/bin/env", "-S", "open -a X"], headless: true))
    }

    /// Fourth review: a text matcher cannot see `p=osascript; $p ...` or `$(echo open)`.
    /// Fifth review: a sandbox around the shell broke `swift build` (macOS refuses a
    /// sandbox inside a sandbox, measured `sandbox_apply: Operation not permitted`) and
    /// went stale when headless mode changed under a running session. So the shell doors
    /// put a guard directory first on PATH: `open`, `osascript`, `shortcuts` and
    /// `automator` there check ~/.grux/HEADLESS each time they run, refuse while it is
    /// there and run the real program when it is not. `osascript -e 'return 1'` reaches
    /// no app even where it runs.
    func testTheShellDoorsFindAGuardFirstOnPathThatFollowsHeadlessLive() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-guard-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grux"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = home.appendingPathComponent(".grux/HEADLESS")

        // A guard of its own, watching a sentinel of its own: the real ~/.grux/HEADLESS is
        // never touched. The stubs read the sentinel's absolute path, not $HOME.
        let guardDir = home.appendingPathComponent("guard").path
        ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel.path)
        func run(_ script: String) throws -> (status: Int32, out: String, err: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["--noprofile", "--norc", "-c", script]
            p.environment = ["HOME": home.path, "PATH": guardDir + ":/usr/bin:/bin"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus,
                    String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(decoding: e, as: UTF8.self))
        }
        let evasions = ["p=osascript; $p -e 'return 1'", "$(echo osascript) -e 'return 1'",
                        "echo x | xargs osascript -e 'return 1'",
                        "export HOME=/tmp; p=osascript; $p -e 'return 1'"]
        try "".write(to: sentinel, atomically: true, encoding: .utf8)
        for evasion in evasions {
            let r = try run(evasion)
            XCTAssertNotEqual(r.out, "1", "osascript ran in headless mode: \(evasion)")
            // 126 from the guard; `xargs` reports its own failing status for the child's.
            XCTAssertNotEqual(r.status, 0, evasion)
            XCTAssertTrue(r.err.contains(ShellAppleEvents.refusalPrefix), r.err)
        }
        XCTAssertEqual(try run("echo quiet ok").out, "quiet ok", "an ordinary command must still run")

        // Headless off: the same command runs the real program, unchanged.
        try FileManager.default.removeItem(at: sentinel)
        let off = try run(evasions[0])
        XCTAssertEqual(off.out, "1", off.err)
        XCTAssertEqual(off.status, 0)

        // A zsh login shell's path_helper reorders PATH, so ShellRunner puts the guard
        // first inside the command itself, quoted.
        let line = ShellAppleEvents.guarded(command: "ls")
        XCTAssertTrue(line.hasPrefix("PATH='"), line)
        XCTAssertTrue(line.hasSuffix(":\"$PATH\"; ls"), line)

        // Fifth review: the guard sat in a temp folder macOS cleans, written once a launch.
        // Every use repairs it, so a deleted stub is back before the next command. Proven on
        // this test's own guard: the live one is never touched (P3-W3d: this used to write
        // the live ~/.grux/headless-guard; under test it is the suite's own folder).
        XCTAssertEqual(ShellAppleEvents.defaultGruxDirectory(underTest: false), NSHomeDirectory() + "/.grux")
        let underTest = ShellAppleEvents.guardedPath("/usr/bin").components(separatedBy: ":")[0]
        XCTAssertFalse(underTest.hasPrefix(NSHomeDirectory() + "/.grux"), "a test wrote the live guard: \(underTest)")
        let fm = FileManager.default
        try fm.removeItem(atPath: guardDir + "/open")
        ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel.path)
        XCTAssertTrue(fm.isExecutableFile(atPath: guardDir + "/open"), "a deleted stub was not put back")

        // Seventh review: something that is not a stub at a stub's path (a directory the
        // shell's PATH search would skip, a FIFO a read would block on), an extra program
        // planted beside the stubs, or a guard path that is not a directory of ours.
        try fm.removeItem(atPath: guardDir + "/osascript")
        try fm.createDirectory(atPath: guardDir + "/osascript", withIntermediateDirectories: false)
        try fm.removeItem(atPath: guardDir + "/shortcuts")
        XCTAssertEqual(mkfifo(guardDir + "/shortcuts", 0o644), 0)
        try "#!/bin/sh\necho planted\n".write(toFile: guardDir + "/git", atomically: true, encoding: .utf8)
        ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel.path)
        for name in ["osascript", "shortcuts"] {
            let type = try fm.attributesOfItem(atPath: guardDir + "/" + name)[.type] as? FileAttributeType
            XCTAssertEqual(type, .typeRegular, name)
            XCTAssertTrue(fm.isExecutableFile(atPath: guardDir + "/" + name), name)
        }
        XCTAssertFalse(fm.fileExists(atPath: guardDir + "/git"), "a planted program stayed first on PATH")
        let fileGuard = home.appendingPathComponent("file-guard").path
        try "not a directory".write(toFile: fileGuard, atomically: true, encoding: .utf8)
        ShellAppleEvents.writeGuard(in: fileGuard, sentinel: sentinel.path)
        XCTAssertTrue(fm.isExecutableFile(atPath: fileGuard + "/open"), "a file at the guard path left no guard")
        let mode = try fm.attributesOfItem(atPath: fileGuard)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)

        // Eighth review: when the guard path is a symlink that cannot be removed (its
        // folder is read only), nothing the link points at may be cleaned or chmodded.
        let target = home.appendingPathComponent("someone-elses-folder")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "keep me".write(to: target.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let locked = home.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: locked.path + "/guard", withDestinationPath: target.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertFalse(ShellAppleEvents.writeGuard(in: locked.path + "/guard", sentinel: sentinel.path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("notes.txt").path), "a file outside the guard was deleted")
        // Ninth review: a guard that could not be made ours is left off PATH, not put first.
        XCTAssertEqual(ShellAppleEvents.prepend(nil, to: "/usr/bin:/bin"), "/usr/bin:/bin")
        XCTAssertEqual(ShellAppleEvents.prepend("/g", to: "/usr/bin"), "/g:/usr/bin")
        XCTAssertTrue(ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel.path))
        // Only a stub's own in-flight name is spared by the cleanup.
        try "#!/bin/sh\n".write(toFile: guardDir + "/planted.tmp", atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(toFile: guardDir + "/open.99999.tmp", atomically: true, encoding: .utf8)
        ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel.path)
        XCTAssertFalse(fm.fileExists(atPath: guardDir + "/planted.tmp"))
        XCTAssertTrue(fm.fileExists(atPath: guardDir + "/open.99999.tmp"))
        XCTAssertEqual(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(SwarmWorker.appOpeningPrograms, ShellAppleEvents.appOpeningPrograms,
                       "the agent sandbox and the shell doors guard the same programs")
    }

    // P3-W3b (operator note 9): a stub that could not be written was skipped and the guard
    // still reported usable, so that name reached the real program first on PATH.
    func testAGuardWithAStubThatCouldNotBeWrittenIsNotUsable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("guard-stub-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let guardDir = root.appendingPathComponent("guard").path
        let sentinel = root.appendingPathComponent("HEADLESS").path
        XCTAssertTrue(ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel))
        // `open`'s stub is gone and its temporary name (spared as another writer's) is a
        // directory, so the stub cannot be written this time.
        try fm.removeItem(atPath: guardDir + "/open")
        try fm.createDirectory(atPath: guardDir + "/open.\(getpid()).tmp", withIntermediateDirectories: false)
        XCTAssertFalse(ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel),
                       "the guard reported usable with no `open` stub in it")
        try fm.removeItem(atPath: guardDir + "/open.\(getpid()).tmp")
        XCTAssertTrue(ShellAppleEvents.writeGuard(in: guardDir, sentinel: sentinel))
        XCTAssertTrue(fm.isExecutableFile(atPath: guardDir + "/open"))
    }

    // P3-W3d: Grux's wiring puts the guard in Persistence.gruxDir, the suite's own folder.
    func testTheGuardFollowsGruxsOwnFolder() {
        _ = AudioOutput.wireShellDoors
        let dir = ShellAppleEvents.guardedPath("/usr/bin").components(separatedBy: ":")[0]
        XCTAssertEqual(dir, Persistence.gruxDir.appendingPathComponent("headless-guard").path)
        // Wave 5 review P3: a GruxShellCore default under test is a `Grux-tests-<pid>`
        // folder, the one Persistence sweeps once its process has ended.
        XCTAssertEqual(ShellAppleEvents.defaultGruxDirectory(underTest: true),
                       NSTemporaryDirectory() + "Grux-tests-\(getpid())/.grux")
    }

    /// Fifth review: an app's own executable opens it with no `open` and no Apple event.
    func testRunningAnAppsOwnExecutableIsRefused() {
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "/System/Applications/Calculator.app/Contents/MacOS/Calculator &", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(argv: ["/Applications/Safari.app/Contents/MacOS/Safari"], headless: true))
        XCTAssertNil(ShellAppleEvents.refusal(for: "ls /Applications/Safari.app/Contents/MacOS", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "time -p open x", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "env -S'open -a X'", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "env --split-string='open -a X'", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "<<< 'open -a X' bash", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "env -uSSH_AUTH_SOCK open -a Safari", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "/System/Applications/Calculator.APP/Contents/MacOS/Calculator", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "build/MyApp.app/Contents/MacOS/MyApp -NSDocumentRevisionsDebugMode YES", headless: true))
        // Seventh review: a redirection is not an argument, and the bundle's own executable
        // need not share its name.
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "/System/Applications/Calculator.app/Contents/MacOS/Calculator >/dev/null 2>&1 &", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "/System/Applications/Calculator.app/Contents/MacOS/Calculator > /tmp/log &", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "/Applications/LibreOffice.app/Contents/MacOS/soffice", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "env -S 'FOO=1' open -a Safari", headless: true))
        // The words after a split value are arguments, not more shell source.
        XCTAssertNil(ShellAppleEvents.refusal(for: "env -S 'grep -E' 'close|open' f", headless: true))
        XCTAssertNil(ShellAppleEvents.refusal(for: "env -S 'printf %s' 'hello; open later'", headless: true))
        XCTAssertNotNil(ShellAppleEvents.refusal(for: "echo 'open -a Safari' | env -S sh", headless: true))
        // A tool inside a bundle, run with its own arguments, opens no window.
        for tool in ["\"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\" --headless --dump-dom https://example.com",
                     "/Applications/LibreOffice.app/Contents/MacOS/soffice --headless --convert-to pdf x.docx",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale status",
                     "/Applications/Wireshark.app/Contents/MacOS/tshark -i en0"] {
            XCTAssertNil(ShellAppleEvents.refusal(for: tool, headless: true), tool)
        }
    }

    /// P1 (wave 3): `open_app` launched and activated another app in headless mode. The
    /// name matches no app, so a broken gate answers "no app matched" and launches nothing.
    @MainActor
    func testOpenAppInHeadlessModeRefusesBeforeLookingAnythingUp() async {
        WindowFacade.headlessUnderTest = true
        let result = await AppLauncherTool.open(name: "grux-test-no-such-app-\(UUID().uuidString.prefix(6))")
        XCTAssertTrue(result.hasPrefix("error: \(ForeignAppScript.refusalPrefix)"), result)
    }

    /// P2 (wave 3): headless mode surfaced as "grant Automation permission", sending a
    /// person after a permission that is not the cause. The Music tools got the same fix
    /// (headless is asked right after silent mode, so "unexpected Music result header: ''"
    /// is gone), but they are not called here: silent mode is checked first, and a test
    /// that lifted it around MusicTool could reach MusicKit, which plays in-process
    /// without any Apple Event for the headless gate to stop.
    @MainActor
    func testAToolThatScriptsAnotherAppSaysHeadlessInsteadOfAMisleadingError() async {
        WindowFacade.headlessUnderTest = true
        let results = [
            await TerminalGridTiler.spawnAndTile(rows: 2, cols: 2),
            await TerminalGridTiler.runInGridCell(row: 0, col: 0, command: "ls"),
            await WorkspacePreparer.makeCleanSlate(),
        ]
        for result in results {
            XCTAssertTrue(result.hasPrefix("error: \(ForeignAppScript.refusalPrefix)"), result)
        }
    }

    /// P2 (wave 3): the refusals on the incident path returned before `make`, so wake.log
    /// never said a model had asked for Chrome.
    @MainActor
    func testARefusalThatReturnsBeforeBuildingAScriptIsStillLogged() async {
        WindowFacade.headlessUnderTest = true
        _ = await BrowserTool.openURL("example.com")
        XCTAssertFalse(ForeignAppScript.firstRefusal(of: "BrowserTool.openURL"), "the refusal was never logged")
        _ = await AppleScriptRunner.run(source: "return 1")
        XCTAssertFalse(ForeignAppScript.firstRefusal(of: "AppleScriptRunner"), "the refusal was never logged")
    }

    /// Measured on the installed build: MusicWatcher ticks every 30 s, so a line per
    /// refusal would write the same sentence 2,880 times a day.
    func testEachCallerIsLoggedOnceALaunch() {
        let purpose = "test-\(UUID().uuidString)"
        XCTAssertTrue(ForeignAppScript.firstRefusal(of: purpose))
        XCTAssertFalse(ForeignAppScript.firstRefusal(of: purpose), "the same caller was logged twice")
        XCTAssertTrue(ForeignAppScript.firstRefusal(of: purpose + "-other"))
    }

    func testHeadlessRefusesEveryScriptAndSaysWhy() async throws {
        WindowFacade.headlessUnderTest = true
        guard case .refused = await ForeignAppScript.run("return 1", purpose: "test") else {
            return XCTFail("a script ran in headless mode")
        }
        guard case .refused = ForeignAppScript.runWaiting("return 1", purpose: "test") else {
            return XCTFail("a script ran in headless mode")
        }
        let why = try XCTUnwrap(ForeignAppScript.refusal())
        XCTAssertTrue(why.hasPrefix(ForeignAppScript.refusalPrefix), why)
        XCTAssertTrue(why.contains("~/.grux/HEADLESS"), why)

        // Built, never executed: compiling `return 1` sends nothing anywhere.
        WindowFacade.headlessUnderTest = false
        XCTAssertNil(ForeignAppScript.refusal())
        let ran = await ForeignAppScript.run("return 1", purpose: "test")
        XCTAssertEqual(ran.stringValue, "1")
    }
}

/// The tools a model calls refuse with a plain sentence instead of reaching Chrome.
/// Never run with headless off: these would script the real Chrome.
@MainActor
final class BrowserToolHeadlessTests: XCTestCase {

    func testABrowserToolInHeadlessModeRefusesBeforeScriptingChrome() async {
        WindowFacade.headlessUnderTest = true
        defer { WindowFacade.headlessUnderTest = nil }
        for result in [await BrowserTool.openURL("example.com"), await BrowserTool.searchWeb("two plus two")] {
            XCTAssertTrue(result.hasPrefix("error: \(ForeignAppScript.refusalPrefix)"), result)
        }
    }

    func testAMacroAppleScriptInHeadlessModeIsRefused() async {
        WindowFacade.headlessUnderTest = true
        defer { WindowFacade.headlessUnderTest = nil }
        let result = await AppleScriptRunner.run(source: "return \"hello\"")
        XCTAssertTrue(result.hasPrefix("error: \(ForeignAppScript.refusalPrefix)"), result)
    }

    func testPlayOnYouTubeInSilentModeIsRefusedAsSound() async {
        // A test run is always silent (AudioOutput.isSilent) and always headless here.
        WindowFacade.headlessUnderTest = true
        defer { WindowFacade.headlessUnderTest = nil }
        let result = await BrowserTool.playOnYouTube("two plus two")
        XCTAssertTrue(result.hasPrefix("error: silent mode is on"), result)
    }
}
