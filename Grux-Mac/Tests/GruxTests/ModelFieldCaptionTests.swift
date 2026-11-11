import XCTest
@testable import Grux

private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// D197 item 1 (sense pass 27, `settings-models-page1.png`): Settings, Models showed
/// `claude-haiku-4-5-20251001` and `gruxai.com/grux/grux-local:2b` with nothing a
/// person reads as a name, under "Default: claude-haiku-4-5-20251001. Use
/// sonnet/opus for higher quality (more cost)." on a Mac with no Claude key. Each
/// field now says which model it holds, and the Claude one says when it is used.
final class ModelFieldCaptionTests: XCTestCase {

    func testAClaudeIDReadsAsItsName() {
        XCTAssertEqual(ModelFieldCaption.claudeName("claude-haiku-4-5-20251001"), "Claude Haiku 4.5")
        XCTAssertEqual(ModelFieldCaption.claudeName("claude-sonnet-5-5"), "Claude Sonnet 5.5")
        XCTAssertEqual(ModelFieldCaption.claudeName("claude-opus-4-8"), "Claude Opus 4.8")
        XCTAssertEqual(ModelFieldCaption.claudeName(" claude-opus-5 "), "Claude Opus 5")
        XCTAssertEqual(ModelFieldCaption.claudeName("Claude-Sonnet-4-6"), "Claude Sonnet 4.6")
        // Not shaped like a Claude model ID: no name is made up for it.
        for odd in ["", "claude", "claude-", "gpt-4o", "claude-3-5-sonnet-20241022", "claude-haiku",
                    "claude-haiku-four", "anthropic/claude-haiku-4-5", "claude-haiku-4-5-2025"] {
            XCTAssertNil(ModelFieldCaption.claudeName(odd), odd)
        }
    }

    func testTheDefaultIsNamedWithWhatTheOthersCost() {
        let line = ModelFieldCaption.claude(modelID: ModelFieldCaption.defaultClaude, hasKey: true)
        XCTAssertEqual(line, "This is Claude Haiku 4.5, the default: quick and low cost. A Sonnet or Opus model answers better and costs more.")
        XCTAssertFalse(line.contains("claude-haiku-4-5-20251001"), line)
        XCTAssertFalse(line.contains("sonnet/opus"), line)
    }

    func testAnotherModelIsNamedBesideTheDefault() {
        XCTAssertEqual(ModelFieldCaption.claude(modelID: "claude-sonnet-5-5", hasKey: true),
                       "This is Claude Sonnet 5.5. The default, Claude Haiku 4.5 (claude-haiku-4-5-20251001), is quicker and costs less.")
        XCTAssertEqual(ModelFieldCaption.claude(modelID: "my-model", hasKey: true),
                       "Grux sends this model ID to Anthropic as typed. The default is Claude Haiku 4.5 (claude-haiku-4-5-20251001).")
        XCTAssertEqual(ModelFieldCaption.claude(modelID: "  ", hasKey: true),
                       "Type a model ID, such as claude-haiku-4-5-20251001 (Claude Haiku 4.5, the default).")
    }

    /// Without a key the field is a setting for later, and says so; with one it
    /// does not repeat it. Whitespace is not a key.
    func testNoKeySaysTheModelWaitsForOne() {
        let wait = "Grux uses it only once an API key is in the field above."
        for id in [ModelFieldCaption.defaultClaude, "claude-sonnet-5-5", "my-model", ""] {
            XCTAssertTrue(ModelFieldCaption.claude(modelID: id, hasKey: false).hasSuffix(" " + wait), id)
            XCTAssertFalse(ModelFieldCaption.claude(modelID: id, hasKey: true).contains(wait), id)
        }
        XCTAssertEqual(ModelFieldCaption.hasKey("   \n"), false)
        XCTAssertEqual(ModelFieldCaption.hasKey(""), false)
        XCTAssertEqual(ModelFieldCaption.hasKey(" sk-ant-x "), true)
    }

    /// Wave 68 round 1: the alias of the default (and any other date on it) is
    /// the default, not a model the default is "quicker" than; an ID with spaces
    /// or capitals is sent as typed (`c.model = model`), so it gets no name.
    func testTheDefaultsAliasIsTheDefaultAndAMistypedIDIsNotNamed() {
        let defaultLine = "This is Claude Haiku 4.5, the default: quick and low cost. A Sonnet or Opus model answers better and costs more."
        for alias in ["claude-haiku-4-5", "claude-haiku-4-5-20260101"] {
            XCTAssertEqual(ModelFieldCaption.claude(modelID: alias, hasKey: true), defaultLine, alias)
        }
        for typed in [" claude-sonnet-4-6 ", "Claude-Sonnet-4-6", "claude-haiku-4-5-20251001\n"] {
            let line = ModelFieldCaption.claude(modelID: typed, hasKey: true)
            XCTAssertFalse(line.hasPrefix("This is"), "\(typed): \(line)")
            XCTAssertTrue(line.contains("as typed"), "\(typed): \(line)")
        }
    }

    /// Wave 68 round 1: clearing the field and pressing Save keeps the key saved
    /// earlier (`save()` writes only a non-empty key), and Grux keeps using it, so
    /// "only once an API key is in the field" must not show then.
    func testAKeySavedEarlierCountsAsAKey() {
        XCTAssertTrue(ModelFieldCaption.keyInUse(field: "", saved: true))
        XCTAssertTrue(ModelFieldCaption.keyInUse(field: " sk-ant-x ", saved: false))
        XCTAssertFalse(ModelFieldCaption.keyInUse(field: "  ", saved: false))
        XCTAssertFalse(ModelFieldCaption.keyInUse(field: "", saved: false))
    }

    func testTheLocalFieldNamesACatalogModelAndNothingElse() {
        XCTAssertEqual(ModelFieldCaption.local(modelID: "gruxai.com/grux/grux-local:2b"), "This is Grux Local 2B.")
        XCTAssertEqual(ModelFieldCaption.local(modelID: " gruxai.com/grux/grux-local:4b "), "This is Grux Local 4B.")
        XCTAssertEqual(ModelFieldCaption.local(modelID: "llama3.2:3b"), "This is \(Cookbook.personName(for: "llama3.2:3b")).")
        // A tag the catalog does not know is already its own name: nothing to add.
        XCTAssertNil(ModelFieldCaption.local(modelID: "my-own-model:7b"))
        XCTAssertNil(ModelFieldCaption.local(modelID: ""))
        XCTAssertNil(ModelFieldCaption.local(modelID: "   "))
    }

    /// The pane draws these lines, and the old one is gone.
    func testSettingsDrawsTheCaptions() throws {
        let s = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertFalse(s.contains("Use sonnet/opus for higher quality"), "the old raw default line is still on screen")
        XCTAssertTrue(s.contains("Text(ModelFieldCaption.claude(modelID: model, hasKey: ModelFieldCaption.keyInUse(field: apiKey, saved: KeychainStore.exists(.anthropicApiKey))))"))
        XCTAssertTrue(s.contains("if let named = ModelFieldCaption.local(modelID: state.config.offlineLLMModel)"))
        XCTAssertEqual(ModelFieldCaption.defaultClaude, GruxConfig.default.model)
    }
}
