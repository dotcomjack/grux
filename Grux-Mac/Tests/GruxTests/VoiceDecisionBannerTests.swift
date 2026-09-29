import XCTest
@testable import Grux

/// A Mac that starts doing things when you talk has to say so. One banner per
/// thing Grux actually DID, and one explanation before the first of them, on
/// each device.
final class VoiceDecisionBannerTests: XCTestCase {

    private func event(_ outcome: VoiceDecisionEvent.Outcome,
                       id: String = "tab:calendar") -> VoiceDecisionEvent {
        VoiceDecisionEvent(heard: "open my calendar", commandId: id, confidence: 0.94,
                           latencyMs: 480, provider: .jev, outcome: outcome)
    }

    func test_onlyThingsGruxActuallyDidReachABanner() {
        XCTAssertTrue(VoiceDecisionBanner.shouldBanner(event(.executed), showLastDecision: true, chatIsFrontmost: false))
        // Chatter is the whole point of the decision engine: it is what Grux
        // correctly did nothing about.
        XCTAssertFalse(VoiceDecisionBanner.shouldBanner(event(.ignored), showLastDecision: true, chatIsFrontmost: false))
        // Asked-first already has a surface. It is sitting in Approvals.
        XCTAssertFalse(VoiceDecisionBanner.shouldBanner(event(.askedFirst), showLastDecision: true, chatIsFrontmost: false))
        XCTAssertFalse(VoiceDecisionBanner.shouldBanner(event(.refused), showLastDecision: true, chatIsFrontmost: false))
    }

    func test_theSwitchOffMeansOff() {
        XCTAssertFalse(VoiceDecisionBanner.shouldBanner(event(.executed), showLastDecision: false, chatIsFrontmost: false))
    }

    func test_dictationYouCanSeeLandDoesNotAlsoBanner() {
        let dictation = event(.executed, id: VoiceCommandRouter.sayToChat)
        XCTAssertFalse(VoiceDecisionBanner.shouldBanner(dictation, showLastDecision: true, chatIsFrontmost: true),
                       "banners the thing the person is watching appear in front of them")
        XCTAssertTrue(VoiceDecisionBanner.shouldBanner(dictation, showLastDecision: true, chatIsFrontmost: false),
                      "with the window away, the person has no other way to know it landed")
    }

    /// A command still banners with the window open: opening a tab in a
    /// background window is exactly the case you would otherwise miss.
    func test_aCommandStillBannersWithTheWindowOpen() {
        XCTAssertTrue(VoiceDecisionBanner.shouldBanner(event(.executed), showLastDecision: true, chatIsFrontmost: true))
    }

    func test_theBannerSaysWhatHappenedWithoutAnyInternalIdentifier() {
        let e = event(.executed)
        let title = VoiceDecisionBanner.title(e)
        let body = VoiceDecisionBanner.body(e)
        XCTAssertTrue(title.hasPrefix("Opened "), "title was \(title)")
        XCTAssertFalse(title.contains("tab:"))
        XCTAssertTrue(body.contains("480 ms"), "body was \(body)")
        XCTAssertTrue(body.contains("open my calendar"))
    }

    /// The explanation has to name what is happening, what it will not do
    /// without asking, and where to turn it off. All three, or it is a
    /// notification about notifications.
    func test_theOneTimeExplanationEarnsItsInterruption() {
        let text = (VoiceDecisionBanner.explainerTitle + " " + VoiceDecisionBanner.explainerBody).lowercased()
        XCTAssertTrue(text.contains("listening is on"), "never says what changed")
        XCTAssertTrue(text.contains("ask"), "never says what stops to ask")
        // The switch moved to Tuning in P-E-2, so that is where it says.
        XCTAssertTrue(text.contains("tuning"), "never says where to turn it off")
    }

    /// The permanent home for the switch, per the rule that nothing ships
    /// without a permanent door and its off state explained. Tuning since
    /// P-E-2, which shows this copy under the switch.
    func test_theSettingsCopyExplainsWhatTurningItOffCosts() throws {
        let body = ListeningSection.bannerCopy.body.lowercased()
        XCTAssertFalse(ListeningSection.bannerCopy.title.isEmpty)
        XCTAssertTrue(body.contains("still acts"), "implies turning it off stops Grux acting")
        XCTAssertTrue(body.contains("menu bar"), "never says where the record still lives")
        let tuning = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Tuning/TuningView.swift"), encoding: .utf8)
        XCTAssertTrue(tuning.contains("binding(\\.showLastDecision)") && tuning.contains("ListeningSection.bannerCopy.body"),
                      "the switch and its explanation are not both in Tuning")
    }
}

/// THE SUITE NEVER WRITES TO THE RUNNING APP.
///
/// Posting a banner also flips `listeningBannerExplained` and saves the
/// config, which is a file in the operator's Application Support directory.
/// Measured earlier in this project: a test that reached a real surface wrote
/// 284 jobs into the live app. The seam defaults to nothing for that reason.
@MainActor
final class VoiceDecisionBannerIsolationTests: XCTestCase {

    func test_aRouterATestBuildsPostsNoBanner() async {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        var posted = 0
        // Count through the seam rather than trusting the default to be
        // inert: if someone points the default at the real surface again,
        // this records it.
        let original = r.banner
        r.banner = { e in original(e); posted += 1 }
        r.navigate = { _ in }
        let before = AppState.shared.config.listeningBannerExplained
        _ = await r.consider(chunk: "open my calendar")
        XCTAssertEqual(posted, 1, "the router stopped reporting its decisions")
        XCTAssertEqual(AppState.shared.config.listeningBannerExplained, before,
                       "a test flipped the live app's banner-explained flag")
    }

    func test_theAppWiresTheRealBannerOnTheOneSharedRouter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Decisions/VoiceCommandRouter.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "the router source did not load")
        XCTAssertTrue(text.contains("r.banner = { NotificationManager.shared.sendVoiceDecision($0) }"),
                      "the shared router no longer posts banners, so nothing ever announces a decision")
        XCTAssertTrue(text.contains("var banner: @MainActor (VoiceDecisionEvent) -> Void = { _ in }"),
                      "the banner seam defaults to a real surface, which lets the suite write to the live app")
    }
}
