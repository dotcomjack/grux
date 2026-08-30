import XCTest
@testable import Grux

/// CHAT OFFERED AN ACTION THAT COULD NOT FIX CHAT AND BROKE SOMETHING ELSE.
///
/// Grux keeps two credentials that are easy to confuse because both end in the
/// word Claude:
///
///   1. An Anthropic API key in the Keychain. `ModelRegistry.resolvedRouting`
///      returns `AppState.shared.anthropicKey`, so this is what CHAT spends.
///   2. A claude.ai OAuth session on the agent CLI, managed by `AccountSwitcher`,
///      which is what headless TERMINAL SESSIONS spend.
///
/// When a chat turn failed on credit or rate limits, the banner offered
/// "Switch account & retry". That calls `AccountSwitcher.switchToAccount`,
/// whose first step is `claude auth logout`. Measured on the owner's machine
/// 2026-08-23:
///
///   - `AccountSwitcher.swift` writes `.anthropicApiKey` ZERO times, so
///     switching cannot change the key chat is about to reuse.
///   - The retry therefore re-sends with the identical credential and fails
///     identically.
///   - Meanwhile the CLI has been logged out, so a WORKING terminal session
///     is destroyed to "fix" a chat problem it was never part of.
///   - With no accounts configured, and the owner had none, the button instead
///     says "Add one in Settings", sending the user to configure an OAuth
///     account that still would not power chat.
///
/// The user's own report: an active claude.ai plan, signed in, plenty of usage
/// left, and Grux telling them to switch accounts. They were right and the app
/// was wrong.
///
/// THE RULE THIS FILE ENFORCES: a chat recovery may only offer actions that can
/// change the credential CHAT actually spends. Anything else is at best noise
/// and at worst destructive.
final class ChatRecoveryCredentialBoundaryTests: XCTestCase {

    private func macRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: macRoot().appendingPathComponent(rel), encoding: .utf8)
    }

    /// CONTROL. If the recovery banner moved, every assertion below is aimed at
    /// nothing and would pass for the wrong reason.
    func testTheChatRecoveryBannerIsWhereWeThinkItIs() throws {
        let view = try source("Sources/Grux/ChatView.swift")
        XCTAssertTrue(view.contains("case .limitHit:"),
                      "the chat recovery banner no longer switches on recovery.kind")
    }

    /// THE DESTRUCTIVE ONE. Chat must never drive the CLI's OAuth session.
    func testChatNeverOffersToSwitchTheAgentCliAccount() throws {
        let view = try source("Sources/Grux/ChatView.swift")
        XCTAssertFalse(view.contains("switchAccountAndRetry"),
                       """
                       The chat recovery banner still offers to switch the agent CLI account. \
                       That runs `claude auth logout`, cannot change the API key chat spends, \
                       and destroys a working terminal session to fix a chat failure.
                       """)
        XCTAssertFalse(view.contains("AccountSwitcher"),
                       "ChatView still reaches into AccountSwitcher, which owns a different credential")
    }

    /// The message must not TELL the user to switch accounts either, even with
    /// the button gone. Advice that cannot work is the same defect in prose.
    func testChatCreditAndLimitCopyDoesNotAdviseSwitchingAccounts() throws {
        let service = try source("Sources/Grux/ChatService.swift")
        for (needle, why) in [
            ("switch account and retry", "credit-balance copy still tells the user to switch account"),
            ("Switch account and retry", "usage-limit copy still tells the user to switch account"),
        ] {
            XCTAssertFalse(service.contains(needle), why)
        }
    }

    /// AND IT MUST EXPLAIN THE THING THE USER ACTUALLY GOT WRONG. A claude.ai
    /// Pro or Max subscription does not fund the Anthropic API: they are
    /// separate balances. A user with an active plan and no API credit is
    /// entitled to be confused, and the app is the thing that should say so.
    func testCreditCopyExplainsThatASubscriptionIsNotApiCredit() {
        let text = ChatCredentialHelp.apiCreditVersusSubscription.lowercased()
        XCTAssertTrue(text.contains("subscription") || text.contains("plan"),
                      "the copy never mentions the subscription the user is thinking of")
        XCTAssertTrue(text.contains("api"),
                      "the copy never names the API balance as the separate thing")
        XCTAssertFalse(text.contains("switch account"),
                       "the copy still suggests the action that cannot help")
    }

    /// The affordances chat DOES offer have to be ones that can change the
    /// outcome: a local model needs no key at all, and the key field is where a
    /// working key gets added.
    func testChatOffersOnlyActionsThatCanChangeTheOutcome() throws {
        let view = try source("Sources/Grux/ChatView.swift")
        guard let r = view.range(of: "case .limitHit:") else {
            return XCTFail("limitHit branch missing")
        }
        let branch = String(view[r.upperBound...].prefix(700))
        XCTAssertTrue(branch.contains("openKeySettings") || branch.contains("\"api\""),
                      "chat's limit banner offers no route to the key field")
    }

    /// The agent path KEEPS account switching, because there it is the correct
    /// fix: swarm workers really do spend the CLI's OAuth session. Removing it
    /// everywhere would trade one wrong behaviour for another.
    func testTheAgentPathStillSwitchesAccountsBecauseThereItWorks() throws {
        let agent = try source("Sources/Grux/AgentService.swift")
        XCTAssertTrue(agent.contains("resumeWithAccountSwitch"),
                      "the agent path lost account switching, where it is the legitimate fix")
    }
}
