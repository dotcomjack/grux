import XCTest
@testable import Grux

/// D86, live 2026-10-30 6:12:40 PM on qwen3.5:4b: "Grux, upgrade yourself" called
/// no tool although `foundry_upgrade_cycle` was offered and ranked first, and the
/// person read only an offer. The exact ask now takes the tool's own path before
/// any model sees it, as an exact Commands V2 trigger does, so the first ask starts
/// the cycle (or says plainly why it cannot) on every route and every model.
@MainActor
final class UpgradeYourselfRouteTests: XCTestCase {

    // MARK: - The match: the whole sentence is the ask, nothing fuzzier

    func testTheExplicitAsksMatch() {
        for ask in ["Grux, upgrade yourself", "grux upgrade yourself", "Upgrade yourself.",
                    "upgrade yourself!", "Hey Grux, upgrade yourself", "OK Grux: upgrade yourself",
                    "Grux, please upgrade yourself", "upgrade yourself, please", "Upgrade yourself now",
                    "upgrade yourself, Grux", "  Grux,   upgrade   yourself  ",
                    "Run an upgrade cycle", "start an upgrade cycle", "Run a self-upgrade cycle",
                    "Grux, start a self upgrade cycle.", "start a self-upgrade", "Run a self upgrade"] {
            XCTAssertTrue(ChatIntentClassifier.isUpgradeYourselfAsk(ask), ask)
        }
    }

    /// A question, a negation, talk about it, or the ask inside a longer message
    /// goes to the model as before. A miss costs one model turn; a false match
    /// would start a paid cycle nobody asked for, so the match fails toward the model.
    func testAnythingButTheExactAskGoesToTheModel() {
        for text in ["Can you upgrade yourself?", "upgrade yourself?", "Grux, upgrade yourself, ok?",
                     "Don't upgrade yourself", "do not upgrade yourself", "how do you upgrade yourself",
                     "should I let you upgrade yourself", "upgrade yourself and then email Maria",
                     "Upgrade yourself to 3.2", "upgrade", "upgrade the tracker", "look for upgrades",
                     "check for updates", "what is an upgrade cycle", "I said upgrade yourself",
                     "never upgrade yourself", "grux", "", "   ", "please", "upgrade yourself please now later",
                     "Grux, upgrade yourself. Also, what's on my calendar?"] {
            XCTAssertFalse(ChatIntentClassifier.isUpgradeYourselfAsk(text), text)
        }
    }

    // MARK: - What the person reads, for every result the tool can give

    func testEveryCycleResultReadsAsAPlainSentence() {
        let input: [String: Any] = ["action": "start"]
        let cases: [(String, String)] = [
            ("foundry: " + FoundryEngine.manualCycleRefusal(foundryEnabled: false)!,
             "Self-upgrade is off, so I did not start anything. Turn it on in Self-Upgrade or Settings, then ask again."),
            ("foundry: started: manual upgrade cycle (sense pass + 0 accepted proposals on the build rail)",
             "Started a self-upgrade cycle. What it finds lands in Self-Upgrade, and nothing is built until you accept it."),
            ("foundry: started: manual upgrade cycle (sense pass + 1 accepted proposal on the build rail)",
             "Started a self-upgrade cycle. What it finds lands in Self-Upgrade, and it builds the 1 proposal you already accepted."),
            ("foundry: started: manual upgrade cycle (sense pass + 3 accepted proposals on the build rail)",
             "Started a self-upgrade cycle. What it finds lands in Self-Upgrade, and it builds the 3 proposals you already accepted."),
            ("foundry: already running a manual pass, current spend $0.42",
             "A self-upgrade cycle is already running. Estimated spend so far: $0.42."),
            ("foundry: yielded: session limit active on the current claude.ai account",
             "I could not start a self-upgrade cycle right now: session limit active on the current claude.ai account."),
            ("foundry: could not start a cycle right now",
             "I could not start a self-upgrade cycle right now."),
            (JaxToolGate.pendingResult(goesOutAs: nil),
             "The self-upgrade cycle is waiting for your OK in Approvals. Nothing happens until you approve it."),
        ]
        for (result, expected) in cases {
            let line = ToolReplyCopy.forPerson(tool: "foundry_upgrade_cycle", input: input, result: result)
            XCTAssertEqual(line, expected, result)
            XCTAssertEqual(ToolReplyCopy.problems(in: line), [], line)
        }
    }

    // MARK: - The enforcement: the real send()

    private var savedOffline = false
    private var savedChat: [ChatMessage] = []
    private var savedRecovery: ChatRecovery?
    private var savedFoundry = false

    override func setUp() async throws {
        try await super.setUp()
        savedOffline = AppState.shared.offlineMode
        savedChat = AppState.shared.chat
        savedRecovery = AppState.shared.chatRecovery
        savedFoundry = AppState.shared.config.foundryEnabled
    }

    override func tearDown() async throws {
        AppState.shared.offlineMode = savedOffline
        AppState.shared.chat = savedChat
        AppState.shared.chatRecovery = savedRecovery
        AppState.shared.config.foundryEnabled = savedFoundry
        try await super.tearDown()
    }

    /// With no model attached at all, the ask is still answered, and by the
    /// cycle's own path: no model could have written this reply, and no
    /// approval card was raised for a cycle that would refuse when approved.
    func testTheAskIsAnsweredByTheCyclePathBeforeAnyModel() async {
        AppState.shared.offlineMode = true
        ModelRegistry.shared.resetLocalForTest()
        AppState.shared.chat = []
        AppState.shared.chatRecovery = nil
        AppState.shared.config.foundryEnabled = false
        XCTAssertFalse(ChatReadiness.current().canSend, "control: chat must have no model for this to prove anything")
        let pendingBefore = ApprovalQueue.shared.pending.count

        await ChatService.shared.send(userText: "Grux, upgrade yourself")

        let chat = AppState.shared.chat
        XCTAssertEqual(chat.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.last?.content,
                       "Self-upgrade is off, so I did not start anything. Turn it on in Self-Upgrade or Settings, then ask again.")
        XCTAssertEqual(ApprovalQueue.shared.pending.count, pendingBefore, "an approval was queued for a cycle that is off")
        XCTAssertNil(AppState.shared.chatRecovery)
    }

    /// Order in send(): a waiting workflow's answer and an exact V2 trigger first,
    /// then this, then the PIM route and the readiness guard.
    func testTheRouteSitsAfterTheV2TriggerAndBeforeTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let v2 = try XCTUnwrap(src.range(of: "CommandV2Engine.shared.matchTrigger"))
        let route = try XCTUnwrap(src.range(of: "ChatIntentClassifier.isUpgradeYourselfAsk(trimmed)"))
        let pim = try XCTUnwrap(src.range(of: "ChatIntentClassifier.pimRoute(utterance: trimmed)"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(v2.lowerBound < route.lowerBound && route.lowerBound < pim.lowerBound
                      && pim.lowerBound < readiness.lowerBound)
    }
}
