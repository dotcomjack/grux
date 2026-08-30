import XCTest
@testable import Grux

/// The sixteen remaining first-run findings, held by the five mechanisms they actually are.
///
/// Where a decision could be made pure it is driven directly. Where the thing that regresses
/// is PLACEMENT (a call moved back onto the launch path, a guard moved after the side effect
/// it guards), the check is a source scan sharing `LaunchConsentGateTests`'s helpers, which
/// carry their own proven-red self test.

// MARK: - The six that ran at launch with nobody having asked

final class LaunchFlagGateTests: XCTestCase {

    /// Each call, and the flag that has to be read before it can run.
    ///
    /// Deliberately a table rather than six near-identical tests: the failure mode is
    /// somebody adding a seventh ambient starter, and a table is the thing they will notice.
    static let gatedAtLaunch: [(call: String, flag: String)] = [
        ("DomainMonitor.shared.start()",      "domainMonitorEnabled"),
        ("AudioDucker.shared.install()",      "musicDuckingEnabled"),
        ("MeetingAppDetector.shared.start()", "meetingAutoDetectEnabled"),
        ("GruxControlSocket.shared.start()",  "controlSocketEnabled"),
    ]

    // The orb, the inject-chat file and the Foundry governor are gated too, and they are
    // NOT in the table above: each has a second occurrence in GruxApp.swift (a debug
    // launch-argument path, or its own declaration), and this table asserts exactly one call
    // site per entry. Splitting them out is more honest than loosening the count, which is
    // the property that makes this table worth having. See MissedLaunchServiceTests.

    /// The other shape, and the one to prefer: the flag is read inside the periodic callback,
    /// so the timer is always armed and the answer is always current. A launch-only gate on a
    /// flag that has a live toggle is a feature that silently does nothing until a relaunch,
    /// which is what CommitmentScheduler shipped as until a reviewer caught it.
    static let readTheirFlagPerTick: [(file: String, fn: String, flag: String)] = [
        ("Sources/Grux/Memory/PersonMemory.swift", "func checkAndFire", "personMemoryEnabled"),
        ("Sources/Grux/Memory/DecisionLog.swift", "func checkAndFire", "decisionLogEnabled"),
        ("Sources/Grux/Reminders/CommitmentScheduler.swift",
         "func scanMemoriesForNewCommitments", "ambientEnabled"),
    ]

    private func source() throws -> [String] {
        let url = LaunchConsentGateTests.repoRoot().appendingPathComponent("Sources/Grux/GruxApp.swift")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// The flag is read on the line above, not somewhere else in the file. A `config.X` read
    /// three hundred lines away is not a gate on this call.
    func testEveryAmbientStarterSitsUnderItsOwnFlag() throws {
        let src = try source()
        for (call, flag) in Self.gatedAtLaunch {
            let sites = LaunchConsentGateTests.lines(containing: call, in: src)
            XCTAssertEqual(sites.count, 1, "\(call) has \(sites.count) call sites, expected 1")
            guard let site = sites.first else { continue }
            let window = src[max(0, site - 3)...site].joined(separator: "\n")
            XCTAssertTrue(window.contains("config.\(flag)"),
                          "\(call) at line \(site + 1) does not sit under a read of "
                          + "config.\(flag), so it runs on every launch whatever the person chose")
        }
    }

    /// And the flags exist with the right defaults, read off a config DECODED from JSON that
    /// does not mention them, rather than asserted against the same constants the code uses.
    ///
    /// That distinction is the test. The decoder's `?? false` is what an existing install
    /// upgrading into this build actually runs: its config.json on disk predates these keys,
    /// so every one of them arrives absent. Asserting against `GruxConfig.defaults` would
    /// check the memberwise initialiser and leave that path unexercised.
    ///
    /// The dozen keys below are the ones `init(from:)` decodes with a bare `try c.decode`
    /// and therefore genuinely requires. They are here to make the JSON decodable at all;
    /// none of them is what is being asserted.
    func testTheDefaultsAreOffExceptTheOneThatCarriesTheCLI() throws {
        let older = """
        {
          "anthropicApiKey": "", "model": "claude", "captureIntervalSeconds": 30,
          "driftThreshold": 2, "autoPromoteDetectedTask": false,
          "notificationsEnabled": true, "screenAnalysisEnabled": true,
          "launchAtLogin": false, "snoozeMinutes": 15,
          "activeHoursStart": 6, "activeHoursEnd": 23
        }
        """
        let empty = try JSONDecoder().decode(GruxConfig.self, from: Data(older.utf8))
        XCTAssertFalse(empty.domainMonitorEnabled)
        XCTAssertFalse(empty.musicDuckingEnabled)
        XCTAssertFalse(empty.meetingAutoDetectEnabled)
        XCTAssertFalse(empty.personMemoryEnabled)
        XCTAssertFalse(empty.decisionLogEnabled)
        XCTAssertTrue(empty.controlSocketEnabled,
                      "the control socket is how the grux command reaches the app; defaulting "
                      + "it off would silence the CLI for every existing install")
    }

    /// The two nightly transcript passes read their flag inside checkAndFire, not only at
    /// start(), so switching one off stops the timer that is already running.
    func testThePeriodicPassesReadTheirFlagOnEveryTick() throws {
        for (file, fn, flag) in Self.readTheirFlagPerTick {
            let url = LaunchConsentGateTests.repoRoot().appendingPathComponent(file)
            let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: fn, in: src), file)
            XCTAssertFalse(
                LaunchConsentGateTests.lines(containing: flag, in: src)
                    .filter { body.contains($0) }.isEmpty,
                "\(file) \(fn) does not read config.\(flag), so the switch only takes effect "
                + "at the next launch")
        }
    }

    /// The commitment scheduler is ARMED unconditionally for the same reason. Wrapping its
    /// launch call in `if config.ambientEnabled` is what shipped, and it looked like the
    /// AmbientCoach line twenty lines above. It is not the same: `AmbientState.enable()` is
    /// the one door every ambient toggle goes through and it re-fires AmbientCoach itself,
    /// while this had exactly one call site in the whole tree. So turning ambient on
    /// mid-session captured memories and scheduled no commitments at all until a relaunch.
    func testTheCommitmentSchedulerIsArmedWhateverTheAmbientFlagSays() throws {
        let src = try source()
        let site = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "CommitmentScheduler.shared.start()",
                                         in: src).first)
        let window = src[max(0, site - 2)...site].joined(separator: "\n")
        XCTAssertFalse(window.contains("ambientEnabled"),
                       "CommitmentScheduler is behind a launch-time ambient check again, so "
                       + "turning ambient on mid-session schedules nothing until a relaunch")
    }

    /// AND THE FOCUS TIMER IS ARMED BEFORE THE PERMISSION EXISTS. `tick()` already checks
    /// `hasPermission()` on every pass, so a second copy of that check at the launch call
    /// site bought nothing and cost the whole first session: on a Mac that had not granted
    /// Screen Recording, `start()` was never called, no timer existed, and granting the
    /// permission during onboarding changed nothing until a relaunch. Which means the
    /// first-frame consent gate inside tick() would never be reached in the one scenario it
    /// was written for.
    func testTheFocusWatcherIsArmedBeforeThePermissionExists() throws {
        let src = try source()
        let site = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "FocusWatcher.shared.start()", in: src).first)
        let condition = src[max(0, site - 2)...site].joined(separator: "\n")
        XCTAssertFalse(condition.contains("hasPermission"),
                       "FocusWatcher.start() is behind a permission check at launch, so the "
                       + "watcher cannot start in the session where the permission is granted")
        XCTAssertTrue(condition.contains("screenAnalysisEnabled"),
                      "and it still has to respect the off switch")
    }

    /// A credential nobody handed to Grux is not a credential Grux may spend.
    ///
    /// The file and environment branches WRITE both halves into the login Keychain and then
    /// call the registrar, so this is not a read. Default false means the launch pass and the
    /// 24 hour pass cannot reach them.
    func testAmbientCredentialSourcesAreOffByDefault() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Empire/DomainMonitor.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let decl = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "func resolveCredentials(", in: src).first)
        XCTAssertTrue(src[decl].contains("allowAmbientSources: Bool = false"),
                      "resolveCredentials no longer defaults to Keychain only, so a background "
                      + "sweep can adopt ~/.grux/godaddy-creds.json again")

        let body = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "func resolveCredentials(", in: src))
        let guarded = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "guard allowAmbientSources", in: src)
                .first { body.contains($0) },
            "nothing holds the file and environment branches back")
        let fileBranch = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "godaddy-creds.json", in: src)
                .first { body.contains($0) })
        XCTAssertLessThan(guarded, fileBranch, "the guard sits after the branch it guards")
    }
}

// MARK: - Ordinary chat that started a week-long workflow

final class TriggerShapeTests: XCTestCase {

    /// `{content}` can be anything by definition, so the literal part has to carry it.
    /// One common word plus free text is a sentence.
    func testOneBareWordIsNotACommand() {
        for prefix in ["idea ", "translate ", "ship ", "  release  "] {
            XCTAssertFalse(CommandV2Engine.literalPrefixIsCommandShaped(prefix),
                           "\"\(prefix)\" plus free text would swallow ordinary chat")
        }
    }

    /// THE CONTROL, and it is the more important half: every intended phrasing still fires.
    /// A trigger rule that rejects everything is worse than the unanchored one it replaced.
    func testEveryDeliberateFormStillReads() {
        for prefix in ["idea: ", "grux idea ", "new idea ", "capture idea ", "ship the ",
                       "check status of ", "show me testflight feedback for "] {
            XCTAssertTrue(CommandV2Engine.literalPrefixIsCommandShaped(prefix),
                          "\"\(prefix)\" is a deliberate command form and stopped matching")
        }
    }

    /// A `{project}` capture has to NAME a project. `resolve(project:)` cannot answer this:
    /// its last line returns `currentDirectoryPath + "/" + name` for anything unrecognised,
    /// so it always succeeds and can never be a membership test.
    func testAProjectNameThatCannotExistDoesNotResolve() {
        for candidate in ["this email into Spanish",
                          "it when you get a chance",
                          "grux-no-such-project-anywhere-2026",
                          "",
                          "   "] {
            XCTAssertFalse(ProjectsResolver.namesAKnownProject(candidate),
                           "\"\(candidate)\" was accepted as a project name, so a sentence "
                           + "starting with ship/translate/release still starts a workflow")
        }
    }

    /// And `resolve` still answers for the same input, which is what makes this a NEW
    /// question rather than a change to the old one.
    func testResolveStillReturnsAPathForAnythingAsItAlwaysDid() {
        XCTAssertFalse(ProjectsResolver.resolve(project: "grux-no-such-project-anywhere-2026").isEmpty,
                       "resolve() changed behaviour; only the membership test was meant to be new")
    }
}

// MARK: - The commitment that appeared in the calendar once per launch

final class CommitmentDedupeTests: XCTestCase {

    private func at(_ minutesFromNow: Double) -> Date { Date().addingTimeInterval(minutesFromNow * 60) }

    /// The exact relaunch case. "I'll ship it at 9 PM" parsed at 2 PM wrote one reminder and
    /// one real Calendar event; relaunching at 4 PM parsed the same sentence, found it still
    /// in the future, and wrote a second of each.
    func testTheSameCommitmentAtTheSameTimeIsNotScheduledTwice() {
        let fireAt = at(180)
        XCTAssertTrue(CommitmentScheduler.isAlreadyScheduled(
            text: "I'll ship it at 9 PM", firingAt: fireAt,
            existing: [(text: "I'll ship it at 9 PM", at: fireAt)]))
    }

    /// Matched to the minute, not to the second, because the parse re-runs and floats.
    func testASecondsLevelDifferenceIsStillTheSameCommitment() {
        let fireAt = at(180)
        XCTAssertTrue(CommitmentScheduler.isAlreadyScheduled(
            text: "ship it", firingAt: fireAt,
            existing: [(text: "ship it", at: fireAt.addingTimeInterval(31))]))
    }

    /// THE CONTROL, three ways. Collapsing on text alone would lose a commitment somebody
    /// genuinely made twice, and an empty book must never look full.
    func testGenuinelyDifferentCommitmentsAreNotCollapsed() {
        let fireAt = at(180)
        XCTAssertFalse(CommitmentScheduler.isAlreadyScheduled(
            text: "ship it", firingAt: fireAt,
            existing: [(text: "ship it", at: fireAt.addingTimeInterval(24 * 3600))]),
            "the same words tomorrow is a different commitment")
        XCTAssertFalse(CommitmentScheduler.isAlreadyScheduled(
            text: "ship it", firingAt: fireAt,
            existing: [(text: "call mum", at: fireAt)]),
            "different words at the same time is a different commitment")
        XCTAssertFalse(CommitmentScheduler.isAlreadyScheduled(
            text: "ship it", firingAt: fireAt, existing: []),
            "nothing is scheduled, so nothing can be a duplicate")
    }

    /// A row with no fire time cannot match anything: `scheduledFor` is optional and nil
    /// means "fire immediately", which is not a time this can compare against.
    func testARowWithNoTimeIsNotAMatch() {
        XCTAssertFalse(CommitmentScheduler.isAlreadyScheduled(
            text: "ship it", firingAt: at(180),
            existing: [(text: "ship it", at: nil)]))
    }
}

// MARK: - The two empty folders in somebody's Documents

final class BackupPathSideEffectTests: XCTestCase {

    /// Naming a place is not making one.
    ///
    /// Driven against a temp home rather than the real one ON PURPOSE. ~/Documents/Grux
    /// already exists on any machine that has run Grux, so asserting "it was not created"
    /// against the real home passes whether the accessor creates or not, which is a test
    /// that cannot fail. This is the second time in this session that reaching for a real
    /// path produced a vacuous assertion.
    func testAskingWhereBackupsGoDoesNotCreateAnything() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grux-backup-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let path = BackupManager.backupsPath(home: home)
        XCTAssertEqual(path.lastPathComponent, "backups")

        let documents = home.appendingPathComponent("Documents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.path),
                       "computing the backup path created \(documents.path), which is how two "
                       + "empty folders appeared in somebody's Documents during a first launch "
                       + "for a feature that was off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    /// And the scheduler's fallback uses the accessor that does not create.
    func testTheSchedulerFallbackUsesTheNonCreatingAccessor() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Backup/BackupScheduler.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let hits = LaunchConsentGateTests.lines(containing: "defaultBackupsPath", in: src)
        XCTAssertFalse(hits.isEmpty, "the scheduler no longer uses the non-creating accessor")
        XCTAssertTrue(LaunchConsentGateTests.lines(containing: "defaultBackupsDir", in: src).isEmpty,
                      "the creating accessor is back in the scheduler's init")
    }
}

// MARK: - The pause that forgot, and the capture that started on somebody else's grant

final class FocusWatcherGateTests: XCTestCase {

    private func source() throws -> [String] {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/FocusWatcher.swift")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// One owner for the off switch. The menu bar read Watching, the click read Paused, and
    /// the next launch was Watching again because the pause only cleared an @Published flag
    /// that never reached disk while the launch path re-read a config flag that ships true.
    func testBothHalvesOfThePausePersist() throws {
        let src = try source()
        for fn in ["func start()", "func stop()"] {
            let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: fn, in: src), fn)
            XCTAssertFalse(
                LaunchConsentGateTests.lines(containing: "persistWatchingChoice", in: src)
                    .filter { body.contains($0) }.isEmpty,
                "FocusWatcher.\(fn) does not persist the choice, so it is forgotten on quit")
        }
        let persist = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "func persistWatchingChoice", in: src))
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "screenAnalysisEnabled", in: src)
                .filter { persist.contains($0) }.isEmpty,
            "it writes something other than the flag the launch path reads, which is exactly "
            + "the two-switches-that-disagree bug")
    }

    /// The contract's own two conditions, in tick() rather than only at launch so the gate
    /// can OPEN mid-session. The Screen Recording grant that used to be sufficient is the
    /// SAME grant the contract asks for to transcribe meetings.
    func testCaptureWaitsForTheStepThatPromisedToShowYouAFrameFirst() throws {
        let src = try source()
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "func tick", in: src))
        // BOTH steps the registry declares for `focus`, not just the famous one. On the Mac
        // Mini `step.first_frame_reviewed` read TRUE and `step.capture_exclusions_confirmed`
        // read false, so the second one is what actually holds the line there.
        for condition in ["stepFirstFrameReviewed", "stepCaptureExclusionsConfirmed",
                          "FeatureSelection.isOn(\"focus\")"] {
            XCTAssertFalse(
                LaunchConsentGateTests.lines(containing: condition, in: src)
                    .filter { body.contains($0) }.isEmpty,
                "tick() does not check \(condition), so capture starts on a permission the "
                + "person granted for something else")
        }
    }
}

// MARK: - The digests nobody could stop

final class SocialOpsDigestSwitchTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SocialOpsCoordinator.digestsEnabledKey)
        super.tearDown()
    }

    /// ON by default: somebody who pointed Grux at a posting service wants to know when an
    /// account goes dark, and that is the stated purpose. What was missing was any way to
    /// say no, so the only way to stop a daily notification was to stop launching Grux.
    func testTheDigestIsOnUntilSomebodySaysOtherwise() {
        UserDefaults.standard.removeObject(forKey: SocialOpsCoordinator.digestsEnabledKey)
        XCTAssertTrue(SocialOpsCoordinator.digestsEnabled)
        UserDefaults.standard.set(false, forKey: SocialOpsCoordinator.digestsEnabledKey)
        XCTAssertFalse(SocialOpsCoordinator.digestsEnabled, "the off switch does not read")
    }

    /// The step that gated nothing. Its config key `grux.social.accounts` has no writer
    /// anywhere in the app, so it could be ticked green while every Social Ops surface stayed
    /// empty. The real gate was a file the contract never mentioned, and the remediation now
    /// names that file.
    func testTheRemediationNamesTheFileThatIsActuallyTheGate() {
        let remediation = SetupRequirement.endpointSocialAccounts.remediation
        XCTAssertTrue(remediation.contains("social-ops-hosts.txt"),
                      "the remediation still sends people to a Settings screen that does not "
                      + "write anything: \(remediation)")
    }
}

// MARK: - Consent that nobody gave, and a gate that could not bite

@MainActor
final class FirstFrameConsentTests: XCTestCase {

    /// THE ONE THAT WAS TRUE ON A MACHINE WHERE IT COULD NOT POSSIBLY BE TRUE.
    ///
    /// `step.first_frame_reviewed` resolved as `stage == .done && !skippedFirstLook`. But
    /// `.firstLook` is only in the flow `if level.includesPermissions`
    /// (OnboardingModel.stages(for:)), so somebody who picks Level 1 is never shown a frame,
    /// never skips a screen they never reached, and finishes with both conditions passing.
    ///
    /// MEASURED, not reasoned. The Mac Mini had never run Grux before this week, and its
    /// `~/Library/Application Support/Grux/onboarding.json` reads:
    ///
    ///     { "level": "essentials", "skipped": [], "skippedFirstLook": false, "stage": "done" }
    ///
    /// which is precisely the state described above: Level 1, nothing skipped because nothing
    /// was offered, flow finished. The old condition `done && !skippedFirstLook` evaluates
    /// TRUE on that file. Its setup-status.json agrees and reports
    /// `step.first_frame_reviewed` true while `perm.screen_recording` is false, so no frame
    /// had ever been captured on that machine, let alone reviewed. The contract's own words for the step are "Grux will show you one
    /// frame, and the exact text it would send, before anything leaves your Mac. Nothing is
    /// sent until you approve."
    func testFinishingTheShortestFlowIsNotConsentToSendAFrame() {
        XCTAssertFalse(
            CapabilityResolver.firstFrameWasReviewed(
                stage: .done, skippedFirstLook: false, level: .essentials),
            "Level 1 never shows a frame, so finishing it cannot count as having reviewed one")
    }

    /// THE CONTROL. A consent gate that can never be satisfied is worse than one that is
    /// always open, because it silently disables the feature with no way forward.
    func testTheLevelsThatDoShowAFrameStillCount() {
        for level in [OnboardingModel.Level.plusPermissions, .everything] {
            XCTAssertTrue(
                CapabilityResolver.firstFrameWasReviewed(
                    stage: .done, skippedFirstLook: false, level: level),
                "\(level) includes the first look and still does not count as reviewed")
        }
    }

    /// The two original conditions still hold on their own terms.
    func testAnUnfinishedOrSkippedFlowIsStillNotConsent() {
        XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(
            stage: .permissions, skippedFirstLook: false, level: .everything),
            "the flow is not finished")
        XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(
            stage: .done, skippedFirstLook: true, level: .everything),
            "they were shown the frame and skipped it, which is a no")
    }

    /// And the level that never shows a frame genuinely never shows one, read from the flow
    /// itself rather than asserted against the same condition the code uses.
    func testTheShortestFlowGenuinelyHasNoFirstLookStage() {
        XCTAssertFalse(OnboardingModel.stages(for: .essentials).contains(.firstLook))
        XCTAssertTrue(OnboardingModel.stages(for: .plusPermissions).contains(.firstLook))
    }
}

// MARK: - The briefing gate that was inert on the machine it was written for

final class BriefingReadinessGateTests: XCTestCase {

    /// `FeatureSelection.isOn` returns TRUE for everything when nobody has ever chosen, and
    /// NOTHING IN THE APP EVER CHOOSES: every writer of a selection lives in
    /// GruxControlTools, which is the CLI. Measured on the Mac Mini, which has run only the
    /// app: 39 of 39 features reported `chosen: true` and `grux.features.selected` is not in
    /// its defaults domain at all.
    ///
    /// So the gate has to ask a question that a fresh Mac answers NO to. It asks the
    /// registry, which resolves `jax.hq`'s `requires: [.endpointImap]`.
    func testTheBriefingAsksTheRegistryRatherThanTheSelection() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Jax/BriefingEngine.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let tick = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "func tick", in: src))
        XCTAssertTrue(
            LaunchConsentGateTests.lines(containing: "jaxHQIsReady", in: src)
                .contains { tick.contains($0) },
            "tick() no longer asks whether Jax HQ is ready")
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "FeatureSelection.isOn", in: src)
                .contains { tick.contains($0) },
            "tick() is back on FeatureSelection.isOn, which returns true for everything on a "
            + "machine where nobody has ever chosen, which is every machine that has only "
            + "ever run the app")
    }

    /// AND THE BRIEFING HAS ITS OWN CONSENT, which the readiness gate cannot supply.
    ///
    /// Readiness asks whether Jax HQ is ready, which means "is there a mail account".
    /// Connecting an inbox is not consent to be spoken to twice a day, and `endpoint.imap` is
    /// the LAST entry in `OnboardingModel.connectionOrder`, so the first person to finish the
    /// connections flow would have got a talking Mac at 07:00 having never been asked.
    func testSpeakingNeedsItsOwnSwitchAndTheSwitchIsOff() throws {
        let older = #"""
        {
          "anthropicApiKey": "", "model": "claude", "captureIntervalSeconds": 30,
          "driftThreshold": 2, "autoPromoteDetectedTask": false,
          "notificationsEnabled": true, "screenAnalysisEnabled": true,
          "launchAtLogin": false, "snoozeMinutes": 15,
          "activeHoursStart": 6, "activeHoursEnd": 23
        }
        """#
        let cfg = try JSONDecoder().decode(GruxConfig.self, from: Data(older.utf8))
        XCTAssertFalse(cfg.spokenBriefingsEnabled)
        XCTAssertTrue(cfg.speakRepliesAloud,
                      "control: the general speech setting still ships ON, which is why the "
                      + "briefing needed a switch of its own rather than leaning on that one")

        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Jax/BriefingEngine.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "private func speak(", in: src))
        let own = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "spokenBriefingsEnabled", in: src)
                .first { body.contains($0) },
            "speak() does not read its own switch")
        let spoke = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "SpeechEngine.shared", in: src)
                .first { body.contains($0) })
        XCTAssertLessThan(own, spoke)
    }

    /// And the readiness helper demands READY specifically. `.notChosen` and `.needsSetup`
    /// both have to keep the Mac quiet, and needsSetup is what a fresh Mac actually reports
    /// for jax.hq because it has no mail account.
    func testOnlyReadyOpensTheGate() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/Jax/BriefingEngine.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "static func jaxHQIsReady", in: src))
        let line = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "FeatureRegistry.state", in: src)
                .first { body.contains($0) },
            "jaxHQIsReady no longer consults the registry")
        XCTAssertTrue(src[line].contains("== .ready"),
                      "the gate accepts a state other than .ready: \(src[line].trimmingCharacters(in: .whitespaces))")
    }
}

// MARK: - The launch path past the twenty five

@MainActor
final class MissedLaunchServiceTests: XCTestCase {

    private func gruxApp() throws -> [String] {
        let url = LaunchConsentGateTests.repoRoot().appendingPathComponent("Sources/Grux/GruxApp.swift")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// The orb is a floating always-on-top window that defaults ON, and it went up over the
    /// setup flow. The focus overlay eleven lines above it already carries the gate and the
    /// comment explaining exactly this, which is what makes the omission legible: the smaller
    /// card was held back and the larger window that sits on every Space was not.
    func testTheOrbWaitsForOnboardingLikeTheOverlayBesideIt() throws {
        let src = try gruxApp()
        let site = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "OrbAnywhereController.shared.show()", in: src)
                .last)
        let window = src[max(0, site - 4)...site].joined(separator: "\n")
        XCTAssertTrue(window.contains("OnboardingModel.shared.stage == .done"),
                      "the floating orb goes up during the first-run flow")
    }

    /// A file any local process can write, whose contents reach ChatService.send() and
    /// therefore a model with tools. It is a debug seam that shipped, and it had no flag, no
    /// consent step and no stop(). Now behind the same switch as the control socket, because
    /// it is the same kind of thing.
    func testTheInjectChatFileIsBehindTheMachineInterfaceSwitch() throws {
        let src = try gruxApp()
        let site = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "startInjectChatWatcher()", in: src).first)
        let window = src[max(0, site - 3)...site].joined(separator: "\n")
        XCTAssertTrue(window.contains("controlSocketEnabled"),
                      "anything written to ~/.grux/inject-chat.txt still reaches a model with "
                      + "tools, with no way to turn it off")
    }

    /// The contract has declared `grux.foundry.enabled` as "the self-upgrade loop, off by
    /// default" the whole time. Nothing read it, so the governor's 60 second tick ran on
    /// every launch and scheduled a nightly pass that spends model tokens.
    func testTheSelfUpgradeLoopIsOffAsTheContractAlwaysSaid() throws {
        let older = """
        {
          "anthropicApiKey": "", "model": "claude", "captureIntervalSeconds": 30,
          "driftThreshold": 2, "autoPromoteDetectedTask": false,
          "notificationsEnabled": true, "screenAnalysisEnabled": true,
          "launchAtLogin": false, "snoozeMinutes": 15,
          "activeHoursStart": 6, "activeHoursEnd": 23
        }
        """
        let cfg = try JSONDecoder().decode(GruxConfig.self, from: Data(older.utf8))
        XCTAssertFalse(cfg.foundryEnabled)

        let src = try gruxApp()
        let site = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "FoundryEngine.shared.activate()", in: src).first)
        let window = src[max(0, site - 3)...site].joined(separator: "\n")
        XCTAssertTrue(window.contains("foundryEnabled"),
                      "the self-upgrade governor starts on every launch regardless")
    }

    /// And the contract row no longer says nobody implements it, because somebody does now.
    func testTheContractNoLongerCallsTheFoundryKeyUnimplemented() throws {
        let contract = try String(
            contentsOf: LaunchConsentGateTests.repoRoot().appendingPathComponent("docs/contract.md"),
            encoding: .utf8)
        let row = try XCTUnwrap(
            contract.components(separatedBy: "\n").first { $0.hasPrefix("| `grux.foundry.enabled`") })
        XCTAssertFalse(row.contains("not implemented"), row)
    }
}

// MARK: - The hotkey that walked round the consent step

final class TerminalOverlayHotkeyTests: XCTestCase {

    /// Holding the LAUNCH path was not enough. `GlobalHotkey.register` claims Option-Cmd-T
    /// unconditionally, and pressing it reaches `showOverlay()`, which force-set
    /// `isEnabled = true` and called `refresh()` straight past `startIfAllowed()`. `refresh()`
    /// shells osascript at Terminal, so that is the same Automation consent dialog the launch
    /// fix removed, reached by a key combination nobody has been told about.
    ///
    /// Force-enabling the kill-switch is kept on purpose: pressing the hotkey IS a request
    /// for the feature. What does not follow is permission to speak to another app before
    /// the step that explains what this does.
    func testSummoningTheOverlayCannotOutrunTheConsentStep() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/TerminalFocusState.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let body = try XCTUnwrap(LaunchConsentGateTests.bodyLines(of: "func showOverlay", in: src))

        let gate = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "startIfAllowed()", in: src)
                .first { body.contains($0) },
            "showOverlay() does not go through the gate, so the hotkey reaches the system directly")
        let refresh = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "refresh()", in: src)
                .first { body.contains($0) })
        XCTAssertLessThan(gate, refresh, "refresh() runs before the gate is consulted")
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "hasStartedWatching", in: src)
                .filter { body.contains($0) }.isEmpty,
            "nothing stops refresh() when the gate declined")
    }
}
