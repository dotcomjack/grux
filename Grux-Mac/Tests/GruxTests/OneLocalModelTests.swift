import XCTest
@testable import Grux

/// release/3.2: a Mac runs ONE local model. Measured 2026-10-31 on a 48 GB
/// MacBook: chat on the shipped default llama3.2:3b and file naming on the
/// installed Grux Local 4B kept two models resident; one grew to 13 GB and
/// swap filled.
@MainActor
final class OneLocalModelTests: XCTestCase {
    private func mac(_ ram: UInt64, _ gpu: UInt64) -> HardwareProfile {
        HardwareProfile(chipName: "Apple M4", physicalMemoryBytes: ram * 1_073_741_824,
                        gpuWorkingSetBytes: gpu * 1_073_741_824, cpuCoreCount: 10,
                        hasUnifiedMemory: true, isAppleSilicon: true)
    }

    /// The background path follows a Grux Local chat model unless somebody
    /// typed another model for it.
    func test_theBackgroundModelFollowsAGruxLocalChatModel() {
        let four = "gruxai.com/grux/grux-local:4b"
        let here = "http://127.0.0.1:3849/v1/chat/completions"
        func model(_ local: String, _ offline: String, _ endpoint: String = here) -> String {
            GruxConfig.backgroundLocalModel(local: local, offline: offline, endpoint: endpoint)
        }
        XCTAssertEqual(model(GruxConfig.defaultLocalModel, four), four)
        XCTAssertEqual(model("", "grux-local:4b"), "grux-local:4b")
        XCTAssertEqual(model("qwen3.5:4b", four), "qwen3.5:4b", "a typed choice")
        XCTAssertEqual(model("", "qwen3.5:4b"), GruxConfig.defaultLocalModel)
        XCTAssertEqual(model(GruxConfig.defaultLocalModel, "qwen3.5:4b"), GruxConfig.defaultLocalModel)
        XCTAssertEqual(model(GruxConfig.defaultLocalModel, four, "http://media-box.local:3849/v1/chat/completions"),
                       GruxConfig.defaultLocalModel, "a proxy on another machine has its own server")
    }

    /// The Settings field keeps the typed text; a line under it says what
    /// runs when that differs.
    func test_theFieldNoteNamesWhatRuns() {
        let four = "gruxai.com/grux/grux-local:4b"
        let here = "http://127.0.0.1:3849/v1/chat/completions"
        func note(_ local: String, _ offline: String, _ endpoint: String = here, on: Bool = true) -> String? {
            GruxConfig.backgroundFieldNote(local: local, offline: offline, endpoint: endpoint, ambientOn: on)
        }
        XCTAssertEqual(note(GruxConfig.defaultLocalModel, four),
                       "In use: \(four), chat's model, so one local model stays loaded.")
        XCTAssertNil(note("qwen3.5:4b", four), "a typed choice runs")
        XCTAssertNil(note("llama3.2:3b-instruct-q8_0", four), "a tag that starts with the default is a typed choice")
        XCTAssertNil(note("", four), "the placeholder covers empty")
        XCTAssertNil(note(GruxConfig.defaultLocalModel, "qwen3.5:4b"))
        XCTAssertNil(note(GruxConfig.defaultLocalModel, four, "http://media-box.local:3849/v1/chat/completions"),
                     "a proxy on another machine runs the field's model")
        XCTAssertNil(note(GruxConfig.defaultLocalModel, four, on: false), "the local ambient switch is off")
    }

    /// Every background reader goes through the one rule, not its own copy.
    func test_everyBackgroundReaderUsesTheRule() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Grux")
        for file in ["LocalLLM.swift", "SettingsView.swift", "Triggers/AppTriggers.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("GruxConfig.backgroundLocalModel(local:"), "\(file) reads the field directly")
            if file == "SettingsView.swift" {
                XCTAssertTrue(text.contains("GruxConfig.backgroundFieldNote(local:"), "Settings lost the line naming what runs")
            }
            XCTAssertFalse(text.contains("localLLMModel.isEmpty ? GruxConfig.defaultLocalModel"),
                           "\(file) still resolves the background model on its own")
        }
    }

    /// Where the app adopts a model for somebody (first run, Connect a model,
    /// the speed check), it writes chat's field and the background field
    /// together, so the two cannot name different models.
    func test_everyAdoptionWritesBothFields() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Grux")
        var checked = 0
        for file in ["Onboarding/OnboardingView.swift", "Settings/ConnectModelSection.swift",
                     "LocalModelCookbook/LocalModelSpeedCheck.swift"] {
            let lines = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("config.offlineLLMModel = ") {
                let value = line.components(separatedBy: "config.offlineLLMModel = ")[1]
                    .trimmingCharacters(in: .whitespaces)
                let next = i + 1 < lines.count ? lines[i + 1] : ""
                XCTAssertTrue(next.contains("config.localLLMModel = \(value)"),
                              "\(file):\(i + 1) sets chat's model to \(value) and leaves the background one")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 4, "the adoption sites moved; count them again")
    }

    /// The first-run probe names the model chat is set to when the server
    /// holds it, not whichever tag the server lists first, however the server
    /// spells it. Since 3.3 the probe and the button both ask
    /// `ModelGate.modelToUse` (FirstRunNamesTheModelItUsesTests), so the rule
    /// is pinned there.
    func test_theFirstRunProbeNamesChatsModel() throws {
        let installed = ["llama3.2:3b", "gruxai.com/grux/grux-local:4b"]
        XCTAssertEqual(ModelGate.modelToUse(configured: "grux-local:4b", installed: installed, headline: nil),
                       "gruxai.com/grux/grux-local:4b", "the probe names the first listed tag again")
        XCTAssertEqual(ModelGate.modelToUse(configured: "gruxai.com/grux/grux-local:4b", installed: installed,
                                            headline: "llama3.2:3b"),
                       "gruxai.com/grux/grux-local:4b", "chat's own model, not the headline")
        XCTAssertEqual(ModelGate.modelToUse(configured: "grux-local:4b",
                                            installed: ["gruxai.com/grux/grux-local:4b", "grux-local:4b"], headline: nil),
                       "grux-local:4b", "a spelling chat already uses is rewritten to another")
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Grux")
        let view = try String(contentsOf: sources.appendingPathComponent("Onboarding/OnboardingView.swift"),
                              encoding: .utf8)
        let probe = try XCTUnwrap(view.range(of: "private func probeForLocalModel()"))
        let rest = view[probe.upperBound...]
        let end = rest.range(of: "\n    private ")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertTrue(body.contains("ModelGate.modelToUse("), "the probe names a model by a rule of its own")
        XCTAssertTrue(body.contains("probe = .found(usable)"))
    }

    /// File naming uses chat's Grux Local rather than loading the size made
    /// for this Mac beside it.
    func test_namingUsesChatsGruxLocal() {
        let installed = ["llama3.2:3b", "gruxai.com/grux/grux-local:4b", "gruxai.com/grux/grux-local:9b"]
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 48, installed: installed,
                                                 fallback: "gruxai.com/grux/grux-local:4b"),
                       "gruxai.com/grux/grux-local:4b")
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 48, installed: installed, fallback: "grux-local:4b"),
                       "gruxai.com/grux/grux-local:4b", "chat's short name, the server's long one")
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 48, installed: installed, fallback: "llama3.2:3b"),
                       "gruxai.com/grux/grux-local:9b", "control: a chat model that is not Grux Local keeps the old order")
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 48, installed: ["gruxai.com/grux/grux-local:9b"],
                                                 fallback: "gruxai.com/grux/grux-local:4b"),
                       "gruxai.com/grux/grux-local:9b", "chat's Grux Local is not installed, so the old order")
    }

    /// Discovery adopts an installed Grux Local for an unchosen chat model
    /// when the headline is not installed, and never touches a choice.
    func test_discoveryAdoptsAnInstalledGruxLocal() {
        let big = mac(48, 36)
        let current = GruxConfig.defaultLocalModel
        func pick(_ installed: [String], chosen: Bool = false, current: String = current) -> String {
            Cookbook.installedDefault(for: big, installed: installed, userHasChosen: chosen,
                                      current: current, ollamaVersion: nil)
        }
        XCTAssertEqual(pick(["llama3.2:3b", "gruxai.com/grux/grux-local:4b"]), "gruxai.com/grux/grux-local:4b")
        XCTAssertEqual(pick(["llama3.2:3b", "grux-local:4b"]), "grux-local:4b", "as the server names it")
        XCTAssertEqual(pick(["gruxai.com/grux/grux-local:4b", "gruxai.com/grux/grux-local:9b"]),
                       "gruxai.com/grux/grux-local:9b", "the headline when it is here")
        XCTAssertEqual(pick(["gruxai.com/grux/grux-local:4b"], chosen: true, current: "qwen3.5:4b"),
                       "qwen3.5:4b", "a choice stands")
        XCTAssertEqual(pick(["llama3.2:3b"]), current, "nothing better installed")
        XCTAssertEqual(pick(["grux-local:4b"], chosen: Cookbook.userHasChosenModel("grux-local:4b"),
                            current: "grux-local:4b"), "grux-local:4b", "a second discovery changes nothing")
        XCTAssertEqual(Cookbook.installedDefault(for: mac(8, 5), installed: ["llama3.2:3b", "gruxai.com/grux/grux-local:2b",
                                                                           "gruxai.com/grux/grux-local:9b"],
                                                 userHasChosen: false, current: current, ollamaVersion: nil),
                       "gruxai.com/grux/grux-local:2b", "an 8 GB Mac takes the size made for it")
        XCTAssertEqual(Cookbook.installedDefault(for: mac(8, 5), installed: ["llama3.2:3b", "gruxai.com/grux/grux-local:9b"],
                                                 userHasChosen: false, current: current, ollamaVersion: nil),
                       current, "an 8 GB Mac never adopts a size it cannot run")
        XCTAssertEqual(Cookbook.headline(for: big, ollamaVersion: nil)?.id, "gruxai.com/grux/grux-local:9b",
                       "control: the headline this test assumes")
    }
}
