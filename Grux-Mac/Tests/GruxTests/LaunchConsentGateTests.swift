import XCTest
@testable import Grux

/// The launch consent gate: nothing that pops a macOS permission dialog,
/// records what the user is doing, or speaks aloud may start behind the
/// first-run flow.
///
/// This is the defect a stranger hits and the owner never will. On his machine
/// onboarding finished long ago, every TCC grant is already answered, and the
/// briefing scheduler has been speaking for months. On a brand new install the
/// same code put the "Grux would like to control this computer using
/// accessibility features" dialog on screen about half a second after first
/// launch, on top of the onboarding screen, and started logging the frontmost
/// app and window title every 10 seconds. A launch at 7:30 AM also had the Mac
/// start talking, unprompted, with the onboarding screen the only thing on
/// screen.
///
/// ## Why the briefing half is tested through `dueSlot` and not through `tick()`
///
/// `tick()` is the thing that regressed, but calling it in a test either does
/// nothing at all (22 hours out of 24, since it only acts in the 07:00 and
/// 21:00 hours) or, on a broken build, does everything: a paid model call, a
/// write into the real `~/.grux/jax/briefings/`, and Jax speaking out loud on
/// whoever is running the suite. So the decision was split out of `tick()` into
/// `dueSlot`, which is pure and takes the clock and the onboarding state as
/// arguments. The test then pins 07:30 and asserts the decision, with no side
/// effects on either outcome.
final class BriefingConsentGateTests: XCTestCase {

    /// The engine's own calendar, deliberately, not a pinned zone. The
    /// scheduler decides in the machine's local time, so a test that pinned
    /// America/New_York would be asserting about a different clock than the one
    /// under test and would pass or fail by CI geography.
    private let cal = BriefingWindow.calendar

    private func local(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        let base = cal.startOfDay(for: Date())
        let day = cal.date(byAdding: .day, value: dayOffset, to: base)!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// The regression itself: first launch inside a slot hour, onboarding still
    /// on screen, and the scheduler wants to speak.
    func testNothingIsDueWhileOnboardingIsPresenting() {
        for hour in [BriefingWindow.morningHour, BriefingWindow.nightHour] {
            let slot = BriefingEngine.dueSlot(
                at: local(hour, 30),
                onboardingPresenting: true,
                featureOn: true,
                lastMorningAt: nil,
                lastNightAt: nil
            )
            XCTAssertNil(slot,
                         "a briefing was due at \(hour):30 while the first-run flow was on screen")
        }
    }

    /// The other half, and the one that would be easy to ship broken: a gate
    /// that never opens is worse than the ungated start it replaced. The same
    /// instants that were held above must fire the moment onboarding is done.
    func testTheSameInstantsFireOnceOnboardingIsDone() {
        XCTAssertEqual(
            BriefingEngine.dueSlot(at: local(BriefingWindow.morningHour, 30),
                                   onboardingPresenting: false,
                                   featureOn: true,
                                   lastMorningAt: nil, lastNightAt: nil),
            .morning)
        XCTAssertEqual(
            BriefingEngine.dueSlot(at: local(BriefingWindow.nightHour, 30),
                                   onboardingPresenting: false,
                                   featureOn: true,
                                   lastMorningAt: nil, lastNightAt: nil),
            .night)
    }

    /// Holding must not CONSUME the slot. If the gate had been written as "stamp
    /// it and skip", a user who finished onboarding at 7:10 AM would silently
    /// lose that day's morning briefing and nothing would ever say why.
    func testHoldingDoesNotEatTheDaysBriefing() {
        let heldAt = local(BriefingWindow.morningHour, 5)
        XCTAssertNil(BriefingEngine.dueSlot(at: heldAt,
                                            onboardingPresenting: true, featureOn: true,
                                            lastMorningAt: nil, lastNightAt: nil))
        // Same slot hour, same local day, flow now finished, stamps untouched
        // because the held tick returned before the stamping code.
        XCTAssertEqual(
            BriefingEngine.dueSlot(at: local(BriefingWindow.morningHour, 45),
                                   onboardingPresenting: false,
                                   featureOn: true,
                                   lastMorningAt: nil, lastNightAt: nil),
            .morning,
            "the briefing held during onboarding never arrived after it finished")
    }

    /// The once-per-slot-per-day guard has to survive the new gate: the point of
    /// the gate is to delay the first briefing, not to let it repeat.
    func testAlreadySpokenTodayStaysDeduped() {
        XCTAssertNil(
            BriefingEngine.dueSlot(at: local(BriefingWindow.morningHour, 45),
                                   onboardingPresenting: false, featureOn: true,
                                   lastMorningAt: local(BriefingWindow.morningHour, 5),
                                   lastNightAt: nil),
            "the morning briefing spoke twice in one day")
        XCTAssertEqual(
            BriefingEngine.dueSlot(at: local(BriefingWindow.morningHour, 45),
                                   onboardingPresenting: false, featureOn: true,
                                   lastMorningAt: local(BriefingWindow.morningHour, 5, dayOffset: -1),
                                   lastNightAt: nil),
            .morning,
            "yesterday's stamp suppressed today's briefing")
    }

    /// Outside a slot hour nothing is due, gate open or shut. Guards against a
    /// gate that accidentally became the only condition.
    func testOutsideASlotHourNothingIsDue() {
        for presenting in [true, false] {
            XCTAssertNil(BriefingEngine.dueSlot(at: local(14, 0),
                                                onboardingPresenting: presenting,
                                                featureOn: true,
                                                lastMorningAt: nil, lastNightAt: nil))
        }
    }

    /// The feature gate, which is the half `onboardingPresenting` could never cover.
    ///
    /// `onboardingPresenting` is `stage != .done`, so it flips false the instant somebody
    /// reaches OR SKIPS the end of the flow and never returns. From that moment the engine
    /// spoke on schedule forever, aloud, on a machine with no mail account, no model key and
    /// no feature selection. Measured on a fresh install: a person finished the flow at
    /// 9:20 PM and the speakers said "End of the day. Nothing urgent needs you right now.
    /// The empire is steady." within the minute, and again at 07:00.
    ///
    /// The app was already telling them the opposite. The briefing's home is `jax.hq` and
    /// the registry declares it `requires: endpoint.imap`, unresolved on a fresh Mac.
    func testNothingIsDueWhenTheFeatureIsOff() {
        for hour in [BriefingWindow.morningHour, BriefingWindow.nightHour] {
            XCTAssertNil(
                BriefingEngine.dueSlot(at: local(hour, 30),
                                       onboardingPresenting: false,
                                       featureOn: false,
                                       lastMorningAt: nil, lastNightAt: nil),
                "a briefing was due at \(hour):30 with Jax HQ turned off")
        }
    }

    /// THE CONTROL, modelled on its sibling above: a gate that never opens is worse than the
    /// ungated start it replaced. Both instants must still fire with the feature on.
    func testTheSameInstantsFireWithTheFeatureOn() {
        XCTAssertEqual(
            BriefingEngine.dueSlot(at: local(BriefingWindow.morningHour, 30),
                                   onboardingPresenting: false, featureOn: true,
                                   lastMorningAt: nil, lastNightAt: nil),
            .morning)
        XCTAssertEqual(
            BriefingEngine.dueSlot(at: local(BriefingWindow.nightHour, 30),
                                   onboardingPresenting: false, featureOn: true,
                                   lastMorningAt: nil, lastNightAt: nil),
            .night)
    }
}

/// The launch half of the gate, checked at the source level.
///
/// `applicationDidFinishLaunching` cannot be unit tested: it is an
/// NSApplicationDelegate callback that boots the whole singleton graph, and the
/// only honest way to observe the bug is to install the app on a machine that
/// has never run it. What CAN be checked mechanically, and is exactly how this
/// regresses, is placement: the next person adding an ambient watcher will copy
/// the line above it, and if that line sits on the unconditional launch path the
/// watcher ships ungated. So this asserts every consent-gated start lives inside
/// `startConsentGatedWork()` and none of them appear on the launch path.
///
/// Same shape as `NoPersonalIdentityTests`: walk the real source from a path
/// derived off `#filePath`, and carry a self-test proving the scanner can go
/// red, because a guard that has never failed is a guard nobody has confirmed is
/// wired up.
final class LaunchConsentGateTests: XCTestCase {

    /// Calls that pop a macOS permission dialog, begin recording, or speak.
    /// Each is matched as code, not prose, so the explanatory comments naming
    /// the same watchers do not count as call sites.
    static let consentGatedCalls = [
        "ScreenTimeWatcher.shared.start()",      // Accessibility prompt, then window titles every 10s
        "ChromeTabWatcher.shared.start()",       // Automation (Google Chrome) prompt, then tab URLs
        "MusicWatcher.shared.start()",           // Automation (Spotify / Music) prompt, then now-playing
        "NotificationWatcher.shared.start()",    // reads the notificationd store, needs Full Disk Access
        "SleepWatcher.shared.start()",           // records sleep and wake times to disk
        "CalendarCorrelator.ensurePermission()", // EventKit prompt
        "DailyRecapScheduler.shared.start()",    // checks its window on start, takeover plus speech
        "EnergyRecapScheduler.shared.start()",   // same, one window earlier in the evening
        "WorkdayLogScheduler.shared.start()",     // checkAndFire() runs inside start(), 6 to 10 AM
        "CorpusCoordinator.shared.bootstrap()"    // probed Notes, which raised the Automation dialog
    ]

    private func source() throws -> [String] {
        let url = Self.repoRoot()
            .appendingPathComponent("Sources/Grux/GruxApp.swift")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// The whole rule, stated once: none of it may run on the unconditional
    /// launch path.
    func testNoConsentGatedWorkStartsOnTheLaunchPath() throws {
        let src = try source()
        let launch = try XCTUnwrap(Self.bodyLines(of: "func applicationDidFinishLaunching", in: src),
                                   "could not locate applicationDidFinishLaunching")
        for call in Self.consentGatedCalls {
            let hits = Self.lines(containing: call, in: src).filter { launch.contains($0) }
            XCTAssertTrue(hits.isEmpty,
                          "\(call) runs unconditionally at launch (GruxApp.swift line \((hits.first ?? 0) + 1)), "
                          + "which is behind the onboarding screen on a first run")
        }
    }

    /// And the positive half: they are all still started, from the one method
    /// the gate calls. Without this, deleting the calls outright would pass.
    func testEveryConsentGatedCallLivesInTheGatedMethod() throws {
        let src = try source()
        let gated = try XCTUnwrap(Self.bodyLines(of: "private func startConsentGatedWork", in: src),
                                  "startConsentGatedWork() is gone, so nothing opens the gate")
        for call in Self.consentGatedCalls {
            let hits = Self.lines(containing: call, in: src).filter { gated.contains($0) }
            XCTAssertFalse(hits.isEmpty, "\(call) is no longer started by startConsentGatedWork()")
        }
    }

    /// The gate has to be armed and it has to be able to open. A gate nobody
    /// calls leaves the app permanently deaf, which is a worse bug than the
    /// ungated start it replaced.
    func testTheGateIsArmedAtLaunchAndOpensOntoTheWork() throws {
        let src = try source()
        let launch = try XCTUnwrap(Self.bodyLines(of: "func applicationDidFinishLaunching", in: src))
        XCTAssertTrue(
            Self.lines(containing: "startWhenOnboardingIsDone()", in: src).contains { launch.contains($0) },
            "nothing arms the consent gate during launch, so the gated work never starts")

        let arming = try XCTUnwrap(Self.bodyLines(of: "private func startWhenOnboardingIsDone", in: src))
        XCTAssertTrue(
            Self.lines(containing: "startConsentGatedWork()", in: src).contains { arming.contains($0) },
            "the gate never calls the work it gates")
        XCTAssertTrue(
            Self.lines(containing: "OnboardingModel.shared.$stage", in: src).contains { arming.contains($0) },
            "the gate samples onboarding once instead of observing it, so it can only open on the NEXT launch")
    }

    /// Proves the scanner can go red. Both halves: a call planted on the launch
    /// path must be found, and the body locator must not run past the closing
    /// brace of the method it was asked about.
    func testTheScannerDetectsAPlantedUngatedStart() throws {
        let planted = """
        func applicationDidFinishLaunching(_ notification: Notification) {
            // ScreenTimeWatcher.shared.start() in a comment must NOT count
            ScreenTimeWatcher.shared.start()
        }

        private func startConsentGatedWork() {
            ChromeTabWatcher.shared.start()
        }
        """.components(separatedBy: "\n")

        let launch = try XCTUnwrap(Self.bodyLines(of: "func applicationDidFinishLaunching", in: planted))
        XCTAssertEqual(launch, 0...3, "the body locator did not stop at the closing brace")

        let onLaunchPath = Self.lines(containing: "ScreenTimeWatcher.shared.start()", in: planted)
            .filter { launch.contains($0) }
        XCTAssertEqual(onLaunchPath, [2],
                       "the scanner missed a planted ungated start, or counted the comment as one")

        let gatedOnly = Self.lines(containing: "ChromeTabWatcher.shared.start()", in: planted)
            .filter { launch.contains($0) }
        XCTAssertTrue(gatedOnly.isEmpty, "the locator ran past the end of the launch method")
    }

    // MARK: - Machinery

    /// Repo root derived from this file's own path, so the test works from any
    /// working directory and from Xcode as well as from the command line.
    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)   // .../Tests/GruxTests/ThisFile.swift
            .deletingLastPathComponent()  // .../Tests/GruxTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Everything after `//` on a line. Brace counting and call matching both
    /// run on code only, so a watcher named in an explanatory comment is not
    /// mistaken for a call site and a brace in prose cannot close a body early.
    static func stripComment(_ line: String) -> String {
        guard let r = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<r.lowerBound])
    }

    /// Inclusive line range of a method body, brace counted from the line that
    /// declares it. Returns nil when the declaration is absent, which the
    /// callers treat as a failure rather than a pass.
    static func bodyLines(of signature: String, in source: [String]) -> ClosedRange<Int>? {
        guard let start = source.firstIndex(where: { stripComment($0).contains(signature) }) else {
            return nil
        }
        var depth = 0
        var opened = false
        for i in start..<source.count {
            for ch in stripComment(source[i]) {
                if ch == "{" { depth += 1; opened = true }
                else if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { return start...i }
        }
        return nil
    }

    /// Zero-based line numbers where `needle` appears in code.
    static func lines(containing needle: String, in source: [String]) -> [Int] {
        source.enumerated().compactMap { i, line in
            stripComment(line).contains(needle) ? i : nil
        }
    }
}
