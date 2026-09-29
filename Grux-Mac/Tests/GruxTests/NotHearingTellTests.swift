import XCTest
@testable import Grux

/// ARMED while the microphone sends nothing is a lie the person only finds by
/// talking. Measured 2026-09-21: ambient had stopped capturing, every surface
/// read ARMED and LISTENING, and the orb tap the person tried MUTED it.
@MainActor
final class NotHearingTellTests: XCTestCase {

    override func tearDown() {
        MicHealth.shared.set(notHearing: false)
        super.tearDown()
    }

    func test_notHearingReplacesArmedAndNothingElse() {
        XCTAssertEqual(ListeningTell.resolve(mode: .alwaysOn, micMuted: false, isSpeaking: false, isThinking: false,
                                             notHearing: true), .notHearing)
        XCTAssertEqual(ListeningTell.resolve(mode: .alwaysOn, micMuted: false, isSpeaking: false, isThinking: false,
                                             notHearing: false), .armed)
        // Muted, off, speaking and thinking are each still the truer word.
        XCTAssertEqual(ListeningTell.resolve(mode: .alwaysOn, micMuted: true, isSpeaking: false, isThinking: false, notHearing: true), .muted)
        XCTAssertEqual(ListeningTell.resolve(mode: .off, micMuted: false, isSpeaking: false, isThinking: false, notHearing: true), .off)
        XCTAssertEqual(ListeningTell.resolve(mode: .alwaysOn, micMuted: false, isSpeaking: true, isThinking: false, notHearing: true), .speaking)
        XCTAssertEqual(ListeningTell.resolve(mode: .alwaysOn, micMuted: false, isSpeaking: false, isThinking: true, notHearing: true), .thinking)
        XCTAssertEqual(ListeningTell.notHearing.label, "NOT HEARING")
    }

    func test_theCopyIsHonestWhereverTheTellShows() {
        XCTAssertTrue(ComposerPlaceholder.text(for: .notHearing).contains("can't hear"))
        XCTAssertTrue(TodayModel.sayItLine(.notHearing).contains("Tap the orb"))
        XCTAssertTrue(ListeningTell.notHearing.help.contains("tap the orb"))
    }

    /// Every surface that shows the word reads the fact, so none can say ARMED
    /// while another says NOT HEARING.
    func test_everySurfaceThatShowsTheTellReadsMicHealth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        for rel in ["LaunchRootView.swift", "ChatView.swift", "Chat/VoiceLiveRail.swift", "MenuBarView.swift",
                    "Ambient/AmbientHUD.swift", "Home/HomeView.swift", "Shell/OrbCommandPalette.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertTrue(text.contains("ListeningTell.resolve("), "\(rel) no longer resolves the tell")
            XCTAssertTrue(text.contains("micHealth.notHearing") || text.contains("MicHealth.shared.notHearing"),
                          "\(rel) shows the tell without knowing whether the mic is heard")
        }
    }

    /// The orb tap on a deaf listener tries again; it does not mute.
    func test_aTapWhileNotHearingTriesAgainInsteadOfMuting() {
        let state = AppState.shared
        let wasMuted = state.micMuted
        defer { state.micMuted = wasMuted }
        state.micMuted = false
        MicHealth.shared.set(notHearing: true)
        MicController.toggle()
        XCTAssertFalse(state.micMuted, "a tap on a listener that hears nothing muted it")
    }

    func test_micHealthPublishesOnlyOnATransition() {
        var sends = 0
        let sub = MicHealth.shared.objectWillChange.sink { sends += 1 }
        defer { sub.cancel() }
        MicHealth.shared.set(notHearing: false)
        MicHealth.shared.set(notHearing: true)
        MicHealth.shared.set(notHearing: true)
        MicHealth.shared.set(notHearing: false)
        XCTAssertEqual(sends, 2)
    }
}
