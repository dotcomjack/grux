import XCTest
@testable import Grux
import GruxAgentCore

/// D160 (found by D157 item 3's class test): Agents, Jax Command and
/// Self-Upgrade list "Install the agent command line tool" with no button, and
/// its sentence, "Install the coding agent command line tool, then restart
/// Grux. It was not found at any location Grux checks.", never named the tool
/// or how to install it, and asked for a relaunch Grux does not need.
@MainActor
final class SetupCardAgentToolTests: XCTestCase {

    /// The step names the tool, and its sentence holds the one line that
    /// installs it, so `grux status` (which has no button) says it too.
    func testTheStepNamesTheToolAndTheLineThatInstallsIt() {
        let step = SetupRequirement.stepAgentCliInstalled
        XCTAssertEqual(step.label, "Install Claude Code")
        XCTAssertTrue(step.remediation.contains(ClaudeBinaryLocator.installCommand), step.remediation)
        XCTAssertTrue(step.remediation.contains("Terminal"), step.remediation)
        XCTAssertFalse(step.remediation.lowercased().contains("restart"),
                       "Grux re-reads the disk, so nobody restarts it: \(step.remediation)")
        XCTAssertLessThan(step.remediation.count, 140)
    }

    /// The installer writes where Grux looks first, so what the line installs
    /// is what the step detects.
    func testTheInstallerLandsWhereGruxLooksFirst() {
        XCTAssertEqual(ClaudeBinaryLocator.installCommand, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(ClaudeBinaryLocator.candidatePaths(home: "/Users/x").first, "/Users/x/.local/bin/claude")
    }

    /// The card's button copies that line, and the step is off the
    /// no-button list.
    func testTheCardCopiesTheInstallLine() {
        XCTAssertEqual(CapabilitySetupCard.stepRoute(for: .stepAgentCliInstalled),
                       .copy(ClaudeBinaryLocator.installCommand))
        XCTAssertEqual(CapabilitySetupCard.actionTitle(for: .stepAgentCliInstalled), "Copy the command")
        XCTAssertFalse(CapabilitySetupCard.knownWithoutButton.contains(.stepAgentCliInstalled))
    }

    /// Installed from Terminal while the card is up, the step clears with no
    /// relaunch: the card re-reads the steps a person completes outside Grux
    /// while it lists one, and redraws every surface when one lands.
    func testTheCardSeesTheInstallLandWithoutARelaunch() throws {
        XCTAssertEqual(CapabilitySetupCard.detectedOutsideGrux, [.stepAgentCliInstalled])
        XCTAssertTrue(CapabilitySetupCard.landedOutsideGrux(listed: [.stepAgentCliInstalled],
                                                            satisfied: { _ in true }))
        XCTAssertFalse(CapabilitySetupCard.landedOutsideGrux(listed: [.stepAgentCliInstalled],
                                                             satisfied: { _ in false }))
        XCTAssertFalse(CapabilitySetupCard.landedOutsideGrux(listed: [], satisfied: { _ in true }),
                       "nothing listed, nothing to re-read")
        XCTAssertFalse(CapabilitySetupCard.landedOutsideGrux(listed: [.keyBrave], satisfied: { _ in true }),
                       "only steps done outside Grux are polled; a key is read when the card redraws")
        let card = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/SetupCardAgentToolTests.swift", with: "Sources/Grux/Onboarding/CapabilitySetupCard.swift"))
        XCTAssertTrue(card.contains("Timer.publish(every: Self.recheckSeconds"), "the card never re-reads the disk")
        XCTAssertTrue(card.contains("NSApplication.didBecomeActiveNotification"), "coming back from Terminal re-reads nothing")
        XCTAssertTrue(card.contains("if outsideWatch.tick(nowMissing: nowMissing) { SetupRevision.shared.bump() }"),
                      "a landed install redraws nothing")
        XCTAssertTrue(card.contains(".onAppear { recheckOutsideSteps() }"), "the first read waits for the first tick")
    }

    /// W52-FIX (wave 52 review, P2-4): the re-check was proven only as text in
    /// the view, so dropping the line that remembers the last read passed. The
    /// watch is driven here: first read records, a step that lands is seen
    /// once, one still missing or never listed is not.
    func testTheWatchSeesAnInstallLandOnceAndOnlyOnce() {
        var watch = CapabilitySetupCard.OutsideStepWatch()
        XCTAssertNil(watch.missing)
        XCTAssertFalse(watch.tick(nowMissing: [.stepAgentCliInstalled]), "the first read only records")
        XCTAssertEqual(watch.missing, [.stepAgentCliInstalled])
        XCTAssertFalse(watch.tick(nowMissing: [.stepAgentCliInstalled]), "still missing")
        XCTAssertTrue(watch.tick(nowMissing: []), "the install landed")
        XCTAssertFalse(watch.tick(nowMissing: []), "landed once, redraws once")
        // Installed before the card first read it: nothing to see land.
        var already = CapabilitySetupCard.OutsideStepWatch()
        XCTAssertFalse(already.tick(nowMissing: []))
        XCTAssertFalse(already.tick(nowMissing: []))
        // Removed again, then reinstalled: seen landing again.
        XCTAssertFalse(already.tick(nowMissing: [.stepAgentCliInstalled]))
        XCTAssertTrue(already.tick(nowMissing: []))
    }
}
