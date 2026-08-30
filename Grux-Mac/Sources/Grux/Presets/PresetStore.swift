import Foundation
import SwiftUI

extension Persistence {
    static var presetsURL: URL { supportDir.appendingPathComponent("presets.json") }
}

// On-disk payload. Wrapping the array keeps the active-chat pointer and the
// seeded marker in the same atomic file, so there is no UserDefaults split
// brain and tests can point an instance at a temp URL and own everything.
struct PresetFilePayload: Codable {
    var schemaVersion: Int = 1
    var seeded: Bool = false
    var activeChatPresetId: UUID? = nil
    var presets: [Preset] = []
    // The pre-activation config snapshot, captured when a preset WITH config
    // overrides (mode / voice) is first activated and held until that override
    // is cleared. nil = no preset is currently applying config overrides, so
    // config holds its own organic values. Optional so an old presets.json
    // (which never wrote this key) decodes to nil cleanly.
    var configBaseline: PresetConfigBaseline? = nil
}

// Persistent preset registry. Local-first, a single JSON blob at
// ~/Library/Application Support/Grux/presets.json, same shape as FolderStore:
// @MainActor singleton, @Published reads, debounced scheduleSave writes.
// Seeds three starter presets on first launch so the Presets pane never
// opens empty.
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore(fileURL: Persistence.presetsURL)

    @Published private(set) var presets: [Preset] = []
    // The chat preset currently applied to ChatService turns. nil = stock
    // Grux. Session-spanning on purpose: the user picks a preset once and it
    // sticks across relaunches until they clear it.
    @Published private(set) var activeChatPresetId: UUID?

    private let fileURL: URL
    private var seeded = false
    private var saveToken: DispatchWorkItem?
    // The pre-activation config snapshot for the currently-applying preset. See
    // PresetFilePayload.configBaseline. Held in memory and mirrored to disk.
    private var configBaseline: PresetConfigBaseline?

    init(fileURL: URL) {
        self.fileURL = fileURL
        let payload = Persistence.load(PresetFilePayload.self, from: fileURL, fallback: PresetFilePayload())
        self.presets = payload.presets
        self.seeded = payload.seeded
        self.activeChatPresetId = payload.activeChatPresetId
        self.configBaseline = payload.configBaseline
        seedIfNeeded()
        // Heal a dangling pointer (preset deleted out from under us by an
        // older build or a hand-edited file). Restore any orphaned config
        // baseline so config does not stay stuck on a vanished preset.
        if let id = activeChatPresetId, preset(id: id) == nil {
            if configBaseline != nil {
                restoreConfigFromBaseline()
                configBaseline = nil
            }
            activeChatPresetId = nil
            scheduleSave()
        }
    }

    // MARK: - Read

    var ordered: [Preset] {
        presets.sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func preset(id: UUID?) -> Preset? {
        guard let id else { return nil }
        return presets.first(where: { $0.id == id })
    }

    // Case-insensitive name lookup, exact match first, then substring, so
    // "use the writing preset" resolves without the full title.
    func preset(named hint: String) -> Preset? {
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return nil }
        if let exact = presets.first(where: { $0.name.lowercased() == h }) { return exact }
        return presets.first(where: { $0.name.lowercased().contains(h) })
    }

    func presets(kind: PresetKind) -> [Preset] {
        ordered.filter { $0.kind == kind }
    }

    // The pre-resolved application for the current chat preset, or nil when
    // no preset is active. ChatService.send() reads this once per turn.
    func activeChatApplication() -> PresetApplication? {
        guard let p = preset(id: activeChatPresetId), p.kind == .chat else { return nil }
        return PresetApplication(preset: p)
    }

    // MARK: - Write

    @discardableResult
    func create(
        name: String,
        kind: PresetKind = .chat,
        systemPrompt: String = "",
        modelId: String = "",
        temperature: Double? = nil,
        providerOverride: String? = nil,
        mode: GruxMode? = nil,
        voiceId: String? = nil,
        voiceModelId: String? = nil,
        voicePlaybackRate: Double? = nil,
        useElevenLabs: Bool? = nil,
        enabledToolGroups: [String] = [],
        notes: String = ""
    ) -> Preset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preset = Preset(
            name: uniqueName(from: trimmed),
            kind: kind,
            systemPrompt: systemPrompt,
            modelId: modelId.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: temperature,
            providerOverride: providerOverride,
            mode: mode,
            voiceId: voiceId,
            voiceModelId: voiceModelId,
            voicePlaybackRate: voicePlaybackRate,
            useElevenLabs: useElevenLabs,
            enabledToolGroups: enabledToolGroups,
            notes: notes
        )
        presets.append(preset)
        scheduleSave()
        return preset
    }

    @discardableResult
    func update(
        id: UUID,
        name: String? = nil,
        kind: PresetKind? = nil,
        systemPrompt: String? = nil,
        modelId: String? = nil,
        temperature: Double? = nil,
        providerOverride: String? = nil,
        // mode / voiceId / voiceModelId use the empty-string-as-inherit
        // convention from providerOverride: pass "" to clear back to inherit,
        // pass nil to leave the field untouched, pass a value to pin it.
        mode: String? = nil,
        voiceId: String? = nil,
        voiceModelId: String? = nil,
        // voicePlaybackRate / useElevenLabs carry no empty sentinel, so they
        // take a double-optional: outer nil = leave alone, .some(nil) = clear
        // to inherit, .some(value) = pin. The editor always passes an explicit
        // value, so this only matters for programmatic callers.
        voicePlaybackRate: Double?? = nil,
        useElevenLabs: Bool?? = nil,
        enabledToolGroups: [String]? = nil,
        notes: String? = nil
    ) -> Preset? {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return nil }
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            presets[idx].name = n
        }
        if let k = kind {
            presets[idx].kind = k
            // A preset edited away from .chat can't stay the active chat preset.
            // Treat it as a clear so any applied config overrides are undone.
            if k != .chat && activeChatPresetId == id {
                if configBaseline != nil {
                    restoreConfigFromBaseline()
                    configBaseline = nil
                }
                activeChatPresetId = nil
            }
        }
        if let sp = systemPrompt { presets[idx].systemPrompt = sp }
        if let m = modelId { presets[idx].modelId = m.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let t = temperature { presets[idx].temperature = t }
        if let pr = providerOverride { presets[idx].providerOverride = pr.isEmpty ? nil : pr }
        if let md = mode { presets[idx].mode = md.isEmpty ? nil : GruxMode(rawValue: md) }
        if let vid = voiceId {
            let t = vid.trimmingCharacters(in: .whitespacesAndNewlines)
            presets[idx].voiceId = t.isEmpty ? nil : t
        }
        if let vmid = voiceModelId {
            let t = vmid.trimmingCharacters(in: .whitespacesAndNewlines)
            presets[idx].voiceModelId = t.isEmpty ? nil : t
        }
        if let rate = voicePlaybackRate { presets[idx].voicePlaybackRate = rate }
        if let useEL = useElevenLabs { presets[idx].useElevenLabs = useEL }
        if let g = enabledToolGroups { presets[idx].enabledToolGroups = g }
        if let no = notes { presets[idx].notes = no }
        presets[idx].updatedAt = Date()
        // If the user edits the active preset's config overrides, re-apply so the
        // live config tracks the edit (restore baseline first, then reapply).
        if activeChatPresetId == id { reapplyActiveConfigOverrides() }
        scheduleSave()
        return presets[idx]
    }

    @discardableResult
    func delete(id: UUID) -> Preset? {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return nil }
        let victim = presets.remove(at: idx)
        if activeChatPresetId == id {
            // Deleting the active preset is a clear: restore organic config.
            if configBaseline != nil {
                restoreConfigFromBaseline()
                configBaseline = nil
            }
            activeChatPresetId = nil
        }
        scheduleSave()
        return victim
    }

    @discardableResult
    func duplicate(id: UUID) -> Preset? {
        guard let source = preset(id: id) else { return nil }
        let copy = Preset(
            name: uniqueName(from: source.name),
            kind: source.kind,
            systemPrompt: source.systemPrompt,
            modelId: source.modelId,
            temperature: source.temperature,
            providerOverride: source.providerOverride,
            mode: source.mode,
            voiceId: source.voiceId,
            voiceModelId: source.voiceModelId,
            voicePlaybackRate: source.voicePlaybackRate,
            useElevenLabs: source.useElevenLabs,
            enabledToolGroups: source.enabledToolGroups,
            notes: source.notes
        )
        presets.append(copy)
        scheduleSave()
        return copy
    }

    // Apply / clear the chat preset. Applying a non-chat preset is a no-op
    // by design; swarm and cron presets are consumed by their own flows.
    //
    // CONFIG-STATE handling (mode + voice): these fields live on
    // AppState.shared.config, not in the per-turn PresetApplication, so
    // activating a preset that pins any of them must mutate config and
    // capture a one-time baseline so a later clear restores the true
    // pre-activation values. The baseline is persisted, so it survives a
    // relaunch where config already holds the applied values.
    func setActiveChat(id: UUID?) {
        if let id {
            guard let p = preset(id: id), p.kind == .chat else { return }

            if p.hasConfigOverrides {
                // Switching from a different active preset that may have left
                // its overrides on config: restore the baseline FIRST so we
                // never compound preset A's values into preset B. The baseline
                // stays as-is (it is the true pre-activation state).
                if configBaseline != nil {
                    restoreConfigFromBaseline()
                } else {
                    // First override-bearing preset since stock: snapshot the
                    // current organic config as the baseline before mutating.
                    configBaseline = captureConfigBaseline()
                }
                activeChatPresetId = id
                applyConfigOverrides(from: p)
            } else {
                // New preset pins no config state. If a prior preset had, undo
                // it and drop the baseline so config is back to organic values.
                if configBaseline != nil {
                    restoreConfigFromBaseline()
                    configBaseline = nil
                }
                activeChatPresetId = id
            }
        } else {
            // Clearing to stock Grux: restore organic config and drop baseline.
            if configBaseline != nil {
                restoreConfigFromBaseline()
                configBaseline = nil
            }
            activeChatPresetId = nil
        }
        scheduleSave()
    }

    // MARK: - Config-state apply / restore

    // Snapshot of the current AppState config values a preset can override.
    private func captureConfigBaseline() -> PresetConfigBaseline {
        let cfg = AppState.shared.config
        return PresetConfigBaseline(
            currentMode: cfg.currentMode,
            elevenLabsVoiceId: cfg.elevenLabsVoiceId,
            elevenLabsModelId: cfg.elevenLabsModelId,
            voicePlaybackRate: cfg.voicePlaybackRate,
            useElevenLabs: cfg.useElevenLabs
        )
    }

    // Push the preset's non-nil config overrides onto AppState.config. nil
    // fields are left as the baseline/current value (inherit).
    private func applyConfigOverrides(from p: Preset) {
        var cfg = AppState.shared.config
        if let m = p.mode { cfg.currentMode = m }
        if let vid = p.voiceId { cfg.elevenLabsVoiceId = vid }
        if let vmid = p.voiceModelId { cfg.elevenLabsModelId = vmid }
        if let rate = p.voicePlaybackRate { cfg.voicePlaybackRate = rate }
        if let useEL = p.useElevenLabs { cfg.useElevenLabs = useEL }
        AppState.shared.config = cfg
        AppState.shared.saveConfig()
    }

    // Write the captured baseline back onto AppState.config verbatim.
    private func restoreConfigFromBaseline() {
        guard let base = configBaseline else { return }
        var cfg = AppState.shared.config
        cfg.currentMode = base.currentMode
        cfg.elevenLabsVoiceId = base.elevenLabsVoiceId
        cfg.elevenLabsModelId = base.elevenLabsModelId
        cfg.voicePlaybackRate = base.voicePlaybackRate
        cfg.useElevenLabs = base.useElevenLabs
        AppState.shared.config = cfg
        AppState.shared.saveConfig()
    }

    // After an in-place edit to the active preset, restore baseline then
    // reapply so the live config tracks the edit without compounding. Handles
    // the case where the edit added or removed config overrides entirely.
    private func reapplyActiveConfigOverrides() {
        guard let id = activeChatPresetId, let p = preset(id: id) else { return }
        if p.hasConfigOverrides {
            if configBaseline == nil { configBaseline = captureConfigBaseline() }
            restoreConfigFromBaseline()
            applyConfigOverrides(from: p)
        } else if configBaseline != nil {
            restoreConfigFromBaseline()
            configBaseline = nil
        }
    }

    // MARK: - Seeding

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        guard presets.isEmpty else { scheduleSave(); return }
        presets = [
            Preset(
                name: "Deep work, no noise",
                kind: .chat,
                systemPrompt: "The user is heads down. Keep replies to one sentence unless they explicitly ask for more. Do not surface pending memories or proposed actions unprompted.",
                enabledToolGroups: [PresetToolGroup.tasks.rawValue,
                                    PresetToolGroup.screen.rawValue,
                                    PresetToolGroup.macros.rawValue],
                notes: "Minimal chatter while shipping. Tasks, screen reads, and macros only."
            ),
            Preset(
                name: "Research copilot",
                kind: .chat,
                systemPrompt: "The user is in research mode. Prefer search_web and research_web before answering factual questions, cite what you found in one line, and capture durable findings with capture_memory.",
                enabledToolGroups: [PresetToolGroup.web.rawValue,
                                    PresetToolGroup.memory.rawValue,
                                    PresetToolGroup.files.rawValue,
                                    PresetToolGroup.documents.rawValue,
                                    PresetToolGroup.notes.rawValue],
                notes: "Web-first answers with memory capture."
            ),
            Preset(
                name: "Morning brief",
                kind: .cron,
                systemPrompt: "Summarize the user's day in under 120 words: top 3 tasks, any calendar events before noon, and one suggestion for what to knock out first.",
                notes: "Pair with a Schedules job (agent prompt) for a daily kickoff."
            ),
            // Reference presets exercising the full field set (mode, voice,
            // temperature, provider) now that those overrides exist.
            Preset(
                name: "Deep Work",
                kind: .chat,
                systemPrompt: "The user is in deep focus. Answer in one tight sentence, lead with the action, and never surface pending memories or proposed actions unprompted.",
                temperature: 0.3,
                mode: .sheesh,
                enabledToolGroups: [PresetToolGroup.tasks.rawValue],
                notes: "Sheesh mode, low temperature, tasks only. Maximum focus, minimum chatter."
            ),
            Preset(
                name: "Research Copilot",
                kind: .chat,
                systemPrompt: "Research mode. Search before answering factual questions, cite what you found in one line, and read the source files when they matter.",
                modelId: "claude-sonnet-4-6",
                temperature: 0.8,
                enabledToolGroups: [PresetToolGroup.web.rawValue,
                                    PresetToolGroup.files.rawValue],
                notes: "Sonnet, higher temperature, web plus files. Built for digging."
            ),
            Preset(
                name: "Offline / Private",
                kind: .chat,
                systemPrompt: "This conversation stays on the local model. Keep it private, do not reach for cloud tools, and answer from what is on the machine.",
                providerOverride: "local",
                notes: "Pinned to the local model. Slower, but private. Needs a discovered local server (Settings, Offline mode)."
            ),
            Preset(
                name: "Voice Brief",
                kind: .chat,
                systemPrompt: "You are being read aloud. Write for the ear: short spoken sentences, no bullet lists, no markdown, no code blocks. Lead with the headline, then the detail.",
                voicePlaybackRate: 1.25,
                notes: "Spoken-brief style with a brisker 1.25x playback rate."
            )
        ]
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveToken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        saveToken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        objectWillChange.send()
    }

    func saveNow() {
        let payload = PresetFilePayload(
            schemaVersion: 1,
            seeded: seeded,
            activeChatPresetId: activeChatPresetId,
            presets: presets,
            configBaseline: configBaseline
        )
        Persistence.save(payload, to: fileURL)
    }

    // MARK: - Helpers

    // "Name", "Name 2", "Name 3", ... so create/duplicate never collide.
    private func uniqueName(from base: String) -> String {
        let existing = Set(presets.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var n = 2
        while existing.contains("\(base.lowercased()) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
