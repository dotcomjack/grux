import XCTest
@testable import Grux

// Unit tests for PresetStore + PresetApplication. The store takes an explicit
// fileURL, so every test owns a throwaway instance against a temp file and
// never touches the real ~/Library/Application Support/Grux/presets.json.
@MainActor
final class PresetStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-preset-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        super.tearDown()
    }

    // MARK: - Store round-trip

    func testSeedsOnFirstLaunch() {
        let store = PresetStore(fileURL: tempURL)
        XCTAssertFalse(store.presets.isEmpty, "fresh store should seed starter presets")
        XCTAssertTrue(store.presets.contains { $0.kind == .chat }, "seed includes a chat preset")
        XCTAssertNil(store.activeChatPresetId, "no preset is active out of the box")
    }

    func testCreateSaveReloadRoundTrip() {
        let store = PresetStore(fileURL: tempURL)
        guard let created = store.create(
            name: "Writing mode",
            kind: .chat,
            systemPrompt: "Long-form prose, no bullets.",
            modelId: "claude-opus-4-7",
            enabledToolGroups: [PresetToolGroup.memory.rawValue, PresetToolGroup.web.rawValue],
            notes: "for drafts"
        ) else { return XCTFail("create returned nil") }
        store.setActiveChat(id: created.id)
        store.saveNow()

        let reloaded = PresetStore(fileURL: tempURL)
        guard let back = reloaded.preset(id: created.id) else {
            return XCTFail("preset lost across reload")
        }
        XCTAssertEqual(back.name, "Writing mode")
        XCTAssertEqual(back.kind, .chat)
        XCTAssertEqual(back.systemPrompt, "Long-form prose, no bullets.")
        XCTAssertEqual(back.modelId, "claude-opus-4-7")
        XCTAssertEqual(back.enabledGroups, [.memory, .web])
        XCTAssertEqual(back.notes, "for drafts")
        XCTAssertEqual(reloaded.activeChatPresetId, created.id, "active pointer persists")
        XCTAssertEqual(reloaded.presets.count, store.presets.count, "no reseed on second launch")
    }

    func testEmptyNameRejected() {
        let store = PresetStore(fileURL: tempURL)
        XCTAssertNil(store.create(name: "   "))
    }

    func testDuplicateGetsUniqueName() {
        let store = PresetStore(fileURL: tempURL)
        guard let a = store.create(name: "Solo") else { return XCTFail() }
        guard let b = store.duplicate(id: a.id) else { return XCTFail() }
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.name, b.name, "duplicate must not collide on name")
        XCTAssertEqual(b.systemPrompt, a.systemPrompt)
        XCTAssertEqual(b.enabledToolGroups, a.enabledToolGroups)
        guard let c = store.duplicate(id: a.id) else { return XCTFail() }
        XCTAssertNotEqual(c.name, b.name, "second duplicate also unique")
    }

    func testDeleteClearsActivePointer() {
        let store = PresetStore(fileURL: tempURL)
        guard let p = store.create(name: "Throwaway", kind: .chat) else { return XCTFail() }
        store.setActiveChat(id: p.id)
        XCTAssertEqual(store.activeChatPresetId, p.id)
        XCTAssertNotNil(store.delete(id: p.id))
        XCTAssertNil(store.activeChatPresetId, "deleting the active preset clears the pointer")
        XCTAssertNil(store.preset(id: p.id))
    }

    func testApplyRejectsNonChatPreset() {
        let store = PresetStore(fileURL: tempURL)
        guard let cron = store.create(name: "Nightly", kind: .cron) else { return XCTFail() }
        store.setActiveChat(id: cron.id)
        XCTAssertNil(store.activeChatPresetId, "cron presets can't become the active chat preset")
        XCTAssertNil(store.activeChatApplication())
    }

    func testKindChangeAwayFromChatClearsActive() {
        let store = PresetStore(fileURL: tempURL)
        guard let p = store.create(name: "Flexible", kind: .chat) else { return XCTFail() }
        store.setActiveChat(id: p.id)
        _ = store.update(id: p.id, kind: .swarm)
        XCTAssertNil(store.activeChatPresetId)
    }

    func testNamedLookupExactThenSubstring() {
        let store = PresetStore(fileURL: tempURL)
        _ = store.create(name: "Research copilot v2")
        guard let exact = store.create(name: "Research") else { return XCTFail() }
        XCTAssertEqual(store.preset(named: "research")?.id, exact.id, "exact name wins over substring")
        XCTAssertNotNil(store.preset(named: "copilot"), "substring fallback works")
        XCTAssertNil(store.preset(named: "zzz-nope"))
    }

    // MARK: - PresetApplication

    func testApplicationFromBlankPresetIsNoOp() {
        let app = PresetApplication(preset: Preset(name: "Blank"))
        XCTAssertNil(app.systemPromptOverride)
        XCTAssertNil(app.modelIdOverride)
        XCTAssertNil(app.enabledGroups)
        XCTAssertNil(app.systemBlockText())
        XCTAssertEqual(app.resolvedModelId(fallback: "claude-haiku-4-5"), "claude-haiku-4-5")
        XCTAssertTrue(app.allows(toolName: "add_task"))
        XCTAssertTrue(app.allows(toolName: "shell_run"))
    }

    func testApplicationResolvesOverrides() {
        let preset = Preset(
            name: "Pinned",
            systemPrompt: "  Be terse.  ",
            modelId: " claude-opus-4-7 ",
            enabledToolGroups: [PresetToolGroup.tasks.rawValue]
        )
        let app = PresetApplication(preset: preset)
        XCTAssertEqual(app.systemPromptOverride, "Be terse.")
        XCTAssertEqual(app.resolvedModelId(fallback: "claude-haiku-4-5"), "claude-opus-4-7")
        let block = app.systemBlockText()
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("Pinned"), "block names the preset")
        XCTAssertTrue(block!.contains("Be terse."), "block carries the prompt text")
    }

    func testApplicationToolFiltering() {
        let preset = Preset(
            name: "Tasks only",
            enabledToolGroups: [PresetToolGroup.tasks.rawValue]
        )
        let app = PresetApplication(preset: preset)
        // Tasks group survives.
        XCTAssertTrue(app.allows(toolName: "add_task"))
        XCTAssertTrue(app.allows(toolName: "list_proposed_actions"))
        // Other known groups are filtered.
        XCTAssertFalse(app.allows(toolName: "shell_run"))
        XCTAssertFalse(app.allows(toolName: "play_music_track"))
        XCTAssertFalse(app.allows(toolName: "compose_email"))
        XCTAssertFalse(app.allows(toolName: "agent_swarm_start"))
        // Core plumbing (no group owner) always passes.
        XCTAssertTrue(app.allows(toolName: "set_mode"))
        XCTAssertTrue(app.allows(toolName: "grux_orb_hint"))
        XCTAssertTrue(app.allows(toolName: "some_future_tool"))
    }

    func testToolGroupResolution() {
        XCTAssertEqual(PresetToolGroup.group(forToolName: "add_task"), .tasks)
        XCTAssertEqual(PresetToolGroup.group(forToolName: "shell_run_confirmed"), .shell)
        XCTAssertEqual(PresetToolGroup.group(forToolName: "agent_status"), .agents)
        XCTAssertEqual(PresetToolGroup.group(forToolName: "ios_scaffold"), .agents)
        XCTAssertEqual(PresetToolGroup.group(forToolName: "documents_list"), .documents)
        XCTAssertEqual(PresetToolGroup.group(forToolName: "fs_read"), .files)
        XCTAssertEqual(PresetToolGroup.group(forToolName: "search_web"), .web)
        XCTAssertEqual(PresetToolGroup.group(forToolName: "capture_memory"), .memory)
        XCTAssertNil(PresetToolGroup.group(forToolName: "set_mode"), "core tools belong to no group")
    }

    func testUnknownGroupRawValuesAreDropped() {
        let preset = Preset(
            name: "Old file",
            enabledToolGroups: ["tasks", "renamed-away-group"]
        )
        XCTAssertEqual(preset.enabledGroups, [.tasks], "unknown raw values decode away silently")
    }

    // MARK: - Config-state overrides (mode + voice)

    // Snapshot + restore AppState.shared.config around each config test so the
    // shared singleton is never left mutated for later tests.
    private func withConfigSnapshot(_ body: () -> Void) {
        let saved = AppState.shared.config
        defer { AppState.shared.config = saved }
        body()
    }

    func testActivatingPresetAppliesConfigOverridesAndCapturesBaseline() {
        withConfigSnapshot {
            // Known organic config to diff against.
            AppState.shared.config.currentMode = .normal
            AppState.shared.config.elevenLabsVoiceId = "organic-voice"
            AppState.shared.config.voicePlaybackRate = 1.0
            AppState.shared.config.useElevenLabs = false

            let store = PresetStore(fileURL: tempURL)
            guard let p = store.create(
                name: "Focus voice",
                kind: .chat,
                mode: .sheesh,
                voiceId: "preset-voice",
                voicePlaybackRate: 1.5,
                useElevenLabs: true
            ) else { return XCTFail("create returned nil") }

            store.setActiveChat(id: p.id)

            // Overrides landed on config.
            XCTAssertEqual(AppState.shared.config.currentMode, .sheesh)
            XCTAssertEqual(AppState.shared.config.elevenLabsVoiceId, "preset-voice")
            XCTAssertEqual(AppState.shared.config.voicePlaybackRate, 1.5)
            XCTAssertTrue(AppState.shared.config.useElevenLabs)

            // Baseline was captured and persisted (visible on reload).
            store.saveNow()
            let payload = Persistence.load(PresetFilePayload.self, from: tempURL, fallback: PresetFilePayload())
            XCTAssertNotNil(payload.configBaseline, "baseline persisted")
            XCTAssertEqual(payload.configBaseline?.currentMode, .normal)
            XCTAssertEqual(payload.configBaseline?.elevenLabsVoiceId, "organic-voice")
            XCTAssertEqual(payload.configBaseline?.voicePlaybackRate, 1.0)
            XCTAssertEqual(payload.configBaseline?.useElevenLabs, false)

            // Clearing restores the original config and drops the baseline.
            store.setActiveChat(id: nil)
            XCTAssertEqual(AppState.shared.config.currentMode, .normal)
            XCTAssertEqual(AppState.shared.config.elevenLabsVoiceId, "organic-voice")
            XCTAssertEqual(AppState.shared.config.voicePlaybackRate, 1.0)
            XCTAssertFalse(AppState.shared.config.useElevenLabs)

            store.saveNow()
            let after = Persistence.load(PresetFilePayload.self, from: tempURL, fallback: PresetFilePayload())
            XCTAssertNil(after.configBaseline, "baseline cleared after restore")
        }
    }

    func testSwitchingPresetsRestoresThenReappliesNoCompounding() {
        withConfigSnapshot {
            AppState.shared.config.currentMode = .normal
            AppState.shared.config.voicePlaybackRate = 1.0

            let store = PresetStore(fileURL: tempURL)
            guard let a = store.create(name: "A", kind: .chat, mode: .grind, voicePlaybackRate: 1.25) else {
                return XCTFail("create A nil")
            }
            guard let b = store.create(name: "B", kind: .chat, mode: .sheesh, voicePlaybackRate: 1.75) else {
                return XCTFail("create B nil")
            }

            store.setActiveChat(id: a.id)
            XCTAssertEqual(AppState.shared.config.currentMode, .grind)
            XCTAssertEqual(AppState.shared.config.voicePlaybackRate, 1.25)

            // Switch directly A -> B: B's values, not compounded onto A's.
            store.setActiveChat(id: b.id)
            XCTAssertEqual(AppState.shared.config.currentMode, .sheesh)
            XCTAssertEqual(AppState.shared.config.voicePlaybackRate, 1.75)

            // Clearing from B restores the TRUE pre-activation baseline (organic
            // values), proving the baseline survived the switch intact.
            store.setActiveChat(id: nil)
            XCTAssertEqual(AppState.shared.config.currentMode, .normal)
            XCTAssertEqual(AppState.shared.config.voicePlaybackRate, 1.0)
        }
    }

    func testActivatingPresetWithoutConfigOverridesLeavesConfigAndBaseline() {
        withConfigSnapshot {
            AppState.shared.config.currentMode = .chill
            let store = PresetStore(fileURL: tempURL)
            guard let plain = store.create(name: "Plain", kind: .chat, systemPrompt: "hi") else {
                return XCTFail("create nil")
            }
            store.setActiveChat(id: plain.id)
            XCTAssertEqual(AppState.shared.config.currentMode, .chill, "no override means config untouched")
            store.saveNow()
            let payload = Persistence.load(PresetFilePayload.self, from: tempURL, fallback: PresetFilePayload())
            XCTAssertNil(payload.configBaseline, "no baseline captured for a no-config preset")
        }
    }

    func testConfigOverrideFieldsRoundTrip() {
        let store = PresetStore(fileURL: tempURL)
        guard let p = store.create(
            name: "Voiced",
            kind: .chat,
            mode: .grind,
            voiceId: "v123",
            voiceModelId: "m456",
            voicePlaybackRate: 1.4,
            useElevenLabs: true
        ) else { return XCTFail("create nil") }
        store.saveNow()
        let reloaded = PresetStore(fileURL: tempURL)
        guard let back = reloaded.preset(id: p.id) else { return XCTFail("lost on reload") }
        XCTAssertEqual(back.mode, .grind)
        XCTAssertEqual(back.voiceId, "v123")
        XCTAssertEqual(back.voiceModelId, "m456")
        XCTAssertEqual(back.voicePlaybackRate, 1.4)
        XCTAssertEqual(back.useElevenLabs, true)
        XCTAssertTrue(back.hasConfigOverrides)
    }

    func testPresetCodableRoundTrip() throws {
        let preset = Preset(
            name: "Codable",
            kind: .swarm,
            systemPrompt: "Architect first.",
            modelId: "claude-sonnet-4-6",
            enabledToolGroups: [PresetToolGroup.files.rawValue, PresetToolGroup.shell.rawValue],
            notes: "n"
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Preset.self, from: enc.encode(preset))
        XCTAssertEqual(back.id, preset.id)
        XCTAssertEqual(back.name, preset.name)
        XCTAssertEqual(back.kind, preset.kind)
        XCTAssertEqual(back.systemPrompt, preset.systemPrompt)
        XCTAssertEqual(back.modelId, preset.modelId)
        XCTAssertEqual(back.enabledToolGroups, preset.enabledToolGroups)
        XCTAssertEqual(back.notes, preset.notes)
        // ISO8601 drops sub-second precision, so dates compare with tolerance.
        XCTAssertEqual(back.createdAt.timeIntervalSinceReferenceDate,
                       preset.createdAt.timeIntervalSinceReferenceDate, accuracy: 1.0)
        XCTAssertEqual(back.updatedAt.timeIntervalSinceReferenceDate,
                       preset.updatedAt.timeIntervalSinceReferenceDate, accuracy: 1.0)
    }
}
