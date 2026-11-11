import XCTest
@testable import Grux
@testable import GruxShellCore

/// D187 item 4: Settings, Sessions said "Most sessions at once" over "The limit
/// is per swarm, not across all of them", and "Guarded (default) runs anything,
/// and asks first before a command reaches the network". Each caption is pinned
/// here to the code it describes, so a caption and its behaviour cannot drift.
@MainActor
final class SessionsPaneCaptionTruthTests: XCTestCase {

    /// The cap is applied to each job as it is planned (`AgentService.plannedJob`),
    /// so two jobs can each start that many. The label has to say per job.
    func testTheConcurrencyLabelSaysTheLimitIsPerJob() {
        let ceiling = SessionConcurrency.ceiling
        let a = AgentService.plannedJob(goal: "a", rootDir: "/tmp", maxParallelWorkers: 99)
        let b = AgentService.plannedJob(goal: "b", rootDir: "/tmp", maxParallelWorkers: 99)
        XCTAssertEqual(a.maxParallelWorkers, ceiling)
        XCTAssertEqual(b.maxParallelWorkers, ceiling, "the cap is per job, not shared across jobs")

        let label = TerminalSessionsSettingsView.concurrencyLabel
        XCTAssertFalse(label.lowercased().contains("at once"),
                       "\"at once\" reads as a cap across every job: \(label)")
        XCTAssertTrue(label.lowercased().contains("per agent job"), label)

        let caption = TerminalSessionsSettingsView.concurrencyCaption
        XCTAssertFalse(caption.lowercased().contains("swarm"), "the pane calls them agent jobs: \(caption)")
        XCTAssertTrue(caption.lowercased().contains("each"), caption)
    }

    /// Every mode's line says "asks first" for what that mode stops for a
    /// confirm, "refuses" when it refuses some of them, and "without asking"
    /// when it runs them unasked, naming each one it asks about. Measured on
    /// `ShellSafety.evaluate`, the gate every run goes through.
    func testEachTrustLineSaysWhatThatModeAsksAbout() {
        // W64-FIX P2-3: Strict judges only a command's first program, so each
        // one is also tried after a tool Strict allows ("git status && sudo ls"
        // asks in Strict) and as a deploy through an allowed tool.
        // W64-FIX round 2 P2-1: publishes, pushes and deploys through other
        // tools ran unasked under a line that promised a question.
        let alone = [("push", "git push origin main"), ("publish", "npm publish"),
                     ("deploy", "gh release create v1"), ("deploy", "npx vercel deploy --prod"), ("sudo", "sudo ls"),
                     ("publish", "yarn publish"), ("publish", "bun publish"), ("publish", "poetry publish"),
                     ("publish", "uv publish"), ("publish", "pnpm publish"), ("publish", "twine upload dist/*"),
                     ("publish", "gem push grux.gem"), ("push", "docker push org/img"),
                     ("push", "podman push org/img"), ("deploy", "fly deploy"), ("deploy", "make deploy"),
                     ("deploy", "npm run deploy"), ("deploy", "yarn run publish:prod"), ("sudo", "npm test;sudo ls"),
                     // W64-FIX round 3 P2-1: behind a flag, a clean step or a launcher.
                     ("publish", "python3 -m twine upload dist/*"), ("deploy", "mvn clean deploy"),
                     ("publish", "./gradlew clean publish"), ("publish", "pnpm -r publish"),
                     ("publish", "pnpm --filter x publish"), ("publish", "npx lerna publish"),
                     ("publish", "npx changeset publish"), ("publish", "yarn lerna publish"),
                     ("deploy", "npx cdk deploy"), ("push", "dotnet nuget push pkg.nupkg"),
                     ("push", "docker compose push"), ("deploy", "npm run --silent deploy"),
                     ("publish", "npm --workspace a publish")]
        let gated = alone + alone.map { ($0.0, "git status && " + $0.1) }
        for mode in ShellTrustCeiling.selectableModes {
            let line = TerminalSessionsSettingsView.trustExplanation(mode)
            var asked = false, refused = false, ran = false
            for (word, command) in gated {
                let verdict = ShellSafety.evaluate(command: command, rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: mode)
                switch verdict.decision {
                case .requiresConfirm:
                    asked = true
                    XCTAssertTrue(line.contains(word), "\(mode) asks before \(command) but its line does not name it: \(line)")
                case .blockedStrictAllowlist, .blockedOutsideRoot:
                    refused = true
                case .allow:
                    ran = true
                    XCTAssertTrue(line.contains(word), "\(mode) runs \(command) unasked but its line does not name it: \(line)")
                }
            }
            XCTAssertEqual(line.contains("asks first"), asked, "\(mode): \(line)")
            XCTAssertEqual(line.contains("refuses"), refused, "\(mode): \(line)")
            XCTAssertEqual(line.contains("without asking"), ran, "\(mode): \(line)")
        }
    }

    /// W64-FIX P2-3: "refuses every other program" was false in Strict: only a
    /// command's first program is checked, so another program later in the
    /// command runs. A line may claim a program is refused only where every
    /// place it can stand is refused.
    func testNoTrustLineClaimsToRefuseAProgramLaterInTheCommand() {
        for mode in ShellTrustCeiling.selectableModes {
            let line = TerminalSessionsSettingsView.trustExplanation(mode)
            let first = ShellSafety.evaluate(command: "ssh prod uptime", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: mode)
            let later = ShellSafety.evaluate(command: "npm test && ssh prod uptime", rootDir: "/tmp/r",
                                             currentCwd: "/tmp/r", mode: mode)
            if case .blockedStrictAllowlist = first.decision {
                XCTAssertEqual(later.decision, .allow, "the premise: Strict checks only the first program")
                XCTAssertTrue(line.contains("does not start with"), "\(mode) refuses by the first program: \(line)")
            }
            if later.decision == .allow {
                for claim in ["every other program", "runs only"] {
                    XCTAssertFalse(line.contains(claim), "\(mode) runs a second program unchecked: \(line)")
                }
            }
        }
    }

    /// A deploy hidden in a script under another name cannot be recognized,
    /// so the pane says so once under the lines; and the wider net does not
    /// stop reading or searching files that only mention a deploy.
    func testThePaneSaysWhatTheGateCannotRecognize() {
        // W64-FIX round 3: no list of commands is complete, so no line promises
        // one is. Each line that asks names what it recognizes, and the limit
        // says one it does not is never asked about (Strict refuses a script,
        // Guarded runs it): true in every mode.
        let limit = TerminalSessionsSettingsView.trustLimit
        XCTAssertTrue(limit.contains("not asked about in any mode"), limit)
        for mode in ShellTrustCeiling.selectableModes {
            let line = TerminalSessionsSettingsView.trustExplanation(mode)
            if line.contains("asks first") { XCTAssertTrue(line.contains("it recognizes"), "\(mode): \(line)") }
            let script = ShellSafety.evaluate(command: "./release.sh", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: mode)
            if case .requiresConfirm = script.decision { XCTFail("\(mode) asked before a script: the limit says it does not") }
        }
        for command in ["cat deploy.md", "grep -r publish docs", "ls deploy", "rg 'docker push' notes.txt",
                        "rm deploy", "diff deploy deploy.bak", "pytest deploy", "cargo run -- publish",
                        "npm run build", "make test", "swift build", "git checkout deploy", "python deploy_check.py"] {
            let verdict = ShellSafety.evaluate(command: command, rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: .guarded)
            XCTAssertEqual(verdict.decision, .allow, command)
        }
    }

    /// W64-FIX rounds 4 and 5: a hand-written list in the Strict line drifted
    /// both ways (it named "a development tool" while refusing Maven, then left
    /// out npx, pip and uv, which run). The line is built from the gate's own
    /// list, so every program it names runs in Strict and every program that
    /// runs is named; the limit names no tool, so it claims nothing per tool.
    func testTheStrictLineIsTheGatesOwnList() {
        let line = TerminalSessionsSettingsView.trustExplanation(.strict)
        let named = Set(line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        XCTAssertGreaterThan(ShellSafety.strictAllowedPrograms.count, 20)
        for program in ShellSafety.strictAllowedPrograms {
            XCTAssertTrue(named.contains(program), "Strict runs \(program) but its line does not name it: \(line)")
            let verdict = ShellSafety.evaluate(command: "\(program) --version", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: .strict)
            if case .blockedStrictAllowlist = verdict.decision { XCTFail("Strict refuses \(program), which its line lists") }
        }
        for program in ["mvn", "gradle", "docker", "twine", "curl", "ssh", "brew", "rm"] {
            let verdict = ShellSafety.evaluate(command: "\(program) --version", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: .strict)
            guard case .blockedStrictAllowlist = verdict.decision else { XCTFail("the premise: Strict refuses \(program)"); continue }
            XCTAssertFalse(named.contains(program), "Strict refuses \(program) but its line names it: \(line)")
        }
        let limit = TerminalSessionsSettingsView.trustLimit
        for tool in ["Maven", "Gradle", "Docker", "twine", "yarn"] {
            XCTAssertFalse(limit.contains(tool), "the limit names no tool: \(limit)")
        }
        XCTAssertTrue(limit.contains("another tool"), limit)
    }

    /// W64-FIX round 5 P2-1: a publish run through a project runner
    /// (`uv run twine upload`) ran unasked in Strict.
    func testAPublishThroughARunnerAsks() {
        for command in ["uv run twine upload dist/*", "uv run --with twine twine upload dist/*",
                        "poetry run twine upload dist/*", "pipx run twine upload dist/*"] {
            for mode in [ShellMode.strict, .guarded] {
                let verdict = ShellSafety.evaluate(command: command, rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: mode)
                switch verdict.decision {
                case .requiresConfirm, .blockedStrictAllowlist: break
                default: XCTFail("\(mode) ran \(command) unasked")
                }
            }
        }
        let check = ShellSafety.evaluate(command: "uv run twine check dist/*", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: .guarded)
        XCTAssertEqual(check.decision, .allow, "twine check sends nothing")
    }

    /// W64-FIX round 6 (P1): a `cd` inside the session's folder anywhere in a
    /// command returned allow at once and skipped every later check, so
    /// `cd packages/core && npm publish` ran unasked in Strict and Guarded.
    /// A cd inside the folder is noted and the rest of the command is still
    /// judged; a cd out of it is still refused, and a plain cd still runs.
    func testACdDoesNotSkipTheQuestion() {
        let root = "/tmp/r"
        for (mode, command) in [
            (ShellMode.guarded, "cd packages/core && npm publish"), (.guarded, "cd repo && git push origin main"),
            (.guarded, "cd app && sudo make install"), (.guarded, "cd frontend && vercel deploy --prod"),
            (.strict, "npm run build && cd dist && npm publish"),
            (.strict, "git add -A && git commit -m x && cd . && git push"),
            (.guarded, "npm publish; cd ."), (.strict, "npm publish; cd ."),
        ] {
            let verdict = ShellSafety.evaluate(command: command, rootDir: root, currentCwd: root, mode: mode)
            if case .requiresConfirm = verdict.decision {} else {
                XCTFail("\(mode) did not ask before \(command): \(verdict.decision)")
            }
        }
        let plain = ShellSafety.evaluate(command: "cd sub", rootDir: root, currentCwd: root, mode: .guarded)
        XCTAssertEqual(plain.decision, .allow)
        XCTAssertEqual(plain.detectedCdTarget, root + "/sub", "the cd target is still reported")
        let chained = ShellSafety.evaluate(command: "cd sub && npm test", rootDir: root, currentCwd: root, mode: .guarded)
        XCTAssertEqual(chained.decision, .allow)
        XCTAssertEqual(chained.detectedCdTarget, root + "/sub")
        let out = ShellSafety.evaluate(command: "cd / && npm publish", rootDir: root, currentCwd: root, mode: .guarded)
        if case .blockedOutsideRoot = out.decision {} else { XCTFail("a cd out of the folder is refused: \(out.decision)") }
    }

    /// `dotnet publish` builds a folder on this Mac; only `dotnet nuget push` sends anything out.
    func testADotnetBuildIsNotADeploy() {
        let build = ShellSafety.evaluate(command: "dotnet publish -c Release", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: .guarded)
        XCTAssertEqual(build.decision, .allow)
        let push = ShellSafety.evaluate(command: "dotnet nuget push pkg.nupkg", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: .guarded)
        if case .requiresConfirm = push.decision {} else { XCTFail("dotnet nuget push must ask: \(push.decision)") }
    }

    /// No mode runs everything (a cd out of the session's folder is refused in
    /// every mode), a plain download is not stopped in Guarded, so "the network"
    /// overclaims, and nothing checks that a person is at the keyboard.
    func testNoTrustLineClaimsWhatNoModeDoes() {
        let plainGet = ShellSafety.evaluate(command: "curl https://example.com", rootDir: "/tmp/r",
                                            currentCwd: "/tmp/r", mode: .guarded)
        XCTAssertEqual(plainGet.decision, .allow, "the premise: Guarded does not ask before a plain download")
        for mode in ShellTrustCeiling.selectableModes {
            let leave = ShellSafety.evaluate(command: "cd /", rootDir: "/tmp/r", currentCwd: "/tmp/r", mode: mode)
            XCTAssertNotEqual(leave.decision, .allow, "\(mode) let a session leave its folder")
            let line = TerminalSessionsSettingsView.trustExplanation(mode)
            XCTAssertFalse(line.contains("anything"), "\(mode): \(line)")
            XCTAssertFalse(line.contains("network"), "\(mode): \(line)")
            XCTAssertFalse(line.contains("keyboard"), "\(mode): \(line)")
        }
    }
}
