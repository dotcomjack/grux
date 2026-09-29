import XCTest
@testable import Grux

/// A card that sends somebody to grant something has to be able to notice.
///
/// Reported from the Mac Mini, 2026-08-30, at step 7 of 8: the owner granted
/// Automation in System Settings, toggled it off and on again to force
/// something to happen, and the card never moved. Two independent defects,
/// either of which alone was enough:
///
/// 1. `perm.automation` read `grux.capability.automation_observed`, a
///    UserDefaults key that NOTHING IN THE CODEBASE EVER WROTE. `bool(forKey:)`
///    on an unset key is false, so the answer was false on every read forever
///    and no grant could ever satisfy it.
/// 2. The only re-check ran on `didBecomeActive`, so even a working check would
///    have waited for him to come back to Grux and look.
@MainActor
final class PermissionRefreshTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The verdict

    /// A grant on any target wins, because Automation IS per target.
    func testAnyGrantedTargetCountsAsGranted() {
        XCTAssertTrue(CapabilityResolver.automationVerdict(
            statuses: [OSStatus(procNotFound), OSStatus(noErr)], previous: false))
    }

    /// An explicit refusal turns it off even if it was on before.
    func testAnExplicitRefusalRevokesAPreviousGrant() {
        XCTAssertFalse(CapabilityResolver.automationVerdict(
            statuses: [OSStatus(errAEEventNotPermitted)], previous: true))
    }

    /// A grant outranks a refusal on a different target. One yes is a yes.
    func testAGrantOutranksARefusalOnAnotherTarget() {
        XCTAssertTrue(CapabilityResolver.automationVerdict(
            statuses: [OSStatus(errAEEventNotPermitted), OSStatus(noErr)], previous: false))
    }

    /// THE ONE THAT MATTERS MOST. `-600` means the target app is not running,
    /// so TCC has nothing to say about it. Reading that as "not granted" would
    /// switch a real grant back off the moment somebody quit Terminal.
    func testATargetThatIsNotRunningNeverChangesTheAnswer() {
        let closed = [OSStatus(procNotFound), OSStatus(procNotFound)]
        XCTAssertTrue(CapabilityResolver.automationVerdict(statuses: closed, previous: true),
                      "A closed target must not revoke a grant.")
        XCTAssertFalse(CapabilityResolver.automationVerdict(statuses: closed, previous: false),
                       "A closed target must not invent a grant either.")
    }

    /// Undecided is not refused. It says nothing and leaves the record alone.
    func testNotYetDecidedLeavesTheRecordAlone() {
        let undecided = [OSStatus(errAEEventWouldRequireUserConsent)]
        XCTAssertTrue(CapabilityResolver.automationVerdict(statuses: undecided, previous: true))
        XCTAssertFalse(CapabilityResolver.automationVerdict(statuses: undecided, previous: false))
    }

    // MARK: - The writer that did not exist

    /// The key must have a writer.
    ///
    /// This is the actual reported bug expressed as an assertion: remove the
    /// key, run the refresh, and require that something wrote it. Against the
    /// code they hit, nothing did, so the key stayed absent.
    ///
    /// UserDefaults persists across `swift test` runs, so teardown REMOVES
    /// rather than restoring a fabricated value.
    func testRefreshingTheObservationActuallyWritesTheKey() {
        let key = CapabilityResolver.automationObservedKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // A stubbed probe: the real one blocks while the screen is locked.
        var asked: [String] = []
        UserDefaults.standard.removeObject(forKey: key)
        CapabilityResolver.refreshAutomationObservation(probe: { asked.append($0); return OSStatus(noErr) })
        XCTAssertEqual(asked, CapabilityResolver.automationTargets, "the refresh did not ask about every target")
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true, "a grant was not recorded")
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key),
                        "Nothing wrote the automation observation, so the Automation card "
                            + "can never be satisfied no matter what the user grants.")
    }

    /// The probe asks about applications Grux actually drives.
    func testTheProbedTargetsAreOnesGruxReallyAutomates() throws {
        XCTAssertFalse(CapabilityResolver.automationTargets.isEmpty)
        // Terminal is the most-automated target in the codebase, so if the list
        // ever stops naming it the probe has drifted from what Grux does.
        XCTAssertTrue(CapabilityResolver.automationTargets.contains("com.apple.Terminal"))
        for id in CapabilityResolver.automationTargets {
            XCTAssertTrue(id.contains("."), "\(id) is not a bundle identifier")
        }
    }

    // MARK: - Noticing without being told

    /// The card polls, so a grant lands without the user coming back to check.
    ///
    /// Source-pinned because it is a view modifier: a behavioural test would
    /// need a running permissions screen and a real TCC change mid-test.
    func testThePermissionsCardRechecksOnATimerAndNotOnlyOnReturn() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingSteps.swift")
        XCTAssertTrue(src.contains("while !Task.isCancelled"),
                      "The permissions card no longer polls, so it is back to only "
                        + "noticing a grant when the user returns to Grux.")
        XCTAssertTrue(src.contains("await recheck()"),
                      "Nothing calls recheck().")
        XCTAssertTrue(src.contains("NSApplication.didBecomeActiveNotification"),
                      "The on-return recheck was dropped.")
    }

    /// The recheck refreshes the two capabilities that cannot be read live.
    func testTheRecheckRefreshesBothStaleCapabilities() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingSteps.swift")
        let lines = src.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("private func recheck() async") })
        else { return XCTFail("recheck() was renamed or removed.") }
        let body = lines[i ..< min(i + 20, lines.count)].joined(separator: "\n")
        XCTAssertTrue(body.contains("refreshedNotificationAuthorization"),
                      "recheck no longer refreshes the cached notification answer.")
        XCTAssertTrue(body.contains("refreshAutomationObservation"),
                      "recheck no longer refreshes the automation observation, so the "
                        + "Automation card is back to reading a value nothing updates.")
    }

    // MARK: - Skipping while the probe is out

    /// THE CARD AFTER MUST NOT BE PASSED. The re-check awaits its probe, and the person can
    /// press Skip meanwhile. Deciding from the card that was up when the probe started
    /// called `next()` a second time on the grant, passing the following card unseen.
    /// Stubbed: the refresh moves the person on, and the permission reads granted.
    func testSkippingWhileTheProbeIsOutDoesNotPassTheNextCard() async {
        var current: SetupRequirement? = .permAutomation
        let advance = await PermissionsRecheck.shouldAdvance(
            .permAutomation,
            refresh: { _ in current = .permFullDiskAccess },
            isSatisfied: { _ in true },
            current: { current })
        XCTAssertFalse(advance, "a grant for a card the person had already skipped moved past the next one")
    }

    func testAGrantOnTheCardStillShowingAdvances() async {
        let advance = await PermissionsRecheck.shouldAdvance(
            .permAutomation, refresh: { _ in }, isSatisfied: { _ in true }, current: { .permAutomation })
        XCTAssertTrue(advance)
    }

    func testNoGrantDoesNotAdvance() async {
        let advance = await PermissionsRecheck.shouldAdvance(
            .permAutomation, refresh: { _ in }, isSatisfied: { _ in false }, current: { .permAutomation })
        XCTAssertFalse(advance)
    }

    /// And the card's re-check decides through it, so the guard is the one that runs.
    func testThePermissionsRecheckDecidesAfterTheProbe() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingSteps.swift")
        let lines = src.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("private func recheck() async") })
        else { return XCTFail("recheck() was renamed or removed.") }
        let body = lines[i ..< min(i + 20, lines.count)].joined().filter { !$0.isWhitespace }
        XCTAssertTrue(body.contains("PermissionsRecheck.shouldAdvance(req,"),
                      "the permissions card decides without the after-the-probe guard")
        XCTAssertTrue(body.contains("current:{current})guardmoveelse{return}"),
                      "the permissions card does not pass where the person is now")
    }

}
