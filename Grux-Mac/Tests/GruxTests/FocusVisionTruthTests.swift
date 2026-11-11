import XCTest
@testable import Grux

/// D190 (sense pass 25): Focus log said "Focus log checks your screen with Claude,
/// and no local model can do that." while Local Models listed Qwen 3 VL 4B as
/// "Reads screenshots and images". Read side by side, one pane says no local model
/// can read a screen and the other offers one for exactly that.
///
/// What the code does: Focus log's judgement (`FocusWatcher.judgeVision`) and the
/// read-my-screen tool (`VisionTool`) are pinned to Anthropic, so no local model
/// ever sees the screen. A picture attached in Chat does go to a local model
/// (`ChatService.modelFacingMessages` carries the image block, and
/// `OpenAICompatBackend.ollamaMessages` sends it as `images`). So the truth is that
/// Grux chooses Claude for the screen, and a vision model reads pictures in Chat.
final class FocusVisionTruthTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(contentsOfFile: #filePath.components(separatedBy: "/Tests/")[0] + "/Sources/Grux/" + path,
                   encoding: .utf8)
    }

    private var readsPictures: [CookbookModel] {
        Cookbook.catalog.filter {
            $0.strengths.range(of: #"image|screenshot|picture|photo|vision"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    func test_focusLine_saysGruxUsesClaude_neverThatNoLocalModelCanRead() {
        XCTAssertFalse(readsPictures.isEmpty, "the catalog still offers a model that reads pictures")
        let line = CapabilitySetupCard.line(for: .keyAnthropic, featureKey: "focus")
        XCTAssertTrue(line.contains("Focus log") && line.contains("Claude"), line)
        XCTAssertNil(line.range(of: #"no local model can|local models? cannot|local models? can't"#,
                                options: [.regularExpression, .caseInsensitive]),
                     "Local Models offers a model that reads pictures; the line denies one exists: \(line)")
        XCTAssertTrue(line.localizedCaseInsensitiveContains("local model"),
                      "the line never says the screen does not go to a local model: \(line)")
    }

    /// "Vision" on a card read as reading the screen (Mistral Small 3.2, Qwen 3.8,
    /// Gemma 4 26B said it too), so every picture claim names Chat.
    func test_aCardThatReadsPictures_saysWhereGruxUsesIt() {
        for model in readsPictures {
            let s = model.strengths
            XCTAssertTrue(s.contains("in Chat"), "\(model.id) never says where Grux shows it a picture: \(s)")
            XCTAssertFalse(s.localizedCaseInsensitiveContains("screenshot"),
                           "\(model.id) offers to read screenshots, which Grux sends only to Claude: \(s)")
        }
    }

    /// The two lines above are true only while the code below holds. If screen
    /// reading is ever routed to a local model, or Chat stops sending pictures, this
    /// fails and points at both lines.
    func test_theCodeTheseLinesDescribe() throws {
        XCTAssertTrue(try source("FocusWatcher.swift").contains(#"resolvedRouting(provider: "anthropic","#))
        XCTAssertTrue(try source("VisionTool.swift").contains(#"provider: "anthropic", modelOverride:"#))
        XCTAssertTrue(try source("ChatService.swift").contains(#""type": "image","#))
        XCTAssertTrue(try source("Backend/OpenAICompatBackend.swift").contains(#"out["images"] = images"#))
    }
}
