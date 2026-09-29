import XCTest
@testable import Grux

/// EVERY SURFACE TELLS THE SAME STORY.
///
/// The orb, the menu bar, the ambient HUD and the floating focus card each
/// used to derive the microphone state themselves. Four derivations means
/// four chances to disagree, and they did: always-on listening drives no
/// wake listener, so surfaces gated on `WakeWordListener.isListening` read
/// IDLE while the microphone was live.
///
/// These are source contracts rather than view snapshots, because what
/// regressed was never a pixel. It was a surface quietly going back to
/// reasoning for itself.
final class DecisionTellsTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux").appendingPathComponent(relative)
        let text = try String(contentsOf: url, encoding: .utf8)
        // A scan that reads an empty or missing file passes everything.
        XCTAssertGreaterThan(text.count, 500, "\(relative) did not load")
        return text
    }

    /// The surfaces that show a microphone state, and must all ask the one
    /// resolver for it. Grows as each tell packet lands.
    private static let tellSurfaces = ["MenuBarView.swift", "LaunchRootView.swift",
                                       "Ambient/AmbientHUD.swift", "ChatView.swift"]

    func testEverySurfaceAsksTheOneResolverForTheWord() throws {
        for file in Self.tellSurfaces {
            let text = try source(file)
            XCTAssertTrue(text.contains("ListeningTell.resolve("),
                          "\(file) no longer asks ListeningTell for the state")
            XCTAssertTrue(text.contains("listeningTell.label"),
                          "\(file) shows a word that is not the shared tell")
        }
    }

    /// The exact shape of the bug: a surface deciding it is listening only
    /// when the wake listener is up. Always-on listening never sets that.
    func testNoSurfaceInfersListeningFromTheWakeListenerAlone() throws {
        for file in Self.tellSurfaces {
            let text = try source(file)
            XCTAssertFalse(text.contains("if wake.isListening { return .listening }"),
                           "\(file) reads listening off the wake listener, which always-on never sets")
        }
    }

    func testTheMenuBarShowsTheLastDecisionAndItsLatency() throws {
        let text = try source("MenuBarView.swift")
        XCTAssertTrue(text.contains("DecisionUsageSummary.lastLine("),
                      "the menu bar no longer shows the last decision")
        XCTAssertTrue(text.contains("DecisionLedger.shared"),
                      "the menu bar is not reading the decision ledger")
    }

    /// The line carries a latency in milliseconds, and says what was heard
    /// rather than the engine's answer shape.
    func testTheHUDShowsTheDecisionStreamAndNotJustWhatItHeard() throws {
        let text = try source("Ambient/AmbientHUD.swift")
        XCTAssertTrue(text.contains("VoiceCommandRouter.shared"),
                      "the HUD is not reading the live decision stream")
        XCTAssertTrue(text.contains("event.latencyLine"),
                      "the HUD shows a decision with no latency next to it")
        XCTAssertTrue(text.contains("tone.color"),
                      "the HUD no longer tones chatter apart from decisions")
    }

    /// Chat is the face. It carried the wake chip, which read the wake
    /// listener and therefore said WAKE OFF while always-on listening held
    /// the microphone: the whole bug, in two words, on the first screen.
    func testChatShowsTheListeningChipAndTheLiveRail() throws {
        let text = try source("ChatView.swift")
        XCTAssertTrue(text.contains("listeningIndicator"), "Chat lost the listening chip")
        XCTAssertFalse(text.contains("\"WAKE OFF\""), "Chat is back to reporting the wake listener")
        XCTAssertTrue(text.contains("VoiceLiveRail()"), "Chat lost the live decision rail")
        // The rail takes height from the conversation when it appears. If
        // nothing re-pins, the last message slides underneath it and reads
        // as Grux having eaten the reply.
        XCTAssertTrue(text.contains("onChange(of: railRowCount)"),
                      "the conversation no longer re-pins when the rail appears")
    }

    func testTheDecisionLineIsReadableRatherThanInternal() {
        let entry = DecisionLedgerEntry(surface: "ambient", provider: .jev, latencyMs: 480,
                                        inputTokens: 4_466, outputTokens: 0, at: Date(),
                                        summary: "open my calendar -> intent=open_calendar 0.94")
        let line = DecisionUsageSummary.lastLine(entry)
        XCTAssertEqual(line, "open my calendar, 480 ms")
        XCTAssertFalse(line?.contains("intent=") ?? true, "the answer shape leaked into the face")
        XCTAssertFalse(line?.contains("->") ?? true, "the ledger arrow leaked into the face")
    }
}

/// ONE ELEMENT PER JOB PER VIEW.
///
/// The operator's rule, 2026-09-21: no two elements of the same dialog or
/// function in the same viewpoint. The rail showed ARMED twice, once as a pill
/// under the orb and once in the foot, a few hundred points apart. The foot
/// keeps it because the foot is also where you tap to mute; the orb's glow
/// still carries the state without a second word.
final class NoRedundantSidebarTellTests: XCTestCase {
    private func launchRoot() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/LaunchRootView.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "LaunchRootView did not load")
        return t
    }

    func test_theRailShowsTheListeningWordExactlyOnce() throws {
        let t = try launchRoot()
        let occurrences = t.components(separatedBy: "listeningTell.label").count - 1
        XCTAssertEqual(occurrences, 1,
                       "the listening word renders \(occurrences) times in the rail; it belongs in the foot only")
    }

    func test_thePillUnderTheOrbIsGone() throws {
        XCTAssertFalse(try launchRoot().contains("OrbStatusPill("),
                       "the status pill is back under the orb, duplicating the foot")
    }

    /// The word left the hero; the STATE did not. The orb still glows by it.
    func test_theOrbStillCarriesTheStateByItsGlow() throws {
        let t = try launchRoot()
        XCTAssertTrue(t.contains("OrbView(state: orbState"), "the orb no longer renders the state")
        XCTAssertTrue(t.contains("return listeningTell.orbState"), "the orb stopped reading the shared tell")
    }
}
