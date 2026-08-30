import SwiftUI

// Settings IA consolidation (blueprint section 02, proposal 5): 12 tabs down
// to 5 panes. This file owns the pane enum, the legacy-tag alias map that
// keeps the --open-settings-tab seam working, and the per-pane keyword
// registry that backs the search field at the top of SettingsView.

// MARK: - Panes (the 5 top-level tabs)

enum SettingsPane: String, CaseIterable {
    case general = "general"
    case voiceAmbient = "voice-ambient"
    case models = "models"
    case appearance = "appearance"
    case dataSecurity = "data-security"

    var label: String {
        switch self {
        case .general: return "General"
        case .voiceAmbient: return "Voice & Ambient"
        case .models: return "Models"
        case .appearance: return "Appearance"
        case .dataSecurity: return "Data & Security"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .voiceAmbient: return "waveform.circle"
        case .models: return "brain"
        case .appearance: return "paintpalette"
        case .dataSecurity: return "lock.shield"
        }
    }
}

// MARK: - Location (pane + optional sub-pane + optional scroll anchor)

struct SettingsLocation: Equatable {
    let pane: SettingsPane
    var sub: String? = nil
    var anchor: String? = nil
}

// MARK: - Legacy tag aliases
//
// The --open-settings-tab=<name> launch arg (and AppState.requestedSettingsTab)
// historically accepted the 12 old tab tags. Every old tag still resolves to
// the new pane, sub-pane, and scroll target so existing automation and tests
// keep working. New pane raw values resolve too.

enum SettingsTabAliases {
    static let map: [String: SettingsLocation] = [
        // Old 12-tab tags
        "general":    SettingsLocation(pane: .general),
        "about":      SettingsLocation(pane: .general, anchor: "general.about"),
        "voice":      SettingsLocation(pane: .voiceAmbient, sub: "voice"),
        "ambient":    SettingsLocation(pane: .voiceAmbient, sub: "ambient"),
        "focus":      SettingsLocation(pane: .voiceAmbient, sub: "focus"),
        "terminal":   SettingsLocation(pane: .voiceAmbient, sub: "terminal"),
        // The session engine, distinct from Terminal Focus above. Focus is an
        // overlay watching sessions somebody else started; this one spawns them
        // and spends a credential, so it is separately addressable.
        "sessions":   SettingsLocation(pane: .voiceAmbient, sub: "sessions"),
        "api":        SettingsLocation(pane: .models, sub: "models", anchor: "models.api"),
        "upgrades":   SettingsLocation(pane: .models, sub: "models", anchor: "models.tier"),
        "presets":    SettingsLocation(pane: .models, sub: "presets"),
        "appearance": SettingsLocation(pane: .appearance),
        "backup":     SettingsLocation(pane: .dataSecurity, sub: "backup"),
        "security":   SettingsLocation(pane: .dataSecurity, sub: "security"),
        // Convenience tags for new structure
        "voice-ambient": SettingsLocation(pane: .voiceAmbient),
        "models":        SettingsLocation(pane: .models),
        "data-security": SettingsLocation(pane: .dataSecurity),
        "data":          SettingsLocation(pane: .dataSecurity),
        "offline":       SettingsLocation(pane: .models, sub: "models", anchor: "models.offline"),
        "endpoints":     SettingsLocation(pane: .models, sub: "models", anchor: "models.endpoints"),
        "mcp":           SettingsLocation(pane: .models, sub: "models", anchor: "models.mcp"),
        // Where the sidebar's needs-setup count goes, and the words somebody
        // would search for to find the same list.
        "capabilities":  SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.credentials"),
        "credentials":   SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.credentials"),
        "api keys":      SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.credentials"),
        "keys":          SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.credentials"),
        "needs setup":   SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.credentials"),
        "memory":        SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.memory"),
        "fal":           SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.fal"),
        // The first-run flow's only door back in. It had a search entry and a
        // scroll anchor but no tag here, so `--open-settings-tab=first-run`
        // landed at the top of General and the row stayed below the fold,
        // which is the same "technically present, practically unreachable"
        // shape as having no row at all.
        "first-run":     SettingsLocation(pane: .general, anchor: "general.firstRun"),
        "onboarding":    SettingsLocation(pane: .general, anchor: "general.firstRun"),
        "restart":       SettingsLocation(pane: .general, anchor: "general.firstRun"),
    ]

    // Unknown tags fall back to General, matching the old TabView behavior
    // where a bogus tag simply left the first tab selected.
    /// The scroll anchor a credential row carries, so a setup card can send the
    /// user to the exact field rather than to a list of fourteen.
    /// Where a `step.` capability is completed, when the answer is Settings.
    ///
    /// Most steps are completed by the feature itself and correctly have no
    /// destination, which is why `CapabilitySetupCard` gives steps no button by
    /// default. A CONSENT step is different: it is completed in Settings, its
    /// remediation says so, and without a route the setup card is a sentence
    /// telling the user to go somewhere with no way to get there.
    ///
    /// Returns a tag `resolve(_:)` understands, or nil for steps the feature
    /// completes. Deliberately sparse. A step earns an entry here only when
    /// Settings genuinely is where it gets done.
    static func stepDestination(_ requirement: SetupRequirement) -> String? {
        switch requirement {
        case .stepTerminalSessionsExplained: return "sessions"
        default: return nil
        }
    }

    static func credentialAnchor(_ requirement: SetupRequirement) -> String {
        "credential." + requirement.rawValue
    }

    static func resolve(_ tag: String) -> SettingsLocation {
        let key = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let loc = map[key] { return loc }
        if let pane = SettingsPane(rawValue: key) { return SettingsLocation(pane: pane) }
        // A capability id resolves to its own field. Generated rather than added
        // to `map` as fourteen hand-written rows, because a hand-written list
        // silently stops covering a capability the moment the contract gains
        // one, and this whole project exists because that kind of drift is
        // invisible until a user hits a dead end.
        //
        // Reuses the existing deep-link machinery on purpose. An earlier note
        // claimed pane selection was private view state and needed new plumbing;
        // that was REFUTED by reading this file, which already resolves a tag to
        // a pane, a sub-pane and a scroll anchor. Adding a second mechanism
        // beside it would be the exact duplication this work is removing.
        if let req = SetupRequirement(rawValue: key), req.kind == .key {
            return SettingsLocation(pane: .dataSecurity,
                                    sub: "capabilities",
                                    anchor: credentialAnchor(req))
        }
        return SettingsLocation(pane: .general)
    }
}

// MARK: - Search registry

struct SettingsSearchEntry: Identifiable {
    // id doubles as the scroll-anchor string for sections that live in
    // SettingsView's own forms. Entries for embedded standalone views
    // (Presets, Backup, Security, Appearance, Terminal) jump to the pane
    // and sub-pane only.
    let id: String
    let title: String
    let location: SettingsLocation
    let keywords: [String]

    func matches(_ lowercasedQuery: String) -> Bool {
        if title.lowercased().contains(lowercasedQuery) { return true }
        return keywords.contains { $0.contains(lowercasedQuery) }
    }
}

enum SettingsSearchRegistry {
    static let entries: [SettingsSearchEntry] = [
        // General
        SettingsSearchEntry(id: "general.screen", title: "Screen awareness",
            location: SettingsLocation(pane: .general, anchor: "general.screen"),
            keywords: ["screen", "analysis", "notifications", "reminder", "auto-promote", "permission", "recording", "watch"]),
        SettingsSearchEntry(id: "general.notifications", title: "Notification triage",
            location: SettingsLocation(pane: .general, anchor: "general.notifications"),
            keywords: ["notifications", "triage", "quiet hours", "interrupt", "batch", "silent", "speak", "escalation"]),
        SettingsSearchEntry(id: "general.hours", title: "Active hours",
            location: SettingsLocation(pane: .general, anchor: "general.hours"),
            keywords: ["active hours", "start", "end", "schedule", "quiet"]),
        // The words a person reaches for here are all over the map ("welcome",
        // "wizard", "tour", "start over"), and none of them appear in the
        // section title, so the keyword list carries the whole discovery
        // burden. A row that only "Run it again" finds is unreachable in
        // practice, which is the same defect as having no row at all.
        // The words people reach for when a macOS dialog has just appeared are
        // the NAMES OF THE PERMISSIONS, not the word "permissions", so every one
        // is a keyword here. Somebody who just denied Accessibility and wants to
        // know what they gave up types "accessibility", and a row only
        // "permissions" can find would be unreachable exactly when it is needed.
        // Somebody looking for this types their own name, or the assistant's, or
        // "rename". They do not type "identity".
        SettingsSearchEntry(id: "general.identity", title: "Names",
            location: SettingsLocation(pane: .general, anchor: "general.identity"),
            keywords: ["name", "names", "my name", "your name", "rename", "call me",
                       "what to call", "identity", "assistant name", "jax", "greeting",
                       "good morning", "who am i", "nickname"]),
        // The words somebody reaches for here are all over the map: "agent",
        // "handoff", "delegate", "set up for me", and the name of whatever tool
        // they actually use. None of them appear in the section title, so they
        // all have to be keywords or the search finds nothing.
        SettingsSearchEntry(id: "general.handoff", title: "Hand setup to your agent",
            location: SettingsLocation(pane: .general, anchor: "general.handoff"),
            keywords: ["agent", "handoff", "hand off", "delegate", "prompt", "copy", "setup",
                       "set up", "onboard", "claude", "codex", "cursor", "automate", "do it for me"]),
        SettingsSearchEntry(id: "general.permissions", title: "Permissions",
            location: SettingsLocation(pane: .general, anchor: "general.permissions"),
            keywords: ["permission", "permissions", "privacy", "access", "grant", "granted",
                       "microphone", "mic", "screen recording", "screen", "accessibility",
                       "automation", "calendar", "contacts", "notifications", "system audio",
                       "full disk access", "full disk", "tcc", "denied", "revoked", "allow",
                       "why does grux need", "what does grux need"]),
        SettingsSearchEntry(id: "general.firstRun", title: "Restart onboarding",
            location: SettingsLocation(pane: .general, anchor: "general.firstRun"),
            keywords: ["onboarding", "first run", "first-run", "reset onboarding", "run onboarding",
                       "setup", "set up", "welcome", "wizard", "walkthrough", "tour", "intro",
                       "getting started", "start over", "run again", "first launch", "new user",
                       "restart", "restart onboarding", "restart setup", "do it again",
                       "redacted", "first frame"]),
        // "reset onboarding" moved to the entry above, where the control that
        // actually does it now lives. Leaving it here would have sent the
        // search straight past the new row to the button that resets config.
        SettingsSearchEntry(id: "general.about", title: "About Grux",
            location: SettingsLocation(pane: .general, anchor: "general.about"),
            keywords: ["about", "version", "support dir", "reset all settings", "defaults", "events", "tasks", "reveal"]),

        // Voice & Ambient, Voice sub-pane
        SettingsSearchEntry(id: "voice.mics", title: "Microphones",
            location: SettingsLocation(pane: .voiceAmbient, sub: "voice", anchor: "voice.mics"),
            keywords: ["microphone", "mic", "input", "fidelity", "dji", "voice processing", "default input", "built-in",
                       "noise cancellation", "echo cancellation", "aec", "agc", "noise suppression",
                       "tinny", "muffled", "narrow band", "comm mode", "audio quality", "music quality",
                       "sound quality", "speakers", "spotify", "youtube", "netflix"]),
        SettingsSearchEntry(id: "voice.engine", title: "Voice engine",
            location: SettingsLocation(pane: .voiceAmbient, sub: "voice", anchor: "voice.engine"),
            keywords: ["voice engine", "whisper", "dictation", "transcription", "recognition"]),
        SettingsSearchEntry(id: "voice.wake", title: "Wake word",
            location: SettingsLocation(pane: .voiceAmbient, sub: "voice", anchor: "voice.wake"),
            keywords: ["wake word", "hey grux", "auto-send", "listening"]),
        SettingsSearchEntry(id: "voice.replies", title: "Spoken replies",
            location: SettingsLocation(pane: .voiceAmbient, sub: "voice", anchor: "voice.replies"),
            keywords: ["spoken replies", "speak aloud", "barge-in", "voice speed", "playback", "tts", "test voice"]),
        SettingsSearchEntry(id: "voice.eleven", title: "ElevenLabs",
            location: SettingsLocation(pane: .voiceAmbient, sub: "voice", anchor: "voice.eleven"),
            keywords: ["elevenlabs", "voice id", "api key", "turbo", "multilingual", "flash", "catalog", "jarvis"]),

        // Voice & Ambient, Ambient sub-pane
        // Searching Settings is how anyone actually finds a setting. A whole
        // sub-pane was added without these and the suite stayed green, so the
        // keywords are the words a user arrives with after reading onboarding,
        // not the words the code happens to use.
        SettingsSearchEntry(id: "sessions.overview", title: "Terminal sessions",
            location: SettingsLocation(pane: .voiceAmbient, sub: "sessions", anchor: "sessions.overview"),
            keywords: ["terminal", "terminal session", "headless", "session", "agent cli", "claude", "codex", "shell", "hands free"]),
        SettingsSearchEntry(id: "sessions.credential", title: "Which credential sessions spend",
            location: SettingsLocation(pane: .voiceAmbient, sub: "sessions", anchor: "sessions.credential"),
            keywords: ["subscription", "api key", "oauth", "billing", "cost", "who pays", "rate limit", "credential"]),
        SettingsSearchEntry(id: "ambient.passive", title: "Passive listening",
            location: SettingsLocation(pane: .voiceAmbient, sub: "ambient", anchor: "ambient.passive"),
            keywords: ["ambient", "passive listening", "transcribe", "whisper", "capture"]),
        SettingsSearchEntry(id: "ambient.behaviors", title: "Ambient behaviors",
            location: SettingsLocation(pane: .voiceAmbient, sub: "ambient", anchor: "ambient.behaviors"),
            keywords: ["auto-promote", "actions", "coach", "nudge", "hud", "floating", "task stack"]),
        SettingsSearchEntry(id: "meeting.consent", title: "Recording consent",
            location: SettingsLocation(pane: .voiceAmbient, sub: "ambient", anchor: "meeting.consent"),
            keywords: ["recording", "consent", "record", "meeting", "call", "privacy",
                       "permission", "legal", "two party", "tell them", "participants"]),
        SettingsSearchEntry(id: "ambient.crashsafe", title: "Crash-safe meeting capture",
            location: SettingsLocation(pane: .voiceAmbient, sub: "ambient", anchor: "ambient.crashsafe"),
            keywords: ["crash", "meeting", "capture", "safety net", "audio", "wal", "recover"]),
        SettingsSearchEntry(id: "ambient.qwen", title: "Local Qwen ambient brain",
            location: SettingsLocation(pane: .voiceAmbient, sub: "ambient", anchor: "ambient.qwen"),
            keywords: ["qwen", "local llm", "endpoint", "summaries", "ping", "proxy"]),
        SettingsSearchEntry(id: "ambient.data", title: "Ambient data",
            location: SettingsLocation(pane: .voiceAmbient, sub: "ambient", anchor: "ambient.data"),
            keywords: ["transcript", "chunks", "memories", "detected actions", "extraction", "clear ambient"]),

        // Voice & Ambient, Focus + Terminal sub-panes
        SettingsSearchEntry(id: "focus.pane", title: "Focus cadence & snooze",
            location: SettingsLocation(pane: .voiceAmbient, sub: "focus"),
            keywords: ["focus", "cadence", "capture interval", "drift", "threshold", "snooze", "nudging"]),
        SettingsSearchEntry(id: "terminal.pane", title: "Terminal focus",
            location: SettingsLocation(pane: .voiceAmbient, sub: "terminal"),
            keywords: ["terminal", "claude session", "hotkey", "mapping", "recorder", "stuck"]),

        // Models
        SettingsSearchEntry(id: "models.api", title: "Anthropic API",
            location: SettingsLocation(pane: .models, sub: "models", anchor: "models.api"),
            keywords: ["anthropic", "api key", "model id", "claude", "haiku", "sonnet", "opus", "test api"]),
        SettingsSearchEntry(id: "models.tier", title: "Intelligence tier",
            location: SettingsLocation(pane: .models, sub: "models", anchor: "models.tier"),
            keywords: ["tier", "intelligence", "upgrades", "cost", "prefilter", "hybrid", "monthly"]),
        SettingsSearchEntry(id: "models.offline", title: "Offline mode (local model)",
            location: SettingsLocation(pane: .models, sub: "models", anchor: "models.offline"),
            keywords: ["offline", "local model", "ollama", "base url", "discover", "llama", "vllm", "llama.cpp"]),
        SettingsSearchEntry(id: "models.endpoints", title: "Custom model endpoints",
            location: SettingsLocation(pane: .models, sub: "models", anchor: "models.endpoints"),
            keywords: ["custom endpoint", "model config", "openai-compatible", "provider", "registry"]),
        SettingsSearchEntry(id: "models.mcp", title: "MCP servers",
            location: SettingsLocation(pane: .models, sub: "models", anchor: "models.mcp"),
            keywords: ["mcp", "server", "tools", "integration"]),
        SettingsSearchEntry(id: "models.presets", title: "Presets",
            location: SettingsLocation(pane: .models, sub: "presets"),
            keywords: ["preset", "chat preset", "swarm", "cron", "editor", "template"]),

        // Appearance
        SettingsSearchEntry(id: "appearance.pane", title: "Appearance",
            location: SettingsLocation(pane: .appearance),
            keywords: ["appearance", "accent", "hue", "dark", "light", "auto", "glass", "motion", "orb", "glow", "stage", "theme", "wcag", "contrast"]),

        // Data & Security
        SettingsSearchEntry(id: "data.backup", title: "Backup & restore",
            location: SettingsLocation(pane: .dataSecurity, sub: "backup"),
            keywords: ["backup", "restore", "export", "import", "zip", "manifest", "auto-backup", "snapshot"]),
        SettingsSearchEntry(id: "data.security", title: "Security",
            location: SettingsLocation(pane: .dataSecurity, sub: "security"),
            keywords: ["security", "injection", "screening", "url guard", "touch id", "flags", "policy"]),
        SettingsSearchEntry(id: "data.memory", title: "Persistent memory",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.memory"),
            keywords: ["memory", "persistent", "embeddings", "remember", "clear memory", "semantic"]),
        SettingsSearchEntry(id: "data.replicate", title: "Media generation",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.replicate"),
            keywords: ["replicate", "media", "image generation", "api key", "token", "video",
                       "provider", "design", "flux", "fal"]),
        SettingsSearchEntry(id: "data.phone", title: "Grux Phone companion",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.phone"),
            keywords: ["phone", "iphone", "companion", "pair", "pairing", "tunnel", "remote",
                       "websocket", "network", "wifi"]),
        // The words somebody reaches for here are the SYMPTOM, not the feature
        // name: they have seen a listening socket in lsof, Little Snitch, or a
        // firewall prompt and want to know what opened it. So the port number
        // and the network vocabulary carry the discovery, not "digest".
        SettingsSearchEntry(id: "data.prInbox", title: "Digest inbox",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.prInbox"),
            keywords: ["digest", "inbox", "pr digest", "pull request", "listener", "listening",
                       "port", "3852", "server", "http", "network", "socket", "open port",
                       "firewall", "incoming", "push", "companion service"]),
        SettingsSearchEntry(id: "data.asc", title: "App Store Connect",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.asc"),
            keywords: ["app store", "appstore", "app store connect", "asc", "apple", "review",
                       "rejected", "testflight", "ios", "ship", "ship-config", "p8", "api key",
                       "sweep", "outbound", "network"]),
        SettingsSearchEntry(id: "data.screenControl", title: "Screen control",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.screenControl"),
            keywords: ["screen control", "click", "type", "scroll", "accessibility", "control",
                       "automation", "pointer", "keyboard", "operate", "mouse", "hands-free"]),
        SettingsSearchEntry(id: "data.web", title: "Real-time web research",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.web"),
            keywords: ["web research", "brave", "search", "brave api key", "summarize"]),
        SettingsSearchEntry(id: "data.music", title: "Music picking",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.music"),
            keywords: ["music", "apple music", "song", "library", "strategy", "playback"]),
        SettingsSearchEntry(id: "data.ios", title: "iOS developer",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.ios"),
            keywords: ["ios", "developer", "bundle prefix", "team id", "scaffold", "iphone"]),
        SettingsSearchEntry(id: "data.domainMonitor", title: "Domain renewals",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.domainMonitor"),
            keywords: ["domain", "domains", "registrar", "godaddy", "expiry", "expire", "renewal",
                       "dns", "renew"]),
        SettingsSearchEntry(id: "data.controlSocket", title: "Command line",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.controlSocket"),
            keywords: ["cli", "command line", "grux command", "socket", "mcp", "terminal",
                       "control socket", "headless"]),
        SettingsSearchEntry(id: "data.foundry", title: "Self-upgrade loop",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.foundry"),
            keywords: ["foundry", "self upgrade", "self-upgrade", "propose", "proposals",
                       "nightly", "improve itself", "governor"]),
        SettingsSearchEntry(id: "ambient.nightly", title: "Nightly passes over the transcript",
            location: SettingsLocation(pane: .voiceAmbient, sub: "ambient", anchor: "ambient.nightly"),
            keywords: ["people", "person", "dossier", "notes on people", "decisions",
                       "decision log", "nightly", "overnight", "transcript"]),
        SettingsSearchEntry(id: "data.workdayLog", title: "Workday log",
            location: SettingsLocation(pane: .dataSecurity, sub: "capabilities", anchor: "data.workdayLog"),
            keywords: ["workday", "workday log", "daily log", "icloud", "icloud drive", "mirror",
                       "markdown", "commits", "git", "projects", "rollup", "6am", "morning"]),
    ]

    // Minimum 2 characters so a single keystroke does not hide everything.
    static func matches(_ query: String) -> [SettingsSearchEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        return entries.filter { $0.matches(q) }
    }

    // Section filter: when a query is active, sections in SettingsView's own
    // forms hide unless their registry entry matches. Unknown anchors stay
    // visible so a registry gap never hides a control.
    static func sectionVisible(anchor: String, query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return true }
        guard let entry = entries.first(where: { $0.id == anchor }) else { return true }
        return entry.matches(q)
    }
}
