import XCTest
@testable import Grux

/// D187 item 5 (sense pass 24, `settings-ambient-page1.png`): Ambient's nightly
/// passes said the transcript goes to "the cloud model you configured" on a
/// Mac with none, and an empty bordered row sat under "Grux will ask before
/// the first recording."
@MainActor
final class NightlyPassCaptionTests: XCTestCase {

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

    /// Every route, brain and key: the caption names where the transcript goes
    /// and never a cloud model the route does not use.
    func test_theCaptionNamesWhereTheTranscriptReallyGoes() {
        for brainOn in [true, false] {
            for claudeKey in [true, false] {
                for route in routes {
                    let text = NightlyPassCaption.text(brainOn: brainOn, route: route, claudeKey: claudeKey)
                    let label = "brain \(brainOn) key \(claudeKey) route \(route): \(text)"
                    XCTAssertTrue(text.hasPrefix("Two jobs can read the day's ambient transcript overnight."), label)
                    XCTAssertFalse(text.contains("cloud model you configured"), label)
                    XCTAssertEqual(text.contains("your proxy endpoint below"), brainOn, label)
                    switch route {
                    case .thisMac(let model):
                        XCTAssertTrue(text.contains(model) && text.contains("this Mac"), label)
                    case .otherMachine(let model, let host):
                        XCTAssertTrue(text.contains(model) && text.contains(host), label)
                    case .anthropic:
                        XCTAssertTrue(text.contains("Claude") && text.contains("leaves your Mac"), label)
                    case .custom(let name, let host):
                        XCTAssertTrue(text.contains(name) && text.contains(host), label)
                    case .none:
                        XCTAssertTrue(text.contains("no model"), label)
                    }
                    // Person notes retry on Claude only after the proxy
                    // answered unreadably, and only with a Claude key.
                    XCTAssertEqual(text.contains("retry on Claude"), brainOn && claudeKey, label)
                }
            }
        }
    }

    /// The pane reads the caption from the rule, with the route the jobs use.
    func test_theAmbientPaneReadsTheRule() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        guard let at = settings.range(of: "Section(\"Nightly passes over the transcript\")") else {
            return XCTFail("the nightly passes section moved; point this test at it")
        }
        let around = String(settings[at.lowerBound...].prefix(600))
        XCTAssertTrue(around.contains("NightlyPassCaption.text("), "the caption is a fixed string again")
        XCTAssertTrue(around.contains("PrivacyAsk.routes("), "the caption does not read the route the jobs use")
        XCTAssertFalse(settings.contains("otherwise the cloud model you configured"))
    }

    /// A `Divider()` placed as a row of a grouped Form draws an empty bordered
    /// row. Every Form in Sources separates its rows itself.
    func test_noFormDrawsADividerAsAnEmptyRow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("Form {") else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.trimmingCharacters(in: .whitespaces) == "Divider()" {
                found.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(found, [], "a Divider in a file with a Form; wrap it in a stack or drop it")
    }
}
