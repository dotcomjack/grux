import XCTest
@testable import Grux

/// The Self-Upgrade card tells a person what to do next, in words they can act
/// on, and it never says "Build it" when it cannot build. Every decision here
/// is a pure function over measured inputs so the matrix is asserted directly
/// rather than by driving the app into each state.
@MainActor
final class SelfUpgradeDirectionTests: XCTestCase {

    // MARK: - Fixtures

    private func card(
        stage: FoundryProposalStage = .proposed,
        evidence: [String] = ["manual: the sidebar has no groups", "transcript: asked for favorites twice"],
        touchedPaths: [String] = ["Sources/Grux/DesignSystem/SidebarModel.swift"]
    ) -> FoundryProposalCardModel {
        FoundryProposalCardModel(
            id: "card-1",
            title: "Sidebar IA: four collapsible groups plus pinned favorites",
            lane: "UX Polish",
            domain: "Mac",
            evidence: evidence,
            expectedGain: "Expected gain score 86 of 100",
            estimatedCostUSD: 8,
            risk: "Medium",
            tierRequired: 0,
            score: 0.86,
            readyPrompt: "Group the sidebar into four collapsible sections and add a pinned favorites row.",
            status: stage == .proposed ? .pending : (stage == .rejected || stage == .rolledBack ? .rejected : .accepted),
            stage: stage,
            touchedPaths: touchedPaths
        )
    }

    private func ready(
        auth: FoundryAuthState = .signedIn,
        subscriptionType: String? = "max",
        cliInstalled: Bool = true,
        foundryEnabled: Bool = true,
        sourceAvailable: Bool = true,
        stage: FoundryProposalStage = .proposed,
        buildInFlight: Bool = false,
        escalatedJobId: String? = nil,
        approvalPending: Bool = false
    ) -> FoundryBuildReadiness {
        FoundryBuildReadiness(
            auth: auth,
            subscriptionType: subscriptionType,
            cliInstalled: cliInstalled,
            foundryEnabled: foundryEnabled,
            sourceAvailable: sourceAvailable,
            stage: stage,
            buildInFlight: buildInFlight,
            escalatedJobId: escalatedJobId,
            approvalPending: approvalPending
        )
    }

    // MARK: - The power line names the real subscription, or nothing

    func testPowerLineNamesTheSubscription() {
        XCTAssertEqual(FoundryDirection.powerLine(subscriptionType: "max"), "powered by your Claude Max subscription")
        XCTAssertEqual(FoundryDirection.powerLine(subscriptionType: "pro"), "powered by your Claude Pro subscription")
        XCTAssertEqual(FoundryDirection.powerLine(subscriptionType: "team"), "powered by your Claude Team subscription")
        XCTAssertEqual(FoundryDirection.powerLine(subscriptionType: "enterprise"), "powered by your Claude Enterprise subscription")
        XCTAssertEqual(FoundryDirection.powerLine(subscriptionType: " Max "), "powered by your Claude Max subscription")
        // No plan the CLI names, no claim: the line is nil rather than a
        // generic sentence that would sit under a clickable Build it.
        XCTAssertNil(FoundryDirection.powerLine(subscriptionType: nil))
        XCTAssertNil(FoundryDirection.powerLine(subscriptionType: ""))
        XCTAssertNil(FoundryDirection.powerLine(subscriptionType: "free"))
    }

    func testSignedInWithoutAPaidPlanGetsItsOwnHonestState() {
        for plan in [nil, "", "free", "console"] as [String?] {
            let action = FoundryDirection.primaryAction(ready(subscriptionType: plan))
            XCTAssertEqual(action, .noPaidPlan, "plan \(String(describing: plan)) offered \(action)")
            XCTAssertFalse(action.isActionable, "a free or unknown login must never click into a build")
            XCTAssertFalse(action.title.contains("Build it"))
            XCTAssertTrue(action.subtitle.contains("Pro"), "the copy names the plans that can build")
            XCTAssertTrue(action.subtitle.contains("handoff"), "and the way forward without one")
        }
        // The foundry-off variant is gated the same way.
        XCTAssertEqual(FoundryDirection.primaryAction(ready(subscriptionType: "free", foundryEnabled: false)), .noPaidPlan)
    }

    // MARK: - Auth is three states, and "not checked yet" is not "signed out"

    func testAuthStateMapping() {
        let live = AccountSwitcher.LiveStatus(loggedIn: true, authMethod: "claude.ai", email: nil, orgId: nil,
                                              orgName: nil, subscriptionType: "max", checkedAt: Date())
        let out = AccountSwitcher.LiveStatus(loggedIn: false, authMethod: nil, email: nil, orgId: nil,
                                             orgName: nil, subscriptionType: nil, checkedAt: Date())
        XCTAssertEqual(FoundryDirection.authState(checked: false, liveStatus: nil), .checking)
        XCTAssertEqual(FoundryDirection.authState(checked: false, liveStatus: live), .signedIn,
                       "a status already in hand is used even before the flag flips")
        XCTAssertEqual(FoundryDirection.authState(checked: true, liveStatus: nil), .signedOut,
                       "a check that came back with nothing is signed out, not checking forever")
        XCTAssertEqual(FoundryDirection.authState(checked: true, liveStatus: out), .signedOut)
        XCTAssertEqual(FoundryDirection.authState(checked: true, liveStatus: live), .signedIn)
    }

    func testCheckingSignInIsNeutralAndNotClickable() {
        let action = FoundryDirection.primaryAction(ready(auth: .checking, subscriptionType: nil))
        XCTAssertEqual(action, .checkingSignIn)
        XCTAssertEqual(action.title, "Checking your sign-in")
        XCTAssertFalse(action.isActionable)
        XCTAssertFalse(action.title.lowercased().contains("sign in to"), "never reads as signed out while unknown")
        // The CLI gate still wins: no CLI means nothing to check.
        XCTAssertEqual(FoundryDirection.primaryAction(ready(auth: .checking, subscriptionType: nil, cliInstalled: false)), .installCLI)
    }

    // MARK: - A checkout that vanished after the tab loaded

    func testNoSourceCopyNamesTheWayOut() {
        let action = FoundryDirection.primaryAction(ready(sourceAvailable: false))
        XCTAssertEqual(action, .noSource)
        XCTAssertTrue(action.subtitle.contains("build.sh"), "rebuilding from the source folder is one way out")
        XCTAssertTrue(action.subtitle.contains("handoff"), "the handoff is the other")
    }

    func testAVanishedRootIsRecordedOnTheTimelineNotJustTheLog() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-foundry-missing-source-\(UUID().uuidString).json")
        let timeline = FoundryTimelineStore(storageURL: url)
        let proposal = UpgradeProposal(title: "Debounce orb glow", lane: .performance, domain: .mac,
                                       expectedGain: 0.5, riskClass: .low, estCostLabel: "$2 estimated",
                                       tierRequired: .propose, readyPrompt: "p")
        FoundryEngine.noteMissingSource(for: proposal, timeline: timeline)
        XCTAssertEqual(timeline.entries.count, 1)
        let entry = try XCTUnwrap(timeline.entries.first)
        XCTAssertTrue(entry.title.contains("Debounce orb glow"))
        XCTAssertTrue(entry.title.lowercased().contains("could not start"))
        XCTAssertTrue(entry.detail.contains("build.sh"))
        XCTAssertTrue(entry.detail.contains("handoff"))
        XCTAssertEqual(entry.lane, "Performance")
    }

    // MARK: - The primary action, one state at a time

    func testSignedInAndReadyOffersBuildIt() {
        let action = FoundryDirection.primaryAction(ready())
        XCTAssertEqual(action, .build(power: "powered by your Claude Max subscription"))
        XCTAssertEqual(action.title, "Build it")
        XCTAssertEqual(action.subtitle, "powered by your Claude Max subscription")
    }

    func testSignedOutOffersSignInInstead() {
        let action = FoundryDirection.primaryAction(ready(auth: .signedOut, subscriptionType: nil))
        XCTAssertEqual(action, .signIn)
        XCTAssertEqual(action.title, "Sign in to build it")
        XCTAssertFalse(action.subtitle.isEmpty, "the sign-in button says why")
    }

    func testMissingCliIsNamedBeforeSignIn() {
        // Sign-in runs through the CLI, so offering it without the CLI would fail.
        let action = FoundryDirection.primaryAction(ready(auth: .signedOut, subscriptionType: nil, cliInstalled: false))
        XCTAssertEqual(action, .installCLI)
        XCTAssertTrue(action.title.contains("Claude Code"))
    }

    func testFoundryOffTurnsItOnInTheSameClick() {
        let action = FoundryDirection.primaryAction(ready(foundryEnabled: false))
        XCTAssertEqual(action, .enableAndBuild(power: "powered by your Claude Max subscription"))
        XCTAssertEqual(action.title, "Turn on self-upgrade and build it")
    }

    func testNoSourceCheckoutSaysSoAndPointsAtTheHandoff() {
        let action = FoundryDirection.primaryAction(ready(sourceAvailable: false))
        XCTAssertEqual(action, .noSource)
        XCTAssertTrue(action.subtitle.contains("handoff"), "the next step is the handoff, and the copy says so")
    }

    func testABuildInFlightNeverOffersASecondBuildIt() {
        let building = FoundryDirection.primaryAction(ready(stage: .building, buildInFlight: true))
        XCTAssertEqual(building, .inFlight(stage: .building, jobId: nil))
        XCTAssertEqual(building.title, "Building now")

        let escalated = FoundryDirection.primaryAction(ready(stage: .building, buildInFlight: true, escalatedJobId: "job-9"))
        XCTAssertEqual(escalated, .inFlight(stage: .building, jobId: "job-9"))

        let verifying = FoundryDirection.primaryAction(ready(stage: .verifying))
        XCTAssertEqual(verifying, .inFlight(stage: .verifying, jobId: nil))
        XCTAssertEqual(verifying.title, "Verifying the build")
    }

    func testVerifiedWithAnApprovalWaitingPointsUp() {
        let action = FoundryDirection.primaryAction(ready(stage: .verifying, approvalPending: true))
        XCTAssertEqual(action, .awaitingApproval)
        XCTAssertTrue(action.subtitle.lowercased().contains("approve"))
    }

    func testAcceptedButIdleStillOffersBuildIt() {
        // Accepted before the engine could build (no source at the time, or a
        // relaunch): the card must offer the build again, not sit there.
        let action = FoundryDirection.primaryAction(ready(stage: .accepted))
        XCTAssertEqual(action, .build(power: "powered by your Claude Max subscription"))
    }

    func testShippedAndNotPursuedAreTerminal() {
        XCTAssertEqual(FoundryDirection.primaryAction(ready(stage: .landed)), .shipped)
        XCTAssertEqual(FoundryDirection.primaryAction(ready(stage: .rejected)), .notPursued)
        XCTAssertEqual(FoundryDirection.primaryAction(ready(stage: .rolledBack)), .rolledBack)
        for action in [FoundryPrimaryAction.shipped, .notPursued, .rolledBack] {
            XCTAssertFalse(action.isActionable, "\(action) must not render as a button")
        }
    }

    func testTheGateOrderIsCliThenSignInThenSourceThenFoundry() {
        // Everything missing at once: the first thing a person must do wins.
        let all = ready(auth: .signedOut, subscriptionType: nil, cliInstalled: false, foundryEnabled: false, sourceAvailable: false)
        XCTAssertEqual(FoundryDirection.primaryAction(all), .installCLI)
        let cli = ready(auth: .signedOut, subscriptionType: nil, foundryEnabled: false, sourceAvailable: false)
        XCTAssertEqual(FoundryDirection.primaryAction(cli), .signIn)
        let signed = ready(foundryEnabled: false, sourceAvailable: false)
        XCTAssertEqual(FoundryDirection.primaryAction(signed), .noSource)
    }

    // MARK: - Plain words replace the internal vocabulary

    func testCostLineIsPlainAndAlwaysANumeral() {
        XCTAssertEqual(FoundryFormat.costLine(usd: 8), "About $8 of your subscription")
        XCTAssertEqual(FoundryFormat.costLine(usd: 12.6), "About $13 of your subscription")
        XCTAssertEqual(FoundryFormat.costLine(usd: 0.45), "Under $1 of your subscription")
        XCTAssertEqual(FoundryFormat.costLine(usd: 0), "No measurable subscription cost")
        XCTAssertEqual(FoundryFormat.costLine(usd: -3), "No measurable subscription cost")
        for usd in [0.2, 1.0, 4.0, 25.0] {
            let line = FoundryFormat.costLine(usd: usd)
            XCTAssertTrue(line.contains("$"), "\(line) has no dollar symbol")
            XCTAssertFalse(line.lowercased().contains("dollar"), "\(line) spells the amount out")
        }
    }

    func testRiskReadsAsWords() {
        XCTAssertEqual(FoundryFormat.riskLabel("medium"), "Medium risk")
        XCTAssertEqual(FoundryFormat.riskLabel("Medium"), "Medium risk")
        XCTAssertEqual(FoundryFormat.riskLabel("low"), "Low risk")
        XCTAssertEqual(FoundryFormat.riskLabel("high"), "High risk")
        XCTAssertEqual(FoundryFormat.riskLabel("protected"), "Protected area")
    }

    func testEvidenceSourcesBecomeReadableLabels() {
        XCTAssertEqual(FoundryFormat.evidenceLabel("manual: the sidebar has no groups"), "Noted by you: the sidebar has no groups")
        XCTAssertEqual(FoundryFormat.evidenceLabel("transcript: asked twice"), "From a conversation: asked twice")
        XCTAssertEqual(FoundryFormat.evidenceLabel("swarm: worker retried"), "From an agent run: worker retried")
        XCTAssertEqual(FoundryFormat.evidenceLabel("crash: hang on launch"), "From a crash: hang on launch")
        XCTAssertEqual(FoundryFormat.evidenceLabel("metrics: p95 41ms"), "From metrics: p95 41ms")
        XCTAssertEqual(FoundryFormat.evidenceLabel("no prefix here"), "no prefix here")
        XCTAssertEqual(FoundryFormat.evidenceLabel("https://example.com/x"), "https://example.com/x",
                       "a URL's scheme colon is not a source prefix")
    }

    func testTierReadsAsWhatItMeansForThePerson() {
        XCTAssertEqual(FoundryFormat.tierPlain(0), "Tier 0: you approve every build")
        XCTAssertEqual(FoundryFormat.tierPlain(1), "Tier 1: builds on its own, you approve the install")
        XCTAssertEqual(FoundryFormat.tierPlain(2), "Tier 2: installs on its own behind a 24 hour rollback")
    }

    // MARK: - The bridge carries the stage and the paths

    func testBridgeCarriesStageAndTouchedPaths() {
        var proposal = UpgradeProposal(
            title: "t", lane: .uxPolish, domain: .mac,
            expectedGain: 0.5, riskClass: .medium, estCostLabel: "$8 estimated",
            tierRequired: .propose, readyPrompt: "p",
            touchedPaths: ["Sources/Grux/A.swift", "Sources/Grux/B.swift"]
        )
        proposal.status = .building
        let card = FoundryViewBridge.card(from: proposal)
        XCTAssertEqual(card.stage, .building)
        XCTAssertEqual(card.status, .accepted, "the coarse status is unchanged for ranking")
        XCTAssertEqual(card.touchedPaths, ["Sources/Grux/A.swift", "Sources/Grux/B.swift"])
        XCTAssertEqual(card.updatedAt, proposal.updatedAt)
        for status in ProposalStatus.allCases {
            proposal.status = status
            XCTAssertEqual(FoundryViewBridge.card(from: proposal).stage.rawValue, status.rawValue,
                           "stage mirrors the engine status by name so nothing is lost")
        }
    }

    // MARK: - The handoff a coding agent can run

    private static let releaseContext = WorkOrderContext(
        appPath: "/Applications/Grux.app", version: "3.0.0", build: "1",
        installed: .release(olderSource: nil), supportDir: "/tmp/support", orderDir: "/tmp/orders/wo-test12")

    /// The text Copy handoff puts on the clipboard: the one work order line,
    /// with the proposal as its request and detail.
    private func handoff(_ c: FoundryProposalCardModel? = nil, context: WorkOrderContext = releaseContext) -> String {
        let c = c ?? card()
        return WorkOrderPrompt.build(id: "wo-test12", request: ProposalHandoff.request(for: c),
                                     detail: ProposalHandoff.detail(for: c), context: context)
    }

    func testHandoffCarriesEverythingTheAgentNeeds() {
        let c = card(evidence: ["manual: a", "transcript: b", "swarm: c", "crash: d", "metrics: e"])
        let text = handoff(c)
        XCTAssertTrue(text.contains(c.title))
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains(c.readyPrompt), "the full rationale, not a summary")
        for line in c.evidence {
            XCTAssertTrue(text.contains(FoundryFormat.evidenceLabel(line)), "evidence dropped: \(line)")
        }
        XCTAssertTrue(text.contains("86 of 100"))
        XCTAssertTrue(text.contains("About $8"))
        XCTAssertTrue(text.contains("Sources/Grux/DesignSystem/SidebarModel.swift"))
        XCTAssertTrue(text.contains("Medium risk"))
        XCTAssertTrue(text.contains("UX Polish"))
    }

    func testHandoffStatesTheHouseRulesAndAcceptance() {
        let text = handoff()
        XCTAssertTrue(text.contains("U+2014"), "the no-dash rule is named by code point")
        XCTAssertTrue(text.contains("U+2013"))
        XCTAssertTrue(text.contains("DesignSystem"), "tokens, never raw literals")
        XCTAssertTrue(text.lowercased().contains("fail"), "tests go red before the change")
        XCTAssertTrue(text.contains("swift test"))
        XCTAssertTrue(text.contains("design-ratchet"), "the ratchet is part of done")
    }

    /// ONE LINE: the Self-Upgrade handoff is a work order, with every station
    /// in order, the progress log to report to, and the end at live.
    func testHandoffIsAWorkOrderOnTheOneLine() {
        let text = handoff()
        XCTAssertTrue(text.hasPrefix("# Grux work order wo-test12"), "the handoff is not a work order")
        XCTAssertTrue(text.contains("/tmp/orders/wo-test12/progress.log"), "the agent is not told where to report")
        var cursor = text.startIndex
        for station in WorkOrderStage.line {
            guard let r = text.range(of: "**\(station.rawValue)**", range: cursor..<text.endIndex)
                    ?? text.range(of: "### \(station.rawValue)", range: cursor..<text.endIndex) else {
                return XCTFail("\(station.rawValue) is missing or out of order")
            }
            cursor = r.upperBound
        }
        XCTAssertFalse(text.contains("Commit or push only if I ask"), "the old stop-at-a-diff line survived")
    }

    func testHandoffHasNoTypographicDashes() {
        let text = handoff()
        XCTAssertFalse(text.contains("\u{2014}"))
        XCTAssertFalse(text.contains("\u{2013}"))
    }

    func testHandoffScrubsDashesOutOfModelWrittenProse() {
        var c = card()
        c.title = "Sidebar IA \u{2014} four groups"
        c.readyPrompt = "Do this \u{2013} then that"
        c.evidence = ["manual: a \u{2014} b"]
        let text = handoff(c)
        XCTAssertFalse(text.contains("\u{2014}"))
        XCTAssertFalse(text.contains("\u{2013}"))
    }

    func testHandoffWithNoPathsSaysSoInsteadOfInventingThem() {
        let text = handoff(card(touchedPaths: []))
        XCTAssertTrue(text.contains("No files are pinned"))
    }

    func testHandoffNamesTheSourceWhenTheContextKnowsIt() {
        let source = WorkOrderSource(path: "/tmp/grux-src", commit: "abc1234", binaryMtime: 1)
        let context = WorkOrderContext(
            appPath: "/Applications/Grux.app", version: "3.0.0", build: "1",
            installed: .localBuild(source), supportDir: "/tmp/support", orderDir: "/tmp/orders"
        )
        let text = handoff(context: context)
        XCTAssertTrue(text.contains("/tmp/grux-src"))
        XCTAssertTrue(text.contains("abc1234"))
    }
}
