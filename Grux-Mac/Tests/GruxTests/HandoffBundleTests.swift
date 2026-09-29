import XCTest
import AppKit
@testable import Grux

/// The bundle an agent reads to apply "my Grux" elsewhere. Secrets never
/// survive it, and that is proven by planting them.
final class HandoffBundleTests: XCTestCase {
    private var scratch: URL { Persistence.gruxDir.appendingPathComponent("handoff-tests", isDirectory: true) }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// A folder that does not exist yet, under the suite's scratch grux dir.
    private func temp() -> URL {
        scratch.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
    }

    private let planted = ["anthropicApiKey": "sk-ant-PLANTED-1",
                           "elevenLabsApiKey": "el-PLANTED-2",
                           "someToken": "tok-PLANTED-3",
                           "webhookSecret": "whs-PLANTED-4",
                           "imapPassword": "pw-PLANTED-5"]

    private func config(extra: [String: Any] = [:]) throws -> Data {
        var dict: [String: Any] = ["model": "deepseek", "listeningMode": "alwaysOn"]
        for (k, v) in planted { dict[k] = v }
        for (k, v) in extra { dict[k] = v }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_everyPlantedSecretIsGone_andTheRestSurvives() throws {
        let url = try HandoffBundle.write(to: temp(), config: config(), theme: Data("{\"hue\":12}".utf8), macros: nil,
                                          orders: [], setupPrompt: "CONTEXT\nhello").get()
        let all = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for (_, v) in planted { XCTAssertFalse(all.contains(v), "\(v) leaked") }
        let cfg = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("config.json"))) as? [String: Any])
        XCTAssertEqual(cfg["model"] as? String, "deepseek")
        XCTAssertNil(cfg["anthropicApiKey"])
    }

    func test_aNestedSecretIsStripped() throws {
        let url = try HandoffBundle.write(to: temp(),
                                          config: config(extra: ["accounts": [["host": "imap.x", "password": "pw-NESTED-9"]],
                                                                 "vault": ["inner": ["passphrase": "pp-NESTED-10", "label": "kept"]]]),
                                          theme: nil, macros: nil, orders: [], setupPrompt: "").get()
        let text = try String(contentsOf: url.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("pw-NESTED-9"), "a secret inside an array of objects survived")
        XCTAssertFalse(text.contains("pp-NESTED-10"), "a secret two objects deep survived")
        XCTAssertTrue(text.contains("imap.x"))
        XCTAssertTrue(text.contains("kept"))
    }

    /// R9.8: theme, macros and the work-order index go through the same
    /// strip as the config.
    func test_aSecretNestedInMacrosIsStripped() throws {
        let macros: [[String: Any]] = [["name": "deploy_site", "triggers": ["ship it"],
                                        "actions": [["action": ["shell": ["command": "make deploy",
                                                                          "apiToken": "tok-MACRO-11"]]]]]]
        let theme: [String: Any] = ["accentHue": 12, "sync": ["clientSecret": "cs-THEME-12"]]
        let url = try HandoffBundle.write(to: temp(), config: config(),
                                          theme: JSONSerialization.data(withJSONObject: theme),
                                          macros: JSONSerialization.data(withJSONObject: macros),
                                          orders: [], setupPrompt: "").get()
        let macroText = try String(contentsOf: url.appendingPathComponent("macros.json"), encoding: .utf8)
        XCTAssertFalse(macroText.contains("tok-MACRO-11"), "a secret nested in a macro survived")
        XCTAssertTrue(macroText.contains("make deploy"), "the macro itself did not survive")
        let themeText = try String(contentsOf: url.appendingPathComponent("theme.json"), encoding: .utf8)
        XCTAssertFalse(themeText.contains("cs-THEME-12"), "a secret nested in the theme survived")
        XCTAssertTrue(themeText.contains("accentHue"))
    }

    /// R9.9: under a secret-shaped key only strings go, at any depth. A
    /// number or a boolean is a setting, not a secret, and survives.
    func test_aNumberUnderASecretShapedKeySurvives_aStringDoesNot() throws {
        let url = try HandoffBundle.write(to: temp(),
                                          config: config(extra: ["maxTokens": 4096, "useTokenCache": true,
                                                                 "tokens": ["PLANTED-A"],
                                                                 "tokenBudget": ["daily": 50, "label": "PLANTED-B"]]),
                                          theme: nil, macros: nil, orders: [], setupPrompt: "").get()
        let text = try String(contentsOf: url.appendingPathComponent("config.json"), encoding: .utf8)
        let cfg = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(cfg["maxTokens"] as? Int, 4096, "a numeric setting was stripped as a secret")
        XCTAssertEqual(cfg["useTokenCache"] as? Bool, true, "a boolean setting was stripped as a secret")
        XCTAssertEqual((cfg["tokenBudget"] as? [String: Any])?["daily"] as? Int, 50)
        XCTAssertNil(cfg["anthropicApiKey"])
        for planted in ["PLANTED-A", "PLANTED-B", "sk-ant-PLANTED-1"] {
            XCTAssertFalse(text.contains(planted), "\(planted) survived under a secret-shaped key")
        }
    }

    /// A theme or macros file that is there but does not parse is left out,
    /// and GRUX.md says so rather than claiming it never existed.
    func test_anUnreadableThemeIsNamedAsLeftOut_notAsNeverChanged() throws {
        let url = try HandoffBundle.write(to: temp(), config: config(), theme: Data("not json".utf8),
                                          macros: Data("{".utf8), orders: [], setupPrompt: "").get()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        XCTAssertFalse(names.contains("theme.json"))
        XCTAssertFalse(names.contains("macros.json"))
        let readme = try String(contentsOf: url.appendingPathComponent("GRUX.md"), encoding: .utf8)
        XCTAssertFalse(readme.contains("never changed the theme"), "GRUX.md claims a theme that exists was never changed")
        XCTAssertFalse(readme.contains("they have no macros"), "GRUX.md claims macros that exist are absent")
        XCTAssertTrue(readme.contains("`theme.json`: left out because it did not parse"))
        XCTAssertTrue(readme.contains("`macros.json`: left out because it did not parse"))
    }

    /// An agent reads these files as text, so a URL reads as a URL.
    func test_urlsAreWrittenWithoutEscapedSlashes() throws {
        let url = try HandoffBundle.write(to: temp(), config: config(extra: ["ollamaBaseURL": "http://localhost:11434"]),
                                          theme: nil, macros: nil, orders: [], setupPrompt: "").get()
        let text = try String(contentsOf: url.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("http://localhost:11434"), "slashes were escaped")
    }

    /// Settings' "Hand setup to your agent" works in both shells: the legacy
    /// shell has no hub to open, so it writes the bundle there and says where;
    /// the panel shell opens the hub and writes nothing itself.
    @MainActor
    func test_settingsHandsOverInBothShells() {
        let savedTab = AppState.shared.requestedTab
        let savedExpanded = OptimizeHubState.shared.isExpanded
        defer {
            AppState.shared.requestedTab = savedTab
            OptimizeHubState.shared.isExpanded = savedExpanded
        }
        let bundle = Persistence.gruxDir.appendingPathComponent("handoff/20260926-101500", isDirectory: true)
        var writes = 0
        OptimizeHubState.shared.isExpanded = false
        AppState.shared.requestedTab = "chat"

        let legacy = SettingsHandoff.run(legacyShell: true, write: { writes += 1; return .success(bundle) })
        XCTAssertEqual(writes, 1, "the legacy shell did not write the bundle")
        XCTAssertTrue(legacy?.contains("20260926-101500") == true, "the legacy line does not say where: \(String(describing: legacy))")
        XCTAssertFalse(OptimizeHubState.shared.isExpanded, "the legacy shell opened a hub it does not host")
        XCTAssertEqual(AppState.shared.requestedTab, "chat", "the legacy shell was sent to another tab")

        let failed = SettingsHandoff.run(legacyShell: true, write: { .failure(HandoffBundle.Error.noConfig) })
        XCTAssertTrue(failed?.contains(HandoffBundle.Error.noConfig.localizedDescription) == true,
                      "the legacy error was not shown: \(String(describing: failed))")

        let panel = SettingsHandoff.run(legacyShell: false, write: { writes += 1; return .success(bundle) })
        XCTAssertNil(panel, "the panel shell showed a line instead of opening the hub")
        XCTAssertEqual(writes, 1, "the panel shell wrote the bundle itself")
        XCTAssertTrue(OptimizeHubState.shared.isExpanded, "the panel shell did not open the hub")
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none)
    }

    /// Settings is its own window, often over the panel or with the launch
    /// window closed (Grux lives in the menu bar). In the panel shell "Hand
    /// setup to your agent" must bring the panel forward, as the palette's
    /// Optimize Grux does, or the card expands where nobody can see it.
    @MainActor
    func test_thePanelHandoffBringsThePanelForward() {
        let savedTab = AppState.shared.requestedTab
        let savedExpanded = OptimizeHubState.shared.isExpanded
        let savedDelegate = AppDelegate.shared
        let delegate = AppDelegate()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: GruxLayout.panelWidth, height: GruxLayout.panelMinHeight),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        delegate.launchWindow = win
        AppDelegate.shared = delegate
        defer {
            win.orderOut(nil)
            AppDelegate.shared = savedDelegate
            AppState.shared.requestedTab = savedTab
            OptimizeHubState.shared.isExpanded = savedExpanded
        }
        win.orderOut(nil)
        XCTAssertFalse(win.isVisible, "the suite could not hide the launch window")

        let legacy = SettingsHandoff.run(legacyShell: true, write: { .failure(HandoffBundle.Error.noConfig) })
        XCTAssertNotNil(legacy)
        XCTAssertFalse(win.isVisible, "the classic shell's inline handoff raised the launch window")

        AppState.shared.requestedTab = "mailbox"
        XCTAssertNil(SettingsHandoff.run(legacyShell: false, write: { .failure(HandoffBundle.Error.noConfig) }))
        XCTAssertTrue(win.isVisible, "the panel's card expanded in a window that was never brought forward")
        XCTAssertEqual(AppState.shared.requestedTab, PanelKeys.none)
        XCTAssertTrue(OptimizeHubState.shared.isExpanded)
    }

    func test_settingsUsesTheSharedHandoffAction() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("SettingsHandoff.run(legacyShell: state.config.legacyShell)"),
                      "Settings does not branch on the shell")
    }

    func test_theBundleHasTheSixFiles_andGRUXmdNamesEachOne() throws {
        let url = try HandoffBundle.write(to: temp(), config: config(), theme: Data("{}".utf8), macros: Data("[]".utf8),
                                          orders: [], setupPrompt: "p").get()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        XCTAssertEqual(names, ["GRUX.md", "config.json", "theme.json", "macros.json", "work-orders.json", "setup-prompt.md"])
        let readme = try String(contentsOf: url.appendingPathComponent("GRUX.md"), encoding: .utf8)
        for n in names where n != "GRUX.md" { XCTAssertTrue(readme.contains("`\(n)`"), "GRUX.md does not explain \(n)") }
        XCTAssertTrue(readme.contains("Sources/Grux/DesignSystem"), "the rules did not travel")
    }

    func test_absentThemeAndMacrosAreNotInvented() throws {
        let url = try HandoffBundle.write(to: temp(), config: config(), theme: nil, macros: nil, orders: [], setupPrompt: "").get()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        XCTAssertFalse(names.contains("theme.json"))
        XCTAssertFalse(names.contains("macros.json"))
    }

    /// R9.2: the folder exists before the first file write fails, and a failure
    /// still leaves nothing behind.
    func test_aFailedWriteLeavesNoPartialFolder() throws {
        let folder = temp()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("config.json", isDirectory: true),
                                                withIntermediateDirectories: true)
        let r = HandoffBundle.write(to: folder, config: try config(), theme: nil, macros: nil, orders: [], setupPrompt: "")
        guard case .failure = r else { return XCTFail("wrote config.json over a directory") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a partial bundle was left behind")
    }

    /// R9.2: two hand overs in the same second get two folders, never one
    /// overwritten.
    func test_aSecondBundleInTheSameSecondNeverOverwritesTheFirst() throws {
        let root = temp()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = HandoffBundle.folder(in: root, now: now)
        XCTAssertEqual(first.deletingLastPathComponent().path, root.path)
        XCTAssertNotNil(first.lastPathComponent.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression),
                        "\(first.lastPathComponent) is not yyyyMMdd-HHmmss")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = HandoffBundle.folder(in: root, now: now)
        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + "-2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        XCTAssertEqual(HandoffBundle.folder(in: root, now: now).lastPathComponent, first.lastPathComponent + "-3")
    }

    // Limit: this sees only `var name: String` lines in Models.swift; a secret held with `let` or as Data or a dictionary would slip past it.
    func test_everyConfigKeyThatLooksSecretIsMatched() throws {
        let models = try source("Sources/Grux/Models.swift")
        let re = try NSRegularExpression(pattern: #"^\s+var ([A-Za-z0-9_]+): String"#, options: .anchorsMatchLines)
        let names = re.matches(in: models, range: NSRange(models.startIndex..., in: models))
            .map { String(models[Range($0.range(at: 1), in: models)!]) }
        let suspicious = names.filter { $0.range(of: "(?i)(key|token|secret|password|credential)", options: .regularExpression) != nil }
        XCTAssertFalse(suspicious.isEmpty, "the scan found no string config keys at all; the regex is broken")
        for n in suspicious {
            XCTAssertTrue(HandoffBundle.isSecretKey(n), "\(n) looks like a secret and would survive the bundle")
        }
    }

    /// R9.3, spec 5.3: the live bundle lands in ~/.grux/handoff.
    func test_theLiveRootIsUnderTheGruxDir() {
        XCTAssertTrue(HandoffBundle.liveRoot.path.hasPrefix(Persistence.gruxDir.path))
        XCTAssertEqual(HandoffBundle.liveRoot.lastPathComponent, "handoff")
    }

    /// R8.10: the card shows the error's description, so it reads as a
    /// sentence and never as an enum name.
    func test_anErrorReadsAsASentence() {
        for error in [HandoffBundle.Error.noConfig, .cannotCreate("~/.grux/handoff/x")] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("HandoffBundle"), text)
            XCTAssertFalse(text.contains("error 0") || text.contains("error 1"), text)
        }
        XCTAssertTrue(HandoffBundle.Error.cannotCreate("~/.grux/handoff/x").localizedDescription.contains("~/.grux/handoff/x"))
    }

    /// R9.4: writing the bundle never opens Finder; the card's Reveal in
    /// Finder button does, when asked.
    func test_writeLiveNeverOpensFinder() throws {
        let bundle = try source("Sources/Grux/Optimize/HandoffBundle.swift")
        XCTAssertTrue(bundle.contains("func writeLive()"), "the scan is reading the wrong file")
        XCTAssertFalse(bundle.contains("activateFileViewerSelecting"), "writeLive opens Finder")
        XCTAssertFalse(bundle.contains("NSWorkspace"), "writeLive reaches for the workspace")
        let card = try source("Sources/Grux/Optimize/OptimizeHubCard.swift")
        XCTAssertTrue(card.contains("activateFileViewerSelecting"), "nothing reveals the bundle")
    }
}
