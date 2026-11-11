import XCTest
@testable import Grux

/// D108: Local Models put "CONTEXT 256K" beside "MEMORY ~4 GB" for Grux Local 4B.
/// The memory figure was measured at the window Grux runs a model at (16K on a
/// 16 GB Mac, `LocalTurn.contextTokens`), and 256K is the model's own maximum,
/// which a 16 GB Mac never runs; read side by side they promised a long context
/// in 4 GB. The chip now says the window Grux uses here. The line naming the
/// pick also repeated the raw pull tag that the pick's own card shows under TAG.
final class CookbookCardWordsTests: XCTestCase {

    func test_contextChip_isTheWindowGruxRunsHere_neverMoreThanTheModelHolds() {
        // Over, on and under this Mac's window.
        XCTAssertEqual(Cookbook.contextChip(modelTokens: 262_144, macTokens: 16_384), "16K")
        XCTAssertEqual(Cookbook.contextChip(modelTokens: 16_385, macTokens: 16_384), "16K")
        XCTAssertEqual(Cookbook.contextChip(modelTokens: 16_384, macTokens: 16_384), "16K")
        XCTAssertEqual(Cookbook.contextChip(modelTokens: 8_192, macTokens: 16_384), "8K")
        XCTAssertEqual(Cookbook.contextChip(modelTokens: 131_072, macTokens: 8_192), "8K")
        XCTAssertEqual(Cookbook.contextChip(modelTokens: 131_072, macTokens: 32_768), "32K")
    }

    func test_everyCatalogCard_onEveryTier_showsAWindowGruxCanRun() {
        for ram in [8.0, 16, 32, 64, 128] {
            let mac = LocalTurn.contextTokens(memoryGB: ram)
            for model in Cookbook.catalog {
                let chip = Cookbook.contextChip(modelTokens: model.contextTokens, macTokens: mac)
                XCTAssertEqual(chip, "\(min(model.contextTokens, mac) / 1024)K", "\(model.id) at \(ram) GB")
            }
        }
    }

    /// D157 item 8 (sense pass 19): Qwen 3.5 4B's card said "a 256K window" in its
    /// one-line pitch beside the CONTEXT 16K chip on a 16 GB Mac. The chip is the only
    /// place a window figure belongs (it says the window Grux runs here), so no pitch
    /// names a window, a context length or a token count.
    func test_noPitch_namesAWindow_theContextChipSaysIt() throws {
        let window = try NSRegularExpression(pattern: #"\b\d+\s?[KkMm]\b|window|context|tokens"#,
                                              options: [.caseInsensitive])
        for model in Cookbook.catalog {
            let s = model.strengths
            let hit = window.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            XCTAssertNil(hit, "\(model.id): \(s)")
        }
        // The guard itself, on the line that was shipped and one under and over.
        for line in ["Small generalist with tool calling and a 256K window", "a 128k context", "holds 1M tokens"] {
            XCTAssertNotNil(window.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
        for line in ["Small generalist with tool calling", "Reads screenshots and images, small enough for any Mac", "96 GB and up only"] {
            XCTAssertNil(window.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
    }

    func test_recommendedLine_namesTheModel_notItsPullTag() throws {
        let local = try XCTUnwrap(Cookbook.catalog.first { $0.id == "gruxai.com/grux/grux-local:4b" })
        XCTAssertEqual(Cookbook.recommendedLine(local), "Recommended: Grux Local 4B")
        for model in Cookbook.catalog {
            XCTAssertFalse(Cookbook.recommendedLine(model).contains(model.id), model.id)
        }
    }

    /// D115 (sense pass 10): the top of Local Models named only the pick ("Recommended:
    /// Grux Local 4B", with PULL) while Grux ran Qwen 3.5 4B, whose Selected card sat out of
    /// view further down, so the pane read as if nothing was in use. The hardware card now
    /// names the local model set for Grux whenever that is not the pick. It names the
    /// setting, not what chat runs on: with a Claude key or a custom endpoint chat goes
    /// elsewhere, and "Grux uses" was false there (wave 30).
    func test_inUseLine_namesTheLocalModelSet_whenItIsNotThePick() throws {
        let pick = try XCTUnwrap(Cookbook.catalog.first { $0.id == "gruxai.com/grux/grux-local:4b" })
        XCTAssertEqual(Cookbook.inUseLine(configured: "qwen3.5:4b", installed: true, headline: pick),
                       "Your local model: Qwen 3.5 4B")
        // A tag the catalog does not know reads as itself.
        XCTAssertEqual(Cookbook.inUseLine(configured: "mistral:7b", installed: true, headline: pick),
                       "Your local model: mistral:7b")
        // No pick at all (nothing fits under pressure): still says what is in use.
        XCTAssertEqual(Cookbook.inUseLine(configured: "qwen3.5:4b", installed: true, headline: nil),
                       "Your local model: Qwen 3.5 4B")
        // True on every chat route: no claim that anything runs on it.
        let line = try XCTUnwrap(Cookbook.inUseLine(configured: "qwen3.5:4b", installed: true, headline: pick))
        for claim in ["uses", "runs", "chat", "Chat", "answers"] {
            XCTAssertFalse(line.contains(claim), "\(line) claims \(claim)")
        }
    }

    func test_inUseLine_saysNothing_whenItWouldRepeatThePickOrIsNotTrue() throws {
        let pick = try XCTUnwrap(Cookbook.catalog.first { $0.id == "gruxai.com/grux/grux-local:4b" })
        // The pick itself: its own card says Selected.
        XCTAssertNil(Cookbook.inUseLine(configured: pick.id, installed: true, headline: pick))
        XCTAssertNil(Cookbook.inUseLine(configured: pick.id.uppercased(), installed: true, headline: pick))
        // Not on this Mac: Grux cannot be using it.
        XCTAssertNil(Cookbook.inUseLine(configured: "qwen3.5:4b", installed: false, headline: pick))
        // Nothing configured.
        XCTAssertNil(Cookbook.inUseLine(configured: "", installed: true, headline: pick))
        XCTAssertNil(Cookbook.inUseLine(configured: "  ", installed: true, headline: pick))
    }

    /// The pane draws these words, not a copy of them.
    func test_thePaneDrawsTheseWords() throws {
        let src = try String(contentsOfFile: #filePath.components(separatedBy: "/Tests/")[0]
            + "/Sources/Grux/LocalModelCookbook/CookbookView.swift", encoding: .utf8)
        XCTAssertTrue(src.contains("Cookbook.recommendedLine(pick)"))
        XCTAssertTrue(src.contains("Cookbook.contextChip(modelTokens: model.contextTokens, macTokens: LocalTurn.contextTokens)"))
        XCTAssertFalse(src.contains("Recommended: \\("))
        XCTAssertTrue(src.contains("Cookbook.inUseLine(configured: state.config.offlineLLMModel,"))
        XCTAssertFalse(src.contains("Your local model: \\("))
    }
}
