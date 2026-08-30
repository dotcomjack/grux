import Foundation

// MARK: - PresetKind

// What surface a preset targets. Chat presets override the live ChatService
// turn (prompt, model, tool exposure). Swarm presets pre-fill agent_swarm_start
// parameters. Cron presets seed UserCron agent-prompt jobs. v1 wires the chat
// path end to end; swarm and cron presets are stored and editable so the
// integrator can pull them from PresetStore wherever those flows assemble
// their prompts.
enum PresetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case swarm
    case cron

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .swarm: return "Swarm"
        case .cron: return "Cron"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .swarm: return "person.3.fill"
        case .cron: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - PresetToolGroup

// Coarse clusters over ChatService.allTools(). A preset stores the groups it
// keeps ENABLED; an empty selection means "everything" (no restriction).
// Membership is resolved by exact tool name first, then by prefix, so new
// tools in an existing family (shell_*, agent_*, documents_*) are covered
// without touching this file. Tool names that match no group are treated as
// core plumbing and are NEVER filtered out, so a stale preset can't break
// fundamentals like set_mode or grux_orb_hint.
enum PresetToolGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case tasks
    case memory
    case screen
    case web
    case music
    case macros
    case files
    case shell
    case agents
    case meetings
    case email
    case calendar
    case notes
    case documents
    case contacts
    case integrations

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tasks: return "Tasks"
        case .memory: return "Memory"
        case .screen: return "Screen"
        case .web: return "Web & apps"
        case .music: return "Music"
        case .macros: return "Macros"
        case .files: return "Files"
        case .shell: return "Shell"
        case .agents: return "Agents & workflows"
        case .meetings: return "Meetings"
        case .email: return "Email"
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        case .documents: return "Documents"
        case .contacts: return "Contacts"
        case .integrations: return "Integrations"
        }
    }

    // Exact tool names owned by this group.
    private var memberNames: Set<String> {
        switch self {
        case .tasks:
            return ["add_task", "remove_task", "complete_task", "focus_on_task",
                    "list_tasks", "promote_action", "dismiss_action",
                    "list_proposed_actions"]
        case .memory:
            return ["remember_slang", "remember_fact", "capture_memory",
                    "search_memory", "list_memories", "mark_memory_reviewed",
                    "recall_thread_summary", "compact_thread_now",
                    "decision_log_query"]
        case .screen:
            return ["read_screen", "get_current_activity", "focus_summary",
                    "run_focus_check_now", "read_workday_log"]
        case .web:
            return ["open_app", "open_url", "search_web", "research_web",
                    "play_on_youtube"]
        case .music:
            return ["play_music_track", "list_library_tracks"]
        case .macros:
            return ["run_macro", "list_macros"]
        case .files:
            return ["fs_read", "fs_list"]
        case .shell:
            return []
        case .agents:
            return ["start_workflow_v2"]
        case .meetings:
            return []
        case .email:
            return ["compose_email", "list_inbox"]
        case .calendar:
            return ["create_event", "list_events", "import_ics", "export_ics"]
        case .notes:
            return ["create_note", "search_notes", "update_note"]
        case .documents:
            return ["edit_document", "pdf_form_fill"]
        case .contacts:
            return ["create_contact", "lookup_contact"]
        case .integrations:
            return []
        }
    }

    // Name prefixes owned by this group, checked after exact names.
    private var memberPrefixes: [String] {
        switch self {
        case .shell: return ["shell_"]
        case .agents: return ["agent_", "ios_", "workflow_"]
        case .meetings: return ["meeting_", "speaker_", "audio_", "folder_"]
        case .documents: return ["documents_", "document_"]
        case .notes: return ["notes_", "note_"]
        case .email: return ["email_"]
        case .calendar: return ["calendar_"]
        case .contacts: return ["contact", "search_contacts"]
        case .integrations: return ["slack_", "notion_", "creative_"]
        default: return []
        }
    }

    // Which group, if any, owns a tool name. nil means core plumbing.
    static func group(forToolName name: String) -> PresetToolGroup? {
        for g in allCases where g.memberNames.contains(name) { return g }
        for g in allCases {
            for p in g.memberPrefixes where name.hasPrefix(p) { return g }
        }
        return nil
    }
}

// MARK: - Preset

// One saved configuration: an optional system-prompt addition, an optional
// model pin, and an optional tool-group restriction. Empty string / empty
// array consistently mean "no override", so a blank preset applies as a
// no-op and the JSON on disk stays human-readable.
struct Preset: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var kind: PresetKind
    // Appended to the system prompt as its own block when non-empty. It does
    // NOT replace the stable Grux persona; replacing wholesale would strip
    // the trust boundary and tool-trigger guidance baked into ChatService.
    var systemPrompt: String
    // Model id override ("claude-opus-4-7", "llama3.1", ...). Empty = use the
    // ModelRegistry default for the active backend.
    var modelId: String
    // Sampling temperature override (0.0-1.0). nil = the chat default (0.5).
    // Optional so an existing presets.json decodes cleanly (missing key -> nil).
    var temperature: Double?
    // Backend pin: "anthropic" | "local". nil/empty = inherit the registry's
    // current routing. Lets a preset force a specific brain, e.g. a private
    // offline preset pinned to the local model. Optional for decode compat.
    var providerOverride: String?
    // CONFIG-STATE overrides (mode + voice). Unlike the per-turn fields above
    // (prompt/model/temperature/provider, resolved fresh each turn into a
    // PresetApplication), these mutate AppState.shared.config when the preset
    // is ACTIVATED and are restored from a persisted baseline when it clears.
    // All optional so an existing presets.json decodes cleanly (missing -> nil
    // -> inherit the live config value). Deliberately NO screen-watch "tier"
    // field: tier is orthogonal to a chat preset.
    var mode: GruxMode?
    var voiceId: String?
    var voiceModelId: String?
    var voicePlaybackRate: Double?
    var useElevenLabs: Bool?
    // Raw values of PresetToolGroup kept enabled. Empty = all tools. Stored
    // as strings so an old presets.json survives group renames gracefully.
    var enabledToolGroups: [String]
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
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
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.systemPrompt = systemPrompt
        self.modelId = modelId
        self.temperature = temperature
        self.providerOverride = providerOverride
        self.mode = mode
        self.voiceId = voiceId
        self.voiceModelId = voiceModelId
        self.voicePlaybackRate = voicePlaybackRate
        self.useElevenLabs = useElevenLabs
        self.enabledToolGroups = enabledToolGroups
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Typed view over enabledToolGroups. Unknown raw values are dropped.
    var enabledGroups: Set<PresetToolGroup> {
        Set(enabledToolGroups.compactMap { PresetToolGroup(rawValue: $0) })
    }

    // True when the preset pins any config-state value (mode or voice). The
    // store uses this to decide whether activating it should capture a config
    // baseline and mutate AppState.shared.config. A preset that touches none
    // of these leaves config untouched and clears any prior baseline.
    var hasConfigOverrides: Bool {
        mode != nil
            || voiceId != nil
            || voiceModelId != nil
            || voicePlaybackRate != nil
            || useElevenLabs != nil
    }
}

// MARK: - PresetConfigBaseline

// Snapshot of the config-state values a preset can override, captured the
// moment a preset WITH config overrides is first activated. Persisted in
// PresetFilePayload so a relaunch can still restore the true pre-activation
// config when the preset is later cleared. Equatable so tests can assert it.
struct PresetConfigBaseline: Codable, Equatable {
    var currentMode: GruxMode
    var elevenLabsVoiceId: String
    var elevenLabsModelId: String
    var voicePlaybackRate: Double
    var useElevenLabs: Bool
}

// MARK: - PresetApplication

// The seam between PresetStore and ChatService. Applying a chat preset means
// handing send() one of these; everything is pre-resolved to plain values so
// the streaming loop never touches the store. nil fields are explicit no-ops:
// nil prompt = stock persona only, nil model = registry default, nil groups =
// every tool ships.
struct PresetApplication: Equatable, Sendable {
    let presetId: UUID
    let presetName: String
    let systemPromptOverride: String?
    let modelIdOverride: String?
    let temperatureOverride: Double?
    let providerOverride: String?
    let enabledGroups: Set<PresetToolGroup>?

    init(preset: Preset) {
        self.presetId = preset.id
        self.presetName = preset.name
        let prompt = preset.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.systemPromptOverride = prompt.isEmpty ? nil : prompt
        let model = preset.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelIdOverride = model.isEmpty ? nil : model
        self.temperatureOverride = preset.temperature
        let provider = (preset.providerOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerOverride = provider.isEmpty ? nil : provider
        let groups = preset.enabledGroups
        self.enabledGroups = groups.isEmpty ? nil : groups
    }

    // Model id this turn should use given the registry's current default.
    func resolvedModelId(fallback: String) -> String {
        modelIdOverride ?? fallback
    }

    // Whether a tool survives this preset's restriction. Tools owned by no
    // group are core plumbing and always pass.
    func allows(toolName: String) -> Bool {
        guard let enabledGroups else { return true }
        guard let group = PresetToolGroup.group(forToolName: toolName) else { return true }
        return enabledGroups.contains(group)
    }

    // Extra system block for buildSystemBlocks. Labeled so the model treats
    // it as an addendum from the user, not a persona replacement.
    func systemBlockText() -> String? {
        guard let systemPromptOverride else { return nil }
        return """
        ACTIVE PRESET: \(presetName)
        The user applied this preset to the current chat. Follow these additional instructions; they extend (never replace) everything above:

        \(systemPromptOverride)
        """
    }
}
