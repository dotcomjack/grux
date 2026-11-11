import XCTest
@testable import Grux

/// D13 (P1): a script to another app ran on its caller's thread, most often the main
/// actor, so while macOS held the Apple Event for an Automation prompt (measured: the
/// prompt answered at +153.94 s) the whole of Grux was frozen. The gate now runs every
/// script on its own queue and gives the caller an answer within a limit.
///
/// No real Apple Event is sent here: `executeUnderTest` plays the other app, so headless
/// is lifted only with the fake in place.
final class ForeignAppScriptTimeoutTests: XCTestCase {

    /// Every fake app a test made, answered in tearDown so none keeps the gate's queue.
    private var apps: [HungApp] = []

    override func tearDown() {
        for app in apps { for _ in 0..<8 { app.answer.signal() } }
        apps = []
        // Let a released fake finish before the next test reads the gate.
        Thread.sleep(forTimeInterval: 0.05)
        ForeignAppScript.resetUnderTest()
        ForeignAppScript.executeUnderTest = nil
        ForeignAppScript.timeoutUnderTest = nil
        WindowFacade.headlessUnderTest = nil
        super.tearDown()
    }

    /// An app that answers only when `answer` is signalled, recording what it was sent.
    private final class HungApp: @unchecked Sendable {
        let answer = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _sent: [String] = []
        private var _onMain: [Bool] = []
        var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
        var ranOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return _onMain }
        func execute(_ source: String) -> ForeignAppScript.Outcome {
            lock.lock(); _sent.append(source); _onMain.append(Thread.isMainThread); lock.unlock()
            answer.wait()
            return .ok(NSAppleEventDescriptor(string: "late"))
        }
    }

    private func install(_ app: HungApp) {
        apps.append(app)
        ForeignAppScript.executeUnderTest = { app.execute($0) }
        WindowFacade.headlessUnderTest = false
    }

    /// Lets the stuck script finish and waits until the gate takes a new one, so no test
    /// leaves the next one a busy gate.
    private func release(_ app: HungApp) async {
        app.answer.signal()
        ForeignAppScript.executeUnderTest = { _ in .ok(NSAppleEventDescriptor(string: "free")) }
        for _ in 0..<200 {
            if case .ok = await ForeignAppScript.run("return 1", purpose: "test-release", timeout: 1) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the gate stayed busy after its script finished")
    }

    @MainActor
    func testTheMainActorStaysFreeWhileAnAppDoesNotAnswer() async {
        let app = HungApp()
        install(app)
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        let started = Date()
        let outcome = await ForeignAppScript.run("tell application \"Google Chrome\" to activate",
                                                 purpose: "test-hung", timeout: 0.5)
        let waited = Date().timeIntervalSince(started)
        ticker.cancel()
        if case .timedOut(let limit) = outcome { XCTAssertEqual(limit, 0.5) } else { XCTFail("expected a timeout, got \(outcome)") }
        // Loose bounds: the full suite loads this Mac. A frozen main actor ticks 0 or 1
        // times, and an unbounded wait never returns at all.
        XCTAssertLessThan(waited, 5.0, "the caller waited past its limit")
        XCTAssertGreaterThan(ticks, 2, "the main actor was frozen while the app did not answer")
        XCTAssertEqual(app.ranOnMain, [false], "the script ran on the main thread")
        XCTAssertTrue(outcome.problem?.contains("did not answer within 0 s") == false)
        XCTAssertTrue(outcome.problem?.contains("goes through once you allow it") == true, outcome.problem ?? "")
        await release(app)
    }

    /// The one waiting on a prompt would make every script queued behind it wait as long.
    func testWhileOneScriptIsStuckTheNextIsNotSentAndSaysWhy() async {
        let app = HungApp()
        install(app)
        _ = await ForeignAppScript.run("first", purpose: "test-stuck", timeout: 0.2)
        let started = Date()
        let second = await ForeignAppScript.run("second", purpose: "test-stuck", timeout: 5)
        if case .busy = second {} else { XCTFail("expected busy, got \(second)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.0, "the second caller waited behind the stuck one")
        XCTAssertEqual(app.sent, ["first"], "a script was sent while another was stuck")
        XCTAssertTrue(second.problem?.contains("still waiting on another app") == true, second.problem ?? "")
        await release(app)
        let third = await ForeignAppScript.run("third", purpose: "test-stuck", timeout: 1)
        XCTAssertEqual(third.stringValue, "free", "the gate did not take a script once the stuck one answered")
    }

    /// A caller whose script was still waiting its turn when the limit came is told it
    /// was not sent, and the script never runs later behind its back.
    func testAScriptWhoseCallerGaveUpInTheQueueNeverRuns() async {
        let app = HungApp()
        install(app)
        // An ordinary limit, so the second caller queues behind it (a longer one refuses at once).
        let first = Task { await ForeignAppScript.run("first", purpose: "test-queue", timeout: ForeignAppScript.ordinaryLimit) }
        for _ in 0..<500 where app.sent.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(app.sent, ["first"], "the first script never started")
        let queued = await ForeignAppScript.run("queued", purpose: "test-queue", timeout: 0.2)
        if case .busy = queued {} else { XCTFail("expected not sent (busy), got \(queued)") }
        app.answer.signal()
        _ = await first.value
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(app.sent, ["first"], "a script ran after its caller had moved on")
        await release(app)
    }

    /// Wave 9 review (P1): a script that finished just as its limit fired could leave the
    /// gate marked stuck with nothing to clear it, so every later script read busy until
    /// relaunch. Tried at the boundary many times: the gate must always free up again.
    func testAScriptThatFinishesAsItsLimitFiresNeverLeavesTheGateBusy() async {
        // One fake for the whole test, chosen by source, so nothing swaps it mid-run.
        ForeignAppScript.executeUnderTest = { source in
            if source == "edge" { Thread.sleep(forTimeInterval: 0.005) }
            return .ok(NSAppleEventDescriptor(string: source == "edge" ? "done" : "free"))
        }
        WindowFacade.headlessUnderTest = false
        for i in 0..<300 {
            _ = await ForeignAppScript.run("edge", purpose: "test-edge", timeout: 0.005)
            // A loaded Mac may still be running the edge script: wait for it, up to 1 s.
            var next = await ForeignAppScript.run("next", purpose: "test-edge", timeout: 2)
            let deadline = Date().addingTimeInterval(1)
            while next.stringValue != "free", Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
                next = await ForeignAppScript.run("next", purpose: "test-edge", timeout: 2)
            }
            guard next.stringValue == "free" else { return XCTFail("the gate stayed busy after try \(i): \(next)") }
        }
    }

    /// Wave 9 review round 2 (P2): with a long script executing (the Notes export may take
    /// 5 min), a caller with a short limit (AudioDucker's 3 s, on the main actor) waited
    /// its whole limit in the queue. It is told "not sent" at once instead.
    func testACallerWhoseLimitEndsBeforeTheRunningScriptsIsNotSentAndHearsAtOnce() async {
        let app = HungApp()
        install(app)
        let long = Task { await ForeignAppScript.run("long", purpose: "test-long", timeout: 30) }
        for _ in 0..<500 where app.sent.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        let started = Date()
        let short = await ForeignAppScript.run("short", purpose: "test-long", timeout: 3)
        if case .behindLongerScript = short {} else { XCTFail("expected not sent, got \(short)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the short caller waited in the queue")
        app.answer.signal()
        _ = await long.value
        XCTAssertEqual(app.sent, ["long"])
        await release(app)
    }

    /// Wave 9 review round 3 (P2): the rule above compared limits, not durations, so
    /// AudioDucker's 3 s read was refused behind a watcher tick that takes 50 ms under the
    /// ordinary 20 s limit, and Grux spoke over full-volume music. Behind an ordinary
    /// script a caller queues, as before.
    func testAShortCallerQueuesBehindAnOrdinaryScriptThatIsQuick() async {
        ForeignAppScript.executeUnderTest = { source in
            if source == "tick" { Thread.sleep(forTimeInterval: 0.05) }
            return .ok(NSAppleEventDescriptor(string: source))
        }
        WindowFacade.headlessUnderTest = false
        let tick = Task { await ForeignAppScript.run("tick", purpose: "test-tick", timeout: 20) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let duck = await ForeignAppScript.run("duck", purpose: "test-duck", timeout: 3)
        XCTAssertEqual(duck.stringValue, "duck", "a 3 s caller was refused behind a quick ordinary script")
        _ = await tick.value
    }

    /// Refused behind a longer script, the caller is told what is true: no prompt waits.
    func testTheRefusalBehindALongerScriptSaysWhatIsTrue() async {
        let app = HungApp()
        install(app)
        let long = Task { await ForeignAppScript.run("long", purpose: "test-long", timeout: 30) }
        for _ in 0..<500 where app.sent.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        let short = await ForeignAppScript.run("short", purpose: "test-long", timeout: 3)
        XCTAssertEqual(short.problem, "Grux is busy with a longer request to another app, so this one was not sent; ask again in a moment")
        app.answer.signal()
        _ = await long.value
        await release(app)
    }

    /// The other side of that boundary: a caller whose limit outlasts the running script's
    /// is queued and runs once it finishes.
    func testACallerWhoseLimitOutlastsTheRunningScriptsIsQueued() async {
        let app = HungApp()
        install(app)
        let first = Task { await ForeignAppScript.run("first", purpose: "test-long", timeout: 1) }
        for _ in 0..<500 where app.sent.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        let second = Task { await ForeignAppScript.run("second", purpose: "test-long", timeout: 10) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        app.answer.signal()
        app.answer.signal()
        _ = await first.value
        let got = await second.value
        XCTAssertEqual(got.stringValue, "late", "the queued caller was refused although its limit outlasted the first")
        XCTAssertEqual(app.sent, ["first", "second"])
        await release(app)
    }

    /// A person's own macro script runs in its own process, so a dialog has a process to
    /// show in, and one that outlives its limit is stopped. `delay` sends no Apple Event.
    func testAPersonsScriptRunsOutOfProcessAndIsStoppedAtItsLimit() async {
        WindowFacade.headlessUnderTest = false
        let hello = await ForeignAppScript.runOutOfProcess("return \"hello\"", purpose: "test-oop", timeout: 20)
        XCTAssertEqual(hello.stringValue, "hello")
        let started = Date()
        let slow = await ForeignAppScript.runOutOfProcess("delay 30", purpose: "test-oop", timeout: 1)
        // Wave 9 review round 2: the process is killed, so nothing "goes through later".
        if case .stopped = slow {} else { XCTFail("expected stopped, got \(slow)") }
        XCTAssertEqual(slow.problem, "the script did not finish within 1 s, so Grux stopped it")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        guard case .failed(let code, let message) = ForeignAppScript.osascriptFailure(
            "0:59: execution error: Not authorized to send Apple events to Music. (-1743)") else { return XCTFail() }
        XCTAssertEqual(code, -1743)
        XCTAssertEqual(message, "Not authorized to send Apple events to Music.")
    }

    /// The waiting door, for callers already off the main thread, keeps the same limit.
    func testTheWaitingDoorReturnsWithinItsLimitToo() async {
        let app = HungApp()
        install(app)
        let started = Date()
        let outcome = ForeignAppScript.runWaiting("x", purpose: "test-waiting", timeout: 0.3)
        if case .timedOut = outcome {} else { XCTFail("expected a timeout, got \(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
        await release(app)
    }

    /// The incident path: a model asks for a page while Chrome waits on a prompt.
    @MainActor
    func testOpeningAPageWhileChromeDoesNotAnswerReturnsAPlainErrorInTime() async {
        let app = HungApp()
        install(app)
        ForeignAppScript.timeoutUnderTest = 0.3
        XCTAssertNotNil(ForeignAppScript.executeUnderTest, "never script the real Chrome")
        let result = await BrowserTool.openURL("example.com")
        XCTAssertTrue(result.hasPrefix("error: Chrome: the app did not answer"), result)
        XCTAssertEqual(app.sent.count, 1)
        XCTAssertTrue(app.sent.first?.contains("https://example.com") == true)
        await release(app)
    }

    @MainActor
    func testADeniedAutomationPromptStillNamesTheSetting() async {
        ForeignAppScript.executeUnderTest = { _ in .failed(code: -1743, message: "Not authorized to send Apple events") }
        WindowFacade.headlessUnderTest = false
        let result = await BrowserTool.searchWeb("two plus two")
        XCTAssertTrue(result.contains("Privacy & Security → Automation → Grux AI → Google Chrome"), result)
        let other = await AppleScriptRunner.run(source: "return 1")
        XCTAssertEqual(other, "error: applescript failed (-1743) - Not authorized to send Apple events")
    }
}
