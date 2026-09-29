import XCTest
@testable import Grux

/// What a KEYLESS install actually does when the room talks.
///
/// Most people run Grux without a Decisions key, so the on-device provider is
/// the one that matters most, and nothing measured it on anything but a few
/// single utterances. This drives the REAL router over a fixture of commands,
/// room talk, television and near misses (talking ABOUT Grux rather than TO
/// it), and holds the one property that cannot be traded away: with nobody
/// addressing it, Grux must not act.
///
/// The fixture is written here rather than taken from the operator's ledger,
/// which holds real conversations. Same shapes, no private lines.
@MainActor
final class VoiceGateFixtureTests: XCTestCase {

    /// (said, the command id it should run, or nil for "nothing")
    static let fixture: [(String, String?)] = [
        // Plain commands.
        ("open my calendar", "tab:calendar"),
        ("show me my calendar", "tab:calendar"),
        ("open notes", "tab:notes"),
        ("show me notes", "tab:notes"),
        ("go to tasks", "tab:tasks"),
        ("open my tasks", "tab:tasks"),
        ("mute", "mute"),
        ("stop listening", "mute"),
        ("grux mute", "mute"),
        // Room talk: nobody is speaking to Grux.
        ("so anyway I was thinking about lunch", nil),
        ("did you see the game last night", nil),
        ("I need to call my mum back", nil),
        ("the calendar on the wall is wrong", nil),
        ("he said he would open the store at nine", nil),
        ("my inbox is a disaster this week", nil),
        ("can you close the window it is freezing", nil),
        ("just put it in the notes app on your phone", nil),
        ("we should mute the group chat", nil),
        ("tasks for the quarter are all over the place", nil),
        ("I have a meeting on the calendar tomorrow", nil),
        // Television and advertising.
        ("call now and get fifty percent off your first order", nil),
        ("tonight on channel four, the story of a man who lost everything", nil),
        ("open your heart and let the music in", nil),
        ("mute the ads with our premium subscription", nil),
        // Talking ABOUT Grux, not to it.
        ("I told you Grux can open my calendar for me", nil),
        ("apparently it closes all your windows if you ask", nil),
    ]

    private func router() -> VoiceCommandRouter {
        // Keyless: the on-device provider, which is what a fresh install runs.
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        return r
    }

    /// THE PROPERTY: room talk never moves the machine. An overheard line may
    /// be ignored (right) but must never be acted on, and since P-E-2 it must
    /// not queue an approval either, because an approval for something nobody
    /// said is an interruption with no upside.
    func test_theRoomNeverMovesTheMachine() async {
        let r = router()
        var acted: [String] = []
        var asked: [String] = []
        r.navigate = { key in acted.append("tab:\(key)") }
        r.askFirst = { cmd in asked.append(cmd.id) }
        for (said, want) in Self.fixture where want == nil {
            acted.removeAll(); asked.removeAll()
            let e = await r.consider(chunk: said)
            XCTAssertTrue(acted.isEmpty, "\(said.prefix(40))... acted: \(acted)")
            XCTAssertTrue(asked.isEmpty, "\(said.prefix(40))... queued an approval: \(asked)")
            XCTAssertNotEqual(e?.outcome, .executed, "\(said.prefix(40))... executed")
        }
    }

    /// And a plain command still works without a key, or the keyless install
    /// is safe and useless. Counted rather than asserted one by one: the
    /// on-device provider matches phrases, so some phrasings genuinely miss,
    /// and the number is the thing worth watching.
    func test_aKeylessInstallStillObeysPlainCommands() async {
        let r = router()
        var ran: String?
        r.navigate = { ran = "tab:\($0)" }
        r.setMuted = { _ in ran = "mute" }
        var hit = 0, total = 0
        var missed: [String] = []
        for (said, want) in Self.fixture {
            guard let want else { continue }
            total += 1
            ran = nil
            _ = await r.consider(chunk: said)
            if ran == want { hit += 1 } else { missed.append(said) }
        }
        XCTAssertGreaterThanOrEqual(hit, total * 2 / 3,
                                    "the on-device path obeyed \(hit) of \(total) plain commands, missed: \(missed)")
    }
}
