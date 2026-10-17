import Network
import XCTest
@testable import Grux

/// The W4 clean-VM walk, pass 2 (2026-10-13): what a stranger met after
/// connecting a local model. One class per finding.
private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// W2d-1. "Use a local model instead" said "did not finish" about 5 s into a
/// download that completed 70 s later, and no progress line ever showed.
@MainActor
final class LocalDownloadRunsToTheEndTests: XCTestCase {
    private var savedBase = ""
    private var savedModel = ""
    private var savedLocalModel = ""
    private var server: SlowOllama?

    override func setUp() async throws {
        savedBase = AppState.shared.config.ollamaBaseURL
        savedModel = AppState.shared.config.offlineLLMModel
        savedLocalModel = AppState.shared.config.localLLMModel
    }

    override func tearDown() async throws {
        server?.stop()
        AppState.shared.config.ollamaBaseURL = savedBase
        AppState.shared.config.offlineLLMModel = savedModel
        AppState.shared.config.localLLMModel = savedLocalModel
        ModelRegistry.shared.resetLocalForTest()
    }

    private func start(model: String) throws {
        let s = try SlowOllama(model: model)
        server = s
        try s.start()
        XCTAssertGreaterThan(s.port, 0, "the stub never bound a port")
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:\(s.port)"
    }

    func test_thePullIsAwaitedToItsLastLineAndShowsBytes() async throws {
        let id = "w2d-stub-\(UUID().uuidString.prefix(6)):1b"
        try start(model: id)
        let began = Date()
        let task = Task { await OllamaManager.shared.pullToEnd(id) }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let mid = OllamaManager.shared.pulls[id]
        XCTAssertEqual(mid?.failed, false, "a live download already reads as failed: \(String(describing: mid))")
        XCTAssertNotNil(mid?.completedBytes, "the streamed byte counts never reached the row")
        let pick = try XCTUnwrap(Cookbook.catalog.first)
        let line = ConnectModelCopy.downloading(pick, mid)
        XCTAssertTrue(line.contains(" of ") && line.contains("%"), "the progress line has no bytes: \(line)")
        let ended = await task.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), SlowOllama.streamSeconds - 0.2,
                                    "returned before the stream ended")
        XCTAssertEqual(ended?.failed, false, "the finished download reads as failed: \(String(describing: ended))")
        XCTAssertEqual(ended?.status, "installed")
    }

    /// Settings, Models' Download runs the same path to the same end.
    func test_settingsDownloadSucceedsOnASlowStream() async throws {
        guard let pick = Cookbook.headline(for: HardwareProfile.detect()) else {
            throw XCTSkip("no catalog model fits this Mac")
        }
        try start(model: pick.id)
        var shown: [CookbookModel?] = []
        let error = await LocalModelFetch.fetchHeadline { shown.append($0) }
        XCTAssertNil(error, "a download that finished was reported as: \(error ?? "")")
        XCTAssertEqual(shown.first??.id, pick.id, "the progress line never named the model")
        XCTAssertNil(shown.last ?? nil, "the progress line stayed up after the end")
    }

    func test_bothCallersAwaitTheEnd() throws {
        let onboarding = try macSource("Sources/Grux/Onboarding/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains("await OllamaManager.shared.pullToEnd(pick.id)"))
        XCTAssertFalse(onboarding.contains("await OllamaManager.shared.pull(pick.id)"),
                       "first run reads the tags while the download still runs")
        let settings = try macSource("Sources/Grux/Settings/ConnectModelSection.swift")
        XCTAssertTrue(settings.contains("await OllamaManager.shared.pullToEnd(pick.id)"))
    }
}

/// A loopback Ollama whose /api/pull streams its progress slowly, then success.
private final class SlowOllama: @unchecked Sendable {
    static let streamSeconds: TimeInterval = 2.0
    private let listener: NWListener
    private let model: String
    /// The model is listed only once the pull's last line has gone out, as a
    /// real Ollama lists it only once it is pulled.
    private let pulled = PulledFlag()
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(model: String) throws {
        self.model = model
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        let model = self.model
        let pulled = self.pulled
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                func send(_ s: String, close: Bool) {
                    conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in if close { conn.cancel() } })
                }
                func whole(_ body: String) {
                    send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)", close: true)
                }
                switch path {
                case "/api/version": whole(#"{"version":"0.22.0"}"#)
                case "/api/tags": whole(pulled.value ? #"{"models":[{"name":"\#(model)"}]}"# : #"{"models":[]}"#)
                case "/api/pull":
                    send("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n", close: false)
                    let total = 2_000_000_000.0
                    let lines = [#"{"status":"pulling manifest"}"#] + (1...4).map {
                        #"{"status":"pulling abc","total":\#(Int(total)),"completed":\#(Int(total * Double($0) / 5))}"#
                    } + [#"{"status":"verifying sha256 digest"}"#, #"{"status":"success"}"#]
                    let step = SlowOllama.streamSeconds / Double(lines.count)
                    for (i, l) in lines.enumerated() {
                        DispatchQueue.global().asyncAfter(deadline: .now() + step * Double(i + 1)) {
                            if i == lines.count - 1 { pulled.value = true }
                            send(l + "\n", close: i == lines.count - 1)
                        }
                    }
                default: whole(#"{"error":"not found"}"#)
                }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "SlowOllama", code: 1)
        }
    }

    func stop() { listener.cancel() }
}

private final class PulledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

/// W2d-2. The first local reply took 329 s on an 8 GB Mac: a 32768 window,
/// about 15,000 tokens of prompt, and the title call queued ahead of it.
@MainActor
final class LeanLocalTurnTests: XCTestCase {
    func test_theWindowFitsTheMac() {
        XCTAssertEqual(LocalTurn.contextTokens(memoryGB: 8), 8_192)
        XCTAssertEqual(LocalTurn.contextTokens(memoryGB: 16), 16_384)
        XCTAssertEqual(LocalTurn.contextTokens(memoryGB: 64), 32_768)
        XCTAssertEqual(OpenAICompatBackend.ollamaContextTokens, LocalTurn.contextTokens)
    }

    /// The real turn for the walker's question, built lean for an 8 GB Mac.
    func test_aLocalTurnFitsAnEightGigabyteWindow() throws {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        state.chat = [ChatMessage(role: .user, content: "what is on my plate today?")]
        let full = ChatService.shared.assemblePendingContext(state: state, lean: false)
        let lean = ChatService.shared.assemblePendingContext(state: state, lean: true, window: 8_192)
        func systemChars(_ p: ChatService.PendingTurnContext) -> Int {
            p.systemBlocks.compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.count }
        }
        let prompt = LocalTurn.tokens(chars: systemChars(lean))
            + lean.messages.map(LocalTurn.chars).map(LocalTurn.tokens).reduce(0, +)
            + lean.tools.map(LocalTurn.chars).map(LocalTurn.tokens).reduce(0, +)
        XCTAssertLessThanOrEqual(prompt + lean.maxTokens, 8_192, "the lean turn does not fit its window")
        XCTAssertLessThan(systemChars(lean) * 2, systemChars(full), "the lean system prompt is not lean")
        XCTAssertTrue(lean.tools.contains { $0.name == "list_tasks" }, "the tool the question needs was dropped")
        XCTAssertEqual(lean.messages.count, 1)
        XCTAssertEqual(lean.maxTokens, LocalTurn.replyTokens)
        XCTAssertEqual(full.maxTokens, 2000, "a cloud turn changed")
        XCTAssertGreaterThan(full.tools.count, lean.tools.count)
    }

    func test_theLeanPromptKeepsWhoGruxIsAndCutsTheToolManual() throws {
        let src = try macSource("Sources/Grux/ChatService.swift")
        XCTAssertTrue(src.contains(LocalTurn.leanCut), "the cut marker is gone, so a local turn sends the whole manual")
        let lean = LocalTurn.leanStable("PERSONA\n\nTRUST\n\n\(LocalTurn.leanCut). manual", tail: ["PROFILE"])
        XCTAssertTrue(lean.hasPrefix("PERSONA"))
        XCTAssertFalse(lean.contains("manual"))
        XCTAssertTrue(lean.hasSuffix("PROFILE"))
    }

    func test_theToolsAskedAboutComeFirst() {
        func tool(_ n: String, _ d: String) -> ClaudeTool { ClaudeTool(name: n, description: d, inputSchema: [:]) }
        let tools = [tool("play_music_track", "Play a song"), tool("create_note", "Write a note"),
                     tool("list_tasks", "List the tasks"), tool("search_web", "Search the web")]
        XCTAssertEqual(LocalTurn.rank(tools, utterance: "write a note about lunch").first?.name, "create_note")
        XCTAssertEqual(LocalTurn.rank(tools, utterance: "hi").first?.name, "list_tasks", "the everyday tools lead an unclear message")
    }

    func test_fitKeepsTheNewestMessageAndPrefersToolsToOldHistory() {
        let fit = LocalTurn.fit(systemChars: 7_000, messageChars: Array(repeating: 2_000, count: 20) + [100],
                                toolChars: Array(repeating: 700, count: 50), window: 8_192)
        XCTAssertGreaterThanOrEqual(fit.messages, 1)
        XCTAssertGreaterThan(fit.tools, 0)
        XCTAssertLessThan(fit.messages, 21)
    }

    /// One model, served in order: the title call must not go first.
    func test_backgroundCallsWaitForALocalReply() throws {
        XCTAssertTrue(AppState.backgroundWaitsForTurn(thinking: true, resolved: .local))
        XCTAssertFalse(AppState.backgroundWaitsForTurn(thinking: false, resolved: .local))
        XCTAssertFalse(AppState.backgroundWaitsForTurn(thinking: true, resolved: .anthropic), "a cloud turn changed")
        let send = try macSource("Sources/Grux/ChatService.swift")
        let thinking = try XCTUnwrap(send.range(of: "        state.beginChatTurn()\n        defer { state.endChatTurn() }\n        state.appendChat(userMsg)"),
                                     "the turn is not marked in flight before the message lands")
        XCTAssertNotNil(thinking)
        // FocusWatcher toggles isThinking around its own calls; the wait must
        // not key on it (PR 40 W2d review).
        let app = try macSource("Sources/Grux/AppState.swift")
        XCTAssertTrue(app.contains("backgroundWaitsForTurn(thinking: chatTurnInFlight,"))
        XCTAssertFalse(try macSource("Sources/Grux/FocusWatcher.swift").contains("ChatTurn"),
                       "the vision watcher can end a chat turn")
        XCTAssertTrue(try macSource("Sources/Grux/ChatView.swift").contains("if state.chatTurnInFlight {"),
                      "the Chat bubble shows for the vision watcher's calls")
    }

    /// Overlapping turns: the flag clears when the LAST one ends.
    func test_overlappingTurnsEndWithTheLastOne() {
        let state = AppState.shared
        state.beginChatTurn()
        state.beginChatTurn()
        state.endChatTurn()
        XCTAssertTrue(state.chatTurnInFlight, "the first turn to end cleared a turn still running")
        XCTAssertNotNil(state.thinkingSince)
        state.endChatTurn()
        XCTAssertFalse(state.chatTurnInFlight)
        XCTAssertNil(state.thinkingSince)
    }

    func test_theWaitSaysHowLongAndWhere() {
        let t0 = Date()
        XCTAssertEqual(ChatThinkingCopy.line(since: t0, now: t0.addingTimeInterval(12.4), local: true),
                       "Thinking, 12 s, local model")
        XCTAssertEqual(ChatThinkingCopy.line(since: t0, now: t0.addingTimeInterval(3), local: false), "Thinking, 3 s")
        XCTAssertEqual(ChatThinkingCopy.line(since: nil, now: t0, local: true), "Thinking", "a count with no turn to count")
    }
}

/// W2d-3. An Energy Recap card popped up over the first-run window at 8:00 PM.
final class NothingScheduledDuringSetupTests: XCTestCase {
    func test_recapsWaitForSetup() throws {
        for rel in ["Sources/Grux/Reminders/EnergyRecapScheduler.swift", "Sources/Grux/Reminders/DailyRecap.swift"] {
            let src = try macSource(rel)
            let fire = try XCTUnwrap(src.components(separatedBy: "private func checkAndFire() {").dropFirst().first)
            let guardAt = try XCTUnwrap(fire.range(of: "guard !OnboardingModel.shared.isPresenting else { return }"),
                                        "\(rel) can fire over first run")
            let stamp = try XCTUnwrap(fire.range(of: "lastFiredDayKey = dayKey"))
            XCTAssertLessThan(guardAt.lowerBound, stamp.lowerBound, "\(rel) spends the day before checking setup")
        }
        // The briefing already holds itself back during first run.
        XCTAssertTrue(try macSource("Sources/Grux/Jax/BriefingEngine.swift")
            .contains("onboardingPresenting: OnboardingModel.shared.isPresenting"))
    }
}

/// W2d-5. Jack runs the Mac by voice. Two panel buttons both called
/// "Microphone, <state>" made "click Microphone" offer numbered choices, and
/// the Focus window's collapse button was read as "Go Down" (W4 build 10,
/// live accessibility probe).
@MainActor
final class PanelVoiceNamesTests: XCTestCase {
    /// What each label expression in the panel says, by its first words.
    private func spoken(_ expr: String) -> String? {
        let tell = ListeningTell.muted
        switch expr {
        case "PanelCopy.orbLabel(tell)": return PanelCopy.orbLabel(tell)
        case "PanelCopy.micLabel(tell)": return PanelCopy.micLabel(tell)
        case "PanelCopy.listeningStatusLabel(tell)": return PanelCopy.listeningStatusLabel(tell)
        case "PanelCopy.settings": return PanelCopy.settings
        case "PanelCopy.inputLabel": return PanelCopy.inputLabel
        case "PanelCopy.closePane": return PanelCopy.closePane
        default: return nil
        }
    }

    func test_noTwoPanelControlsShareAName() throws {
        let files = ["Sources/Grux/Shell/CommandPanel/PanelHead.swift", "Sources/Grux/Shell/CommandPanel/PanelInput.swift",
                     "Sources/Grux/Shell/CommandPanel/PanelFoot.swift", "Sources/Grux/Shell/CommandPanel/PanelNowList.swift",
                     "Sources/Grux/Shell/CommandPanelRoot.swift"]
        var owner: [String: String] = [:]
        var known = 0
        for rel in files {
            let src = try macSource(rel)
            // One file may say the same label in two branches of one `if`;
            // only one of them is ever on screen.
            var mine: Set<String> = []
            for chunk in src.components(separatedBy: ".accessibilityLabel(").dropFirst() {
                var depth = 0
                let expr = String(chunk.prefix { c in
                    if c == "(" { depth += 1 } else if c == ")" { if depth == 0 { return false }; depth -= 1 }
                    return true
                })
                guard let words = spoken(expr) else { continue }
                known += 1
                let name = String(words.split(separator: ",").first ?? "")
                mine.insert(name)
            }
            for name in mine {
                if let other = owner[name] {
                    XCTFail("\(rel) and \(other) both name a control \"\(name)\", so a spoken click cannot choose")
                }
                owner[name] = rel
            }
        }
        XCTAssertGreaterThanOrEqual(known, 5, "the sweep recognised almost no labels, so it checked nothing")
        XCTAssertNotNil(owner["Microphone"], "the input's mic lost its name")
        XCTAssertNotNil(owner["Listening status"], "the foot's status lost its name")
    }

    func test_theFocusCollapseButtonSaysWhatItDoes() throws {
        let src = try macSource("Sources/Grux/FocusOverlayView.swift")
        let control = try XCTUnwrap(src.components(separatedBy: "private var collapseControl: some View {").dropFirst().first?.prefix(700))
        XCTAssertTrue(control.contains(".accessibilityLabel(\"Collapse to orb\")"), "Voice Control reads the chevron as \"Go Down\"")
    }
}

/// W2d-6. A Settings window already on screen applied a new deep link but did
/// not spend it, so closing it and reopening from the gear within 2 s went
/// back to the old section (PR 40 review).
@MainActor
final class VisibleSettingsSpendsTheRequestTests: XCTestCase {
    func test_aWindowOnScreenSpendsWhatItApplies() throws {
        let state = AppState.shared
        let saved = state.requestedSettingsTab
        defer { state.requestedSettingsTab = saved }
        let t0 = Date()
        state.requestedSettingsTab = "connect"
        // The already-open window applies it through onChange, on screen.
        XCTAssertEqual(state.takeSettingsRequest(now: t0, appearing: true), "connect")
        // Closed, then reopened from the gear inside the window: opens plainly.
        XCTAssertNil(state.takeSettingsRequest(now: t0.addingTimeInterval(1.2), appearing: true),
                     "the reopened Settings goes back to the old section")
        let src = try macSource("Sources/Grux/SettingsView.swift")
        let change = try XCTUnwrap(src.components(separatedBy: ".onChange(of: state.requestedSettingsTab) { _, _ in").dropFirst().first?.prefix(300))
        XCTAssertTrue(change.contains("applyRequestedSettingsTab(appearing: hostWindow.window?.isVisible == true)"),
                      "a window on screen applies the link without spending it")
    }
}

/// PR 40 W2d review, P2s. Tools a lean turn leaves out are named, so a
/// request that needs one is told why; and only a server on THIS Mac gets a
/// window sized to this Mac's memory.
@MainActor
final class LeanTurnHonestyTests: XCTestCase {
    private func systemText(_ p: ChatService.PendingTurnContext) -> String {
        p.systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func test_toolsLeftOutAreNamedAndToolsThatFitAreNot() {
        let state = AppState.shared
        let saved = state.chat
        defer { state.chat = saved }
        state.chat = [ChatMessage(role: .user, content: "what is on my plate today?")]
        let tight = ChatService.shared.assemblePendingContext(state: state, lean: true, window: 8_192)
        let all = ChatService.shared.assemblePendingContext(state: state, lean: false).tools.map(\.name)
        let cut = all.filter { name in !tight.tools.contains { $0.name == name } }
        XCTAssertFalse(cut.isEmpty, "nothing was cut, so this checks nothing")
        let text = systemText(tight)
        XCTAssertTrue(text.contains("TOOLS NOT OFFERED IN THIS LOCAL TURN:"), "the cut tools vanish silently")
        for name in cut { XCTAssertTrue(text.contains(name), "\(name) was cut and not named") }
        // Still inside its window with the line in it.
        let prompt = LocalTurn.tokens(chars: tight.systemBlocks.compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.count })
            + tight.messages.map(LocalTurn.chars).map(LocalTurn.tokens).reduce(0, +)
            + tight.tools.map(LocalTurn.chars).map(LocalTurn.tokens).reduce(0, +)
        XCTAssertLessThanOrEqual(prompt + tight.maxTokens, 8_192)
        let roomy = ChatService.shared.assemblePendingContext(state: state, lean: true, window: 200_000, ceiling: 200_000)
        XCTAssertEqual(roomy.tools.count, all.count, "control: with room, every tool fits")
        XCTAssertFalse(systemText(roomy).contains("TOOLS NOT OFFERED"), "a turn that fits names tools it did not cut")
        XCTAssertNil(LocalTurn.cutToolsLine([]))
    }

    func test_onlyALoopbackServerGetsThisMacsWindow() {
        for base in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            XCTAssertTrue(LocalTurn.isLoopback(baseURL: base), base)
            XCTAssertEqual(OpenAICompatBackend.contextTokens(forBaseURL: base), OpenAICompatBackend.ollamaContextTokens, base)
        }
        for base in ["http://studio.local:11434", "http://192.168.1.20:11434", "https://gpu.example.com"] {
            XCTAssertFalse(LocalTurn.isLoopback(baseURL: base), base)
            XCTAssertNil(OpenAICompatBackend.contextTokens(forBaseURL: base), "\(base) was sent this Mac's window")
        }
        let remote = OpenAICompatBackend.ollamaChatBody(["model": "m", "messages": []], stream: false, contextTokens: nil)
        XCTAssertNil((remote["options"] as? [String: Any])?["num_ctx"], "a remote server was told a window")
        let local = OpenAICompatBackend.ollamaChatBody(["model": "m", "messages": []], stream: false, contextTokens: 8_192)
        XCTAssertEqual((local["options"] as? [String: Any])?["num_ctx"] as? Int, 8_192)
    }
}
