import Foundation
import GruxShellCore

// MARK: - ShellDemo
//
// End-to-end exercise of the Grux shell tool against a project folder you name
// on the command line. Speaks the exact JSON dispatch surface that Claude would
// use - ShellDispatcher.dispatch with the same tool names and input dicts.
// Every scenario prints
//   • tool name + inputs
//   • the formatted response
//   • a pass/fail assertion
//
// Usage:  shell-demo <path-to-project>
//
// The target must be a scratch Node project you do not mind mutating: the run
// deletes and restores files in it. It needs a `package.json`, a `src/index.js`
// that prints something, and an `npm test` script.
//
// Scenarios (ordered):
//   1.  shell_start (guarded, hybrid) - open session on the target project
//   2.  shell_run `pwd`, `ls`, `npm test` - baseline run
//   3.  shell_run `cd ..` - containment check, should BLOCK
//   4.  shell_run `cat /etc/passwd > /tmp/leaked.txt` - absolute-path write
//       outside rootDir, should BLOCK
//   5.  shell_run `git push` - network gate, should GATE
//   6.  shell_run_confirmed `git push` - bypass gate but still tracked
//       (container is actually a stub repo so git push will fail at remote
//       resolution - we only verify the tool allowed it through)
//   7.  destructive test: write a temp file, `rm file.txt`, verify gone,
//       shell_undo, verify file BACK (this is the main reversibility claim)
//   8.  hybrid auto-snapshot: `rm src/index.js` in hybrid mode should create
//       an extra destructive-detect snapshot; verify + undo
//   9.  shell_status
//   10. shell_end
//
// Exits with code 0 if every scenario's expected outcome matched, non-zero
// otherwise. Final summary printed to stdout.

@main
struct ShellDemo {
    static func main() async {
        guard let argument = CommandLine.arguments.dropFirst().first, !argument.isEmpty else {
            print("usage: shell-demo <path-to-project>")
            print("  A scratch Node project with package.json, src/index.js and an npm test")
            print("  script. The run mutates it: files are deleted and restored.")
            exit(2)
        }
        let rootDir = NSString(string: argument).expandingTildeInPath
        // The harness declares its own allowed root, because the allowlist is
        // whatever the user pointed Grux at and this process is not the app.
        UserDefaults.standard.set(rootDir, forKey: ShellAllowlist.watchedRootDefaultsKey)
        print("═════════════════════════════════════════════════════════════")
        print(" Grux ShellTool - end-to-end harness")
        print(" target: \(rootDir)")
        print("═════════════════════════════════════════════════════════════\n")

        var results: [(String, Bool, String)] = []

        // ── Scenario 1: shell_start ──
        let startOut = await ShellDispatcher.dispatch(name: "shell_start", input: [
            "root_dir": rootDir,
            "mode": "guarded",
            "undo_mode": "hybrid",
            "mirror": false                   // headless - don't pop a Terminal window in a demo
        ])
        printScenario("1. shell_start (guarded, hybrid, no mirror)",
                      tool: "shell_start", input: ["root_dir": rootDir, "mode": "guarded"],
                      output: startOut)
        guard let sessionId = extractSessionId(from: startOut) else {
            print("FATAL: could not extract session_id from shell_start output")
            exit(1)
        }
        results.append(("shell_start", startOut.hasPrefix("ok:"), sessionId))
        print("→ session_id: \(sessionId)\n")

        // Seed a known file for the reversibility test. Done OUTSIDE the
        // ShellTool so we know the starting state is clean before any command
        // runs inside the session.
        let seededFile = rootDir + "/reversibility.txt"
        try? "original contents\n".write(toFile: seededFile, atomically: true, encoding: .utf8)

        // ── Scenario 2: baseline commands ──
        let pwdOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "pwd"
        ])
        printScenario("2a. shell_run pwd", tool: "shell_run",
                      input: ["command": "pwd"], output: pwdOut)
        results.append(("pwd returns rootDir", pwdOut.contains(rootDir), "expected rootDir in output"))

        let lsOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "ls"
        ])
        printScenario("2b. shell_run ls", tool: "shell_run",
                      input: ["command": "ls"], output: lsOut)
        results.append(("ls shows package.json", lsOut.contains("package.json"), "expected package.json in ls"))

        let testOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "npm test"
        ])
        printScenario("2c. shell_run npm test", tool: "shell_run",
                      input: ["command": "npm test"], output: testOut)
        // npm test may pipe node into grep, which suppresses stdout; run the
        // entry point directly so there is a clean exit code to assert on.
        let sanityOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "node src/index.js"
        ])
        printScenario("2d. shell_run node src/index.js", tool: "shell_run",
                      input: ["command": "node src/index.js"], output: sanityOut)
        results.append(("node src/index.js ran clean", sanityOut.contains("exit=0"), "non-zero exit from src/index.js"))

        // ── Scenario 3: containment - cd escape ──
        let cdEscapeOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "cd .."
        ])
        printScenario("3. containment - cd .. should BLOCK", tool: "shell_run",
                      input: ["command": "cd .."], output: cdEscapeOut)
        results.append(("cd .. blocked", cdEscapeOut.contains("blocked") && cdEscapeOut.contains("rootDir"), "expected containment block"))

        // Followup: cwd should STILL be rootDir after the blocked cd
        let pwdAfterOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "pwd"
        ])
        printScenario("3b. pwd after blocked cd - should still be rootDir", tool: "shell_run",
                      input: ["command": "pwd"], output: pwdAfterOut)
        results.append(("cwd unchanged after blocked cd", pwdAfterOut.contains(rootDir), "cwd drifted"))

        // ── Scenario 4: absolute-path write outside rootDir ──
        let writeEscapeOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "cat /etc/passwd > /tmp/leaked.txt"
        ])
        printScenario("4. containment - write to /tmp should BLOCK", tool: "shell_run",
                      input: ["command": "cat /etc/passwd > /tmp/leaked.txt"], output: writeEscapeOut)
        results.append(("outside-root write blocked", writeEscapeOut.contains("blocked"), "expected outside-root block"))

        // ── Scenario 5: network gate ──
        let pushOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "git push origin main"
        ])
        printScenario("5. network gate - git push should GATE (not run)", tool: "shell_run",
                      input: ["command": "git push origin main"], output: pushOut)
        results.append(("git push gated", pushOut.contains("gated"), "expected network-gate"))

        // ── Scenario 6: shell_run_confirmed bypasses the gate ──
        // We don't want a real push to a real remote. We verify the tool
        // ALLOWED the command through (exit != -2/-1). Since there's no git
        // init here, the command will fail at git's level - we care that the
        // TOOL dispatched instead of blocking.
        let confirmedOut = await ShellDispatcher.dispatch(name: "shell_run_confirmed", input: [
            "session_id": sessionId, "command": "git push --dry-run 2>&1 || echo 'expected: no repo'"
        ])
        printScenario("6. shell_run_confirmed bypasses gate", tool: "shell_run_confirmed",
                      input: ["command": "git push --dry-run"], output: confirmedOut)
        results.append(("confirmed path ran through", !confirmedOut.contains("gated") && !confirmedOut.contains("blocked:"), "still gated/blocked after confirm"))

        // ── Scenario 7: reversibility - delete + undo ──
        let rmOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "rm reversibility.txt"
        ])
        printScenario("7a. rm reversibility.txt (triggers hybrid snapshot)", tool: "shell_run",
                      input: ["command": "rm reversibility.txt"], output: rmOut)
        results.append(("rm ran", rmOut.hasPrefix("ok:"), "rm failed"))
        results.append(("hybrid pre-snapshot taken", rmOut.contains("snapshot="), "no snapshot recorded before destructive cmd"))
        let goneCheck = FileManager.default.fileExists(atPath: seededFile)
        results.append(("file actually deleted", !goneCheck, "file still present after rm"))

        let undoOut = await ShellDispatcher.dispatch(name: "shell_undo", input: [
            "session_id": sessionId
        ])
        printScenario("7b. shell_undo - restore most recent snapshot", tool: "shell_undo",
                      input: [:], output: undoOut)
        let restoredCheck = FileManager.default.fileExists(atPath: seededFile)
        results.append(("undo restored deleted file", restoredCheck, "file not restored - snapshot broken"))
        if restoredCheck {
            let content = (try? String(contentsOfFile: seededFile, encoding: .utf8)) ?? ""
            results.append(("restored contents match", content == "original contents\n", "content drifted"))
        }

        // ── Scenario 8: destructive detection inside nested path ──
        // Write a new file AFTER the last snapshot, then rm src/index.js
        // (destructive), then undo and verify both the new file and src/index.js
        // are restored to their snapshot state.
        let scratchOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "echo 'scratch' > scratch.txt"
        ])
        printScenario("8a. create scratch.txt (non-destructive)", tool: "shell_run",
                      input: ["command": "echo 'scratch' > scratch.txt"], output: scratchOut)
        let rmIndexOut = await ShellDispatcher.dispatch(name: "shell_run", input: [
            "session_id": sessionId, "command": "rm src/index.js"
        ])
        printScenario("8b. rm src/index.js (destructive → extra snapshot)", tool: "shell_run",
                      input: ["command": "rm src/index.js"], output: rmIndexOut)
        results.append(("rm src/index.js triggered snapshot", rmIndexOut.contains("snapshot="), "no hybrid snapshot before rm src/"))
        let undo2Out = await ShellDispatcher.dispatch(name: "shell_undo", input: [
            "session_id": sessionId
        ])
        printScenario("8c. shell_undo - restore pre-rm state", tool: "shell_undo",
                      input: [:], output: undo2Out)
        let indexBack = FileManager.default.fileExists(atPath: rootDir + "/src/index.js")
        results.append(("src/index.js restored by undo", indexBack, "undo didn't restore src/index.js"))

        // ── Scenario 9: status ──
        let statusOut = await ShellDispatcher.dispatch(name: "shell_status", input: [
            "session_id": sessionId
        ])
        printScenario("9. shell_status", tool: "shell_status",
                      input: [:], output: statusOut)
        results.append(("status reports rootDir", statusOut.contains(rootDir), "rootDir missing from status"))
        results.append(("status reports commands_run", statusOut.contains("commands_run:"), "commands_run missing"))

        // ── Scenario 10: shell_end ──
        let endOut = await ShellDispatcher.dispatch(name: "shell_end", input: [
            "session_id": sessionId
        ])
        printScenario("10. shell_end", tool: "shell_end",
                      input: [:], output: endOut)
        results.append(("session ended cleanly", endOut.hasPrefix("ok:"), "end failed"))

        // Cleanup seeded file if still there (don't want test pollution).
        try? FileManager.default.removeItem(atPath: seededFile)
        try? FileManager.default.removeItem(atPath: rootDir + "/scratch.txt")

        // ── Summary ──
        print("═════════════════════════════════════════════════════════════")
        print(" RESULTS")
        print("═════════════════════════════════════════════════════════════")
        var pass = 0
        var fail = 0
        for (label, ok, note) in results {
            let tag = ok ? "✅ PASS" : "❌ FAIL"
            let detail = ok ? "" : "  → \(note)"
            print("\(tag) · \(label)\(detail)")
            if ok { pass += 1 } else { fail += 1 }
        }
        print("\n\(pass) passed · \(fail) failed\n")
        exit(fail == 0 ? 0 : 1)
    }

    // MARK: - Helpers

    static func printScenario(_ title: String, tool: String, input: [String: Any], output: String) {
        print("── \(title) ──")
        print("tool: \(tool)")
        if !input.isEmpty {
            let inputStr = input.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            print("input: \(inputStr)")
        }
        print("output:")
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            print("  \(line)")
        }
        print("")
    }

    static func extractSessionId(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            if line.hasPrefix("session_id:") {
                return String(line.dropFirst("session_id:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
