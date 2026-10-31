import Foundation

/// GruxShellCore's half of Grux's Apple Events gate (`ForeignAppScript`): the shell doors
/// and the one GruxShellCore feature that opens another app (the Simulator) ask here.
///
/// In headless mode (`~/.grux/HEADLESS`) the Mac's screen belongs to someone else, so
/// nothing may script another app or open one: either can bring that app forward or
/// raise a macOS permission prompt nobody will answer. ForeignAppScriptTests fails on any
/// `osascript` or `/usr/bin/open` launched outside this file and `ForeignAppScript`.
public enum ShellAppleEvents {
    /// Every refusal starts with this, so a reader (and the CLI) can tell it from the
    /// other gates.
    public static let refusalPrefix = "refused: headless mode is on"

    /// Why no Apple Event may go to another app now, or nil. Grux points it at
    /// `ForeignAppScript.refusal` at launch; the default reads the headless sentinel
    /// itself, so a door used before (or without) that wiring still holds.
    nonisolated(unsafe) public static var refusal: () -> String? = {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.grux/HEADLESS") ? sentence : nil
    }

    /// Told about each refusal (who asked, the sentence). Grux writes it to wake.log once
    /// a launch per caller.
    nonisolated(unsafe) public static var onRefused: (String, String) -> Void = { _, _ in }

    static let sentence = "\(refusalPrefix) (~/.grux/HEADLESS), so Grux will not script another app"

    /// `refusal()`, told to `onRefused` when it says no.
    public static func refuse(_ purpose: String) -> String? {
        guard let why = refusal() else { return nil }
        onRefused(purpose, why)
        return why
    }

    /// The reason to refuse a shell `command`, or nil when it may run: in headless mode a
    /// command that scripts or opens another app (`osascript`, `open`, `shortcuts`,
    /// `automator`, directly, behind a wrapper, or inside `sh -c`).
    public static func refusal(for command: String, headless: Bool? = nil) -> String? {
        guard let program = ForeignAppCommand.program(in: command) else { return nil }
        let why: String?
        if let headless { why = headless ? sentence : nil } else { why = refusal() }
        guard let why else { return nil }
        onRefused("shell: \(program)", why)
        return "\(why), and `\(program)` reaches another app"
    }

    /// The same question for a program run with an argument vector and no shell
    /// (`ShellRunner.runArgs`): its arguments are data, never re-read as commands.
    public static func refusal(argv: [String], headless: Bool? = nil) -> String? {
        guard let program = ForeignAppCommand.program(argv: argv) else { return nil }
        let why: String?
        if let headless { why = headless ? sentence : nil } else { why = refusal() }
        guard let why else { return nil }
        onRefused("shell: \(program)", why)
        return "\(why), and `\(program)` reaches another app"
    }

    /// The programs that open or script another app. The shell doors guard them on PATH;
    /// the agents' headless sandbox will not start them. GruxAgentCore's
    /// `SwarmWorker.appOpeningPrograms` is the same list (tested).
    public static let appOpeningPrograms = [
        "/usr/bin/open", "/usr/bin/osascript", "/usr/bin/shortcuts", "/usr/bin/automator",
    ]

    /// A directory of stand-ins for `appOpeningPrograms`, put first on a shell door's PATH.
    /// Each checks the headless sentinel every time it runs (its absolute path, written
    /// in, so changing $HOME does not move it): while it is there it refuses with exit
    /// 126, and when it is not it runs the real program with the same arguments. So a
    /// program found by name on PATH (`p=open; $p -a Safari`, `xargs open`, Python's
    /// `subprocess.run(["open", ...])`) is refused, and a session started before headless
    /// mode changed follows the change.
    ///
    /// What it does not cover, on purpose: a deliberate evasion (an absolute path in a
    /// variable, a nested login shell that rebuilds PATH, a copied binary, an Apple event
    /// sent from a script). Headless mode keeps an unattended Mac safe from a model
    /// reaching for these tools, not from someone set on getting past it. A sandbox around
    /// the shell would cover more, but macOS refuses a sandbox inside a sandbox, so it
    /// broke `swift build`'s own (measured).
    /// nil when the guard could not be made a directory of ours: then it stays off PATH.
    static var guardDirectory: String? {
        let dir = gruxDirectory() + "/headless-guard"
        return writeGuard(in: dir, sentinel: NSHomeDirectory() + "/.grux/HEADLESS") ? dir : nil
    }

    /// The folder the guard lives in. Grux points it at `Persistence.gruxDir` at launch,
    /// so under test the guard is written in the suite's own folder, never the person's.
    nonisolated(unsafe) public static var gruxDirectory: () -> String = {
        defaultGruxDirectory(underTest: NSClassFromString("XCTestCase") != nil)
    }

    /// `~/.grux`, or under XCTest the test process's own `Grux-tests-<pid>` folder, the
    /// one Persistence sweeps after the process ends (a GruxShellCore test that never
    /// wires Grux still never writes the live guard).
    public static func defaultGruxDirectory(underTest: Bool) -> String {
        underTest ? NSTemporaryDirectory() + "Grux-tests-\(getpid())/.grux" : NSHomeDirectory() + "/.grux"
    }

    private static let guardLock = NSLock()

    /// Writes (or repairs) the stand-ins in `dir`, watching `sentinel`. Cheap when they
    /// are already right, so every door start asks: a deleted stub is back before the
    /// next command. Each is written executable under a temporary name, then renamed,
    /// so no lookup ever finds it half written. False when `dir` could not be made a
    /// directory of ours, or a stub is missing from it: then it must not go on PATH.
    @discardableResult
    public static func writeGuard(in dir: String, sentinel: String) -> Bool {
        guardLock.lock()
        defer { guardLock.unlock() }
        let fm = FileManager.default
        // Only a directory of ours, closed to everyone else, holding only the stubs: the
        // first entry on every Grux shell's PATH must not run anything planted there.
        // (attributesOfItem does not follow a symlink, so a link is replaced, not used.)
        if let attrs = try? fm.attributesOfItem(atPath: dir),
           attrs[.type] as? FileAttributeType != .typeDirectory
            || (attrs[.ownerAccountID] as? NSNumber)?.uint32Value != getuid() {
            try? fm.removeItem(atPath: dir)
        }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A removal can fail (a read-only parent): then the path may still be a link to
        // someone else's folder, and nothing below may chmod or clean through it.
        guard let attrs = try? fm.attributesOfItem(atPath: dir),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let names = Set(appOpeningPrograms.map { ($0 as NSString).lastPathComponent })
        // `<stub>.<pid>.tmp` is another process's stub mid-write (the app and a test run
        // share this); nothing else is spared.
        func inFlight(_ item: String) -> Bool {
            let parts = item.split(separator: ".")
            return parts.count == 3 && names.contains(String(parts[0])) && Int(parts[1]) != nil && parts[2] == "tmp"
        }
        for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !names.contains(item) && !inFlight(item) {
            try? fm.removeItem(atPath: dir + "/" + item)
        }
        for real in appOpeningPrograms {
            let name = (real as NSString).lastPathComponent
            let stub = """
                #!/bin/sh
                # Grux: in headless mode this would open or script another app.
                if [ -e \(shellQuoted(sentinel)) ]; then
                  echo "\(sentence), and \\`\(name)\\` reaches another app" >&2
                  exit 126
                fi
                exec \(real) "$@"

                """
            let path = dir + "/" + name
            // Read only a regular file: a FIFO would block here, a directory would be
            // skipped by the shell's PATH search.
            if let attrs = try? fm.attributesOfItem(atPath: path) {
                if attrs[.type] as? FileAttributeType != .typeRegular {
                    try? fm.removeItem(atPath: path)
                } else if (try? String(contentsOfFile: path, encoding: .utf8)) == stub, fm.isExecutableFile(atPath: path) {
                    continue
                }
            }
            let temp = path + ".\(getpid()).tmp"
            guard fm.createFile(atPath: temp, contents: Data(stub.utf8), attributes: [.posixPermissions: 0o755]) else { continue }
            if rename(temp, path) != 0 { try? fm.removeItem(atPath: temp) }
        }
        // Usable only with every stub in place: a name whose stub could not be written
        // would reach the real program first on PATH.
        return names.allSatisfy { name in
            let path = dir + "/" + name
            return (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
                && fm.isExecutableFile(atPath: path)
        }
    }

    /// `text` in single quotes for sh, with any single quote in it closed and escaped.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `path` with the guard directory first, when there is one.
    public static func guardedPath(_ path: String) -> String { prepend(guardDirectory, to: path) }

    public static func prepend(_ guardDir: String?, to path: String) -> String {
        guardDir.map { $0 + ":" + path } ?? path
    }

    /// `command` with the guard first on its PATH, for a login shell (`zsh -lc`), whose
    /// path_helper puts the system directories back in front of an inherited PATH.
    public static func guarded(command: String) -> String {
        guard let dir = guardDirectory else { return command }
        return "PATH=\(shellQuoted(dir)):\"$PATH\"; \(command)"
    }

    /// Runs AppleScript in `osascript` and returns what it printed, or nil when refused
    /// or failed.
    static func runOsascript(_ source: String, purpose: String) async -> String? {
        if refuse(purpose) != nil { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", source]
            let out = Pipe(); let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            do { try proc.run() } catch { return nil }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// Runs `/usr/bin/open` with `arguments`, unless refused, and waits up to
    /// `timeoutSeconds` for it. Returns the refusal, or nil.
    @discardableResult
    public static func open(_ arguments: [String], purpose: String, timeoutSeconds: TimeInterval = 5) async -> String? {
        if let why = refuse(purpose) { return why }
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = arguments
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { return }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if proc.isRunning { proc.terminate() }
        }.value
        return nil
    }
}

/// Recognizes shell commands that script or open another app.
///
/// Judged by command position, the way the shell reads it: quotes and escapes join a
/// word (`grep -E "close|open"` runs grep), `$( )`, backticks and `<( )` are commands of
/// their own and leave an argument behind (`open "$(pbpaste)"` has one), a here
/// document's body is input, not commands, and `#` starts a comment. The match ignores
/// case, as the Mac's file system does (`OPEN -a Safari` runs `open`).
public enum ForeignAppCommand {
    static let programs: Set<String> = ["osascript", "open", "shortcuts", "automator"]

    /// The program in shell source `command` that would reach another app, or nil.
    public static func program(in command: String) -> String? {
        for words in ShellWords.commands(in: command) {
            if let hit = judge(words, source: command) { return hit }
        }
        return nil
    }

    /// The program an argument vector runs that would reach another app, or nil.
    public static func program(argv: [String]) -> String? {
        judge(argv, source: argv.joined(separator: " "))
    }

    /// Shell keywords that put a command after them.
    static let keywords: Set<String> = ["do", "then", "else", "elif", "if", "while", "until", "!", "{"]

    /// Programs that run the command after them, with the flags of theirs that take a value.
    static let runners: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T"],
        "env": ["-u", "-C", "-P"],
        "xargs": ["-I", "-J", "-L", "-n", "-P", "-E", "-s", "-R", "-S", "-a", "-d"],
        "exec": ["-a"],
        "nice": ["-n"],
        "timeout": ["-s", "-k"],
        "arch": ["-arch"],
        "caffeinate": ["-t", "-w"],
        "nohup": [], "command": [], "builtin": [], "coproc": [], "time": [],
    ]

    /// `find ... -exec open {} \;` runs the word after these.
    static let findRunners: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]

    static func judge(_ words: [String], source: String) -> String? {
        var rest = words[...]
        while let word = rest.first {
            let name = (word as NSString).lastPathComponent.lowercased()
            if isAssignment(word) || keywords.contains(word) {
                rest = rest.dropFirst()
            } else if let operatorOnly = redirection(word) {
                rest = rest.dropFirst(operatorOnly ? 2 : 1)
            } else if word == "function" {
                rest = rest.dropFirst(2)
            } else if name == "eval" {
                return Self.program(in: rest.dropFirst().joined(separator: " "))
            } else if let valued = runners[name] {
                rest = rest.dropFirst()
                // `command -v open` and `command -V open` look a name up and run nothing.
                if name == "command", let flag = rest.first, flag == "-v" || flag == "-V" { return nil }
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest = rest.dropFirst()
                    if flag == "--" { break }
                    // `env -S 'open -a X'` splits its value into the command it runs.
                    if name == "env" {
                        // The split value starts the command; the words after it are its
                        // arguments, already unquoted, so they are not read as shell again.
                        func split(_ value: String, then after: ArraySlice<String>) -> String? {
                            judge((ShellWords.commands(in: value).first ?? []) + Array(after), source: source)
                        }
                        if flag.hasPrefix("--split-string=") {
                            return split(String(flag.dropFirst("--split-string=".count)), then: rest)
                        }
                        if flag == "-S" || flag == "--split-string" {
                            return rest.first.flatMap { split($0, then: rest.dropFirst()) }
                        }
                        // `-iS` is a cluster; in `-uSSH_AUTH_SOCK` the S belongs to -u's value.
                        if !flag.hasPrefix("--"), let s = flag.firstIndex(of: "S"),
                           flag.dropFirst()[..<s].allSatisfy({ "iv0".contains($0) }) {
                            let joined = String(flag[flag.index(after: s)...])
                            return joined.isEmpty ? rest.first.flatMap { split($0, then: rest.dropFirst()) } : split(joined, then: rest)
                        }
                    }
                    if valued.contains(flag) { rest = rest.dropFirst() }
                }
                if name == "timeout" { rest = rest.dropFirst() }  // the duration
            } else {
                break
            }
        }
        guard let head = rest.first else { return nil }
        let runs = (head as NSString).lastPathComponent.lowercased()
        // An app's own executable, started bare, opens the app with no `open` and no Apple
        // event. A tool in a bundle run with its own arguments (`soffice --headless`,
        // `Tailscale status`) opens no window; only launch arguments (`-NS...`, `-Apple...`)
        // still count as bare.
        if head.range(of: ".app/Contents/MacOS/", options: .caseInsensitive) != nil {
            var args = rest.dropFirst()
            while let word = args.first, let operatorOnly = redirection(word) {
                args = args.dropFirst(operatorOnly ? 2 : 1)
            }
            let launched = args.first.map { $0.hasPrefix("-NS") || $0.hasPrefix("-Apple") || $0.hasPrefix("-psn_") } ?? true
            if launched { return runs }
        }
        let args = Array(rest.dropFirst())
        if runs == "find" {
            // Every `-exec` runs its own command, so each one is judged, not only the first.
            for (i, arg) in args.enumerated() where findRunners.contains(arg) {
                if let program = judge(Array(args[(i + 1)...]), source: source) { return program }
            }
            return nil
        }
        guard SoundingCommand.shells.contains(runs) else {
            return programs.contains(runs) ? runs : nil
        }
        // `sh -c 'open x'`, `zsh -lc ...`, `fish --command ...`: judge the string it runs.
        for (i, arg) in args.enumerated() {
            if arg.hasPrefix("--command=") { return Self.program(in: String(arg.dropFirst("--command=".count))) }
            let commandFlag = arg == "--command" || (arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.contains("c"))
            if commandFlag {
                return i + 1 < args.count ? Self.program(in: args[i + 1]) : nil
            }
        }
        // A shell with no script file reads its commands from a pipe, a here string or a
        // here document, which cannot be seen from here: any app-opening word anywhere in
        // the source refuses it.
        let script = args.first { !$0.hasPrefix("-") }
        guard script == nil || script?.hasPrefix("<") == true else { return nil }
        return anyProgramWord(in: source)
    }

    /// `NAME=value` before a command.
    static func isAssignment(_ word: String) -> Bool {
        word.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\+?=", options: .regularExpression) != nil
    }

    /// For a redirection word: true when it is the operator alone (`>`, `2>`), so its
    /// target is the next word; false when the target is joined (`>/dev/null`, `2>&1`);
    /// nil when the word is not a redirection.
    static func redirection(_ word: String) -> Bool? {
        guard let r = word.range(of: "^[0-9]*(<<<|<<-|<<|&>>|&>|>>|>&|<&|<>|>\\||>|<)", options: .regularExpression) else { return nil }
        return r.upperBound == word.endIndex
    }

    /// A whole word: `open-tool`, `open.spotify.com` and `--open` are not `open`.
    private static func anyProgramWord(in source: String) -> String? {
        let pattern = "(?<![\\w.-])(" + programs.sorted().joined(separator: "|") + ")(?![\\w.-])"
        guard let range = source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return source[range].lowercased()
    }
}

/// A small reader of shell source: just enough of the grammar to say which word of each
/// simple command is in command position.
enum ShellWords {
    /// What a substitution leaves in its word: a value the shell supplies at run time.
    static let substituted = "$SUBSTITUTED"

    /// Every simple command in `source`, as its words, including the ones inside `$( )`,
    /// backticks and `<( )`.
    static func commands(in source: String) -> [[String]] {
        var reader = Reader(Array(source.unicodeScalars))
        reader.read()
        return reader.commands
    }

    private struct Reader {
        // Unicode scalars, not Characters: "\r\n" and a quote followed by a combining mark
        // are one Character each, and the shell splits them.
        let chars: [Unicode.Scalar]
        var i = 0
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var heredocs: [(delimiter: String, stripTabs: Bool)] = []

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        func at(_ k: Int) -> Unicode.Scalar? { k < chars.count ? chars[k] : nil }

        func text(_ from: Int, _ to: Int) -> String {
            var out = String.UnicodeScalarView()
            out.append(contentsOf: chars[from..<max(from, min(to, chars.count))])
            return String(out)
        }

        mutating func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }

        mutating func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }

        mutating func append(_ c: Unicode.Scalar) { word.unicodeScalars.append(c); inWord = true }

        /// Skips arithmetic (`(( ))`, `$[ ]`) to its close: its `<<` is a shift, not a here
        /// document, and nothing in it runs.
        mutating func skipArithmetic(open: Unicode.Scalar, close: Unicode.Scalar) {
            var depth = 0
            while let c = at(i) {
                if c == open { depth += 1 }
                if c == close { depth -= 1; if depth <= 0 { i += 1; break } }
                i += 1
            }
        }

        /// Reads a nested command whose text runs to the `)` matching an already consumed
        /// `(`, judged as commands of its own, and leaves a placeholder in this word.
        mutating func substitution() {
            var depth = 1
            var quote: Unicode.Scalar?
            let start = i
            while i < chars.count {
                let c = chars[i]
                if let q = quote {
                    if c == "\\" && q == "\"" { i += 2; continue }
                    if c == q { quote = nil }
                } else if c == "\\" {
                    i += 2; continue
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                i += 1
            }
            let inner = text(start, i)
            i += 1
            commands += ShellWords.commands(in: inner)
            word += ShellWords.substituted
            inWord = true
        }

        /// Reads a backtick substitution whose opening backtick is consumed.
        mutating func backtick() {
            let start = i
            while i < chars.count && chars[i] != "`" {
                i += chars[i] == "\\" ? 2 : 1
            }
            let inner = text(start, i)
            i += 1
            commands += ShellWords.commands(in: inner)
            word += ShellWords.substituted
            inWord = true
        }

        /// After a newline: skips the bodies of the here documents opened on that line.
        mutating func skipHeredocBodies() {
            for doc in heredocs {
                while i < chars.count {
                    var end = i
                    while end < chars.count && chars[end] != "\n" { end += 1 }
                    var line = text(i, end)
                    if doc.stripTabs { line = String(line.drop { $0 == "\t" }) }
                    i = min(end + 1, chars.count)
                    if line == doc.delimiter { break }
                }
            }
            heredocs = []
        }

        /// `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`: the delimiter, quotes removed.
        mutating func heredoc() {
            var stripTabs = false
            if at(i) == "-" { stripTabs = true; i += 1 }
            while at(i) == " " || at(i) == "\t" { i += 1 }
            var delimiter = ""
            while let c = at(i), !" \t\r\n;|&<>()".unicodeScalars.contains(c) {
                if c != "'" && c != "\"" && c != "\\" { delimiter.unicodeScalars.append(c) }
                i += 1
            }
            heredocs.append((delimiter, stripTabs))
            endWord()
            words.append("<<")
            words.append(delimiter)
        }

        mutating func read() {
            while i < chars.count {
                let c = chars[i]
                let next = at(i + 1)
                switch c {
                case "\\":
                    if let n = next, n != "\n" { append(n) }
                    i += 2
                case "'":
                    i += 1
                    while let q = at(i), q != "'" { append(q); i += 1 }
                    inWord = true
                    i += 1
                case "\"":
                    i += 1
                    inWord = true
                    while let q = at(i), q != "\"" {
                        if q == "\\", let e = at(i + 1) { append(e); i += 2; continue }
                        if q == "$" && at(i + 1) == "(" { i += 2; substitution(); continue }
                        if q == "`" { i += 1; backtick(); continue }
                        append(q); i += 1
                    }
                    i += 1
                case "`":
                    i += 1
                    backtick()
                case "$" where next == "(":
                    i += 2
                    substitution()
                case "(" where next == "(" && !inWord:
                    endCommand()
                    skipArithmetic(open: "(", close: ")")
                case "$" where next == "[":
                    i += 1
                    skipArithmetic(open: "[", close: "]")
                    word += ShellWords.substituted
                    inWord = true
                case "<" where next == "(", ">" where next == "(":
                    i += 2
                    substitution()
                case "<" where next == "<" && at(i + 2) != "<":
                    i += 2
                    heredoc()
                case "<" where next == "<":
                    endWord()
                    words.append("<<<")
                    i += 3
                case "#" where !inWord:
                    while let n = at(i), n != "\n" { i += 1 }
                case " ", "\t", "\r":
                    endWord()
                    i += 1
                case "\n":
                    endCommand()
                    i += 1
                    skipHeredocBodies()
                case ";", "(", ")":
                    endCommand()
                    i += 1
                case "|":
                    endCommand()
                    i += (next == "|" || next == "&") ? 2 : 1
                case "&":
                    if next == "&" {
                        endCommand(); i += 2
                    } else if next == ">" || word.hasSuffix(">") || word.hasSuffix("<") {
                        append(c); i += 1
                    } else {
                        endCommand(); i += 1
                    }
                default:
                    append(c)
                    i += 1
                }
            }
            endCommand()
        }
    }
}
