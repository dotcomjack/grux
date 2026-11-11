import XCTest
@testable import Grux

/// D200 item 15 (sense pass 28, seen iteration 144): Settings, Ambient showed
/// "Local Qwen ambient brain" with a developer's companion port, "Ollama-backed
/// Qwen3" and "Claude is the fallback", beside Grux Local everywhere else. The
/// switch only reaches a proxy that answers Grux's own `/api/llm/local` shape
/// (`LocalLLMClient`), and with it off, or when that proxy does not answer,
/// the jobs take chat's route (`AmbientLLM.completeTagged`), never Claude by name.
@MainActor
final class AmbientProxyCopyTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private let routes: [PrivacyAsk.Route] = [
        .thisMac(model: "Grux Local 2B"),
        .otherMachine(model: "qwen3.5:4b", host: "studio.local"),
        .anthropic,
        .custom(name: "OpenRouter", host: "openrouter.ai"),
        .none(step: "Connect a model"),
    ]

    /// Every route: the caption names where the jobs already go, what the
    /// switch is for, and what happens when the proxy does not answer.
    func test_theCaptionSaysWhereBackgroundJobsReallyGo() {
        for route in routes {
            let text = AmbientProxyCopy.caption(route: route, proxyOn: false)
            let label = "route \(route): \(text)"
            XCTAssertFalse(text.contains("Qwen"), label)
            XCTAssertFalse(text.contains("Claude is the fallback"), label)
            XCTAssertFalse(text.contains("LAN"), label)
            XCTAssertTrue(text.contains("/api/llm/local"), label)
            XCTAssertTrue(text.contains("Ollama's own address does not work here"), label)
            XCTAssertTrue(text.contains("does not answer"), label)
            switch route {
            case .thisMac(let model):
                XCTAssertTrue(text.contains(model) && text.contains("this Mac") && text.contains("leave this off"), label)
                XCTAssertTrue(text.contains("not running"), label)
            case .otherMachine(let model, let host):
                XCTAssertTrue(text.contains(model) && text.contains(host), label)
                XCTAssertTrue(text.contains("not running"), label)
            case .anthropic:
                XCTAssertTrue(text.contains("Claude with your Anthropic key"), label)
            case .custom(let name, let host):
                XCTAssertTrue(text.contains(name) && text.contains(host), label)
            case .none:
                XCTAssertTrue(text.contains("no model"), label)
            }
        }
    }

    func test_theLabelsNameAProxyNotAModel() {
        for line in [AmbientProxyCopy.title, AmbientProxyCopy.toggle] {
            XCTAssertFalse(line.contains("Qwen"), line)
            XCTAssertTrue(line.contains("proxy"), line)
        }
        XCTAssertFalse(AmbientProxyCopy.endpointPrompt.contains("3849"), "the developer's companion port is not an example")
        XCTAssertTrue(AmbientProxyCopy.endpointPrompt.hasSuffix("/api/llm/local"))
    }

    /// The pane, its search entry and the nightly caption read the one copy.
    func test_thePaneAndSearchReadTheCopy() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("Section(AmbientProxyCopy.title)"))
        XCTAssertTrue(settings.contains("Toggle(AmbientProxyCopy.toggle"))
        XCTAssertTrue(settings.contains("AmbientProxyCopy.caption(route:"))
        XCTAssertFalse(settings.contains("Local Qwen"))
        XCTAssertFalse(settings.contains("Claude is the fallback"))
        let entry = SettingsSearchRegistry.entries.first { $0.id == "ambient.qwen" }
        XCTAssertEqual(entry?.title, AmbientProxyCopy.title)
        for route in routes {
            XCTAssertFalse(NightlyPassCaption.text(brainOn: true, route: route, claudeKey: true).contains("Qwen"))
        }
    }
}
