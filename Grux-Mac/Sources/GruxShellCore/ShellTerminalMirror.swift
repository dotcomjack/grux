import Foundation

// MARK: - ShellTerminalMirror
//
// Opens a Terminal.app window that tails the session's mirror log in real time.
// The user SEES everything Grux is doing but SHOULDN'T TYPE into this window -
// their keystrokes would go into the `tail` process, which discards them.
//
// We open the window via AppleScript (`tell application "Terminal" to do script`)
// because (a) it's the right surface - the user already has a Terminal in the dock,
// it's not a weird new process - and (b) it spawns a fresh window/tab with a
// tty, so output rendering (colors/progress bars) is real.
//
// The window runs:
//     less +F <logpath>
// `less +F` is follow-mode: displays file contents, follows growth like tail -f,
// BUT is visibly in-app ("Waiting for data..."), making "read-only" clear to
// the user. Ctrl-C interrupts follow, not `less` - so the user can scroll up to
// review older output and come back.
//
// On close() we send `:quit` into less and close the Terminal window via a
// second AppleScript call (scoped to the window ID we recorded on open).

public actor ShellTerminalMirror {

    public let sessionId: String
    public let logPath: String
    private var terminalWindowId: Int? = nil
    public private(set) var isOpen: Bool = false

    public init(sessionId: String, logPath: String) {
        self.sessionId = sessionId
        self.logPath = logPath
    }

    // Open a Terminal.app window tailing logPath. Returns silently on success.
    public func open(rootDir: String, mode: ShellMode, undoMode: ShellUndoMode) async {
        // Ensure log file exists so `less +F` has something to open.
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: Data())
        }

        // Escape for AppleScript single-line string: backslashes and double quotes.
        let escapedLog = logPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // `less -R +F -n` -
        //   -R  pass through ANSI color escapes (clean colors on git, npm, etc.)
        //   +F  start in follow mode
        //   -n  disable line-number computation (faster on long logs)
        let script = """
        tell application "Terminal"
            activate
            set newTab to do script "clear; printf '\\\\033]0;Grux Session \(sessionId)\\\\007'; less -R +F -n \\"\(escapedLog)\\""
            set winId to id of (first window whose tabs contains newTab)
            return winId
        end tell
        """

        let result = await runAppleScript(script)
        if let out = result, let id = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            terminalWindowId = id
            isOpen = true
        } else {
            // If the AppleScript failed (permissions, Terminal.app not there,
            // user denied automation prompt) - leave mirror closed. Session
            // continues to work; user just won't see a live terminal.
            isOpen = false
        }
    }

    // Close the mirror terminal window. Swallows failures - a session end
    // should never fail because we couldn't close an AppleScript window.
    public func close() async {
        guard isOpen, let winId = terminalWindowId else { isOpen = false; return }
        // Send `q` via AppleScript to exit `less`, then close the window.
        // `less` running in follow-mode needs Ctrl-C + q to exit; sending a `q`
        // keystroke plus closing the window is the most reliable.
        let script = """
        tell application "Terminal"
            try
                close (first window whose id is \(winId)) saving no
            end try
        end tell
        """
        _ = await runAppleScript(script)
        isOpen = false
        terminalWindowId = nil
    }

    // MARK: - Internals

    private func runAppleScript(_ source: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
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
}
