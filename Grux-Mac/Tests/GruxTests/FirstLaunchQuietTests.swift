import XCTest
@testable import Grux

/// The first-launch surprises a stranger met on a Mac that had never run Grux, each
/// held by the smallest gate that could hold it.
///
/// Every one of these was found by installing 1.2.0 on a clean profile and watching, not by
/// reading code, so each test below states the thing that was actually seen. The scanners
/// borrow `LaunchConsentGateTests`'s helpers rather than growing a second copy, and each one
/// carries a planted-source self test, because a guard that has never gone red is a guard
/// nobody has confirmed is wired up.

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
