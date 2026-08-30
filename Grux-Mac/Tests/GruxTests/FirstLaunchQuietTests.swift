import XCTest
@testable import Grux

/// The three first-launch surprises a stranger met on a Mac that had never run Grux, each
/// held by the smallest gate that could hold it.
///
/// Every one of these was found by installing 1.2.0 on a clean profile and watching, not by
/// reading code, so each test below states the thing that was actually seen. The scanners
/// borrow `LaunchConsentGateTests`'s helpers rather than growing a second copy, and each one
/// carries a planted-source self test, because a guard that has never gone red is a guard
/// nobody has confirmed is wired up.

// MARK: - Terminal Focus: the two dialogs and the four windows

final class TerminalFocusStartGateTests: XCTestCase {

    private func source() throws -> [String] {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/TerminalFocusState.swift")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// All eight combinations, because the bug was that only ONE of the three was checked
    /// (and on the overlay path only, which is why the picture was gated and the machinery
    /// behind it was not).
    func testEveryConditionIsNecessaryAndTogetherTheyAreSufficient() {
        for enabled in [true, false] {
            for done in [true, false] {
                for explained in [true, false] {
                    let may = TerminalFocusState.mayStartWatching(
                        isEnabled: enabled, onboardingDone: done, sessionsExplained: explained)
                    XCTAssertEqual(may, enabled && done && explained,
                                   "isEnabled=\(enabled) done=\(done) explained=\(explained)")
                }
            }
        }
    }

    /// THE CONTROL. A gate that never opens is worse than the ungated start it replaced, and
    /// this is the combination a person reaches by reading the Terminal Sessions card and
    /// switching the feature on.
    func testTheFeatureStillStartsOnceSomebodyHasSaidYes() {
        XCTAssertTrue(TerminalFocusState.mayStartWatching(
            isEnabled: true, onboardingDone: true, sessionsExplained: true))
    }

    /// The Screen Recording one-shot is not spent here any more.
    ///
    /// `CGRequestScreenCaptureAccess()` is the prompting call and `CGPreflightScreenCaptureAccess()`
    /// is the silent one. Asserting on the whole FILE rather than on `start()` is deliberate:
    /// the finding was about spending a one-shot that onboarding depends on, and moving the
    /// call to a different method in the same Labs feature would not fix that.
    func testTerminalFocusNeverAsksForScreenRecordingItself() throws {
        let src = try source()
        let hits = LaunchConsentGateTests.lines(containing: "CGRequestScreenCaptureAccess()", in: src)
        XCTAssertTrue(hits.isEmpty,
                      "TerminalFocusState.swift line \((hits.first ?? 0) + 1) spends the one-shot "
                      + "Screen Recording prompt, which onboarding and the Terminal Focus setup "
                      + "card both need and both explain first")
    }

    /// Placement, which is what regresses: the next person adding a watcher copies the line
    /// above it. Every call that talks to the system has to sit AFTER the gate.
    func testTheSystemTouchingCallsAllSitBehindTheGate() throws {
        let src = try source()
        let body = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "func startIfAllowed", in: src),
            "startIfAllowed() is gone, so nothing holds the machinery back")
        let guardLine = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "mayStartWatching", in: src)
                .first { body.contains($0) },
            "startIfAllowed() no longer consults mayStartWatching")

        for call in ["startPollTimer()", "setupWorkspaceObserver()",
                     "startClaudeSessionBridge()", "refresh()"] {
            let inBody = LaunchConsentGateTests.lines(containing: call, in: src)
                .filter { body.contains($0) }
            XCTAssertFalse(inBody.isEmpty, "\(call) is no longer started at all")
            for line in inBody {
                XCTAssertGreaterThan(line, guardLine,
                                     "\(call) runs at line \(line + 1), before the gate at "
                                     + "line \(guardLine + 1)")
            }
        }
    }

    /// And the gate is ARMED, not sampled. `start()` is called once per launch from
    /// GruxApp.swift, so sampling would mean switching the feature on did nothing until the
    /// next launch.
    func testTheGateIsObservedRatherThanSampledOnce() throws {
        let src = try source()
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "func start()", in: src))
        for observed in ["$isEnabled", "OnboardingModel.shared.$stage"] {
            XCTAssertFalse(
                LaunchConsentGateTests.lines(containing: observed, in: src)
                    .filter { body.contains($0) }.isEmpty,
                "start() does not observe \(observed), so the gate can only open on the NEXT launch")
        }
    }

    /// The third condition has no publisher, so the pane that writes it calls the gate.
    func testTheSettingsPaneOpensTheGateItself() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Settings/TerminalSessionsSettingsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let marked = try XCTUnwrap(
            LaunchConsentGateTests.lines(
                containing: "markStepCompleted(.stepTerminalSessionsExplained", in: src).first)
        let opened = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "TerminalFocusState.shared.startIfAllowed()",
                                         in: src).first,
            "nothing starts Terminal Focus when the step is completed, so switching it on "
            + "here does nothing until the app is relaunched")
        XCTAssertGreaterThan(opened, marked, "the gate is opened before the step is written")
    }

    /// Proves the placement scanner can go red, on source shaped exactly like the bug.
    func testTheScannerDetectsAStartAheadOfTheGate() throws {
        let planted = """
        func startIfAllowed() {
            refresh()
            guard Self.mayStartWatching(isEnabled: true, onboardingDone: true,
                                        sessionsExplained: true) else { return }
            startPollTimer()
        }
        """.components(separatedBy: "\n")

        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "func startIfAllowed", in: planted))
        let guardLine = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "mayStartWatching", in: planted)
                .first { body.contains($0) })
        let early = LaunchConsentGateTests.lines(containing: "refresh()", in: planted)
            .filter { body.contains($0) }
        XCTAssertEqual(early, [1])
        XCTAssertLessThan(early[0], guardLine,
                          "the scanner would not have caught a call placed ahead of the gate")
    }
}

// MARK: - Terminal Focus: the query that launched Terminal.app

final class TerminalQueryLaunchTests: XCTestCase {

    /// `tell application "Terminal"` launches Terminal when it is closed. On a Mac where
    /// Terminal had never been opened, approving the Automation dialog opened it.
    func testTheQueryIsSkippedWhenTerminalIsNotRunning() {
        XCTAssertFalse(TerminalWindowMapper.shouldQueryTerminal(runningBundleIds: []))
        XCTAssertFalse(TerminalWindowMapper.shouldQueryTerminal(
            runningBundleIds: ["com.apple.finder", "com.gruxai.grux", "com.googlecode.iterm2"]),
            "another terminal emulator is not Terminal.app and does not answer this script")
    }

    /// THE CONTROL: with Terminal up, the mapper still does its job.
    func testTheQueryStillRunsWhenTerminalIsUp() {
        XCTAssertTrue(TerminalWindowMapper.shouldQueryTerminal(
            runningBundleIds: ["com.apple.finder", "com.apple.Terminal"]))
    }

    /// And the call site asks before it shells, rather than after.
    func testTheCallSiteAsksBeforeItShells() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/TerminalWindowMapper.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "func fetchWindowTTYPairsViaOsascript", in: src))
        let asked = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "shouldQueryTerminal(", in: src)
                .first { body.contains($0) },
            "the osascript query no longer checks whether Terminal is running, so a poll can "
            + "launch Terminal.app on a Mac where it is closed")
        let shelled = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "/usr/bin/osascript", in: src)
                .first { body.contains($0) })
        XCTAssertLessThan(asked, shelled,
                          "the check runs after the Apple event has already been sent")
    }
}

// MARK: - The Mac that started talking

final class BriefingSpeechGateTests: XCTestCase {

    /// Measured on a fresh install: the speakers said "End of the day. Nothing urgent needs
    /// you right now. The empire is steady." within a minute of the first-run flow closing,
    /// and again at 07:00. Turning OFF Settings > Spoken replies changed nothing, because
    /// this was the one scheduled speaker in the app that did not read that flag.
    func testTheBriefingReadsTheSpokenRepliesSettingBeforeItSpeaks() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Jax/BriefingEngine.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "private func speak(", in: src))
        let read = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "speakRepliesAloud", in: src)
                .first { body.contains($0) },
            "BriefingEngine.speak() does not read config.speakRepliesAloud, so the Settings "
            + "toggle labelled \"Speak Grux's replies aloud\" does not silence it")
        let spoke = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "SpeechEngine.shared", in: src)
                .first { body.contains($0) })
        XCTAssertLessThan(read, spoke, "the setting is read after the sentence is already out")
    }
}

// MARK: - The corpus probe that opened Notes

final class CorpusProbeQuietTests: XCTestCase {

    /// The probe used to send `tell application "Notes" to return count of notes`, and asking
    /// is enough: macOS answers an Apple event it has no decision for with a modal, and
    /// approving it LAUNCHES Notes to answer. On a Mac that had never run Grux the dialog
    /// arrived before any Grux window was guaranteed to be up, because the app is LSUIElement.
    ///
    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false` asks TCC what it
    /// has already decided. Measured return values, which are not obvious:
    ///
    ///     com.apple.Notes  -> 0     already permitted on this machine
    ///     com.apple.Stocks -> -600  procNotFound, the app is NOT RUNNING
    ///     com.example.nope -> -600
    ///
    /// So the target has to be up for TCC to have anything to say, and crucially nothing here
    /// launches it. This test drives the id that cannot exist, which is the case that must
    /// answer without prompting, without launching anything and without hanging.
    func testAskingAboutAnAppThatCannotExistAnswersWithoutPrompting() {
        let status = NotesIngester.automationPermission(forBundleId: "com.grux.no.such.app.ever")
        XCTAssertEqual(status, OSStatus(procNotFound),
                       "expected procNotFound for a bundle id nothing can be running under")
    }

    /// An empty bundle id must never come back permitted.
    ///
    /// `noErr` is the value `probe()` maps to `.ready`, so anything that returns it for a
    /// target that cannot be addressed would report a source as indexable when nothing is
    /// there. Written after deleting an assertion that compared the result to a constant
    /// minus one, which could not fail and therefore was not a test.
    func testAnEmptyBundleIdIsNeverReportedAsPermitted() {
        XCTAssertNotEqual(NotesIngester.automationPermission(forBundleId: ""), OSStatus(noErr))
    }

    /// The call site, because the pure function above cannot prove the probe stopped using
    /// the old one. `runAppleScript` is still correct for `ingest()`, which is the run a
    /// person asks for and where a consent dialog belongs.
    func testProbeNoLongerSendsAnAppleEvent() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Jax/Corpus/NotesIngester.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "func probe()", in: src))

        for sender in ["runAppleScript", "tell application"] {
            let hits = LaunchConsentGateTests.lines(containing: sender, in: src)
                .filter { body.contains($0) }
            XCTAssertTrue(hits.isEmpty,
                          "probe() sends an Apple event at line \((hits.first ?? 0) + 1), which "
                          + "raises the Automation consent dialog")
        }
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "automationPermission(", in: src)
                .filter { body.contains($0) }.isEmpty,
            "probe() no longer asks TCC what it has already decided")

        // The ingest path keeps it, and that is the point of checking rather than deleting.
        XCTAssertFalse(LaunchConsentGateTests.lines(containing: "runAppleScript", in: src).isEmpty,
                       "ingest() lost its AppleScript path, so Notes can no longer be indexed at all")
    }
}

// MARK: - The report that appeared in somebody's iCloud Drive

final class WorkdayLogSwitchTests: XCTestCase {

    override func tearDown() {
        // REMOVE, never restore. UserDefaults persists across `swift test` runs, so writing
        // a value back would leave the next run reading this test's opinion.
        UserDefaults.standard.removeObject(forKey: WorkdayLogStore.enabledKey)
        UserDefaults.standard.removeObject(forKey: WorkdayLogStore.iCloudMirrorKey)
        super.tearDown()
    }

    /// The log itself is the surface, so it is on unless somebody says otherwise. The point
    /// of the key is that "otherwise" is now sayable at all: `stop()` had zero call sites and
    /// there was no toggle anywhere.
    func testTheLogIsOnByDefaultAndCanBeTurnedOff() {
        UserDefaults.standard.removeObject(forKey: WorkdayLogStore.enabledKey)
        XCTAssertTrue(WorkdayLogStore.isEnabled)
        UserDefaults.standard.set(false, forKey: WorkdayLogStore.enabledKey)
        XCTAssertFalse(WorkdayLogStore.isEnabled, "the off switch does not read")
        UserDefaults.standard.set(true, forKey: WorkdayLogStore.enabledKey)
        XCTAssertTrue(WorkdayLogStore.isEnabled)
    }

    /// THE ONE THAT MATTERS. An absent key is somebody who has never been asked, and the
    /// answer for somebody who has never been asked is no.
    func testTheICloudCopyIsOffUntilSomebodyAsksForIt() {
        UserDefaults.standard.removeObject(forKey: WorkdayLogStore.iCloudMirrorKey)
        XCTAssertFalse(WorkdayLogStore.mirrorsToICloud,
                       "a fresh Mac would copy the person's project names, branches and "
                       + "commit messages into iCloud Drive with nobody having asked")
        UserDefaults.standard.set(true, forKey: WorkdayLogStore.iCloudMirrorKey)
        XCTAssertTrue(WorkdayLogStore.mirrorsToICloud, "turning it on does nothing")
    }

    /// With the mirror off there is no file, so the honest answer to "where is it" is nil.
    ///
    /// THE FIRST VERSION OF THIS TEST WAS NOT A TEST. It called `markdownMirrorURL` directly
    /// and asserted nil, and it PASSED with the preference guard deleted: `xctest` has no
    /// TCC grant for ~/Library/Mobile Documents, so `Persistence.iCloudMirrorDir` returns nil
    /// inside the suite no matter what the switch says. Measured, by planting exactly that
    /// deletion and watching this stay green while its sibling scanner went red.
    ///
    /// Driving the pure function with a directory that exists everywhere is what makes the
    /// decision observable. It also keeps the suite from doing to this Mac what the bug did:
    /// the real getter CREATES the folder, which is how `GruxAI` appeared in somebody's
    /// Finder and on their iPhone in the first place.
    func testTheMirrorPathIsWithheldWhileTheSwitchIsOff() {
        let dir = URL(fileURLWithPath: "/tmp/grux-mirror-test")
        XCTAssertNil(WorkdayLogStore.mirrorURL(in: dir, dayKey: "2026-08-29", mirrorOn: false),
                     "a path was handed out with the iCloud copy switched off")
        XCTAssertNil(WorkdayLogStore.mirrorURL(in: nil, dayKey: "2026-08-29", mirrorOn: true),
                     "a path was invented with no iCloud directory to put it in")
        XCTAssertEqual(
            WorkdayLogStore.mirrorURL(in: dir, dayKey: "2026-08-29", mirrorOn: true)?.lastPathComponent,
            "2026-08-29.md",
            "THE CONTROL: with the switch on there has to be somewhere for the file to go")
    }

    /// And the guards sit AHEAD of the property whose getter is the side effect.
    func testTheGuardsPrecedeTheDirectoryCreatingGetter() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/WorkdayLog/WorkdayLogStore.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")

        for fn in ["private static func writeMarkdownMirror", "static func markdownMirrorURL"] {
            let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: fn, in: src), fn)
            let guarded = try XCTUnwrap(
                LaunchConsentGateTests.lines(containing: "mirrorsToICloud", in: src)
                    .first { body.contains($0) },
                "\(fn) does not check the preference at all")
            let creates = try XCTUnwrap(
                LaunchConsentGateTests.lines(containing: "Persistence.iCloudMirrorDir", in: src)
                    .first { body.contains($0) })
            XCTAssertLessThan(guarded, creates,
                              "\(fn) reads iCloudMirrorDir at line \(creates + 1) before the "
                              + "check at line \(guarded + 1), and that read is what creates "
                              + "the folder in iCloud Drive")
        }
    }

    /// The scheduler reads the switch on every tick, not only at start(), because the timer
    /// polls every 60 seconds and an off that waits for the next launch is not an off.
    func testTheSchedulerReadsTheSwitchOnEveryTick() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/WorkdayLog/WorkdayLogScheduler.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "func checkAndFire", in: src))
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "WorkdayLogStore.isEnabled", in: src)
                .filter { body.contains($0) }.isEmpty,
            "checkAndFire() does not read the enabled switch, so the 60 second timer keeps "
            + "firing until the app is relaunched")
    }
}
