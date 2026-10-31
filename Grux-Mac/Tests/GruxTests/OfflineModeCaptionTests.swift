import XCTest
@testable import Grux

/// Operator note 11 (2026-10-23): the two captions under Settings, "Offline mode
/// (local model)", promised the opposite of the code under them, and every Grux
/// Local user is sent to that section by the public setup steps.
///
/// Each test holds one caption against the behaviour it describes: the behaviour
/// is asserted first, then the words. If the behaviour ever changes, the first
/// half fails and the caption has to be rewritten with it; if the caption drifts,
/// the second half does.
final class OfflineModeCaptionTests: XCTestCase {

    /// Offline on, no local server, a cloud key present: ChatReadiness refuses
    /// the send (ChatService checks `canSend` before every turn). The caption
    /// said chat "falls back to the cloud until one is".
    func test_notReadyCaption_saysChatWaits_becauseTheSendIsRefused() {
        let readiness = ChatReadiness.evaluate(hasAnthropicKey: true,
                                               localModelAvailable: false,
                                               chosenProvider: .local,
                                               routedProvider: .anthropic)
        XCTAssertEqual(readiness, .offlinePinnedButNoLocalModel)
        XCTAssertFalse(readiness.canSend, "behaviour changed: rewrite OfflineModeCaption.notReady with it")

        let caption = OfflineModeCaption.notReady.lowercased()
        XCTAssertTrue(caption.contains("chat will not send"), OfflineModeCaption.notReady)
        XCTAssertFalse(caption.contains("falls back"), OfflineModeCaption.notReady)
        XCTAssertFalse(caption.contains("cloud until"), OfflineModeCaption.notReady)
    }

    /// The switch is saved into config.json (AppState.offlineMode's didSet) and
    /// restored on launch. The caption said it "resets to cloud on relaunch".
    func test_footerCaption_saysTheSwitchIsSaved_becauseItSurvivesARelaunch() throws {
        var cfg = GruxConfig.default
        cfg.offlineMode = true
        let decoded = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertTrue(decoded.offlineMode, "behaviour changed: rewrite OfflineModeCaption.footer with it")

        let caption = OfflineModeCaption.footer.lowercased()
        XCTAssertTrue(caption.contains("the switch, the model and the base url are saved"), OfflineModeCaption.footer)
        XCTAssertFalse(caption.contains("resets"), OfflineModeCaption.footer)
        XCTAssertFalse(caption.contains("falls back"), OfflineModeCaption.footer)
    }

    // Wave 7 review P2-1: with offline mode on, "Use Claude" under Models (or a Claude
    // model from the chat chip) records an explicit provider and leaves the switch on.
    // `activeProvider` then answers that choice, chat sends to the cloud, and the
    // not-ready caption said chat would not send. Driven through the real registry.

    @MainActor
    func test_aProviderChosenUnderModels_beatsTheSwitch_soNotReadyIsNotShown() {
        let registry = ModelRegistry.shared
        let before = registry.providerSelection
        defer { if let before { registry.setActiveProvider(before) } else { registry.clearActiveProvider() } }

        registry.setActiveProvider(.anthropic)
        let chosen = registry.activeProvider
        XCTAssertEqual(chosen, .anthropic, "behaviour changed: an explicit choice no longer beats the switch")
        let readiness = ChatReadiness.evaluate(hasAnthropicKey: true, localModelAvailable: false,
                                               chosenProvider: chosen, routedProvider: .anthropic)
        XCTAssertTrue(readiness.canSend, "chat sends to the chosen cloud provider")

        XCTAssertFalse(OfflineModeCaption.showsNotReady(offlineMode: true, activeProvider: chosen, localUsable: false))
        let line = OfflineModeCaption.overridden(offlineMode: true, activeProvider: chosen)
        XCTAssertNotNil(line, "the switch is on and chat goes elsewhere: say so")
        XCTAssertTrue(line?.lowercased().contains("chat uses that provider") == true, line ?? "")
    }

    @MainActor
    func test_withTheLocalChoice_andNoServer_notReadyIsShown() {
        let registry = ModelRegistry.shared
        let before = registry.providerSelection
        defer { if let before { registry.setActiveProvider(before) } else { registry.clearActiveProvider() } }

        registry.setActiveProvider(.local)
        let chosen = registry.activeProvider
        XCTAssertEqual(chosen, .local)
        XCTAssertFalse(ChatReadiness.evaluate(hasAnthropicKey: true, localModelAvailable: false,
                                              chosenProvider: chosen, routedProvider: .anthropic).canSend)
        XCTAssertTrue(OfflineModeCaption.showsNotReady(offlineMode: true, activeProvider: chosen, localUsable: false))
        XCTAssertNil(OfflineModeCaption.overridden(offlineMode: true, activeProvider: chosen))
        // A ready local model, or the switch off, shows neither.
        XCTAssertFalse(OfflineModeCaption.showsNotReady(offlineMode: true, activeProvider: .local, localUsable: true))
        XCTAssertFalse(OfflineModeCaption.showsNotReady(offlineMode: false, activeProvider: .local, localUsable: false))
        XCTAssertNil(OfflineModeCaption.overridden(offlineMode: false, activeProvider: .anthropic))
    }

    /// The footer's "chat waits instead of using the cloud" holds only while the local
    /// model is the choice; it says what changes it.
    func test_footerNamesWhatOverridesTheSwitch() {
        XCTAssertTrue(OfflineModeCaption.footer.lowercased().contains("another provider under models"), OfflineModeCaption.footer)
    }
}
