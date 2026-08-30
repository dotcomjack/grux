import XCTest
@testable import GruxSetupCore

/// Invariants that hold across the WHOLE command surface, checked as source.
///
/// ## Why these are source scans rather than behaviour tests
///
/// Each of these is a property of all forty five commands at once, and the thing that goes
/// wrong is one command being written without it. A behaviour test proves one command; a
/// scan proves the set, and the set is what the contract is about. Every one of them
/// carries a positive control, because a scan that matches nothing agrees with everything.
///
/// Every invariant below was a REAL DEFECT found by running the shipped binary, not by
/// reasoning about it. They are here so the next person to add a command cannot reintroduce
/// one silently.
final class CLISurfaceInvariantTests: XCTestCase {

    private static var cliRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GruxCLI")
    }

    /// Every command file, with comment lines removed so prose cannot trip a scan.
    private func commandSources() throws -> [(name: String, code: String)] {
        let dir = Self.cliRoot.appendingPathComponent("Commands")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { name in
            let raw = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return (name, code)
        }
    }

    /// One command's declaration block: from `struct X: ParsableCommand {` to the next one.
    private func structs(in code: String) -> [(type: String, body: String)] {
        var out: [(String, String)] = []
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var starts: [Int] = []
        for (i, l) in lines.enumerated() where l.hasPrefix("struct ") && l.contains(": ParsableCommand {") {
            starts.append(i)
        }
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : lines.count
            let type = lines[s].dropFirst("struct ".count).prefix { $0 != ":" }
            out.append((String(type), lines[s..<end].joined(separator: "\n")))
        }
        return out
    }

    // MARK: - --no-input everywhere

    /// EVERY command accepts `--no-input`, and it means one thing on all of them.
    ///
    /// Measured on the shipped binary before this held: seven commands declared the flag and
    /// thirty eight answered `Unknown option '--no-input'` with exit 64, on a surface whose
    /// documented codes are 0, 1, 2 and 3. An agent driving forty five commands should not
    /// have to know which seven take it.
    func testEveryCommandAcceptsNoInput() throws {
        let files = try commandSources()
        XCTAssertGreaterThan(files.count, 20,
            "read \(files.count) command files, so this scan proves nothing")

        var checked = 0
        var missing: [String] = []
        for (name, code) in files {
            for (type, body) in structs(in: code) {
                checked += 1
                let declares = body.contains("var noInput")
                let composes = body.contains("@OptionGroup var input: InputPolicy")
                if !declares && !composes { missing.append("\(name):\(type)") }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 40,
            "found \(checked) command declarations, so the parse missed most of them")
        XCTAssertEqual(missing, [],
            "these commands take no --no-input, so an agent passing it uniformly gets "
            + "exit 64 from them: \(missing.joined(separator: ", ")). Add "
            + "`@OptionGroup var input: InputPolicy`.")
    }

    /// The flag has to GATE, not merely parse.
    ///
    /// A command that prompts behind `RawMode.isSupported` alone parses `--no-input`, ignores
    /// it, and then prompts anyway on a real terminal, which is worse than not offering the
    /// flag at all. Both halves live in `InputPolicy.canAsk` so neither can be forgotten.
    func testEveryPromptIsGatedByBothHalves() throws {
        var offenders: [String] = []
        var prompting = 0
        for (name, code) in try commandSources() {
            for (type, body) in structs(in: code) {
                // WHAT A PROMPTING COMMAND LOOKS LIKE NOW. It used to be a bare `readLine()`
                // and there are none left: every question goes through `InputPolicy.ask`,
                // which is where it learned to reach the person rather than the redirect.
                // This test's own positive control caught the change, which is what a
                // control is for: the scan found one prompting command where there are
                // eleven and said so instead of passing on an empty set.
                guard body.contains("InputPolicy.ask(") || body.contains("SecretPrompt.read")
                else { continue }
                prompting += 1
                // Either the shared policy, or a local flag combined with the terminal check.
                let ok = body.contains("input.canAsk")
                    || (body.contains("noInput") && body.contains("RawMode.isSupported"))
                if !ok { offenders.append("\(name):\(type)") }
            }
        }
        XCTAssertGreaterThanOrEqual(prompting, 8,
            "found \(prompting) prompting commands, so this scan is not seeing them")
        XCTAssertEqual(offenders, [],
            "these prompt without checking BOTH --no-input and whether a terminal is "
            + "attached, so they can hang or can ignore the flag: "
            + "\(offenders.joined(separator: ", "))")
    }

    // MARK: - Exit codes

    /// No command leans on ArgumentParser's own missing-argument exit.
    ///
    /// A non-optional `@Argument` makes ArgumentParser exit 64 (EX_USAGE) when it is omitted.
    /// This surface documents 0, 1, 2 and 3, and eight commands did exactly that until it was
    /// found by running them: enable, disable, which, why, completion, disconnect, import and
    /// watch. An optional argument plus a designed empty state at exit 1 is the shape.
    func testNoCommandRequiresAnArgumentAtTheParserLevel() throws {
        var required: [String] = []
        var arguments = 0
        for (name, code) in try commandSources() {
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, line) in lines.enumerated() where line.contains("@Argument") {
                // The declaration is on this line or the next one.
                let decl = line.contains(" var ") ? line
                    : (i + 1 < lines.count ? lines[i + 1] : "")
                guard let varAt = decl.range(of: " var ") else { continue }
                arguments += 1
                let after = decl[varAt.upperBound...]
                guard let colon = after.range(of: ": ") else { continue }
                let type = after[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                // Optional, or defaulted, or a collection: all three are satisfiable by
                // omission. Anything else is a required positional.
                let satisfiable = type.contains("?") || type.contains("=")
                    || type.hasPrefix("[")
                if !satisfiable {
                    required.append("\(name): var\(after.prefix(while: { $0 != "=" }))")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(arguments, 15,
            "parsed \(arguments) @Argument declarations, so the scan is not seeing them")
        XCTAssertEqual(required, [],
            "these declare a required positional, so omitting it exits 64 rather than 1: "
            + "\(required.joined(separator: ", "))")
    }

    // MARK: - The rail

    /// Every command prints the rail, including the ones with a single beat to run.
    ///
    /// `grux serve` is the one deliberate exception and it is asserted AS an exception rather
    /// than skipped, because stdout there is the JSON-RPC wire and a rail on it is a corrupt
    /// frame. It prints its rail to stderr instead.
    ///
    /// WHAT THIS CANNOT SEE, said plainly rather than implied: it is a text scan, so it
    /// catches a command with no rail at all and NOT a rail that is present and unreachable.
    /// Proven by planting both ways: deleting the calls from a command fails this, and
    /// wrapping them in `if false` does not. The first is the mistake somebody actually
    /// makes when adding a command, which is what this is for; the second would need
    /// somebody to go out of their way.
    func testEveryCommandOpensTheRail() throws {
        var silent: [String] = []
        var seen = 0
        for (name, code) in try commandSources() {
            for (type, body) in structs(in: code) {
                seen += 1
                // THE STRUCT, OR THE FILE. `grux enable` and `grux disable` are the same
                // operation with a different boolean and share one private function, so the
                // rail is opened outside either struct's body. Falling back to the file is
                // the weaker check and it is the honest one: a scan that called Toggle
                // rail-less would be wrong about working code, which is how a guard gets
                // deleted instead of fixed. The gap it leaves is a rail-less struct sharing
                // a file with a railed one, and the asserted exception set below still
                // catches any new command that arrives in a file of its own.
                if body.contains("frame.open(") || code.contains("frame.open(") { continue }
                silent.append("\(name):\(type)")
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 40, "parsed \(seen) commands, so this proves nothing")
        // FOUR EXCEPTIONS, EACH FOR THE SAME REASON: their stdout is not a screen.
        // Completion writes a shell script that gets redirected into a file. Serve writes
        // JSON-RPC frames and a rail among them is a corrupt frame. Handoff writes a prompt
        // that goes straight into somebody's clipboard and then into an agent. Which writes
        // ONE line for a script to grep, and its exit code carries the answer.
        //
        // The set is asserted rather than skipped so that adding a fifth is a decision.
        // Version and both halves of Toggle were in this list until running them showed the
        // omission was an oversight rather than a design.
        XCTAssertEqual(Set(silent), ["Completion.swift:Completion", "Serve.swift:Serve",
                                     "Handoff.swift:Handoff", "Which.swift:Which"],
            "the set of commands that print no rail changed. Every command prints it, and "
            + "the only exceptions are the four whose stdout is not a screen. Found: "
            + "\(silent.sorted().joined(separator: ", "))")

        let serve = try commandSources().first { $0.name == "Serve.swift" }?.code ?? ""
        // STDERR_FILENO with write(2), not FileHandle.standardError: there is no buffer to
        // forget to flush. Scanning for the FileHandle spelling reported this as missing
        // when it was right there, which is a check being wrong about working code.
        XCTAssertTrue(serve.contains("STDERR_FILENO"),
            "grux serve prints no rail and writes nothing to stderr either, so it has simply "
            + "lost its rail rather than moved it off the wire")
    }

    // MARK: - Where a question goes

    /// A question reaches the PERSON, never a redirect.
    ///
    /// Every confirmation printed its question with `print`, which writes to stdout, so with
    /// stdout redirected and stdin still a terminal the question went into the file and the
    /// person was prompted blind. Measured on the shipped binary:
    ///
    ///     printf 'no\n' | script -q /dev/null sh -c 'grux import x.json > out.txt'
    ///
    /// The terminal showed the typed `no` and nothing else; the question and the token to
    /// type were both in out.txt. Anything other than the token takes the "Left everything
    /// alone" path and exits 0, so somebody who cannot see the question answers wrong and
    /// reads it as success.
    ///
    /// `InputPolicy.ask` is the only door, and this holds it shut: no command may write a
    /// prompt to stdout by hand or call `readLine` itself.
    func testEveryQuestionGoesThroughTheOneDoor() throws {
        let files = try commandSources()
        var rawReads: [String] = []
        var rawCursors: [String] = []
        var asks = 0
        for (name, code) in files {
            if code.contains("readLine()") { rawReads.append(name) }
            // The cursor written straight to stdout is the exact shape that was invisible.
            if code.contains("standardOutput.write(Data(\"  > ") { rawCursors.append(name) }
            asks += code.components(separatedBy: "InputPolicy.ask(").count - 1
        }
        // THE POSITIVE CONTROL. With no call sites at all the two assertions below are
        // vacuous, and this command surface really does ask eleven questions.
        XCTAssertGreaterThanOrEqual(asks, 11,
            "found \(asks) calls to InputPolicy.ask, so either the prompts moved somewhere "
            + "this cannot see or the scan is broken")

        XCTAssertEqual(rawReads, [],
            "these read a line themselves instead of going through InputPolicy.ask, so their "
            + "question is written by whatever printed it and can land in a redirect: "
            + "\(rawReads.joined(separator: ", "))")
        XCTAssertEqual(rawCursors, [],
            "these write a prompt cursor straight to stdout, which is the byte the person "
            + "saw while the question itself went into their log file: "
            + "\(rawCursors.joined(separator: ", "))")

        // AND THE CALL HAS TO CARRY THE QUESTION. `InputPolicy.ask([""])` sends a cursor and
        // nothing else, which is the same failure wearing the fix: `grux add project` passed
        // an empty line while printing its question to stdout, so with stdout redirected the
        // terminal showed a blank line and `  > `. A question left behind on stdout is a
        // question the person cannot read.
        var mute: [String] = []
        for (name, code) in files where code.contains("InputPolicy.ask([\"\"])") {
            mute.append(name)
        }
        XCTAssertEqual(mute, [],
            "these ask with no question in the call, so the cursor reaches the person and "
            + "the question does not: \(mute.joined(separator: ", "))")
    }

    /// And the door itself does the two things that make it work.
    func testTheDoorFlushesAndLeavesStdoutWhenNobodyIsWatchingIt() throws {
        let policy = try String(
            contentsOf: Self.cliRoot.appendingPathComponent("InputPolicy.swift"),
            encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(policy.contains("fflush(stdout)"),
            "the question is written with write(2) while the screen above it is buffered, so "
            + "without a flush first the question overtakes the screen it belongs under and "
            + "a log records the answer before the thing it answered")
        XCTAssertTrue(policy.contains("isatty(STDOUT_FILENO)"),
            "nothing asks whether stdout is a terminal, so the question goes to stdout "
            + "whatever stdout turned out to be")
        XCTAssertTrue(policy.contains("/dev/tty"),
            "with stdout redirected there is no fallback to the person's actual terminal, "
            + "which is the whole defect: line buffering stdout fixes the ORDER inside the "
            + "file and leaves the question in the file")
    }

    // MARK: - What may leave the machine

    /// The support bundle carries a log because somebody read it, never because it is a log.
    ///
    /// The first version took all three of `Logs.sources` on the reasoning that a log is
    /// diagnostics. `wake.log` is not: Grux writes what it HEARS into it, so it carries
    /// `ambient chunk:` and `ambient (focus): -> chat:` lines holding verbatim speech picked
    /// up in the room. Measured on the machine this was found on: 2.1 MB of wake.log with
    /// transcript lines through the middle, while the command printed "Never in it, and
    /// never read: ... anything from your notes, chat threads, meetings, journal or ambient
    /// captures."
    ///
    /// The promise is a CONSTRUCTION, not a filter: filtering the transcript lines back out
    /// would be a blocklist, and a blocklist is exactly what the command refuses to be. So
    /// the guard is that the set of logs it may carry is written down, and short.
    ///
    /// WHAT THIS CANNOT SEE, said plainly: it reads the allowlist, not the bytes of a
    /// bundle. It catches a fourth log being waved through and it does not catch
    /// security-audit.log one day starting to carry speech. The defence against that is that
    /// adding a key here is a decision somebody has to write down.
    func testTheSupportBundleCarriesOnlyLogsSomebodyRead() throws {
        let files = try commandSources()
        guard let bundle = files.first(where: { $0.name == "SupportBundle.swift" })?.code else {
            return XCTFail("SupportBundle.swift is gone, so this proves nothing")
        }
        guard let logs = files.first(where: { $0.name == "Logs.swift" })?.code else {
            return XCTFail("Logs.swift is gone, so this proves nothing")
        }

        // Every log key the product names.
        var named: Set<String> = []
        var rest = Substring(logs)
        while let at = rest.range(of: "Source(key: \"") {
            let after = rest[at.upperBound...]
            named.insert(String(after.prefix { $0 != "\"" }))
            rest = after
        }
        XCTAssertGreaterThanOrEqual(named.count, 3,
            "parsed \(named.count) log sources, so this scan is not seeing them")
        XCTAssertTrue(named.contains("app"),
            "the wake log lost its key, so the exclusion below may be excluding nothing")

        // The allowlist the bundle actually iterates.
        guard let decl = bundle.range(of: "static let included: Set<String> = [") else {
            return XCTFail("grux support-bundle no longer names the logs it may carry, so it "
                + "is back to trusting the category rather than the file")
        }
        let listed = bundle[decl.upperBound...].prefix { $0 != "]" }
        var allowed: Set<String> = []
        var scan = Substring(listed)
        while let q = scan.range(of: "\"") {
            let after = scan[q.upperBound...]
            allowed.insert(String(after.prefix { $0 != "\"" }))
            scan = after.drop { $0 != "\"" }.dropFirst()
        }

        XCTAssertFalse(allowed.contains("app"),
            "the support bundle carries wake.log again. Grux writes what it hears into that "
            + "file, so it holds speech picked up in the room, and this command promises in "
            + "its own output that nothing from the ambient captures is in it.")
        XCTAssertEqual(allowed, ["security", "files"],
            "the set of logs the support bundle may carry changed to "
            + "\(allowed.sorted().joined(separator: ", ")). Each one is a file somebody read "
            + "and established is diagnostics, and adding one is that decision.")

        // THE POSITIVE CONTROL. If the allowlist ever equals the full set of named sources,
        // it has stopped filtering and both assertions above would be vacuous.
        XCTAssertNotEqual(allowed, named,
            "the allowlist now names every log there is, so it is not an allowlist")

        // And the loop is actually filtered by it, rather than the list sitting there unused.
        XCTAssertTrue(bundle.contains("where Self.included.contains(source.key)"),
            "the allowlist exists and the loop over Logs.sources does not use it")
    }

    // MARK: - The renderer's own grid

    /// A row fits inside the terminal it is drawn in, and stays whole in a pipe.
    ///
    /// Measured on the shipped binary at 80 columns: `grux support-bundle --dry-run` printed
    /// a 106 character row while its neighbour landed at exactly 100, so two adjacent rows
    /// wrapped differently and the column stopped reading as a column.
    func testARowFitsTheTerminalAndAPipeKeepsItWhole() {
        let long = String(repeating: "x", count: 200)

        let tty = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 80))
        let drawn = tty.row(state: .satisfied, label: "wake.log", detail: long,
                            labelWidth: 20, indent: 2)
        XCTAssertLessThanOrEqual(drawn.count, 80,
            "a row drew \(drawn.count) characters into an 80 column terminal")
        XCTAssertTrue(drawn.hasSuffix("\u{2026}"), "a clipped row does not say it was clipped")

        // THE CONTROL. Without this the assertion above passes on a renderer that drops the
        // detail column entirely, which is a different bug wearing the same green tick.
        XCTAssertTrue(drawn.contains("xxxx"), "the detail was dropped rather than clipped")

        let piped = Renderer(style: TerminalStyle(isTTY: false, colour: false, width: 80))
        let whole = piped.row(state: .satisfied, label: "wake.log", detail: long,
                              labelWidth: 20, indent: 2)
        XCTAssertTrue(whole.contains(long),
            "a pipe truncated a value. A detail is data, a machine is reading, and there is "
            + "no width to fit")

        // WHEN THE DETAIL IS THE ANSWER, a narrow terminal STACKS it rather than dropping it.
        // Below 60 columns the grid drops the detail column, which is right for a capability
        // id sitting beside a label that already said everything and wrong for a path:
        // `grux transcribe --out` printed "Written" and "Words" with no path and no number,
        // and `grux meeting stop` printed six labels and no values, including the row that
        // says whether it heard anything at all.
        let tight = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 44))
        let kept = tight.row(state: .satisfied, label: "Written",
                             detail: "/tmp/a/very/long/path/transcript.txt",
                             labelWidth: 7, indent: 2, detailIsTheAnswer: true)
        XCTAssertTrue(kept.contains("transcript.txt"),
            "a narrow terminal dropped the one thing the command was run to produce")
        XCTAssertTrue(kept.contains("\n"),
            "the detail was appended rather than stacked, so it runs off a 44 column screen")
        for line in kept.split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.count, 44,
                "a stacked line is still \(line.count) characters wide")
        }
        // THE CONTROL. Without the flag the same row still drops its detail, which is what
        // makes the flag mean something rather than being always on.
        let dropped = tight.row(state: .satisfied, label: "Microphone",
                                detail: "perm.microphone", labelWidth: 12, indent: 2)
        XCTAssertFalse(dropped.contains("perm.microphone"),
            "a machine id is still drawn on a narrow terminal, so detailIsTheAnswer is not "
            + "distinguishing anything")

        // A narrow terminal has no room for a detail column at all, and an ellipsis standing
        // in for it would be decoration pretending to be information.
        let narrow = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 40))
        let cramped = narrow.row(state: .satisfied, label: "wake.log", detail: long,
                                 labelWidth: 20, indent: 2)
        XCTAssertFalse(cramped.contains("x"),
            "a 40 column terminal drew a detail column it has no room for")
        XCTAssertLessThanOrEqual(cramped.count, 40, "a narrow row still overflowed")
    }

    // MARK: - The handoff scope other commands offer

    /// A scope line stays a runnable command however long it gets.
    ///
    /// `grux why key.anthropic` scopes to fifteen features and printed a 150 character line
    /// into an 80 column terminal. This line exists to be PASTED, so clipping it would be
    /// worse than letting it run off the edge: a clipped command is not a command. It wraps
    /// on a trailing backslash, which continues a command in every shell this ships to.
    func testAHandoffScopeStaysRunnableHoweverLongItIs() {
        let long = "grux handoff " + (1...20).map { "feature.number.\($0)" }
            .joined(separator: " ")
        let lines = Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 76)).wrapCommand(long, width: 76)

        XCTAssertGreaterThan(lines.count, 1, "a 300 character command came back on one line")
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 76,
                "a wrapped line is still \(line.count) characters wide")
        }
        for line in lines.dropLast() {
            XCTAssertTrue(line.hasSuffix(" \\"),
                "a continued line does not end in a backslash, so pasting it runs a "
                + "truncated command: \(line)")
        }
        XCTAssertFalse(lines[lines.count - 1].hasSuffix("\\"),
            "the last line continues into nothing, so the shell waits for more input")

        // THE CONTROL, AND IT IS THE POINT. Reassembled, it has to be the same command:
        // wrapping that loses or reorders a word produces a prompt about the wrong features.
        let rejoined = lines.map {
            $0.hasSuffix(" \\") ? String($0.dropLast(2)) : $0
        }.joined(separator: " ").split(separator: " ").joined(separator: " ")
        XCTAssertEqual(rejoined, long, "the wrapped command does not reassemble to itself")

        // Short enough already is left exactly alone.
        XCTAssertEqual(Renderer(style: TerminalStyle(isTTY: true, colour: false, width: 76)).wrapCommand("grux handoff chat", width: 76),
                       ["grux handoff chat"])
    }

    // MARK: - The bridge's deadline

    /// `grux serve` waits at least as long as the slowest tool it carries.
    ///
    /// It waited 120 seconds while `grux transcribe` allows 1800 and `grux run` allows 300,
    /// so a client calling `grux_transcribe` through the bridge got a timeout while the app
    /// was still working and a real answer was reported as a failure. A bridge must not
    /// impose a deadline shorter than the work: it carries messages closed, so it cannot
    /// know which method is slow, which leaves the ceiling of the slowest as the only honest
    /// choice.
    ///
    /// This is the enforcement, so adding a slower command is caught rather than remembered.
    func testTheBridgeOutwaitsEveryToolItCarries() throws {
        var longest = 0.0
        var owner = ""
        var found = 0
        var serve = 0.0
        for (name, code) in try commandSources() {
            var rest = Substring(code)
            while let at = rest.range(of: "ControlClient(timeout: ") {
                let after = rest[at.upperBound...]
                let token = after.prefix { $0.isNumber || $0 == "." }
                rest = after
                guard let seconds = Double(token) else { continue }   // a named constant
                found += 1
                if name == "Serve.swift" { continue }
                if seconds > longest { longest = seconds; owner = name }
            }
            // The two that use a named constant, read from the constant itself.
            for (file, needle) in [("Serve.swift", "static let deadline: TimeInterval = "),
                                   ("Transcribe.swift", "static let deadline: TimeInterval = "),
                                   ("Ask.swift", "static let waitSeconds: TimeInterval = ")]
            where name == file {
                guard let at = code.range(of: needle) else { continue }
                let token = code[at.upperBound...].prefix { $0.isNumber || $0 == "." }
                guard let seconds = Double(token) else { continue }
                found += 1
                if file == "Serve.swift" { serve = seconds }
                else if seconds > longest { longest = seconds; owner = file }
            }
        }
        // THE POSITIVE CONTROL, twice over: a scan that finds no timeouts, or no serve
        // deadline, would pass this vacuously.
        XCTAssertGreaterThanOrEqual(found, 10,
            "parsed \(found) client timeouts out of the command surface, so the shape moved")
        XCTAssertGreaterThan(serve, 0, "grux serve no longer names a deadline this can read")
        XCTAssertGreaterThan(longest, 0, "no other command names a timeout, so this is vacuous")

        XCTAssertGreaterThanOrEqual(serve, longest,
            "grux serve waits \(Int(serve))s and \(owner) allows \(Int(longest))s, so a "
            + "client calling that tool through the bridge is told it failed while the app "
            + "is still working on it")
    }
}
