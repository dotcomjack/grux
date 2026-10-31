import XCTest
@testable import Grux

final class ToolRelevanceTests: XCTestCase {
    private func tool(_ name: String) -> ClaudeTool { ClaudeTool(name: name, description: "", inputSchema: [:]) }

    func test_askingTheTime_ridesCoreOnly() {
        let g = ToolRelevance.groups(for: .init(utterance: "what time is it right now?"))
        XCTAssertEqual(g, [.core])
    }

    func test_codeShapedTurn_bringsDeveloperTools() {
        let g = ToolRelevance.groups(for: .init(utterance: "ship the iOS app"))
        XCTAssertTrue(g.contains(.developer))
        XCTAssertFalse(g.contains(.meetings))
    }

    func test_recentToolUse_keepsItsGroupAcrossTurns() {
        let g = ToolRelevance.groups(for: .init(utterance: "try again", recentToolNames: ["ios_build_verify"]))
        XCTAssertTrue(g.contains(.developer))
    }

    func test_emptyUtterance_ridesEverything() {
        XCTAssertEqual(ToolRelevance.groups(for: .init(utterance: " ")), Set(ToolRelevance.Group.allCases))
    }

    func test_filter_dropsHeavyGroupsAndKeepsCore() {
        // search_web left core in wave 9: it opens Google in Chrome and returns no results.
        let tools = [tool("add_task"), tool("control_screen"), tool("agent_swarm_start"), tool("start_meeting_capture"),
                     tool("remember_fact")]
        let kept = ToolRelevance.filter(tools, signals: .init(utterance: "add a task to call the bank")).map(\.name)
        XCTAssertEqual(kept, ["add_task", "remember_fact"])
    }

    func test_everyKnownToolPrefix_hasAGroup() {
        XCTAssertEqual(ToolRelevance.group(for: "ios_scaffold"), .developer)
        XCTAssertEqual(ToolRelevance.group(for: "enroll_speaker_from_meeting"), .meetings)
        XCTAssertEqual(ToolRelevance.group(for: "deep_research"), .research)
        XCTAssertEqual(ToolRelevance.group(for: "slack_send"), .export)
        XCTAssertEqual(ToolRelevance.group(for: "creative_render_image"), .creative)
        XCTAssertEqual(ToolRelevance.group(for: "read_screen"), .screen)
        XCTAssertEqual(ToolRelevance.group(for: "fs_read"), .core)
    }

    // MARK: - D12: a tool that opens another app rides only when the words ask for one

    private static let opensAnotherApp = ["open_url", "open_app", "play_on_youtube", "search_web"]
    private var everyday: [ClaudeTool] {
        (Self.opensAnotherApp + ["add_task", "play_music_track", "remember_fact"]).map(tool)
    }

    /// Measured 2026-10-22: llama3.2:3b answered "what is two plus two" by calling
    /// play_on_youtube, and Grux opened YouTube in Chrome. A question needs no tool that
    /// brings another app to the front, so none is offered.
    func test_aQuestion_isNeverOfferedAToolThatOpensAnotherApp() {
        for q in ["what is two plus two", "what's 12 times 17", "explain recursion like I'm five",
                  "what time is it right now?", "how do I say thank you in French", "add a task to call the bank",
                  "remember that my sister's birthday is in May", "what's on my plate today"] {
            let kept = ToolRelevance.filter(everyday, signals: .init(utterance: q)).map(\.name)
            XCTAssertEqual(kept.filter(Self.opensAnotherApp.contains), [], q)
            XCTAssertTrue(kept.contains("add_task") && kept.contains("play_music_track"), "core went missing: \(q)")
        }
    }

    func test_askingToOpenWatchOrPlaySomething_bringsThem() {
        for q in ["open github.com", "Open Chrome", "pull up example.com/pricing", "go to https://x.com/foo",
                  "play the Succession theme on YouTube", "watch a video of a cat skateboarding", "launch Safari",
                  "play some jazz", "Open example.com in Chrome for me.", "bring up the website for Grux",
                  "show me the docs at docs.swift.org",
                  // Wave 9 review: phrasings Grux's own prompt sends to these tools.
                  "fire up Logic", "boot up Xcode", "start Slack", "switch to Xcode", "put on some Queen",
                  "I want to hear Bohemian Rhapsody", "throw on lofi", "queue up the new Taylor Swift album",
                  "visit hacker news", "navigate to the pricing page", "google the weather in Boston",
                  "search for flights to Denver", "look up the Lakers score"] {
            let kept = ToolRelevance.filter(everyday, signals: .init(utterance: q)).map(\.name)
            XCTAssertEqual(kept.filter(Self.opensAnotherApp.contains), Self.opensAnotherApp, q)
        }
    }

    /// The music fallback: when play_music_track misses, Grux's prompt says to call
    /// play_on_youtube, so a music tool that ran keeps the group for the next turn.
    func test_aMusicToolThatRan_bringsTheYouTubeFallback() {
        let kept = ToolRelevance.filter(everyday, signals: .init(utterance: "try that one", recentToolNames: ["play_music_track"]))
        XCTAssertTrue(kept.map(\.name).contains("play_on_youtube"))
    }

    /// Wave 9 review: a tool the turn did not offer must not run because the model named it.
    func test_aToolThatWasNotOffered_isRefusedByName() {
        let offered = [tool("add_task")]
        XCTAssertNil(ChatService.notOfferedRefusal("add_task", offered: offered))
        let why = ChatService.notOfferedRefusal("play_on_youtube", offered: offered)
        XCTAssertEqual(why, "error: play_on_youtube is not offered on this turn, so it did not run; answer without it")
    }

    func test_theLoggedListIsTheGroup() {
        for name in ToolRelevance.otherAppsTools { XCTAssertEqual(ToolRelevance.group(for: name), .otherApps, name) }
    }

    /// The chat hop loop asks before it dispatches.
    func test_theHopLoopRefusesBeforeItDispatches() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let ask = try XCTUnwrap(chat.range(of: "Self.notOfferedRefusal(use.name, offered: tools)"))
        let run = try XCTUnwrap(chat.range(of: "await Self.dispatchTool(name: use.name, input: use.input)"))
        XCTAssertLessThan(ask.lowerBound, run.lowerBound)
    }

    /// "Try that again" after an open keeps the tools, like every other group.
    func test_aToolThatOpenedAnApp_keepsItsGroupForTheNextTurn() {
        let kept = ToolRelevance.filter(everyday, signals: .init(utterance: "try again", recentToolNames: ["open_url"]))
        XCTAssertEqual(kept.map(\.name).filter(Self.opensAnotherApp.contains), Self.opensAnotherApp)
    }

    /// wake.log says which turns could open another app, so the live check can read it.
    func test_theAssembledLineNamesTheToolsThatOpenAnotherApp() {
        XCTAssertEqual(ChatService.contextAssembledLine(seconds: 0.034, modelId: "qwen3.5:4b", toolNames: ["add_task", "remember_fact"]),
                       "chat stage: context assembled at +0.03s, routed to qwen3.5:4b, 2 tools, none of open_url, open_app, play_on_youtube, search_web")
        XCTAssertEqual(ChatService.contextAssembledLine(seconds: 1, modelId: "m", toolNames: ["add_task", "open_url", "play_on_youtube"]),
                       "chat stage: context assembled at +1.00s, routed to m, 3 tools, with open_url, play_on_youtube")
    }

    @MainActor
    func test_recentToolUse_forgetsAfterTheWindow() {
        let r = RecentToolUse()
        r.record("ios_scaffold", at: Date(timeIntervalSinceNow: -20 * 60))
        r.record("add_task")
        XCTAssertEqual(r.names(), ["add_task"])
    }
}
