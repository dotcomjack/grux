import Foundation

// MARK: - Task Stack

enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case now, next, later
    var id: String { rawValue }
    var label: String {
        switch self {
        case .now: return "NOW"
        case .next: return "NEXT"
        case .later: return "LATER"
        }
    }
}

struct FocusTask: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var project: String
    var priority: TaskPriority
    var createdAt: Date
    var notes: String
    var completed: Bool
    var completedAt: Date?
    // nil = top-level task. Non-nil = sub-task whose parent is this UUID.
    // Optional so pre-existing tasks.json files decode cleanly (synthesized
    // Codable treats missing optional keys as nil).
    var parentId: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        project: String = "",
        priority: TaskPriority = .next,
        notes: String = "",
        parentId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.priority = priority
        self.createdAt = Date()
        self.notes = notes
        self.completed = false
        self.completedAt = nil
        self.parentId = parentId
    }
}

// MARK: - Focus Events

enum FocusVerdict: String, Codable {
    case onTask
    case drifting
    case offTask
    case ambiguous
}

struct FocusEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let currentTaskId: UUID?
    let currentTaskTitle: String
    let activeApp: String
    let windowTitle: String
    let verdict: FocusVerdict
    let confidence: Double
    let rationale: String
    let suggestedTaskId: UUID?
    let suggestedTaskTitle: String?
    let screenTextSnippet: String

    init(id: UUID = UUID(), timestamp: Date = Date(), currentTaskId: UUID?, currentTaskTitle: String,
         activeApp: String, windowTitle: String, verdict: FocusVerdict, confidence: Double,
         rationale: String, suggestedTaskId: UUID?, suggestedTaskTitle: String?, screenTextSnippet: String) {
        self.id = id
        self.timestamp = timestamp
        self.currentTaskId = currentTaskId
        self.currentTaskTitle = currentTaskTitle
        self.activeApp = activeApp
        self.windowTitle = windowTitle
        self.verdict = verdict
        self.confidence = confidence
        self.rationale = rationale
        self.suggestedTaskId = suggestedTaskId
        self.suggestedTaskTitle = suggestedTaskTitle
        self.screenTextSnippet = screenTextSnippet
    }
}

// MARK: - Chat

enum ChatRole: String, Codable { case user, assistant, system }

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatRole
    var content: String
    let timestamp: Date
    // Optional inline image attached by the user via drag-drop. Stored as raw
    // bytes + IANA media type ("image/png", "image/jpeg", etc.) so we can
    // both render in the bubble and forward to Claude as a multimodal content
    // block. Nil for every assistant message and every text-only user message.
    var imageData: Data?
    var imageMediaType: String?

    init(id: UUID = UUID(), role: ChatRole, content: String,
         timestamp: Date = Date(),
         imageData: Data? = nil, imageMediaType: String? = nil) {
        self.id = id; self.role = role; self.content = content; self.timestamp = timestamp
        self.imageData = imageData; self.imageMediaType = imageMediaType
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, imageData, imageMediaType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(ChatRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        imageMediaType = try c.decodeIfPresent(String.self, forKey: .imageMediaType)
    }
}

// A recoverable chat failure plus the original user text needed to retry it.
// Interactive chat used to dead-end on any error: the catch block appended a
// raw "⚠️ <error>" bubble with no next step, so a 429/monthly-limit or a
// network drop both left the user guessing while the swarm path's rich recovery
// (account switch, snooze) and the offline toggle stayed unreachable from the
// surface where they actually spend most of their time. This drives an actionable
// banner above the composer instead.
struct ChatRecovery: Identifiable, Equatable {
    enum Kind: Equatable {
        case limitHit        // 429 / monthly usage limit: offer account switch + snooze
        case network         // connection failure: offer Continue offline (if local found) + retry
        case offlineNoModel  // offline mode on, no local model, cloud also failed
        case generic         // anything else: plain retry
    }
    let id = UUID()
    let kind: Kind
    let message: String      // human-readable cause for the banner
    let retryText: String    // original user text to re-send on Retry
    let retryImageData: Data?
    let retryImageMediaType: String?

    init(kind: Kind, message: String, retryText: String,
         retryImageData: Data? = nil, retryImageMediaType: String? = nil) {
        self.kind = kind
        self.message = message
        self.retryText = retryText
        self.retryImageData = retryImageData
        self.retryImageMediaType = retryImageMediaType
    }
}

// MARK: - Ambient Mode

// Two listening modes:
//   .wake  - classic: Grux only engages on "Hey Grux" (with armed follow-up).
//            Every other utterance is just ambient memory/extraction.
//   .focus - heads-down mode: every meaningful utterance is treated as a
//            command. No wake phrase required - the user can just talk to Grux
//            while working and get instant answers. Higher bar for what
//            counts as "meaningful" to avoid chatter spam.
public enum AmbientMode: String, Codable, CaseIterable, Identifiable {
    case wake
    case focus
    public var id: String { rawValue }
    public var label: String { self == .wake ? "WAKE" : "FOCUS" }
    public var shortHelp: String {
        self == .wake
            ? "Engages on \"Hey Grux\". Quieter - ignores chatter."
            : "Always ready. Every utterance is a command. Heads-down mode."
    }
}

// MARK: - Personality / Energy Modes
//
// Four energy modes affect reply tone, reply length, how often Grux
// volunteers unsolicited info, and how aggressively AmbientCoach nudges
// the user when they drift. The user switches via voice command ("switch to
// grind mode", "sheesh mode"); Claude dispatches via the `set_mode` tool.
//
// The mode is persisted in GruxConfig so it survives restarts.
public enum GruxMode: String, Codable, CaseIterable, Identifiable {
    case chill, normal, grind, sheesh

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .chill:  return "CHILL"
        case .normal: return "NORMAL"
        case .grind:  return "GRIND"
        case .sheesh: return "SHEESH"
        }
    }
    // Single-char menu bar indicator. Normal is blank (no visual noise in
    // the common case - keeps the menu bar minimal).
    public var menuBarGlyph: String {
        switch self {
        case .chill:  return "c"
        case .normal: return ""
        case .grind:  return "G"
        case .sheesh: return "S"
        }
    }
    // Coach nudge cooldown. Chill is sparse; Sheesh catches drift fast.
    public var coachCooldownSeconds: TimeInterval {
        switch self {
        case .chill:  return 600   // 10 min - barely pokes
        case .normal: return 180   // 3 min - current default
        case .grind:  return 90    // 1.5 min - tighter
        case .sheesh: return 60    // 1 min - pit crew
        }
    }
    // Hard reply-length cap Claude will respect, in whole sentences.
    // Sheesh's "≤6 words" cap is baked into the voice rules themselves.
    public var replyCapDescription: String {
        switch self {
        case .chill:  return "up to 2 short sentences, slow and unhurried"
        case .normal: return "1 to 3 short sentences, warm and direct"
        case .grind:  return "ONE sentence, ruthlessly brief, action-first"
        case .sheesh: return "six words MAX. clipped. urgent. one beat."
        }
    }
    public var voiceInstructions: String {
        switch self {
        case .chill:
            return """
            CHILL mode overrides: Slow down the cadence. Softer, more relaxed energy. \
            You can be a little playful. Reply length: up to 2 short sentences. \
            Volunteer unsolicited info only when it genuinely helps - default to quiet. \
            Zero urgency in word choice. Think "lounge DJ between sets", not "coach".
            """
        case .normal:
            return """
            NORMAL mode overrides: Standard Grux energy. Warm, direct, conversational. \
            1 to 3 short sentences. Volunteer useful context when it adds value. \
            This is the balanced default - no pushing toward any extreme.
            """
        case .grind:
            return """
            GRIND mode overrides: Cut every word you can. Drop the small talk, drop the \
            preamble, drop the closers. ONE sentence. Lead with the action or the answer. \
            If a tool call would resolve it, call the tool and reply with ≤6 words. \
            Never volunteer unsolicited info - they are focused. Nudges in this mode are \
            sharper and more frequent. Think "ops lead on comms".
            """
        case .sheesh:
            return """
            SHEESH mode overrides: LOCKED IN. Maximum six words per reply. No full sentences \
            needed. Clipped, punchy, all urgency. Confirmations like "on it.", "done.", \
            "copy.", "locked." are ideal. NEVER volunteer anything. NEVER add explanation. \
            Tool calls fire silently - a 2-word confirm is all they get. \
            If they ask something that genuinely needs detail, answer in a single fragment, \
            not a sentence. Think pit crew on race day - every word costs time.
            """
        }
    }
}

// MARK: - Intelligence Tier
//
// Ten presets that trade off reaction time, reasoning depth, and cost. The
// "hybrid" tiers run a local-first pipeline (pHash + OCR + text embedding
// diff) and only escalate to the cloud when something meaningful changed -
// keeping ~80% of frames off the network while still feeling continuous.
// The "all-cloud" tiers skip the prescreen and send every frame to Claude.
// Tier 4 is the recommended sweet spot.
public enum GruxTier: String, Codable, CaseIterable, Identifiable {
    case tier1_cloud_30s           // current baseline
    case tier2_hybrid_30s
    case tier3_hybrid_15s
    case tier4_hybrid_8s           // ⭐ recommended sweet spot
    case tier5_hybrid_5s
    case tier6_hybrid_2s
    case tier7_cloud_8s
    case tier8_cloud_5s
    case tier9_cloud_2s
    case tier10_cloud_sonnet_5s

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tier1_cloud_30s:       return "Tier 1: Baseline"
        case .tier2_hybrid_30s:      return "Tier 2: Hybrid 30s"
        case .tier3_hybrid_15s:      return "Tier 3: Hybrid 15s"
        case .tier4_hybrid_8s:       return "Tier 4: Hybrid 8s ⭐"
        case .tier5_hybrid_5s:       return "Tier 5: Hybrid 5s"
        case .tier6_hybrid_2s:       return "Tier 6: Hybrid 2s"
        case .tier7_cloud_8s:        return "Tier 7: All-Cloud 8s"
        case .tier8_cloud_5s:        return "Tier 8: All-Cloud 5s"
        case .tier9_cloud_2s:        return "Tier 9: All-Cloud 2s"
        case .tier10_cloud_sonnet_5s:return "Tier 10: Premium Sonnet 5s"
        }
    }

    // Short one-liner describing the architecture at a glance.
    public var architecture: String {
        switch self {
        case .tier1_cloud_30s:       return "Every 30s → cloud Haiku (current default)"
        case .tier2_hybrid_30s:      return "30s · local prescreen · Haiku + Sonnet escalate"
        case .tier3_hybrid_15s:      return "15s · local prescreen · Haiku + Sonnet escalate"
        case .tier4_hybrid_8s:       return "8s · local prescreen · Haiku + Sonnet escalate"
        case .tier5_hybrid_5s:       return "5s · local prescreen · Haiku + Sonnet escalate"
        case .tier6_hybrid_2s:       return "2s · local prescreen · Haiku + Sonnet escalate"
        case .tier7_cloud_8s:        return "Every 8s → cloud Haiku (no local filter)"
        case .tier8_cloud_5s:        return "Every 5s → cloud Haiku (no local filter)"
        case .tier9_cloud_2s:        return "Every 2s → cloud Haiku (no local filter)"
        case .tier10_cloud_sonnet_5s:return "Every 5s → cloud Sonnet (deep reasoning always)"
        }
    }

    // Rounded monthly API spend estimate at ~8h active/day. See cost model.
    public var estimatedMonthlyUSD: Int {
        switch self {
        case .tier1_cloud_30s:       return 66   // all-cloud, no filter: simplest, NOT cheapest
        case .tier2_hybrid_30s:      return 21   // cheapest (local prescreen filters ~80%)
        case .tier3_hybrid_15s:      return 36
        case .tier4_hybrid_8s:       return 60   // best value, recommended default
        case .tier5_hybrid_5s:       return 98
        case .tier6_hybrid_2s:       return 200
        case .tier7_cloud_8s:        return 265
        case .tier8_cloud_5s:        return 415
        case .tier9_cloud_2s:        return 1000
        case .tier10_cloud_sonnet_5s:return 520  // Haiku vision, Sonnet only for deep reasoning
        }
    }

    // Prescreen loop cadence in seconds. For hybrid tiers this is how often
    // the LOCAL pipeline samples a frame; a cloud call only fires when the
    // prescreen says something changed meaningfully (or the max-silence
    // timer elapsed).
    public var cadenceSeconds: Int {
        switch self {
        case .tier1_cloud_30s, .tier2_hybrid_30s:  return 30
        case .tier3_hybrid_15s:                    return 15
        case .tier4_hybrid_8s, .tier7_cloud_8s:    return 8
        case .tier5_hybrid_5s, .tier8_cloud_5s,
             .tier10_cloud_sonnet_5s:              return 5
        case .tier6_hybrid_2s, .tier9_cloud_2s:    return 2
        }
    }

    public var useLocalPrescreen: Bool {
        switch self {
        case .tier2_hybrid_30s, .tier3_hybrid_15s,
             .tier4_hybrid_8s, .tier5_hybrid_5s, .tier6_hybrid_2s:
            return true
        default:
            return false
        }
    }

    // Primary cloud model. Tier 10 uses Sonnet for every frame.
    public var cloudModel: String {
        // Every tier reads frames with Haiku (vision = OCR diff + shallow
        // semantic; Sonnet is wasted there). Deep reasoning escalates separately.
        return "claude-haiku-4-5-20251001"
    }

    // Escalation model for deep reasoning moments (sustained off-task +
    // complex context). `nil` means no escalation.
    public var escalationModel: String? {
        switch self {
        case .tier1_cloud_30s:       return nil
        case .tier10_cloud_sonnet_5s:return "claude-sonnet-4-6" // Haiku vision, Sonnet for deep reasoning
        case .tier7_cloud_8s, .tier8_cloud_5s, .tier9_cloud_2s:
            return "claude-sonnet-4-6" // even all-cloud tiers get deeper reasoning
        default:
            return "claude-sonnet-4-6"
        }
    }

    // Hard ceiling on cloud calls per 24h. Prevents runaway spend when the
    // prescreen misbehaves. Tuned generously above expected steady-state.
    public var maxCloudCallsPerDay: Int {
        switch self {
        case .tier1_cloud_30s:       return 2_500
        case .tier2_hybrid_30s:      return 400
        case .tier3_hybrid_15s:      return 500
        case .tier4_hybrid_8s:       return 700
        case .tier5_hybrid_5s:       return 1_200
        case .tier6_hybrid_2s:       return 2_400
        case .tier7_cloud_8s:        return 5_000
        case .tier8_cloud_5s:        return 8_000
        case .tier9_cloud_2s:        return 20_000
        case .tier10_cloud_sonnet_5s:return 8_000
        }
    }

    // Daily budget for Sonnet escalations (separate ceiling - Sonnet calls
    // are ~3× the cost of a Haiku call).
    public var maxEscalationsPerDay: Int {
        switch self {
        case .tier1_cloud_30s:       return 0
        case .tier10_cloud_sonnet_5s: return 200
        case .tier2_hybrid_30s:      return 25
        case .tier3_hybrid_15s:      return 30
        case .tier4_hybrid_8s:       return 40
        case .tier5_hybrid_5s:       return 60
        case .tier6_hybrid_2s:       return 100
        case .tier7_cloud_8s, .tier8_cloud_5s, .tier9_cloud_2s: return 50
        }
    }

    // If the prescreen hasn't forced an escalation in this long, fire a
    // keepalive cloud check anyway so "on-task" states still get confirmed.
    public var maxSilenceSeconds: Int {
        switch self {
        case .tier1_cloud_30s, .tier2_hybrid_30s, .tier7_cloud_8s,
             .tier8_cloud_5s, .tier9_cloud_2s, .tier10_cloud_sonnet_5s:
            return cadenceSeconds // cloud every tick regardless
        case .tier3_hybrid_15s:      return 60
        case .tier4_hybrid_8s:       return 60
        case .tier5_hybrid_5s:       return 45
        case .tier6_hybrid_2s:       return 30
        }
    }

    // Four-bullet capability summary for the Settings picker card.
    public var capabilityBullets: [String] {
        switch self {
        case .tier1_cloud_30s:
            return [
                "30-second reaction time",
                "Haiku-only reasoning",
                "Short glances slip through",
                "No local prefilter, every frame paid"
            ]
        case .tier2_hybrid_30s:
            return [
                "Cheapest tier, ~$45/mo under Tier 1",
                "Local prefilter skips redundant frames",
                "Sonnet escalation for deep moments (~25/day)",
                "Same feel as baseline, lowest cost"
            ]
        case .tier3_hybrid_15s:
            return [
                "15-second reaction time",
                "Catches most focus shifts fast",
                "Sonnet escalation (~30/day)",
                "Local prefilter keeps cost flat"
            ]
        case .tier4_hybrid_8s:
            return [
                "8-second reaction, feels continuous",
                "Near-zero missed context shifts",
                "40 Sonnet deep-reasoning moments/day",
                "Best value, recommended: ~$60/mo for always-on quality"
            ]
        case .tier5_hybrid_5s:
            return [
                "5-second reaction, near keystroke-aware",
                "Tracks mid-thought transitions",
                "60 Sonnet escalations/day",
                "Great for heavy coding days"
            ]
        case .tier6_hybrid_2s:
            return [
                "2-second reaction, always watching",
                "Keystroke-level awareness",
                "100 Sonnet escalations/day",
                "Overkill unless you want narration"
            ]
        case .tier7_cloud_8s:
            return [
                "8s cadence, every frame cloud-analyzed",
                "No local CPU usage",
                "4.4× more expensive than Tier 4 for marginal gains",
                "Requires constant network"
            ]
        case .tier8_cloud_5s:
            return [
                "5s cadence, every frame cloud-analyzed",
                "Continuous cloud reasoning",
                "Needs constant network",
                "Runaway-cost risk if left on overnight"
            ]
        case .tier9_cloud_2s:
            return [
                "2s cadence, every frame cloud-analyzed",
                "Maximum coverage, maximum cost",
                "Network-hungry, not suitable offline",
                "Rarely worth vs hybrid tiers"
            ]
        case .tier10_cloud_sonnet_5s:
            return [
                "Haiku reads every frame, Sonnet 4.6 for deep reasoning",
                "Deepest possible context interpretation",
                "Can narrate continuously",
                "Premium, burns budget fast"
            ]
        }
    }
}

// MARK: - Music Picking Strategy
//
// Controls how aggressively Grux should reach outside the user's Apple Music
// library when they request a song. This is a PROMPT-level routing setting -
// it changes what Claude is told to do when a request is vague or when a
// library hit misses. The tools themselves don't change behavior.
//
//   libraryFirst (default)
//       D-cascade. Claude picks a specific track (using taste + artist
//       lookup), tries the library, retries with alternates, and falls
//       back to YouTube search if nothing owned matches.
//
//   libraryOnly
//       B. Pure offline pick. Claude only plays tracks the user already owns.
//       If nothing in the library matches after a couple of tries, Grux
//       says so briefly and stops - no YouTube, no web lookup.
//
//   webFirst
//       C. Taste-first. For any vague request ("a hype song by X", "a chill
//       tune"), Claude consults Brave Search via research_web to pick a
//       specific song BEFORE touching the library. Pays the ~1.5-3s latency
//       in exchange for taste signal on artists they don't own deeply.
public enum MusicStrategy: String, Codable, CaseIterable, Identifiable {
    case libraryFirst
    case libraryOnly
    case webFirst

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .libraryFirst: return "Library-first"
        case .libraryOnly:  return "Library-only"
        case .webFirst:     return "Web-first"
        }
    }
    public var shortHelp: String {
        switch self {
        case .libraryFirst: return "Tries your library first; falls back to alternates then YouTube if nothing matches. Fast and smart - the default."
        case .libraryOnly:  return "Plays only songs you already own. No YouTube, no web lookup. Quiet failure if nothing matches."
        case .webFirst:     return "Always consults Brave Search first to pick a specific song before playing. Best for vague requests on artists you don't own deeply."
        }
    }
    // Compact directive injected into the volatile system block. Claude
    // reads this every turn and routes music requests accordingly. Kept
    // short so it doesn't blow the prompt out.
    public var promptDirective: String {
        switch self {
        case .libraryFirst:
            return "libraryFirst - play_music_track auto-cascades library → Apple Music catalog. Only call play_on_youtube if that final cascade misses."
        case .libraryOnly:
            return "libraryOnly - only play what the user owns. play_music_track's catalog fallback is disabled for you. NEVER call play_on_youtube. If library misses, tell them briefly and stop."
        case .webFirst:
            return "webFirst - for any vague request, call research_web first to pick a specific song, then call play_music_track (which itself cascades library → catalog)."
        }
    }
}

// MARK: - Config

struct GruxConfig: Codable {

    /// THE ONE SOURCE OF TRUTH FOR THE DEFAULT LOCAL MODEL.
    ///
    /// Changing the init defaults alone was not enough and review caught it:
    /// the DECODE fallbacks below were still `?? "qwen3:8b"`, so every existing
    /// install whose config predates these keys decoded straight back to the
    /// reasoning model, and two more `.isEmpty ? "qwen3:8b"` fallbacks sat in
    /// SettingsView and LocalLLM. A default spelled in five places is four
    /// places to miss.
    ///
    /// Must not be a reasoning model. Measured on Ollama's OpenAI-compatible
    /// endpoint, qwen3:8b returns EMPTY content at ordinary token budgets
    /// because the whole budget goes into its think block.
    ///
    /// STILL THE SOURCE OF TRUTH, and now also the STARTING POINT rather than the
    /// final answer. This value is one tag for every Mac, so an 8 GB laptop and a
    /// 128 GB workstation were handed the identical 3B while the Cookbook sat
    /// beside them scoring the whole catalog against real hardware and deciding
    /// nothing. `Cookbook.defaultModelID(for:userHasChosen:current:)` upgrades it
    /// once, on the first successful local discovery, and ONLY on a config still
    /// carrying this exact string. Anything else is somebody's decision and is
    /// left alone, which is the same line `migratingLocalModel` below draws.
    static let defaultLocalModel = "llama3.2:3b"

    /// Which installed model the local route should adopt, or nil to keep what
    /// is configured.
    ///
    /// THE DEFAULT IS A NAME, NOT A GUARANTEE. `defaultLocalModel` is a tag this
    /// app ships as a sensible starting point, and nothing makes it true of a
    /// particular Mac. Measured on the Mac Mini 2026-08-30: onboarding's local
    /// path completed happily against a server holding `qwen3:8b` and
    /// `qwen2.5:7b` while the config still said `llama3.2:3b`, so the first
    /// message a person sent came back
    /// `{"error":"model 'llama3.2:3b' not found"}`. Reachability was checked,
    /// then availability was checked, and the thing nobody checked was whether
    /// the model being ASKED FOR was one of the ones that were there.
    ///
    /// Prefers the headline pick when it happens to be installed, because that
    /// is the model this machine was scored for, and otherwise takes whatever is
    /// actually present over a name that is not.
    /// INSTALLED IS NOT THE SAME AS USABLE, and the first version of this
    /// adopted `qwen3:8b` on the Mac Mini for the sole reason that it was there.
    /// That is the one model this app has MEASURED as broken on the path it
    /// drives, and `migratingLocalModel` below exists to move people off it, so
    /// the write was silently undone on the next decode and the chat footer went
    /// on naming a model the config no longer held. A fix that the app's own
    /// migration has to reverse is not a fix.
    static func installedModelToAdopt(configured: String,
                                      installed: [String],
                                      headline: String?) -> String? {
        let usable = usableLocalModels(installed)
        guard !usable.isEmpty else { return nil }
        if usable.contains(configured) { return nil }
        if let headline, usable.contains(headline) { return headline }
        return usable.first
    }

    /// The installed models Grux can actually drive.
    ///
    /// A server holding nothing but the superseded model is, for Grux's
    /// purposes, a server holding nothing: the caller treats an empty result as
    /// "fetch one" rather than as "settle for that".
    static func usableLocalModels(_ installed: [String]) -> [String] {
        installed.filter { $0 != supersededLocalModel }
    }

    /// The local model Grux USED to ship as its default, and which measurably
    /// does not work on the path Grux drives it through: on Ollama's
    /// OpenAI-compatible endpoint it returns EMPTY content at ordinary token
    /// budgets because the whole budget goes into its think block.
    ///
    /// Changing `defaultLocalModel` alone helped nobody who already had Grux,
    /// because config.json stores the value explicitly. Every existing install
    /// kept this string on both keys, which is exactly why a local "hi" still
    /// took the better part of a minute after the "fix" shipped.
    ///
    /// Migrated on decode, and ONLY this exact string. Those users never chose
    /// it, it was assigned to them. Anyone who typed a different model, even a
    /// bigger reasoning one, keeps it: silently overriding a real choice would
    /// be a worse bug than the one this closes.
    static let supersededLocalModel = "qwen3:8b"

    /// Undoes an assignment, never a decision.
    static func migratingLocalModel(_ stored: String) -> String {
        stored == supersededLocalModel ? defaultLocalModel : stored
    }
    var anthropicApiKey: String
    var model: String
    var captureIntervalSeconds: Int
    var driftThreshold: Int
    var autoPromoteDetectedTask: Bool
    var notificationsEnabled: Bool
    var screenAnalysisEnabled: Bool
    var launchAtLogin: Bool
    var snoozeMinutes: Int
    var activeHoursStart: Int
    var activeHoursEnd: Int
    var wakeWordEnabled: Bool
    var autoSendOnWake: Bool
    var speakRepliesAloud: Bool
    var elevenLabsApiKey: String
    var elevenLabsVoiceId: String
    var elevenLabsModelId: String
    var useElevenLabs: Bool
    var bargeInEnabled: Bool
    var voicePlaybackRate: Double  // 0.75 = slower, 1.0 = natural, 1.5 = default, 2.0 = max
    var ambientEnabled: Bool
    var ambientAutoPromoteActions: Bool
    var ambientCoachEnabled: Bool
    var ambientHUDVisible: Bool
    var ambientMode: AmbientMode
    var dailyRecapHour: Int         // 0..23, local time. Default 22 (10pm).
    var energyRecapHour: Int        // 0..23, local time. Default 20 (8pm). Fires the daily energy + focus recap, distinct from the 10pm task-focused dailyRecap.
    var stuckThresholdMinutes: Int  // silence+idle minutes before stuck nudge fires. Default 8.
    var glowOverlayEnabled: Bool    // Ambient animated border on distracted/focused transitions.
    var focusCooldownMinutes: Int   // Min minutes between red glow + drift notification while in the same app.
    var focusVisionModel: String    // Model used for vision analysis (may differ from chat `model`).
    var currentMode: GruxMode       // Chill / Normal / Grind / Sheesh - affects reply tone, length, nudge cadence.
    var tier: GruxTier              // Intelligence tier - controls cadence + local-prescreen + escalation.
    var memoryEnabled: Bool         // Persistent semantic memory across chats / events / ambient.
    var webResearchEnabled: Bool    // Real-time web fetch + summarize (vs opening a browser tab).
    var premiumNoiseCancellation: Bool // Apple hardware voice processing (AEC + NS + AGC) on dictation engine.
    var musicStrategy: MusicStrategy   // How Grux should route ambiguous music requests.
    var developerTeamId: String        // Apple Developer Team ID for iOS device signing. Empty = simulator only.
    var developerBundlePrefix: String  // Reverse-DNS prefix for iOS bundle IDs scaffolded by ios_scaffold.
    // Orb / Glow / HUD overlay - parity-plus additions (2026-04-24). All
    // default on so the visual identity is visible immediately after
    // upgrade. Each can be toggled from Settings → Orb & overlays.
    var orbAnywhereEnabled: Bool       // Floating, always-on-top Grux orb on the desktop.
    var orbAnywhereAudioReactive: Bool // Modulate the floating orb by live mic + TTS level.
    var stageEnabled: Bool             // Expose the cinematic `grux_orb_stage` tool to Claude.
    var audioReactiveGlow: Bool        // Pulse the window-edge glow with TTS output level while Grux speaks.
    var crashSafeAudioEnabled: Bool    // Meeting-capture WAL: rolling 90s PCM buffer on disk so a crash doesn't lose pre-transcription audio.
    // Grux Phone companion: the WS listener the phone connects to over the local
    // network. Defaults OFF because it costs a listening socket for a feature most
    // installs never pair. Gates every call to PhoneReceiverService.start(), which
    // means both of them, at launch and when the Pair iPhone window opens. Adding
    // a third caller without this guard is how the toggle starts lying. Nothing
    // fronts the listener, so it gates no child process and no public ingress; see
    // CloudflareTunnelManager.
    var phoneCompanionEnabled: Bool
    /// Lets Grux click, type, and scroll on the operator's behalf via synthetic
    /// HID events + the macOS Accessibility API (see ScreenControlEngine). OFF
    /// by default: it can drive ANY app, so the operator turns it on
    /// deliberately in Settings, and that toggle is the consent gate.
    var screenControlEnabled: Bool
    /// Opens a token-guarded HTTP listener on the local network so a companion
    /// service can PUSH digests in. OFF by default: an install that has no such
    /// service must not sit on a listening socket it never uses.
    var prInboxEnabled: Bool
    /// Sweeps App Store Connect for the state of your apps, using an ASC API key
    /// you supply. OFF by default: it scans the filesystem for a credential file
    /// and calls Apple on every launch, which an install with no iOS apps should
    /// never do.
    var ascMonitorEnabled: Bool
    /// Sweeps your registrar every 24 hours, and SPEAKS ALOUD plus posts a banner when a
    /// domain crosses the 30-day line. OFF by default for the same reason as the App Store
    /// Connect monitor, which sits nine lines above it in the launch path and was gated
    /// while this was not: it adopts a credential left in ~/.grux/godaddy-creds.json or the
    /// environment and calls GoDaddy on the strength of it. The Empire dashboard's manual
    /// sweep keeps the capability reachable while this is off.
    var domainMonitorEnabled: Bool
    /// Drops Apple Music to 50% while Grux talks. OFF by default because turning it on is
    /// what sends the first Apple event to Music, and macOS answers that with "Grux wants
    /// access to control Music". Nothing in the app said Grux touches Music at all.
    var musicDuckingEnabled: Bool
    /// Watches which app you bring to the front and offers to record when it is FaceTime,
    /// Zoom, Teams or Webex. OFF by default: it put a floating overlay and a menu bar
    /// takeover in front of somebody who had acknowledged nothing and might never intend to
    /// record a call. Recording itself was always gated; the OFFER was not.
    var meetingAutoDetectEnabled: Bool
    /// The nightly 4 AM pass that reads the day's ambient transcript and writes dossiers
    /// about OTHER PEOPLE, by name, to ~/.grux/people. OFF by default, and it is the one
    /// flag here where the default is not really a question: nobody has ever been told this
    /// exists. No feature row, no contract step, no Settings row, and stop() had no caller.
    var personMemoryEnabled: Bool
    /// The nightly 3 AM pass that reads the same transcript and extracts decisions to
    /// ~/.grux/decisions. Same shape, same reason, same default.
    var decisionLogEnabled: Bool
    /// The MCP control socket at ~/.grux/mcp.sock, 0600, no TCP port. ON by default,
    /// because it is how the `grux` command line talks to the app and turning it off
    /// silences that. The point of the flag is that the answer to "can this be turned off"
    /// is now yes: any process running as you can speak MCP to it, and one of the tools it
    /// carries activates Grux and puts a permission dialog on your screen.
    var controlSocketEnabled: Bool
    /// The self-upgrade loop: a 60 second governor tick that schedules a nightly pass,
    /// harvests signals and spends model tokens on the first night of any install. OFF by
    /// default, which is not a new decision: `docs/contract.md` has declared
    /// `grux.foundry.enabled` as "CR-20, the self-upgrade loop, off by default" the whole
    /// time, and nothing implemented it, so it ran unconditionally on every launch. This is
    /// the flag the contract was always describing.
    var foundryEnabled: Bool
    /// Whether the 07:00 and 21:00 briefings SPEAK. OFF by default and separate from
    /// `speakRepliesAloud` on purpose.
    ///
    /// The feature gate on the briefing asks whether Jax HQ is ready, which means "is there a
    /// mail account". That is not the same question as "may Grux talk to you unprompted twice
    /// a day", and `endpoint.imap` is the LAST step of the connections flow, so the first
    /// person to connect an inbox would have got a talking Mac at 07:00 having never been
    /// asked about briefings at all. Narrower than the original bug and the same surprise one
    /// configuration step later.
    var spokenBriefingsEnabled: Bool
    // One-time acknowledgement that recording a call captures everyone on it. Gates
    // MeetingCaptureService.start() at the choke point, so every entry point is covered:
    // the menu bar, the Meetings tab, the panel, the keyboard shortcut, and the
    // model-callable start_meeting_capture tool.
    var recordingConsentAcknowledged: Bool
    // The same one-time acknowledgement, for the two features that hold the
    // microphone continuously. Separate flags because the two make DIFFERENT
    // promises: ambient transcribes on this Mac, the wake word can send short
    // audio to Apple. One shared flag would have a user agree to the second by
    // answering the first.
    //
    // Gated at the choke point, `AmbientState.enable()` and
    // `WakeWordListener.enable()`, so the menu bar row, the ambient HUD pill
    // and Settings are all covered by one gate rather than three.
    var ambientConsentAcknowledged: Bool
    var wakeWordConsentAcknowledged: Bool
    // Who is using this copy of Grux. Empty until they say so: Grux does not
    // know a new user's name and must not guess one. Read through UserIdentity,
    // never directly, so the empty case is handled in one place.
    var userName: String
    // What Grux calls itself. The source is MIT, so a rename is the user's
    // right; almost nobody will, hence the default.
    var assistantName: String
    // Local Qwen ambient brain. When on, AmbientHourlySummarizer,
    // WorkdayLogAssembler, and FolderClassifier route through the local-LLM
    // proxy at `localLLMEndpoint` (Ollama-backed Qwen3) instead of the Anthropic
    // API. Claude is still used as fallback if that endpoint is unreachable.
    var useLocalQwenForAmbient: Bool
    // Empty by default, which every consumer already reads as "not configured"
    // and degrades to the cloud path. It used to default to one developer's own
    // machine on his own private tailnet, so a stranger's install shipped
    // pointing at a host it could never resolve.
    var localLLMEndpoint: String
    var localLLMModel: String          // Default: qwen3:8b
    // Phase 1 (Model Foundation) - offline chat routing. When offlineMode is on
    // AND a local OpenAI-compatible server (Ollama) was discovered, ChatService
    // routes the turn through OpenAICompatBackend(baseURL: ollamaBaseURL) using
    // `offlineLLMModel`. All three PERSIST, so the choice survives a relaunch.
    // Safety: ModelRegistry.active() falls back to Anthropic when no local
    // server is discovered, so a persisted offlineMode=true with no Ollama
    // running degrades to cloud rather than stranding the user offline.
    var offlineLLMModel: String        // Default: qwen3:8b - the local model id passed to /v1/chat/completions (good tool-calling for offline chat)
    var ollamaBaseURL: String          // Default: http://localhost:11434 - OpenAI-compat base (Ollama / vLLM / llama.cpp)
    var offlineMode: Bool              // Default: false - persisted offline switch, mirrored from AppState.offlineMode
    // Self-hosted social tuning dashboard embedded by the Social tab. EMPTY by
    // default: the dashboard is the user's own service, not something Grux
    // ships, so an unconfigured install renders a "not configured" panel rather
    // than reaching for a host it cannot resolve.
    var socialDashboardURL: String
    // Capture privacy. Apps and window titles Grux refuses to photograph. See
    // CapturePrivacy.swift for what these do and why the defaults are narrow.
    // Both are user-editable; both default to the built-in credential lists.
    var captureExcludedBundleIds: [String]
    var captureExcludedTitlePatterns: [String]

    enum CodingKeys: String, CodingKey {
        case anthropicApiKey, model, captureIntervalSeconds, driftThreshold
        case autoPromoteDetectedTask, notificationsEnabled, screenAnalysisEnabled
        case launchAtLogin, snoozeMinutes, activeHoursStart, activeHoursEnd
        case wakeWordEnabled, autoSendOnWake, speakRepliesAloud
        case elevenLabsApiKey, elevenLabsVoiceId, elevenLabsModelId, useElevenLabs, bargeInEnabled
        case voicePlaybackRate
        case ambientEnabled, ambientAutoPromoteActions, ambientCoachEnabled, ambientHUDVisible
        case ambientMode
        case dailyRecapHour
        case energyRecapHour
        case stuckThresholdMinutes
        case glowOverlayEnabled
        case focusCooldownMinutes
        case focusVisionModel
        case currentMode
        case tier
        case memoryEnabled
        case webResearchEnabled
        case premiumNoiseCancellation
        case musicStrategy
        case developerTeamId
        case developerBundlePrefix
        case orbAnywhereEnabled
        case orbAnywhereAudioReactive
        case stageEnabled
        case audioReactiveGlow
        case crashSafeAudioEnabled
        case phoneCompanionEnabled, prInboxEnabled, ascMonitorEnabled
        case domainMonitorEnabled, musicDuckingEnabled, meetingAutoDetectEnabled
        case personMemoryEnabled, decisionLogEnabled, controlSocketEnabled
        case foundryEnabled, spokenBriefingsEnabled
        case screenControlEnabled
        case recordingConsentAcknowledged
        case ambientConsentAcknowledged, wakeWordConsentAcknowledged
        case userName, assistantName
        case useLocalQwenForAmbient
        case localLLMEndpoint
        case localLLMModel
        case offlineLLMModel
        case ollamaBaseURL
        case offlineMode
        case socialDashboardURL
        case captureExcludedBundleIds
        case captureExcludedTitlePatterns
    }

// (AmbientMode moved to top-level - see declaration above GruxConfig.)

    init(anthropicApiKey: String, model: String, captureIntervalSeconds: Int, driftThreshold: Int,
         autoPromoteDetectedTask: Bool, notificationsEnabled: Bool, screenAnalysisEnabled: Bool,
         launchAtLogin: Bool, snoozeMinutes: Int, activeHoursStart: Int, activeHoursEnd: Int,
         wakeWordEnabled: Bool = false, autoSendOnWake: Bool = true, speakRepliesAloud: Bool = true,
         elevenLabsApiKey: String = "",
         elevenLabsVoiceId: String = "RPJ8nnVtuTgG8McXwW6M",
         elevenLabsModelId: String = "eleven_turbo_v2_5",
         useElevenLabs: Bool = true,
         bargeInEnabled: Bool = true,
         voicePlaybackRate: Double = 1.5,
         ambientEnabled: Bool = false,
         ambientAutoPromoteActions: Bool = false,
         ambientCoachEnabled: Bool = true,
         ambientHUDVisible: Bool = true,
         ambientMode: AmbientMode = .wake,
         dailyRecapHour: Int = 22,
         energyRecapHour: Int = 20,
         stuckThresholdMinutes: Int = 8,
         glowOverlayEnabled: Bool = true,
         focusCooldownMinutes: Int = 10,
         focusVisionModel: String = "claude-haiku-4-5-20251001",
         currentMode: GruxMode = .normal,
         tier: GruxTier = .tier4_hybrid_8s,
         memoryEnabled: Bool = true,
         webResearchEnabled: Bool = true,
         premiumNoiseCancellation: Bool = true,
         musicStrategy: MusicStrategy = .libraryFirst,
         developerTeamId: String = "",
         developerBundlePrefix: String = "com.example",
         orbAnywhereEnabled: Bool = true,
         orbAnywhereAudioReactive: Bool = true,
         stageEnabled: Bool = true,
         audioReactiveGlow: Bool = true,
         crashSafeAudioEnabled: Bool = true,
         // OFF by default: an unpaired install should not sit on a listening
         // socket. Turn it on in Settings to pair a phone.
         phoneCompanionEnabled: Bool = false,
         screenControlEnabled: Bool = false,
         prInboxEnabled: Bool = false,
         ascMonitorEnabled: Bool = false,
         domainMonitorEnabled: Bool = false,
         musicDuckingEnabled: Bool = false,
         meetingAutoDetectEnabled: Bool = false,
         personMemoryEnabled: Bool = false,
         decisionLogEnabled: Bool = false,
         controlSocketEnabled: Bool = true,
         foundryEnabled: Bool = false,
         spokenBriefingsEnabled: Bool = false,
         recordingConsentAcknowledged: Bool = false,
         ambientConsentAcknowledged: Bool = false,
         wakeWordConsentAcknowledged: Bool = false,
         userName: String = "",
         assistantName: String = "Jax",
         useLocalQwenForAmbient: Bool = false,
         localLLMEndpoint: String = "",
         localLLMModel: String = GruxConfig.defaultLocalModel,
         offlineLLMModel: String = GruxConfig.defaultLocalModel,
         ollamaBaseURL: String = "http://localhost:11434",
         offlineMode: Bool = false,
         socialDashboardURL: String = "",
         captureExcludedBundleIds: [String] = CapturePrivacy.defaultExcludedBundleIds,
         captureExcludedTitlePatterns: [String] = CapturePrivacy.defaultExcludedTitlePatterns) {
        self.anthropicApiKey = anthropicApiKey
        self.model = model
        self.captureIntervalSeconds = captureIntervalSeconds
        self.driftThreshold = driftThreshold
        self.autoPromoteDetectedTask = autoPromoteDetectedTask
        self.notificationsEnabled = notificationsEnabled
        self.screenAnalysisEnabled = screenAnalysisEnabled
        self.launchAtLogin = launchAtLogin
        self.snoozeMinutes = snoozeMinutes
        self.activeHoursStart = activeHoursStart
        self.activeHoursEnd = activeHoursEnd
        self.wakeWordEnabled = wakeWordEnabled
        self.autoSendOnWake = autoSendOnWake
        self.speakRepliesAloud = speakRepliesAloud
        self.elevenLabsApiKey = elevenLabsApiKey
        self.elevenLabsVoiceId = elevenLabsVoiceId
        self.elevenLabsModelId = elevenLabsModelId
        self.useElevenLabs = useElevenLabs
        self.bargeInEnabled = bargeInEnabled
        self.voicePlaybackRate = voicePlaybackRate
        self.ambientEnabled = ambientEnabled
        self.ambientAutoPromoteActions = ambientAutoPromoteActions
        self.ambientCoachEnabled = ambientCoachEnabled
        self.ambientHUDVisible = ambientHUDVisible
        self.ambientMode = ambientMode
        self.dailyRecapHour = dailyRecapHour
        self.energyRecapHour = energyRecapHour
        self.stuckThresholdMinutes = stuckThresholdMinutes
        self.glowOverlayEnabled = glowOverlayEnabled
        self.focusCooldownMinutes = focusCooldownMinutes
        self.focusVisionModel = focusVisionModel
        self.currentMode = currentMode
        self.tier = tier
        self.memoryEnabled = memoryEnabled
        self.webResearchEnabled = webResearchEnabled
        self.premiumNoiseCancellation = premiumNoiseCancellation
        self.musicStrategy = musicStrategy
        self.developerTeamId = developerTeamId
        self.developerBundlePrefix = developerBundlePrefix
        self.orbAnywhereEnabled = orbAnywhereEnabled
        self.orbAnywhereAudioReactive = orbAnywhereAudioReactive
        self.stageEnabled = stageEnabled
        self.audioReactiveGlow = audioReactiveGlow
        self.crashSafeAudioEnabled = crashSafeAudioEnabled
        self.phoneCompanionEnabled = phoneCompanionEnabled
        self.screenControlEnabled = screenControlEnabled
        self.prInboxEnabled = prInboxEnabled
        self.ascMonitorEnabled = ascMonitorEnabled
        self.domainMonitorEnabled = domainMonitorEnabled
        self.musicDuckingEnabled = musicDuckingEnabled
        self.meetingAutoDetectEnabled = meetingAutoDetectEnabled
        self.personMemoryEnabled = personMemoryEnabled
        self.decisionLogEnabled = decisionLogEnabled
        self.controlSocketEnabled = controlSocketEnabled
        self.foundryEnabled = foundryEnabled
        self.spokenBriefingsEnabled = spokenBriefingsEnabled
        self.recordingConsentAcknowledged = recordingConsentAcknowledged
        self.ambientConsentAcknowledged = ambientConsentAcknowledged
        self.wakeWordConsentAcknowledged = wakeWordConsentAcknowledged
        self.userName = userName
        self.assistantName = assistantName
        self.useLocalQwenForAmbient = useLocalQwenForAmbient
        self.localLLMEndpoint = localLLMEndpoint
        self.localLLMModel = localLLMModel
        self.offlineLLMModel = offlineLLMModel
        self.ollamaBaseURL = ollamaBaseURL
        self.offlineMode = offlineMode
        self.socialDashboardURL = socialDashboardURL
        self.captureExcludedBundleIds = captureExcludedBundleIds
        self.captureExcludedTitlePatterns = captureExcludedTitlePatterns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anthropicApiKey = try c.decode(String.self, forKey: .anthropicApiKey)
        model = try c.decode(String.self, forKey: .model)
        captureIntervalSeconds = try c.decode(Int.self, forKey: .captureIntervalSeconds)
        driftThreshold = try c.decode(Int.self, forKey: .driftThreshold)
        autoPromoteDetectedTask = try c.decode(Bool.self, forKey: .autoPromoteDetectedTask)
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        screenAnalysisEnabled = try c.decode(Bool.self, forKey: .screenAnalysisEnabled)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)
        snoozeMinutes = try c.decode(Int.self, forKey: .snoozeMinutes)
        activeHoursStart = try c.decode(Int.self, forKey: .activeHoursStart)
        activeHoursEnd = try c.decode(Int.self, forKey: .activeHoursEnd)
        // Ships OFF, like ambientEnabled. It was the only always-on
        // feature that shipped enabled, and it is the most expensive one in the app: it
        // holds the microphone open and runs SFSpeechRecognizer continuously, measured at
        // roughly 22% of a core on an idle M-series laptop, forever, on first launch.
        // `requiresOnDeviceRecognition` is false on that path, so it also streamed audio
        // off the machine before the user had asked for anything.
        //
        // decodeIfPresent, so an existing install keeps whatever it already had. This
        // changes what a NEW user gets, which is the whole point.
        wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? false
        autoSendOnWake = try c.decodeIfPresent(Bool.self, forKey: .autoSendOnWake) ?? true
        speakRepliesAloud = try c.decodeIfPresent(Bool.self, forKey: .speakRepliesAloud) ?? true
        elevenLabsApiKey = try c.decodeIfPresent(String.self, forKey: .elevenLabsApiKey) ?? ""
        elevenLabsVoiceId = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceId) ?? "RPJ8nnVtuTgG8McXwW6M"
        elevenLabsModelId = try c.decodeIfPresent(String.self, forKey: .elevenLabsModelId) ?? "eleven_turbo_v2_5"
        useElevenLabs = try c.decodeIfPresent(Bool.self, forKey: .useElevenLabs) ?? true
        bargeInEnabled = try c.decodeIfPresent(Bool.self, forKey: .bargeInEnabled) ?? true
        voicePlaybackRate = try c.decodeIfPresent(Double.self, forKey: .voicePlaybackRate) ?? 1.5
        ambientEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientEnabled) ?? false
        ambientAutoPromoteActions = try c.decodeIfPresent(Bool.self, forKey: .ambientAutoPromoteActions) ?? false
        ambientCoachEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientCoachEnabled) ?? true
        ambientHUDVisible = try c.decodeIfPresent(Bool.self, forKey: .ambientHUDVisible) ?? true
        ambientMode = try c.decodeIfPresent(AmbientMode.self, forKey: .ambientMode) ?? .wake
        dailyRecapHour = try c.decodeIfPresent(Int.self, forKey: .dailyRecapHour) ?? 22
        energyRecapHour = try c.decodeIfPresent(Int.self, forKey: .energyRecapHour) ?? 20
        stuckThresholdMinutes = try c.decodeIfPresent(Int.self, forKey: .stuckThresholdMinutes) ?? 8
        glowOverlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .glowOverlayEnabled) ?? true
        focusCooldownMinutes = try c.decodeIfPresent(Int.self, forKey: .focusCooldownMinutes) ?? 10
        focusVisionModel = try c.decodeIfPresent(String.self, forKey: .focusVisionModel) ?? "claude-haiku-4-5-20251001"
        currentMode = try c.decodeIfPresent(GruxMode.self, forKey: .currentMode) ?? .normal
        tier = try c.decodeIfPresent(GruxTier.self, forKey: .tier) ?? .tier4_hybrid_8s
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        webResearchEnabled = try c.decodeIfPresent(Bool.self, forKey: .webResearchEnabled) ?? true
        premiumNoiseCancellation = try c.decodeIfPresent(Bool.self, forKey: .premiumNoiseCancellation) ?? true
        musicStrategy = try c.decodeIfPresent(MusicStrategy.self, forKey: .musicStrategy) ?? .libraryFirst
        developerTeamId = try c.decodeIfPresent(String.self, forKey: .developerTeamId) ?? ""
        developerBundlePrefix = try c.decodeIfPresent(String.self, forKey: .developerBundlePrefix) ?? "com.example"
        orbAnywhereEnabled = try c.decodeIfPresent(Bool.self, forKey: .orbAnywhereEnabled) ?? true
        orbAnywhereAudioReactive = try c.decodeIfPresent(Bool.self, forKey: .orbAnywhereAudioReactive) ?? true
        stageEnabled = try c.decodeIfPresent(Bool.self, forKey: .stageEnabled) ?? true
        audioReactiveGlow = try c.decodeIfPresent(Bool.self, forKey: .audioReactiveGlow) ?? true
        crashSafeAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .crashSafeAudioEnabled) ?? true
        // Absent key means a config written before the phone companion was
        // gated, when the receiver and its tunnel started unconditionally on
        // every launch. It decodes to OFF rather than inheriting that old
        // behaviour: an install that never paired a phone should not silently
        // start listening after upgrading.
        phoneCompanionEnabled = try c.decodeIfPresent(Bool.self, forKey: .phoneCompanionEnabled) ?? false
        screenControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenControlEnabled) ?? false
        prInboxEnabled = try c.decodeIfPresent(Bool.self, forKey: .prInboxEnabled) ?? false
        ascMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .ascMonitorEnabled) ?? false
        domainMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .domainMonitorEnabled) ?? false
        musicDuckingEnabled = try c.decodeIfPresent(Bool.self, forKey: .musicDuckingEnabled) ?? false
        meetingAutoDetectEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingAutoDetectEnabled) ?? false
        personMemoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .personMemoryEnabled) ?? false
        decisionLogEnabled = try c.decodeIfPresent(Bool.self, forKey: .decisionLogEnabled) ?? false
        // The only ON default in this group, so an existing install keeps its CLI.
        controlSocketEnabled = try c.decodeIfPresent(Bool.self, forKey: .controlSocketEnabled) ?? true
        foundryEnabled = try c.decodeIfPresent(Bool.self, forKey: .foundryEnabled) ?? false
        spokenBriefingsEnabled = try c.decodeIfPresent(Bool.self, forKey: .spokenBriefingsEnabled) ?? false
        // Defaults false for an existing install too, deliberately. Nobody who already has
        // Grux has been asked this question, so the first recording after this ships should
        // ask them once rather than assume an answer they never gave.
        recordingConsentAcknowledged = try c.decodeIfPresent(
            Bool.self, forKey: .recordingConsentAcknowledged) ?? false
        // Same reasoning, and the same answer for an existing install: somebody
        // already running ambient has never been told it holds the microphone
        // the whole time, so the next time they turn it on, they get told once.
        ambientConsentAcknowledged = try c.decodeIfPresent(
            Bool.self, forKey: .ambientConsentAcknowledged) ?? false
        wakeWordConsentAcknowledged = try c.decodeIfPresent(
            Bool.self, forKey: .wakeWordConsentAcknowledged) ?? false
        // decodeIfPresent, so an existing install is untouched. A new install
        // gets an empty name, which is what makes the onboarding gate fire for
        // genuinely new users only.
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        assistantName = try c.decodeIfPresent(String.self, forKey: .assistantName) ?? "Jax"
        useLocalQwenForAmbient = try c.decodeIfPresent(Bool.self, forKey: .useLocalQwenForAmbient) ?? false
        localLLMEndpoint = try c.decodeIfPresent(String.self, forKey: .localLLMEndpoint) ?? ""
        localLLMModel = GruxConfig.migratingLocalModel(try c.decodeIfPresent(String.self, forKey: .localLLMModel) ?? GruxConfig.defaultLocalModel)
        offlineLLMModel = GruxConfig.migratingLocalModel(try c.decodeIfPresent(String.self, forKey: .offlineLLMModel) ?? GruxConfig.defaultLocalModel)
        ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434"
        offlineMode = try c.decodeIfPresent(Bool.self, forKey: .offlineMode) ?? false
        socialDashboardURL = try c.decodeIfPresent(String.self, forKey: .socialDashboardURL) ?? ""
        // An absent list means a config written before capture privacy existed,
        // so it inherits the built-in defaults. An EMPTY list is a deliberate
        // user choice to exclude nothing and is preserved as written, which is
        // why this is decodeIfPresent and not a nil-or-empty coalesce.
        captureExcludedBundleIds = try c.decodeIfPresent([String].self, forKey: .captureExcludedBundleIds)
            ?? CapturePrivacy.defaultExcludedBundleIds
        captureExcludedTitlePatterns = try c.decodeIfPresent([String].self, forKey: .captureExcludedTitlePatterns)
            ?? CapturePrivacy.defaultExcludedTitlePatterns
    }

    static let `default` = GruxConfig(
        anthropicApiKey: "",
        model: "claude-haiku-4-5-20251001",
        captureIntervalSeconds: 30,
        driftThreshold: 2,
        autoPromoteDetectedTask: true,
        notificationsEnabled: true,
        screenAnalysisEnabled: true,
        launchAtLogin: false,
        snoozeMinutes: 15,
        activeHoursStart: 6,
        activeHoursEnd: 23,
        speakRepliesAloud: true
    )
}

// ElevenLabs voice catalog entry, fetched lazily for Settings picker.
struct ElevenLabsVoice: Identifiable, Codable, Hashable {
    let voiceId: String
    let name: String
    let category: String
    let description: String?
    var id: String { voiceId }
}

// Curated voices selectable even without an ElevenLabs API key or before the
// voice list has loaded. The Settings picker merges these with whatever the
// /v1/voices endpoint returns so they're always present.
// Shared-library voice IDs work directly with the TTS endpoint - no
// "add to workspace" step required.
//
// Every entry must be a SHARED-LIBRARY voice. Two personal voice clones of the
// original developer shipped here as "featured", which meant a stranger's
// install offered a real person's cloned voice as a menu option. A voice clone
// is that person's likeness, not a preset.
enum FeaturedVoices {
    static let all: [ElevenLabsVoice] = [
        ElevenLabsVoice(
            voiceId: "RPJ8nnVtuTgG8McXwW6M",
            name: "Grux (default)",
            category: "featured",
            description: "Grux's signature gravelly coach voice."
        ),
        ElevenLabsVoice(
            voiceId: "nPczCjzI2devNBz1zQrb",
            name: "Brian",
            category: "featured",
            description: "Warm, confident American male - neutral baseline."
        ),
        ElevenLabsVoice(
            voiceId: "NoLUBf40dkvyOmP4uxfh",
            name: "Jarvis",
            category: "featured",
            description: "Iron Man's AI butler - polished British, measured, cinematic."
        )
    ]
}
