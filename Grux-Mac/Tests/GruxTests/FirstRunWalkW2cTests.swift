import AppKit
import Network
import SwiftUI
import XCTest
@testable import Grux

/// The build 10 clean-VM walk, passes 1 and 2 (W4, 2026-10-13): what a stranger
/// met after first run, one class per finding.
private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

private func body(of marker: String, in src: String, length: Int = 2500) throws -> Substring {
    try XCTUnwrap(src.components(separatedBy: marker).dropFirst().first).prefix(length)
}

/// Lays a view out offscreen at `size`, fails on no layout, and writes a PNG to
/// `GRUX_SHOT_DIR` when it is set, so the state can be looked at.
@MainActor
private func render<V: View>(_ view: V, _ name: String, size: CGSize,
                             file: StaticString = #filePath, line: UInt = #line) {
    let host = NSHostingView(rootView: view
        .environmentObject(AppState.shared)
        .tint(GruxTheme.accentPrimary)
        .frame(width: size.width, height: size.height)
        .background(GruxTheme.base))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    PaneFitHarness.pump(0.4)
    XCTAssertGreaterThan(host.fittingSize.height, 0, "\(name) produced no layout", file: file, line: line)
    defer { window.contentView = nil }
    guard let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"],
          let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
}

/// 1. With no model, Return in the panel cleared the field and opened a Chat
/// that could not show the message, so it was gone.
@MainActor
final class PanelKeepsTypedTextTests: XCTestCase {
    func test_returnHoldsTheTextOnlyWhenNothingCanAnswerIt() {
        XCTAssertTrue(PanelInput.holdsForModel(canSend: false, needsNoModel: false))
        XCTAssertFalse(PanelInput.holdsForModel(canSend: true, needsNoModel: false))
        XCTAssertFalse(PanelInput.holdsForModel(canSend: false, needsNoModel: true),
                       "a workflow trigger needs no model and must still go")
    }

    func test_theHoldIsDecidedBeforeTheFieldIsCleared() throws {
        let src = try macSource("Sources/Grux/Shell/CommandPanel/PanelInput.swift")
        let send = try body(of: "private func send() {", in: src, length: 400)
        let hold = try XCTUnwrap(send.range(of: "Self.holdsForModel(t)"))
        let clear = try XCTUnwrap(send.range(of: "draft = \"\""))
        XCTAssertLessThan(hold.lowerBound, clear.lowerBound, "Return clears the text before deciding to keep it")
        XCTAssertTrue(try macSource("Sources/Grux/Shell/CommandPanelRoot.swift")
            .contains("onConnectModel: { model.perform(.connectModel) }"), "the held line's action goes nowhere")
    }

    func test_theHeldTextStaysWithTheWayToSendIt() {
        render(PanelInput(onTuning: {}, onSend: { _ in }, draft: "what is on my plate today", heldForModel: true)
            .padding(16), "w2c-1-panel-held", size: CGSize(width: 420, height: 120))
        XCTAssertEqual(PanelCopy.connectToSend, "Connect a model to send this.")
    }
}

/// 2. Focus started on the orb, so a sentence typed while the composer was
/// disabled pressed it on every space and left the microphone muted.
final class MuteTogglesOutOfTheKeyLoopTests: XCTestCase {
    func test_everyShellMuteToggleIsOutOfTheKeyViewLoop() throws {
        for rel in ["Sources/Grux/Shell/CommandPanel/PanelHead.swift",
                    "Sources/Grux/Shell/CommandPanel/PanelInput.swift",
                    "Sources/Grux/LaunchRootView.swift"] {
            let src = try macSource(rel)
            let toggles = src.components(separatedBy: "MicController.toggle(source:").count - 1
            let unfocusable = src.components(separatedBy: ".focusable(false)").count - 1
            XCTAssertGreaterThan(toggles, 0, "\(rel) no longer toggles the mic, so this counts nothing")
            XCTAssertEqual(unfocusable, toggles, "\(rel): a mute toggle can take a space typed for a field")
        }
        let input = try macSource("Sources/Grux/Shell/CommandPanel/PanelInput.swift")
        XCTAssertTrue(input.contains(".onAppear { focused = true }"), "the panel input no longer takes focus")
    }
}

/// Out of the key view loop is not out of reach. Jack runs the Mac by voice,
/// and Voice Control presses through the accessibility tree, so the orb and
/// the mic must stay there as named buttons (PR 40 review).
///
/// A SOURCE GUARD, and only that: the test host builds no SwiftUI
/// accessibility tree (measured: an offscreen and an ordered-in window both
/// exposed one bare AXGroup with no children, and hit tests found nothing
/// else), so the live tree is checked on the VM, not here.
final class MuteTogglesStillNamedForVoiceTests: XCTestCase {
    func test_theOrbAndTheMicKeepTheirNamesAndAreNeverHidden() throws {
        let cases = [("Sources/Grux/Shell/CommandPanel/PanelHead.swift", "MicController.toggle(source: \"orb\")", ".accessibilityLabel(PanelCopy.orbLabel(tell))"),
                     ("Sources/Grux/Shell/CommandPanel/PanelInput.swift", "MicController.toggle(source: \"panel\")", ".accessibilityLabel(PanelCopy.micLabel(tell))")]
        for (rel, action, label) in cases {
            let src = try macSource(rel)
            let button = try body(of: action, in: src, length: 1200)
            XCTAssertTrue(button.contains(".focusable(false)"), "\(rel): the toggle is back in the key view loop")
            XCTAssertTrue(button.contains(label), "\(rel): the toggle lost the name Voice Control says")
            XCTAssertFalse(button.contains("accessibilityHidden"), "\(rel): the toggle is hidden from Voice Control")
        }
        XCTAssertTrue(PanelCopy.orbLabel(.muted).hasPrefix("Grux orb"))
        XCTAssertTrue(PanelCopy.micLabel(.muted).hasPrefix("Microphone"))
    }
}

/// 3. Setup listed Chat as working with no model, sent people to Settings with
/// only a Skip, and made "Listen all the time" the filled default.
@MainActor
final class SetupWalkTruthTests: XCTestCase {
    private var chat: FeatureRow { FeatureRegistry.row(id: "chat")! }

    func test_withNoModelChatIsNotListedAsWorking() {
        let none = SetupOrder.plan(features: [chat], listening: false, listeningStarted: false, satisfied: { _ in false })
        XCTAssertFalse(none.ready.contains("chat"), "Chat is called working with no model")
        XCTAssertEqual(none.needsModel, ["chat"])
        XCTAssertTrue(none.required.isEmpty, "the model is asked for a second time")
        XCTAssertFalse(SetupOrder.screens(for: none, oneAtATime: true, extrasAccepted: false).isEmpty,
                       "a Chat waiting on a model leaves the step with nothing to say")
        let key = SetupOrder.plan(features: [chat], listening: false, listeningStarted: false,
                                  satisfied: { $0 == .keyAnthropic })
        XCTAssertEqual(key.ready, ["chat"])
        XCTAssertTrue(key.needsModel.isEmpty)
    }

    func test_theReadyScreenSaysWhatStillNeedsAModel() {
        let plan = SetupOrder.Plan(ready: ["home", "approvals", "notes"], required: [], optional: [], needsModel: ["chat"])
        render(SetupStep(plan: plan).padding(40), "w2c-3a-setup-needs-model", size: CGSize(width: 720, height: 420))
    }

    func test_aSettingsItemOpensSettingsWhereItIsSetUp() {
        XCTAssertEqual(Setup.settingsTag(for: .endpointImap), "endpoint.imap")
        XCTAssertNil(Setup.settingsTag(for: .permMicrophone), "a permission has its own button")
        let item = SetupOrder.Item(requirement: .endpointImap, neededBy: ["mailbox"])
        let plan = SetupOrder.Plan(ready: [], required: [item], optional: [])
        render(SetupStep(plan: plan).padding(40), "w2c-3b-mail-server-open-settings", size: CGSize(width: 720, height: 360))
    }

    func test_offIsThePrimaryListeningChoice() throws {
        let src = try macSource("Sources/Grux/Onboarding/FirstRunScreens.swift")
        let off = try body(of: "Button(Setup.keepListeningOff)", in: src, length: 160)
        XCTAssertTrue(off.contains(".keyboardShortcut(walking ? .defaultAction : nil)"), "Keep it off is not the default")
        let always = try body(of: "Button(Setup.listenAllTheTime)", in: src, length: 120)
        XCTAssertFalse(always.contains("defaultAction"), "listening all the time is the default again")
        let item = SetupOrder.Item(requirement: .permMicrophone, neededBy: [SetupOrder.listeningId])
        let plan = SetupOrder.Plan(ready: [], required: [item], optional: [])
        render(SetupStep(plan: plan).padding(40), "w2c-3c-listening", size: CGSize(width: 720, height: 360))
    }
}

/// 4. "What Grux found" said Grux keeps using a cloud model nobody had set.
final class FoundReportNothingConnectedTests: XCTestCase {
    func test_noKeyAndNoLocalModelSaysNothingIsConnected() {
        let r = ModelUpdateReport.build(profile: HardwareProfile.detect(), hasCloudModel: false, routesToCloud: true,
                                        localServerRunning: false, installedTags: [])
        XCTAssertFalse(r.qualityWarning.contains("cloud model by default"), r.qualityWarning)
        if r.headline != nil {
            XCTAssertTrue(r.qualityWarning.hasPrefix("No model is connected yet"), r.qualityWarning)
        }
        // A server with no model is not a connected model either.
        let empty = ModelUpdateReport.build(profile: HardwareProfile.detect(), hasCloudModel: false, routesToCloud: true,
                                            localServerRunning: true, installedTags: [])
        XCTAssertFalse(empty.qualityWarning.contains("cloud model by default"), empty.qualityWarning)
    }
}

/// 5. After "Skip for now" nothing in the app got a model: "Connect a model"
/// opened Settings on General, and Models had no download.
@MainActor
final class ConnectAModelInSettingsTests: XCTestCase {
    func test_aRequestTakenByOneSettingsStillReachesTheOneOpening() {
        let state = AppState.shared
        let saved = state.requestedSettingsTab
        defer { state.requestedSettingsTab = saved }
        let t0 = Date()
        state.requestedSettingsTab = "connect"
        XCTAssertEqual(state.takeSettingsRequest(now: t0), "connect", "the first Settings did not get it")
        XCTAssertNil(state.requestedSettingsTab, "the request stays pending and fires on a later open")
        XCTAssertEqual(state.takeSettingsRequest(now: t0.addingTimeInterval(0.5)), "connect",
                       "the Settings that is actually opening lands on General")
        XCTAssertNil(state.takeSettingsRequest(now: t0.addingTimeInterval(AppState.settingsRequestWindow + 1)),
                     "an old request fires on a later plain open")
    }

    /// The Settings that opens spends the request, so closing it and opening
    /// Settings again from the gear inside the window opens plainly (PR 40 review).
    func test_aRequestIsSpentByTheSettingsThatOpens() throws {
        let state = AppState.shared
        let saved = state.requestedSettingsTab
        defer { state.requestedSettingsTab = saved }
        let t0 = Date()
        state.requestedSettingsTab = "connect"
        // A closed Settings window kept alive sees the change first.
        XCTAssertEqual(state.takeSettingsRequest(now: t0), "connect")
        // The Settings actually opening still gets it, and spends it.
        XCTAssertEqual(state.takeSettingsRequest(now: t0.addingTimeInterval(0.3), appearing: true), "connect")
        // A third, unrelated open inside the window opens plainly.
        XCTAssertNil(state.takeSettingsRequest(now: t0.addingTimeInterval(1), appearing: true),
                     "reopening Settings scrolls to the section an earlier link asked for")
        XCTAssertTrue(try macSource("Sources/Grux/SettingsView.swift").contains("applyRequestedSettingsTab(appearing: true)"),
                      "the Settings that appears does not spend the request")
    }

    func test_connectOpensTheSettingsWindowAtModels() throws {
        let loc = SettingsTabAliases.resolve("connect")
        XCTAssertEqual(loc.pane, .models)
        XCTAssertEqual(loc.anchor, "models.connect")
        let root = try macSource("Sources/Grux/Shell/CommandPanelRoot.swift")
        let action = try body(of: "case .connectModel:", in: root, length: 300)
        XCTAssertTrue(action.contains("requestedSettingsTab = \"connect\""))
        XCTAssertTrue(action.contains("WindowOpener.openSettings()"), "Connect a model no longer opens Settings")
        let settings = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("guard let tab = state.takeSettingsRequest(appearing: appearing) else { return }"),
                      "Settings reads the request without the hand-off between two live Settings")
    }

    func test_modelsOffersTheDownloadOrWhereToGetOllama() {
        let pick = Cookbook.headline(for: HardwareProfile.detect())
        XCTAssertEqual(ConnectModelCopy.route(reachable: false, usable: false, pick: pick), .getOllama)
        XCTAssertEqual(ConnectModelCopy.route(reachable: true, usable: true, pick: pick), .ready)
        XCTAssertEqual(ConnectModelCopy.route(reachable: true, usable: false, pick: nil), .noFit)
        if let pick {
            XCTAssertEqual(ConnectModelCopy.route(reachable: true, usable: false, pick: pick), .download(pick))
            XCTAssertEqual(ConnectModelCopy.download(pick),
                           String(format: "Download %@ (%.1f GB)", pick.displayName, pick.diskGB))
            render(Form { ConnectModelSection(preview: .download(pick)) }.formStyle(.grouped),
                   "w2c-5-models-download", size: CGSize(width: 640, height: 260))
        }
        render(Form { ConnectModelSection(preview: .getOllama) }.formStyle(.grouped),
               "w2c-5-models-get-ollama", size: CGSize(width: 640, height: 280))
    }
}

/// 6. Ollama answering with no model routed chat to it, so the "Connect a
/// model" row went away while every turn would fail. The live half is in
/// `OllamaCapabilityTests`, against a real stub server.
final class EmptyLocalServerIsNotAModelTests: XCTestCase {
    func test_routingAndReadinessAskForAUsableModel() throws {
        let registry = try macSource("Sources/Grux/Backend/ModelRegistry.swift")
        XCTAssertTrue(registry.contains("hasLocal: localUsable)"), "no key routes to a server holding nothing")
        XCTAssertTrue(registry.contains("return localUsable ? .local : .anthropic"))
        XCTAssertTrue(try macSource("Sources/Grux/Chat/ChatReadiness.swift")
            .contains("localModelAvailable: registry.localUsable,"), "readiness counts an empty server")
    }
}

/// An OpenAI-compatible server (vLLM, llama.cpp, a proxy) can serve chat
/// while its /v1/models lists nothing standard. Before PR 40 such a server
/// routed and read ready, and it must still (PR 40 review). Only Ollama's own
/// empty /api/tags means nothing is there.
@MainActor
final class CompatServerStillUsableTests: XCTestCase {
    private var savedBase = ""
    private var server: PathServer?

    override func setUp() async throws {
        savedBase = AppState.shared.config.ollamaBaseURL
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() async throws {
        server?.stop()
        AppState.shared.config.ollamaBaseURL = savedBase
        ModelRegistry.shared.resetLocalForTest()
    }

    private func discover(_ routes: [String: (Int, String)]) async throws {
        let s = try PathServer(routes: routes)
        server = s
        try s.start()
        XCTAssertGreaterThan(s.port, 0, "the stub never bound a port")
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:\(s.port)"
        await ModelRegistry.shared.discoverLocal()
        XCTAssertNotNil(ModelRegistry.shared.local, "discovery did not reach the stub: \(ModelRegistry.shared.localStatus ?? "nil")")
    }

    private let chat = (200, #"{"id":"c","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#)

    func test_aCompatServerListingNothingStandardStillServes() async throws {
        for models in [#"{"data":[]}"#, #"{"object":"list"}"#] {
            try await discover(["/api/tags": (404, "not found"), "/v1/models": (200, models), "/v1/chat/completions": chat])
            XCTAssertFalse(ModelRegistry.shared.localServedByOllama)
            XCTAssertTrue(ModelRegistry.shared.localUsable, "a compat server answering \(models) no longer counts")
            XCTAssertEqual(ModelRegistry.anthropicRoute(hasKey: false, hasLocal: ModelRegistry.shared.localUsable), .local)
            server?.stop()
        }
    }

    func test_ollamaReportingNoModelIsStillNotUsable() async throws {
        try await discover(["/api/tags": (200, #"{"models":[]}"#)])
        XCTAssertTrue(ModelRegistry.shared.localServedByOllama)
        XCTAssertFalse(ModelRegistry.shared.localUsable, "an Ollama with nothing pulled counts as a model")
    }
}

/// A loopback server answering by request path, for discovery tests.
private final class PathServer: @unchecked Sendable {
    private let listener: NWListener
    private let routes: [String: (Int, String)]
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(routes: [String: (Int, String)]) throws {
        self.routes = routes
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        let routes = self.routes
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let (code, body) = routes[path] ?? (404, "not found")
                let resp = "HTTP/1.1 \(code) X\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "PathServer", code: 1)
        }
    }

    func stop() { listener.cancel() }
}

/// 7. Search and deep links opened a pane at its top, Models priced a fresh
/// install with no key at "about $60 a month", and the local status was stale.
@MainActor
final class SettingsSmallTruthsTests: XCTestCase {
    func test_noKeyCostsNothing() {
        let line = TuningCopy.tierPointer(.tier4_hybrid_8s, spends: false)
        XCTAssertTrue(line.contains("$0 a month"), line)
        XCTAssertFalse(line.contains("$60"), line)
        XCTAssertTrue(TuningCopy.tierPointer(.tier4_hybrid_8s).contains("$60"), "the estimate is gone where it is true")
    }

    /// Every anchor a search result or a deep link can name, from the
    /// registry itself, must sit in a section a ScrollViewReader can reach:
    /// the reader wraps the Form (or the view holding it), never a ScrollView
    /// around it, where no section id can be found (W4 pass 2; PR 40 review
    /// found Terminal sessions still wrapped).
    func test_aDeepLinkCanFindItsSection() throws {
        var anchors = Set(SettingsSearchRegistry.entries.compactMap(\.location.anchor))
        anchors.formUnion(SettingsTabAliases.map.values.compactMap(\.anchor))
        let credential = Set(SetupRequirement.allCases.filter { $0.kind == .key }.map(SettingsTabAliases.credentialAnchor))
        anchors.formUnion(credential)
        XCTAssertGreaterThan(anchors.count, 20, "the registry yielded almost no anchors, so this checks nothing")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        var files: [String: String] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        let settings = try XCTUnwrap(files["SettingsView.swift"])
        let reader = "ScrollViewReader { proxy in"

        /// The text between the reader enclosing `index` in SettingsView and `index`.
        func readerToHere(_ index: String.Index) -> Substring? {
            guard let r = settings.range(of: reader, options: .backwards, range: settings.startIndex..<index) else { return nil }
            return settings[r.upperBound..<index]
        }

        var checked: Set<String> = []
        for anchor in anchors.sorted() {
            let marker = credential.contains(anchor) ? ".id(SettingsTabAliases.credentialAnchor(req))" : ".id(\"\(anchor)\")"
            guard let (name, text) = files.first(where: { $0.value.contains(marker) }) else {
                XCTFail("\(anchor) is registered but no section carries that id, so it can never be scrolled to")
                continue
            }
            let at = try XCTUnwrap(text.range(of: marker)).lowerBound
            var between: Substring
            if name == "SettingsView.swift" {
                between = try XCTUnwrap(readerToHere(at), "\(anchor) has no ScrollViewReader around it")
            } else {
                // A section in its own view: find that view's call site in SettingsView.
                let decl = try XCTUnwrap(text.range(of: "struct ", options: .backwards, range: text.startIndex..<at))
                let type = String(text[decl.upperBound...].prefix { $0.isLetter || $0.isNumber })
                guard let call = settings.range(of: "\(type)()") else {
                    XCTFail("\(anchor) lives in \(type), which SettingsView never shows")
                    continue
                }
                between = try XCTUnwrap(readerToHere(call.lowerBound), "\(type) has no ScrollViewReader around it")
                // And the view itself must not put its Form inside a ScrollView.
                XCTAssertFalse(text[text.startIndex..<at].contains("ScrollView {"),
                               "\(type) wraps its own sections in a ScrollView, so \(anchor) cannot be found")
            }
            XCTAssertFalse(between.contains("ScrollView {"),
                           "\(anchor) (\(name)): a ScrollView sits between the reader and the section, so the deep link opens at the top")
            checked.insert(name)
        }
        XCTAssertTrue(checked.contains("TerminalSessionsSettingsView.swift"), "the embedded-view path checked nothing")
    }

    func test_modelsRereadsTheLocalServerWhenItOpens() throws {
        let src = try macSource("Sources/Grux/SettingsView.swift")
        let models = try body(of: "private var modelsConfigSub: some View {", in: src, length: 12000)
        XCTAssertTrue(models.contains(".task { await ModelRegistry.shared.discoverLocal() }"),
                      "the local status is whatever the last Discover press found")
    }
}
