import AppKit
import GruxShellCore

/// Every AppleScript Grux sends to another app is built here.
///
/// Measured 2026-10-22 on a headless Mac mini: a small local model answered "what is
/// two plus two" by calling `play_on_youtube`, and Grux ran `tell application "Google
/// Chrome" to activate` on a screen that belonged to someone else, then waited 2 min
/// 34 s on an Apple Event macOS held for an Automation prompt nobody could answer.
/// `WindowFacade` keeps Grux's own windows off that screen; an Apple Event to another
/// app can bring THAT app forward or raise a permission prompt on it, so in headless
/// mode none is sent, and no other app is opened. Twenty call sites built their own
/// `NSAppleScript`; ForeignAppScriptTests fails on any `NSAppleScript(source:`,
/// `osascript`, `/usr/bin/open` or `openApplication` outside this file and GruxShellCore's
/// `ShellAppleEvents`, so the next one cannot skip the gate.
///
/// Each also ran its script on its own thread, most on the main actor, so while macOS
/// held an Apple Event for an Automation prompt the whole app froze (D13). Only this file
/// executes a script now: on its own queue, and the caller waits at most a timeout.
enum ForeignAppScript {
    /// Every refusal starts with this, so a reader can tell it from the other gates.
    static let refusalPrefix = ShellAppleEvents.refusalPrefix

    /// Why no Apple Event may go to another app now, or nil when one may.
    nonisolated static func refusal() -> String? {
        guard WindowFacade.isHeadless else { return nil }
        return "\(refusalPrefix) (~/.grux/HEADLESS), so Grux will not script another app: "
            + "it could come to the front or raise a macOS permission prompt on a screen nobody is watching"
    }

    private static let loggedLock = NSLock()
    nonisolated(unsafe) private static var logged: Set<String> = []

    /// True the first time `purpose` is refused in this launch. A watcher ticks every
    /// 30 s, so a line per refusal would write the same sentence 2,880 times a day.
    nonisolated static func firstRefusal(of purpose: String) -> Bool {
        loggedLock.lock()
        defer { loggedLock.unlock() }
        return logged.insert(purpose).inserted
    }

    /// `refusal()`, written to wake.log once a launch per `purpose` when it says no. Every
    /// door asks this, so a refusal that returns before building anything is still seen.
    nonisolated static func refuse(_ purpose: String) -> String? {
        guard let why = refusal() else { return nil }
        noteRefused(purpose, why)
        return why
    }

    /// Logs a refusal once a launch per `purpose` (the shell doors report here too).
    nonisolated static func noteRefused(_ purpose: String, _ why: String) {
        if firstRefusal(of: purpose) { WakeLog.shared.log("apple-events: \(purpose) not sent: \(why)") }
    }

    /// What a script sent to another app came to.
    enum Outcome: @unchecked Sendable {
        case ok(NSAppleEventDescriptor)
        /// AppleScript's own error number (for example -1743, Automation not allowed).
        case failed(code: Int?, message: String)
        case refused(String)
        /// The app did not answer within the limit. The script is still waiting on it and
        /// finishes when it answers (a person allowing macOS's Automation prompt, say).
        case timedOut(TimeInterval)
        /// An earlier script is still waiting on another app, so this one was not sent.
        case busy
        /// A script run in its own process did not finish within the limit and was stopped.
        case stopped(TimeInterval)
        /// Grux is running a request with a longer limit (a library search, the Notes
        /// export) that would outlast this caller's, so this one was not sent.
        case behindLongerScript

        var stringValue: String? {
            if case .ok(let d) = self { return d.stringValue }
            return nil
        }

        /// A plain sentence for every outcome that is not `.ok`, or nil.
        var problem: String? {
            switch self {
            case .ok: return nil
            case .failed(let code, let message): return "\(message) (\(code.map(String.init) ?? "?"))"
            case .refused(let why): return why
            case .timedOut(let seconds):
                return "the app did not answer within \(max(1, Int(seconds.rounded()))) s; if macOS is asking whether "
                    + "Grux may control it, answer there, and the request goes through once you allow it"
            case .busy:
                return "Grux is still waiting on another app to answer an earlier request "
                    + "(macOS may be asking whether Grux may control it); answer that, then ask again"
            case .behindLongerScript:
                return "Grux is busy with a longer request to another app, so this one was not sent; ask again in a moment"
            case .stopped(let seconds):
                return "the script did not finish within \(max(1, Int(seconds.rounded()))) s, so Grux stopped it"
            }
        }
    }

    /// How long a caller waits for another app before moving on. macOS's own Apple Event
    /// wait is 2 min, and it holds an event that long while an Automation prompt is up.
    nonisolated static var defaultTimeout: TimeInterval { timeoutUnderTest ?? 20 }
    nonisolated(unsafe) static var timeoutUnderTest: TimeInterval?

    /// Runs `source` on the gate's own thread, never the caller's, and returns within
    /// `timeout` whatever the other app does. Refused in headless mode.
    nonisolated static func run(_ source: String, purpose: String,
                                timeout: TimeInterval = defaultTimeout) async -> Outcome {
        if let why = refuse(purpose) { return .refused(why) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            submit(source, purpose: purpose, timeout: timeout) { cont.resume(returning: $0) }
        }
    }

    /// `run`, for a caller that cannot suspend: it waits on its own thread, at most
    /// `timeout`. ForeignAppScriptTests names every file allowed to call this, and why.
    nonisolated static func runWaiting(_ source: String, purpose: String,
                                       timeout: TimeInterval = defaultTimeout) -> Outcome {
        if let why = refuse(purpose) { return .refused(why) }
        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        submit(source, purpose: purpose, timeout: timeout) { box.value = $0; done.signal() }
        done.wait()
        return box.value ?? .busy
    }

    /// Runs `source` in its own `osascript` process, for a person's own script (a macro's
    /// AppleScript step): it may show a dialog, which needs a process of its own, and a
    /// script that outlives `timeout` is stopped. Refused in headless mode.
    nonisolated static func runOutOfProcess(_ source: String, purpose: String,
                                            timeout: TimeInterval = personsScriptTimeout) async -> Outcome {
        if let why = refuse(purpose) { return .refused(why) }
        if let fake = executeUnderTest { return fake(source) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let r = await BoundedProcess.run(proc, timeout: timeout)
        if r.timedOut { return .stopped(timeout) }
        let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 { return .ok(NSAppleEventDescriptor(string: text)) }
        return osascriptFailure(text)
    }

    /// `osascript`'s error line, `0:5: execution error: Not authorized ... (-1743)`, as
    /// AppleScript's own number and message.
    nonisolated static func osascriptFailure(_ text: String) -> Outcome {
        // Past the output cap the last line is the dropped-bytes note, not the error.
        let line = text.components(separatedBy: "\n").last(where: { !$0.isEmpty && !$0.hasPrefix("…(output past") }) ?? text
        let pattern = #"^(?:\d+:\d+: )?(?:execution|syntax) error: (.*) \((-?\d+)\)$"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let msg = Range(m.range(at: 1), in: line), let num = Range(m.range(at: 2), in: line) {
            return .failed(code: Int(line[num]), message: String(line[msg]))
        }
        return .failed(code: nil, message: line.isEmpty ? "osascript failed" : line)
    }

    /// A person's own script may wait on them (a dialog), so it gets longer than one command.
    static let personsScriptTimeout: TimeInterval = 120

    /// The compiler's error for `source`, or nil when it compiles. Compiling sends nothing
    /// to any app.
    nonisolated static func compileError(_ source: String) -> NSDictionary? {
        var err: NSDictionary?
        let compiled = NSAppleScript(source: source)?.compileAndReturnError(&err) ?? false
        return compiled ? nil : (err ?? [NSAppleScript.errorMessage: "could not compile"])
    }

    /// Replaces the real Apple Event under test, so a hung app can be played without one.
    nonisolated(unsafe) static var executeUnderTest: ((String) -> Outcome)?

    private final class OutcomeBox: @unchecked Sendable { var value: Outcome? }

    /// One request's state. Every field is read and written under `gateLock`, together
    /// with `stuck`, so the script finishing and its limit firing can never interleave.
    private final class Ticket: @unchecked Sendable {
        let id = UUID()
        var started = false
        var finished = false
        var answered = false
    }

    /// One script at a time: NSAppleScript is not safe to run on two threads at once.
    private static let queue = DispatchQueue(label: "com.gruxai.foreign-app-script", qos: .userInitiated)
    private static let gateLock = NSLock()
    /// The script that is executing past its caller's limit, still waiting on its app.
    nonisolated(unsafe) private static var stuck: UUID?
    /// Requests with a longer limit than an ordinary command (a library search, the
    /// Notes export), queued or executing, and the latest each may hold the queue.
    nonisolated(unsafe) private static var longHolders: [UUID: Date] = [:]
    /// The limit an ordinary command gets; a request with a longer one is a long holder.
    static let ordinaryLimit: TimeInterval = 20

    /// Clears a stuck script left by a test whose fake app never answered.
    static func resetUnderTest() {
        gateLock.lock(); stuck = nil; longHolders = [:]; gateLock.unlock()
    }

    private static func submit(_ source: String, purpose: String, timeout: TimeInterval,
                               done: @escaping @Sendable (Outcome) -> Void) {
        let ticket = Ticket()
        let now = Date()
        gateLock.lock()
        // A script queued behind one stuck on a prompt would wait the whole 2 min too.
        let isStuck = stuck != nil
        // One queued behind a request with a longer limit (the Notes export may take
        // 5 min) would wait out its own: it is not sent, and the caller hears so at once.
        // Behind an ordinary command it queues; its own limit caps the wait.
        let deadline = now.addingTimeInterval(timeout)
        let behindLong = !isStuck && longHolders.values.contains { $0 >= deadline }
        if !isStuck && !behindLong && timeout > ordinaryLimit { longHolders[ticket.id] = deadline }
        gateLock.unlock()
        if isStuck { done(.busy); return }
        if behindLong {
            WakeLog.shared.log("apple-events: \(purpose) not sent: a longer request to another app holds the queue")
            done(.behindLongerScript)
            return
        }
        queue.async {
            gateLock.lock()
            // Its caller was answered while it waited its turn: it never runs late.
            if ticket.answered { longHolders[ticket.id] = nil; gateLock.unlock(); return }
            ticket.started = true
            if longHolders[ticket.id] != nil { longHolders[ticket.id] = Date().addingTimeInterval(timeout) }
            gateLock.unlock()
            let outcome = execute(source)
            gateLock.lock()
            ticket.finished = true
            if stuck == ticket.id { stuck = nil }
            longHolders[ticket.id] = nil
            let answers = !ticket.answered
            ticket.answered = true
            gateLock.unlock()
            if answers { done(outcome) }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            gateLock.lock()
            if ticket.answered { gateLock.unlock(); return }
            ticket.answered = true
            // Only a script that is executing holds the queue; one still waiting its
            // turn was never sent, and is skipped when its turn comes.
            let executing = ticket.started && !ticket.finished
            if executing && stuck == nil { stuck = ticket.id }
            gateLock.unlock()
            WakeLog.shared.log("apple-events: \(purpose) had no answer within \(max(1, Int(timeout.rounded()))) s"
                + (executing ? "; Grux moved on" : "; it was never sent"))
            done(executing ? .timedOut(timeout) : .busy)
        }
    }

    private static func execute(_ source: String) -> Outcome {
        if let fake = executeUnderTest { return fake(source) }
        guard let script = NSAppleScript(source: source) else {
            return .failed(code: nil, message: "could not compile the script")
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            return .failed(code: err[NSAppleScript.errorNumber] as? Int,
                           message: (err[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error")
        }
        return .ok(result)
    }

    /// Runs `source` in `osascript` without waiting for it, unless `refusal()` says no.
    nonisolated static func launch(_ source: String, purpose: String) {
        if refuse(purpose) != nil { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        try? task.run()
    }

    enum Opened {
        case refused(String)
        case opened(NSRunningApplication?)
        case failed(Error)
    }

    /// Launches (or switches to) the app at `url` through LaunchServices, unless refused.
    @MainActor
    static func launchApp(at url: URL, activates: Bool, purpose: String) async -> Opened {
        if let why = refuse(purpose) { return .refused(why) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        return await withCheckedContinuation { (cont: CheckedContinuation<Opened, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                cont.resume(returning: error.map { .failed($0) } ?? .opened(app))
            }
        }
    }

    /// Runs `/usr/bin/open` with `arguments` and waits up to 5 s for it, unless refused.
    /// Returns the refusal, or nil. One body for both gates: GruxShellCore's.
    @discardableResult
    nonisolated static func open(_ arguments: [String], purpose: String) async -> String? {
        if let why = refuse(purpose) { return why }
        return await ShellAppleEvents.open(arguments, purpose: purpose)
    }
}
