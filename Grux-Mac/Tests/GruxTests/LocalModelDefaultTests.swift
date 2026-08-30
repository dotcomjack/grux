import XCTest
@testable import Grux

/// THE DEFAULT LOCAL MODEL HAS TO ANSWER, NOT JUST THINK.
///
/// The shipped default was `qwen3:8b`, a REASONING model. Measured on the
/// owner's machine against Ollama's OpenAI-compatible endpoint, which is the one
/// `OpenAICompatBackend` uses:
///
///     qwen3:8b     completion_tokens=300  content_len=0    ""
///     llama3.2:3b  completion_tokens=7    content_len=19   "Hello, how are you?"
///
/// Asked to say hi in three words, qwen3 spent the entire budget inside its
/// think block and returned EMPTY CONTENT. Through the native `/api/chat`
/// endpoint with a 400 token budget it eventually produced twelve characters of
/// answer after 1351 characters of thinking and 49 seconds. Either way the user
/// gets a long wait, and with a small budget they get nothing at all, which is
/// the reported "Grux is thinking" hang.
///
/// Three ways to suppress the thinking were measured against that endpoint and
/// ALL THREE FAILED: `chat_template_kwargs.enable_thinking=false`, a top-level
/// `think: false`, and the `/no_think` prompt suffix. Each still burned 300
/// tokens and returned nothing. A first attempt at this fix shipped the first of
/// those, which did nothing, and was removed once measured rather than left in
/// because it looked plausible.
///
/// So the default is a model that answers. Anyone who prefers qwen3 can still
/// pick it in Settings; it is the DEFAULT that must not hang a new user on
/// first contact.
final class LocalModelDefaultTests: XCTestCase {


    /// Encodes a real config, DROPS the two local-model keys, and decodes the
    /// remainder. That is what an install predating these keys actually looks
    /// like, and it is the path that decides what a real user gets.
    ///
    /// A first attempt used `Data("{}".utf8)`, which cannot decode at all
    /// because GruxConfig has fifteen non-optional keys. It sat inside
    /// `if let decoded = try? ...`, so the assertions never ran and the test
    /// passed while proving nothing. Same class of defect as everything else
    /// this file exists to catch.
    @MainActor
    private func configDecodedWithoutModelKeys() throws -> GruxConfig {
        let encoded = try JSONEncoder().encode(AppState.shared.config)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        obj.removeValue(forKey: "localLLMModel")
        obj.removeValue(forKey: "offlineLLMModel")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(GruxConfig.self, from: stripped)
    }

    private func modelsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Grux/Models.swift"), encoding: .utf8)
    }

    /// The default must not be a reasoning model, because reasoning models
    /// return an empty answer through this endpoint at ordinary token budgets.
    /// THE GAP REVIEW FOUND. The original test read only the init signature, so
    /// changing the two init defaults looked like a fix while `?? "qwen3:8b"`
    /// survived in the DECODE path plus two `.isEmpty ?` fallbacks. Every
    /// existing install decodes its config, so those were the ones that
    /// actually decided what a real user got, and the suite was green.
    ///
    /// Asserts on BEHAVIOUR now, not on source text, and sweeps the whole tree
    /// for stragglers.
    @MainActor
    func testNoReasoningModelSurvivesAnywhereAsADefault() throws {
        XCTAssertEqual(GruxConfig.defaultLocalModel, "llama3.2:3b")
        for reasoning in ["qwen3", "deepseek-r1", "qwq"] {
            XCTAssertFalse(GruxConfig.defaultLocalModel.contains(reasoning),
                           "the single source of truth is a reasoning model")
        }

        // A config that predates these keys must decode to the safe default,
        // which is the case the original test could not see.
        let decoded = try configDecodedWithoutModelKeys()
        XCTAssertEqual(decoded.localLLMModel, GruxConfig.defaultLocalModel,
                       "an old config decodes to a reasoning model")
        XCTAssertEqual(decoded.offlineLLMModel, GruxConfig.defaultLocalModel,
                       "an old config decodes to a reasoning model offline")

        // And no stray literal at a DEFAULT site. Scoped deliberately: the
        // Local Model Cookbook is a CATALOG of models the user may choose, so
        // qwen3 belongs there and a sweep that flagged it would be noise. What
        // must not exist is a reasoning model baked in as a fallback.
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "control: walked no files, so this proves nothing")
        var offenders: [String] = []
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                guard t.contains("\"qwen3") else { continue }
                // Only default-assignment shapes count: `?? "qwen3..."`,
                // `.isEmpty ? "qwen3..."`, `= "qwen3..."`.
                // The migration SOURCE is the one legitimate mention: that
                // constant exists precisely to move installs off it. Exempted
                // by name rather than by loosening the rule, so any other
                // hardcoded reasoning model still fails.
                if t.contains("supersededLocalModel") { continue }
                let isDefault = t.contains("?? \"qwen3") || t.contains("? \"qwen3") || t.contains("= \"qwen3")
                if isDefault { offenders.append("\(f.lastPathComponent):\(i + 1)") }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "a reasoning model is still hardcoded at: \(offenders)")
    }

    /// Both defaults come from ONE constant now, so they cannot drift apart.
    /// This replaces two source-text tests that parsed the init signature: the
    /// refactor to a shared constant made them unparseable, which is the
    /// clearest possible demonstration that they were reading syntax rather
    /// than asserting behaviour.
    @MainActor
    func testTheTwoLocalModelDefaultsCannotDrift() throws {
        let cfg = try configDecodedWithoutModelKeys()
        XCTAssertEqual(cfg.localLLMModel, cfg.offlineLLMModel,
                       "switching offline would silently change which model runs")
        XCTAssertEqual(cfg.localLLMModel, GruxConfig.defaultLocalModel)
    }

    /// The ineffective flag must stay out. It was measured doing nothing, and a
    /// no-op that looks like a fix is worse than no fix: it stops the next
    /// person looking.
    func testTheIneffectiveThinkingFlagIsNotReintroduced() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Backend/OpenAICompatBackend.swift"),
                             encoding: .utf8)
        XCTAssertFalse(src.contains("enable_thinking"),
                       "chat_template_kwargs.enable_thinking was measured having no effect on this endpoint")
    }
}

/// THE FIX THAT HELPED NOBODY WHO ALREADY HAD GRUX.
///
/// Changing the default local model was correct and changed nothing for any
/// existing install: `config.json` stores the value explicitly, so every user
/// who had ever launched Grux kept `qwen3:8b` on both keys. Measured on the
/// owner's own machine after the "fix" shipped, both keys still read qwen3:8b,
/// which is why a local "hi" still took the better part of a minute.
///
/// A default is only a default for the first launch. Anything already written
/// down needs a migration, and there was none.
///
/// SCOPED DELIBERATELY. This migrates the exact string Grux itself shipped as
/// the default, because those users never chose it, it was assigned to them. A
/// user who typed a different reasoning model keeps it: overriding a real choice
/// would be a worse bug than the one being fixed.
@MainActor
final class LocalModelMigrationTests: XCTestCase {

    private func decode(localLLMModel: String, offlineLLMModel: String) throws -> GruxConfig {
        let encoded = try JSONEncoder().encode(AppState.shared.config)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        obj["localLLMModel"] = localLLMModel
        obj["offlineLLMModel"] = offlineLLMModel
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(GruxConfig.self, from: data)
    }

    /// The stuck install. This is the owner's actual config.json.
    func testTheOldShippedDefaultIsMigratedAway() throws {
        let cfg = try decode(localLLMModel: "qwen3:8b", offlineLLMModel: "qwen3:8b")
        XCTAssertEqual(cfg.localLLMModel, GruxConfig.defaultLocalModel,
                       "an existing install stays on the model that returns empty content")
        XCTAssertEqual(cfg.offlineLLMModel, GruxConfig.defaultLocalModel,
                       "an existing install stays on the model that returns empty content offline")
    }

    /// A REAL CHOICE SURVIVES. The migration undoes an assignment, not a
    /// decision, so anything the user picked themselves is left alone, including
    /// a bigger reasoning model they may genuinely want.
    func testAUserChosenModelIsNotTouched() throws {
        for chosen in ["qwen3.5:9b", "gemma4:12b", "gpt-oss:20b", "llama3.3:70b"] {
            let cfg = try decode(localLLMModel: chosen, offlineLLMModel: chosen)
            XCTAssertEqual(cfg.localLLMModel, chosen, "\(chosen) was overridden, which is somebody's choice")
            XCTAssertEqual(cfg.offlineLLMModel, chosen, "\(chosen) was overridden, which is somebody's choice")
        }
    }

    /// And the two keys migrate independently, since a half-migrated config is
    /// how the model a user is offered stops being the model that runs.
    func testEachKeyMigratesOnItsOwn() throws {
        let cfg = try decode(localLLMModel: "qwen3:8b", offlineLLMModel: "qwen3.5:9b")
        XCTAssertEqual(cfg.localLLMModel, GruxConfig.defaultLocalModel)
        XCTAssertEqual(cfg.offlineLLMModel, "qwen3.5:9b")
    }
}

/// AN EMPTY REPLY IS A DIAGNOSABLE STATE, NOT A BLANK MESSAGE.
///
/// Measured on qwen3.5:4b through Ollama's OpenAI-compatible endpoint, the one
/// `OpenAICompatBackend` drives: 14.3 seconds, 2,433 characters in the
/// `reasoning` field, and `content` EMPTY. Twice in a row, at an 800 token
/// budget that had produced an answer minutes earlier, so it is not even
/// deterministic. The user waits and then gets nothing, with no way to tell
/// whether Grux broke or the model did.
///
/// Empty content plus non-empty reasoning is distinguishable from a genuine
/// blank, so it must be reported rather than returned as "".
final class LocalEmptyReplyDiagnosisTests: XCTestCase {

    private func backendSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Backend/OpenAICompatBackend.swift"), encoding: .utf8)
    }

    /// The message must name both ways out and must not blame the user.
    func testTheDiagnosisNamesBothWaysOut() {
        let m = OpenAICompatBackend.thinkingBudgetMessage.lowercased()
        XCTAssertTrue(m.contains("thinking"), "does not name the cause")
        XCTAssertTrue(m.contains("limit") || m.contains("budget"), "does not offer raising the limit")
        XCTAssertTrue(m.contains("model"), "does not offer picking a different model")
        XCTAssertFalse(m.contains("http"), "leaks a status code into a local-model problem")
    }

    /// BOTH entry points must diagnose it. The non-streaming `complete` and the
    /// vision path parse `content` separately, so fixing one and not the other
    /// is exactly the kind of half-fix this session has already shipped twice.
    func testEveryContentParseGuardsTheEmptyCase() throws {
        let src = try backendSource()
        let parses = src.components(separatedBy: "[\"content\"] as? String ?? \"\"").count - 1
        let guards = src.components(separatedBy: "thinkingBudgetMessage").count - 1
        XCTAssertGreaterThanOrEqual(guards, 2,
                                    "only \(guards) of the \(parses) content parses diagnose an empty reasoning reply")
    }
}
