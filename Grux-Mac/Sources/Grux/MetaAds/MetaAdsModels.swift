import Foundation

// Power-tool DATA MODEL for the Meta Ads oversight cockpit. These structs back
// the active-ad fleet rows, the attention queue, the brand forecast, anomalies,
// engine-proposed campaigns, the Bayesian confidence readout, the lineage-tree
// visualizer, the per-brand leaderboard, and the empire roll-up. They are the
// authoritative contract for every component-phase view (see POWERTOOL_BLUEPRINT.md
// section 1). The existing small models (MetaAdsSnapshot, MetaAdsBrand, KPIs,
// pacing, families, journal) stay in MetaAdsSnapshot.swift; this file only adds
// the new types plus the optional arrays they ride on.
//
// House style, matching MetaAdsSnapshot.swift exactly:
//   * custom CodingKeys, snake_case primary + camel fallbacks where useful
//   * lenient init(from:) with decodeIfPresent + safe defaults so an OLDER
//     snapshot that lacks any of these keys still decodes cleanly (never throws)
//   * explicit encode(to:) when custom CodingKeys block Encodable synthesis
//   * sensible memberwise init, Equatable, Identifiable where the UI lists it
// Money in CENTS (Int), ratios as Double. SIMULATE/OBSERVE posture throughout:
// nothing spends while a brand's ad account stays act_PLACEHOLDER. Zero em/en
// dashes; dollars as $N.

// MARK: - Shared status / signal enums

// Ad lifecycle status as the fleet table and creative gallery render it. Lenient
// engine mapping so unexpected engine spellings never drop a row.
enum AdStatus: String, Codable, Equatable, CaseIterable {
    case learning, winner, contender, killing, paused

    // Map an engine status string (any case) to a case. testing -> contender,
    // scaling -> winner, archived/killed -> killing, default contender.
    init(engine raw: String?) {
        switch (raw ?? "").lowercased() {
        case "learning", "do_not_judge": self = .learning
        case "winner", "scaling", "scale": self = .winner
        case "killing", "killed", "archived", "kill": self = .killing
        case "paused", "pause": self = .paused
        case "testing", "contender": self = .contender
        default: self = .contender
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = AdStatus(engine: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// Creative fatigue level, derived engine-side from frequency.
enum FatigueLevel: String, Codable, Equatable { case ok, watch, fatigued

    init(engine raw: String?) {
        switch (raw ?? "").lowercased() {
        case "watch": self = .watch
        case "fatigued", "fatigue": self = .fatigued
        default: self = .ok
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = FatigueLevel(engine: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// The decisions.py typed intent per node, normalized for the UI.
enum EngineIntent: String, Codable, Equatable, CaseIterable {
    case hold, scale, kill, spawn, promote

    init(engine raw: String?) {
        switch (raw ?? "").lowercased() {
        case "scale", "scale_up": self = .scale
        case "kill", "killed": self = .kill
        case "spawn", "branch": self = .spawn
        case "promote", "promote_winner", "winner": self = .promote
        default: self = .hold
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = EngineIntent(engine: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - TargetingSummary (the engine-crafted targeting the user verifies)

struct TargetingSummary: Codable, Equatable {
    var locations: [String]        // person-location: ["US", "CA"]
    var ageMin: Int?
    var ageMax: Int?
    var genders: [String]          // ["all"] | ["women"]
    var devices: [String]          // ["mobile","desktop"]
    var placements: [String]       // ["feed","reels","stories"]
    var dayParting: [String]       // ["18:00-23:00"]
    var interests: [String]        // audience interest labels
    var advantageAudience: Bool?   // Meta Advantage+
    var summaryLine: String?       // engine one-liner of the whole targeting

    enum CodingKeys: String, CodingKey {
        case locations
        case ageMin = "age_min"
        case ageMax = "age_max"
        case genders, devices, placements
        case dayParting = "day_parting"
        case interests
        case advantageAudience = "advantage_audience"
        case summaryLine = "summary_line"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locations = (try? c.decodeIfPresent([String].self, forKey: .locations) ?? nil) ?? []
        ageMin = try? c.decodeIfPresent(Int.self, forKey: .ageMin)
        ageMax = try? c.decodeIfPresent(Int.self, forKey: .ageMax)
        genders = (try? c.decodeIfPresent([String].self, forKey: .genders) ?? nil) ?? []
        devices = (try? c.decodeIfPresent([String].self, forKey: .devices) ?? nil) ?? []
        placements = (try? c.decodeIfPresent([String].self, forKey: .placements) ?? nil) ?? []
        dayParting = (try? c.decodeIfPresent([String].self, forKey: .dayParting) ?? nil) ?? []
        interests = (try? c.decodeIfPresent([String].self, forKey: .interests) ?? nil) ?? []
        advantageAudience = try? c.decodeIfPresent(Bool.self, forKey: .advantageAudience)
        summaryLine = try? c.decodeIfPresent(String.self, forKey: .summaryLine)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(locations, forKey: .locations)
        try c.encodeIfPresent(ageMin, forKey: .ageMin)
        try c.encodeIfPresent(ageMax, forKey: .ageMax)
        try c.encode(genders, forKey: .genders)
        try c.encode(devices, forKey: .devices)
        try c.encode(placements, forKey: .placements)
        try c.encode(dayParting, forKey: .dayParting)
        try c.encode(interests, forKey: .interests)
        try c.encodeIfPresent(advantageAudience, forKey: .advantageAudience)
        try c.encodeIfPresent(summaryLine, forKey: .summaryLine)
    }

    init(locations: [String] = [],
         ageMin: Int? = nil,
         ageMax: Int? = nil,
         genders: [String] = [],
         devices: [String] = [],
         placements: [String] = [],
         dayParting: [String] = [],
         interests: [String] = [],
         advantageAudience: Bool? = nil,
         summaryLine: String? = nil) {
        self.locations = locations
        self.ageMin = ageMin
        self.ageMax = ageMax
        self.genders = genders
        self.devices = devices
        self.placements = placements
        self.dayParting = dayParting
        self.interests = interests
        self.advantageAudience = advantageAudience
        self.summaryLine = summaryLine
    }
}

// MARK: - ActiveAd (the fleet row + higher-level signals)

// One struct per real Meta ad (a lineage node mapped to its published ad). Backs
// the active-ad rows AND the creative gallery AND the ad detail view.
struct ActiveAd: Codable, Equatable, Identifiable {
    var id: String                  // node_id (engine lineage node id), stable
    var crid: String                // owning concept-family root
    var brand: String?              // owning brand slug
    var name: String?               // human ad name (engine node name)
    var status: AdStatus            // learning | winner | contender | killing | paused
    var changedVariable: String?    // the ONE tested variable
    var variableValue: String?      // the value of that variable on this node
    var hypothesis: String?         // the engine hypothesis this node tests

    // Creative (gallery + thumbnails)
    var thumbnailURL: String?
    var headline: String?
    var primaryText: String?
    var ctaType: String?            // SHOP_NOW etc.

    // Core KPIs (cents for money, ratios as Double)
    var spendCents: Int
    var cpaCents: Int?
    var roas: Double?
    var impressions: Int
    var clicks: Int
    var conversions: Int
    var ctr: Double?

    // Higher-level signals
    var daysRunning: Int
    var impressionSharePct: Double? // 0...1 Thompson allocation weight
    var learningProgress: Double?   // 0...1 toward exiting the 7-day window
    var frequency: Double?          // avg impressions per person (fatigue signal)
    var fatigueLevel: FatigueLevel? // ok | watch | fatigued
    var pBeatsBaseline: Double?     // 0...1 P(this variant > family baseline)
    var bestAudienceSegment: String?
    var engineIntent: EngineIntent  // hold | scale | kill | spawn | promote
    var proposedNextAction: String? // human one-liner

    // Targeting summary (what the engine published; the user drills to verify)
    var targeting: TargetingSummary?

    // Cost-per-result sparkline series, oldest -> newest, cents per result.
    var costPerResultSeries: [Int]

    enum CodingKeys: String, CodingKey {
        case id = "node_id", crid, brand, name, status
        case changedVariable = "changed_variable"
        case variableValue = "variable_value"
        case hypothesis
        case thumbnailURL = "thumbnail_url", headline
        case primaryText = "primary_text", ctaType = "cta_type"
        case spendCents = "spend_cents", cpaCents = "cpa_cents", roas
        case impressions, clicks, conversions, ctr
        case daysRunning = "days_running"
        case impressionSharePct = "impression_share_pct"
        case learningProgress = "learning_progress", frequency
        case fatigueLevel = "fatigue_level"
        case pBeatsBaseline = "p_beats_baseline"
        case bestAudienceSegment = "best_audience_segment"
        case engineIntent = "engine_intent"
        case proposedNextAction = "proposed_next_action"
        case targeting
        case costPerResultSeries = "cost_per_result_series"
        // camel fallback for id when an echoed snapshot uses "id"
        case idCamel = "id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .idCamel))
            ?? UUID().uuidString
        crid = (try? c.decode(String.self, forKey: .crid)) ?? ""
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        status = (try? c.decode(AdStatus.self, forKey: .status)) ?? .contender
        changedVariable = try? c.decodeIfPresent(String.self, forKey: .changedVariable)
        variableValue = try? c.decodeIfPresent(String.self, forKey: .variableValue)
        hypothesis = try? c.decodeIfPresent(String.self, forKey: .hypothesis)
        thumbnailURL = try? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        headline = try? c.decodeIfPresent(String.self, forKey: .headline)
        primaryText = try? c.decodeIfPresent(String.self, forKey: .primaryText)
        ctaType = try? c.decodeIfPresent(String.self, forKey: .ctaType)
        spendCents = (try? c.decode(Int.self, forKey: .spendCents)) ?? 0
        cpaCents = try? c.decodeIfPresent(Int.self, forKey: .cpaCents)
        roas = try? c.decodeIfPresent(Double.self, forKey: .roas)
        impressions = (try? c.decode(Int.self, forKey: .impressions)) ?? 0
        clicks = (try? c.decode(Int.self, forKey: .clicks)) ?? 0
        conversions = (try? c.decode(Int.self, forKey: .conversions)) ?? 0
        ctr = try? c.decodeIfPresent(Double.self, forKey: .ctr)
        daysRunning = (try? c.decode(Int.self, forKey: .daysRunning)) ?? 0
        impressionSharePct = try? c.decodeIfPresent(Double.self, forKey: .impressionSharePct)
        learningProgress = try? c.decodeIfPresent(Double.self, forKey: .learningProgress)
        frequency = try? c.decodeIfPresent(Double.self, forKey: .frequency)
        fatigueLevel = try? c.decodeIfPresent(FatigueLevel.self, forKey: .fatigueLevel)
        pBeatsBaseline = try? c.decodeIfPresent(Double.self, forKey: .pBeatsBaseline)
        bestAudienceSegment = try? c.decodeIfPresent(String.self, forKey: .bestAudienceSegment)
        engineIntent = (try? c.decode(EngineIntent.self, forKey: .engineIntent)) ?? .hold
        proposedNextAction = try? c.decodeIfPresent(String.self, forKey: .proposedNextAction)
        targeting = try? c.decodeIfPresent(TargetingSummary.self, forKey: .targeting)
        costPerResultSeries = (try? c.decodeIfPresent([Int].self, forKey: .costPerResultSeries) ?? nil) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(crid, forKey: .crid)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(changedVariable, forKey: .changedVariable)
        try c.encodeIfPresent(variableValue, forKey: .variableValue)
        try c.encodeIfPresent(hypothesis, forKey: .hypothesis)
        try c.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try c.encodeIfPresent(headline, forKey: .headline)
        try c.encodeIfPresent(primaryText, forKey: .primaryText)
        try c.encodeIfPresent(ctaType, forKey: .ctaType)
        try c.encode(spendCents, forKey: .spendCents)
        try c.encodeIfPresent(cpaCents, forKey: .cpaCents)
        try c.encodeIfPresent(roas, forKey: .roas)
        try c.encode(impressions, forKey: .impressions)
        try c.encode(clicks, forKey: .clicks)
        try c.encode(conversions, forKey: .conversions)
        try c.encodeIfPresent(ctr, forKey: .ctr)
        try c.encode(daysRunning, forKey: .daysRunning)
        try c.encodeIfPresent(impressionSharePct, forKey: .impressionSharePct)
        try c.encodeIfPresent(learningProgress, forKey: .learningProgress)
        try c.encodeIfPresent(frequency, forKey: .frequency)
        try c.encodeIfPresent(fatigueLevel, forKey: .fatigueLevel)
        try c.encodeIfPresent(pBeatsBaseline, forKey: .pBeatsBaseline)
        try c.encodeIfPresent(bestAudienceSegment, forKey: .bestAudienceSegment)
        try c.encode(engineIntent, forKey: .engineIntent)
        try c.encodeIfPresent(proposedNextAction, forKey: .proposedNextAction)
        try c.encodeIfPresent(targeting, forKey: .targeting)
        try c.encode(costPerResultSeries, forKey: .costPerResultSeries)
    }

    init(id: String,
         crid: String,
         brand: String? = nil,
         name: String? = nil,
         status: AdStatus = .contender,
         changedVariable: String? = nil,
         variableValue: String? = nil,
         hypothesis: String? = nil,
         thumbnailURL: String? = nil,
         headline: String? = nil,
         primaryText: String? = nil,
         ctaType: String? = nil,
         spendCents: Int = 0,
         cpaCents: Int? = nil,
         roas: Double? = nil,
         impressions: Int = 0,
         clicks: Int = 0,
         conversions: Int = 0,
         ctr: Double? = nil,
         daysRunning: Int = 0,
         impressionSharePct: Double? = nil,
         learningProgress: Double? = nil,
         frequency: Double? = nil,
         fatigueLevel: FatigueLevel? = nil,
         pBeatsBaseline: Double? = nil,
         bestAudienceSegment: String? = nil,
         engineIntent: EngineIntent = .hold,
         proposedNextAction: String? = nil,
         targeting: TargetingSummary? = nil,
         costPerResultSeries: [Int] = []) {
        self.id = id
        self.crid = crid
        self.brand = brand
        self.name = name
        self.status = status
        self.changedVariable = changedVariable
        self.variableValue = variableValue
        self.hypothesis = hypothesis
        self.thumbnailURL = thumbnailURL
        self.headline = headline
        self.primaryText = primaryText
        self.ctaType = ctaType
        self.spendCents = spendCents
        self.cpaCents = cpaCents
        self.roas = roas
        self.impressions = impressions
        self.clicks = clicks
        self.conversions = conversions
        self.ctr = ctr
        self.daysRunning = daysRunning
        self.impressionSharePct = impressionSharePct
        self.learningProgress = learningProgress
        self.frequency = frequency
        self.fatigueLevel = fatigueLevel
        self.pBeatsBaseline = pBeatsBaseline
        self.bestAudienceSegment = bestAudienceSegment
        self.engineIntent = engineIntent
        self.proposedNextAction = proposedNextAction
        self.targeting = targeting
        self.costPerResultSeries = costPerResultSeries
    }

    // Human ad label with a sensible fallback to the node id.
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return id
    }
}

// MARK: - Attention queue (the heart of attention-first)

// What an attention item / Send-to-Claude points at, so the UI can deep-link.
struct AttentionTarget: Codable, Equatable {
    var type: TargetType       // brand | family | ad
    var brand: String?
    var crid: String?          // for family
    var nodeId: String?        // for ad
    var label: String?         // display label

    enum TargetType: String, Codable, Equatable {
        case brand, family, ad
        init(engine raw: String?) {
            switch (raw ?? "").lowercased() {
            case "family": self = .family
            case "ad", "node": self = .ad
            default: self = .brand
            }
        }
        init(from decoder: Decoder) throws {
            let raw = try? decoder.singleValueContainer().decode(String.self)
            self = TargetType(engine: raw)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    enum CodingKeys: String, CodingKey { case type, brand, crid, nodeId = "node_id", label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(TargetType.self, forKey: .type)) ?? .brand
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        crid = try? c.decodeIfPresent(String.self, forKey: .crid)
        nodeId = try? c.decodeIfPresent(String.self, forKey: .nodeId)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encodeIfPresent(crid, forKey: .crid)
        try c.encodeIfPresent(nodeId, forKey: .nodeId)
        try c.encodeIfPresent(label, forKey: .label)
    }

    init(type: TargetType = .brand, brand: String? = nil, crid: String? = nil, nodeId: String? = nil, label: String? = nil) {
        self.type = type
        self.brand = brand
        self.crid = crid
        self.nodeId = nodeId
        self.label = label
    }
}

// The one-click action a queue item or row offers. The UI maps verb -> the real
// MetaAdsService control call. actId stays a placeholder in SIMULATE.
struct SuggestedAction: Codable, Equatable {
    var verb: ActionVerb       // approve | veto | pause | scale | kill | spawn | flip_mode
    var label: String          // button copy
    var brand: String?
    var nodeId: String?
    var crid: String?
    var paramCents: Int?       // e.g. proposed new daily budget
    var paramMode: String?     // for flip_mode
    var requiresConfirm: Bool  // default true; never silently spends

    enum ActionVerb: String, Codable, Equatable {
        case approve, veto, pause, scale, kill, spawn, flipMode = "flip_mode"
        init(engine raw: String?) {
            switch (raw ?? "").lowercased() {
            case "veto": self = .veto
            case "pause": self = .pause
            case "scale", "scale_up": self = .scale
            case "kill": self = .kill
            case "spawn", "branch": self = .spawn
            case "flip_mode", "flipmode", "mode": self = .flipMode
            default: self = .approve
            }
        }
        init(from decoder: Decoder) throws {
            let raw = try? decoder.singleValueContainer().decode(String.self)
            self = ActionVerb(engine: raw)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    enum CodingKeys: String, CodingKey {
        case verb, label, brand
        case nodeId = "node_id", crid
        case paramCents = "param_cents"
        case paramMode = "param_mode"
        case requiresConfirm = "requires_confirm"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verb = (try? c.decode(ActionVerb.self, forKey: .verb)) ?? .approve
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        nodeId = try? c.decodeIfPresent(String.self, forKey: .nodeId)
        crid = try? c.decodeIfPresent(String.self, forKey: .crid)
        paramCents = try? c.decodeIfPresent(Int.self, forKey: .paramCents)
        paramMode = try? c.decodeIfPresent(String.self, forKey: .paramMode)
        requiresConfirm = (try? c.decode(Bool.self, forKey: .requiresConfirm)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verb, forKey: .verb)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encodeIfPresent(nodeId, forKey: .nodeId)
        try c.encodeIfPresent(crid, forKey: .crid)
        try c.encodeIfPresent(paramCents, forKey: .paramCents)
        try c.encodeIfPresent(paramMode, forKey: .paramMode)
        try c.encode(requiresConfirm, forKey: .requiresConfirm)
    }

    init(verb: ActionVerb = .approve,
         label: String = "",
         brand: String? = nil,
         nodeId: String? = nil,
         crid: String? = nil,
         paramCents: Int? = nil,
         paramMode: String? = nil,
         requiresConfirm: Bool = true) {
        self.verb = verb
        self.label = label
        self.brand = brand
        self.nodeId = nodeId
        self.crid = crid
        self.paramCents = paramCents
        self.paramMode = paramMode
        self.requiresConfirm = requiresConfirm
    }
}

enum AttentionKind: String, Codable, Equatable {
    case approval, anomaly, drift, fatigue, budget, winner
    case killProposed = "kill_proposed"
    case proposedCampaign = "proposed_campaign"

    init(engine raw: String?) {
        switch (raw ?? "").lowercased() {
        case "approval", "approve": self = .approval
        case "drift": self = .drift
        case "fatigue": self = .fatigue
        case "budget", "pacing": self = .budget
        case "winner": self = .winner
        case "kill_proposed", "killproposed", "kill": self = .killProposed
        case "proposed_campaign", "proposedcampaign", "campaign": self = .proposedCampaign
        default: self = .anomaly
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = AttentionKind(engine: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

enum AttentionSeverity: String, Codable, Equatable, Comparable {
    case info, warning, critical

    var rank: Int { switch self { case .info: return 0; case .warning: return 1; case .critical: return 2 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    init(engine raw: String?) {
        switch (raw ?? "").lowercased() {
        case "info", "notice": self = .info
        case "critical", "crit", "high": self = .critical
        default: self = .warning
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = AttentionSeverity(engine: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct AttentionItem: Codable, Equatable, Identifiable {
    var id: String
    var kind: AttentionKind
    var severity: AttentionSeverity
    var brand: String?
    var title: String
    var message: String
    var target: AttentionTarget?
    var suggestedAction: SuggestedAction?
    var sendToClaudePrompt: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, severity, brand, title, message, target
        case suggestedAction = "suggested_action"
        case sendToClaudePrompt = "send_to_claude_prompt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = (try? c.decode(AttentionKind.self, forKey: .kind)) ?? .anomaly
        severity = (try? c.decode(AttentionSeverity.self, forKey: .severity)) ?? .warning
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        target = try? c.decodeIfPresent(AttentionTarget.self, forKey: .target)
        suggestedAction = try? c.decodeIfPresent(SuggestedAction.self, forKey: .suggestedAction)
        sendToClaudePrompt = try? c.decodeIfPresent(String.self, forKey: .sendToClaudePrompt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(severity, forKey: .severity)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encode(title, forKey: .title)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(suggestedAction, forKey: .suggestedAction)
        try c.encodeIfPresent(sendToClaudePrompt, forKey: .sendToClaudePrompt)
    }

    init(id: String,
         kind: AttentionKind = .anomaly,
         severity: AttentionSeverity = .warning,
         brand: String? = nil,
         title: String = "",
         message: String = "",
         target: AttentionTarget? = nil,
         suggestedAction: SuggestedAction? = nil,
         sendToClaudePrompt: String? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.brand = brand
        self.title = title
        self.message = message
        self.target = target
        self.suggestedAction = suggestedAction
        self.sendToClaudePrompt = sendToClaudePrompt
    }
}

// MARK: - BrandForecast (pacing + forecast)

struct BrandForecast: Codable, Equatable {
    var burnRateCentsPerDay: Int            // trailing avg
    var runwayDays: Double?                 // days until weekly cap at current burn
    var projectedMonthCents: Int            // burn x 30
    var projectedMonthVsBudgetPct: Double?  // 0...1+
    var spendSeries: [Int]                  // daily spend cents, oldest->newest
    var capLineCents: Int?                  // daily cap to draw as a reference line

    enum CodingKeys: String, CodingKey {
        case burnRateCentsPerDay = "burn_rate_cents_per_day"
        case runwayDays = "runway_days"
        case projectedMonthCents = "projected_month_cents"
        case projectedMonthVsBudgetPct = "projected_vs_budget_pct"
        case spendSeries = "spend_series"
        case capLineCents = "cap_line_cents"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        burnRateCentsPerDay = (try? c.decode(Int.self, forKey: .burnRateCentsPerDay)) ?? 0
        runwayDays = try? c.decodeIfPresent(Double.self, forKey: .runwayDays)
        projectedMonthCents = (try? c.decode(Int.self, forKey: .projectedMonthCents)) ?? 0
        projectedMonthVsBudgetPct = try? c.decodeIfPresent(Double.self, forKey: .projectedMonthVsBudgetPct)
        spendSeries = (try? c.decodeIfPresent([Int].self, forKey: .spendSeries) ?? nil) ?? []
        capLineCents = try? c.decodeIfPresent(Int.self, forKey: .capLineCents)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(burnRateCentsPerDay, forKey: .burnRateCentsPerDay)
        try c.encodeIfPresent(runwayDays, forKey: .runwayDays)
        try c.encode(projectedMonthCents, forKey: .projectedMonthCents)
        try c.encodeIfPresent(projectedMonthVsBudgetPct, forKey: .projectedMonthVsBudgetPct)
        try c.encode(spendSeries, forKey: .spendSeries)
        try c.encodeIfPresent(capLineCents, forKey: .capLineCents)
    }

    init(burnRateCentsPerDay: Int = 0,
         runwayDays: Double? = nil,
         projectedMonthCents: Int = 0,
         projectedMonthVsBudgetPct: Double? = nil,
         spendSeries: [Int] = [],
         capLineCents: Int? = nil) {
        self.burnRateCentsPerDay = burnRateCentsPerDay
        self.runwayDays = runwayDays
        self.projectedMonthCents = projectedMonthCents
        self.projectedMonthVsBudgetPct = projectedMonthVsBudgetPct
        self.spendSeries = spendSeries
        self.capLineCents = capLineCents
    }
}

// MARK: - Anomaly (anomaly + drift)

struct Anomaly: Codable, Equatable, Identifiable {
    var id: String
    var brand: String?
    var metric: String          // "cpa" | "ctr" | "spend" | "frequency"
    var kind: String            // "spike" | "drop" | "drift" | "flatline"
    var severity: AttentionSeverity
    var message: String
    var nodeId: String?
    var deltaPct: Double?        // how far off the baseline (signed)
    var detectedAt: String?      // iso

    enum CodingKeys: String, CodingKey {
        case id, brand, metric, kind, severity, message
        case nodeId = "node_id"
        case deltaPct = "delta_pct"
        case detectedAt = "detected_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        metric = (try? c.decode(String.self, forKey: .metric)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "drift"
        severity = (try? c.decode(AttentionSeverity.self, forKey: .severity)) ?? .warning
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        nodeId = try? c.decodeIfPresent(String.self, forKey: .nodeId)
        deltaPct = try? c.decodeIfPresent(Double.self, forKey: .deltaPct)
        detectedAt = try? c.decodeIfPresent(String.self, forKey: .detectedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encode(metric, forKey: .metric)
        try c.encode(kind, forKey: .kind)
        try c.encode(severity, forKey: .severity)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(nodeId, forKey: .nodeId)
        try c.encodeIfPresent(deltaPct, forKey: .deltaPct)
        try c.encodeIfPresent(detectedAt, forKey: .detectedAt)
    }

    init(id: String,
         brand: String? = nil,
         metric: String = "",
         kind: String = "drift",
         severity: AttentionSeverity = .warning,
         message: String = "",
         nodeId: String? = nil,
         deltaPct: Double? = nil,
         detectedAt: String? = nil) {
        self.id = id
        self.brand = brand
        self.metric = metric
        self.kind = kind
        self.severity = severity
        self.message = message
        self.nodeId = nodeId
        self.deltaPct = deltaPct
        self.detectedAt = detectedAt
    }
}

// MARK: - ProposedCampaign (the engine-crafted campaign the user approves)

struct ProposedCampaign: Codable, Equatable, Identifiable {
    var id: String
    var brand: String?
    var concept: String            // the new concept/angle (gen-0 root idea)
    var hypothesis: String?
    var headline: String?
    var primaryText: String?
    var ctaType: String?
    var thumbnailURL: String?      // the proposed product-in-scene
    var dailyBudgetCents: Int      // clamped <= effective cap
    var targeting: TargetingSummary?
    var changedFromCrid: String?   // if spun off a winner
    var changedVariable: String?   // the one variable being branched
    var status: String?            // "pending_approval" | "approved" | "vetoed"
    var sendToClaudePrompt: String?

    enum CodingKeys: String, CodingKey {
        case id, brand, concept, hypothesis, headline
        case primaryText = "primary_text"
        case ctaType = "cta_type"
        case thumbnailURL = "thumbnail_url"
        case dailyBudgetCents = "daily_budget_cents"
        case targeting
        case changedFromCrid = "changed_from_crid"
        case changedVariable = "changed_variable"
        case status
        case sendToClaudePrompt = "send_to_claude_prompt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        concept = (try? c.decode(String.self, forKey: .concept)) ?? ""
        hypothesis = try? c.decodeIfPresent(String.self, forKey: .hypothesis)
        headline = try? c.decodeIfPresent(String.self, forKey: .headline)
        primaryText = try? c.decodeIfPresent(String.self, forKey: .primaryText)
        ctaType = try? c.decodeIfPresent(String.self, forKey: .ctaType)
        thumbnailURL = try? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        dailyBudgetCents = (try? c.decode(Int.self, forKey: .dailyBudgetCents)) ?? 0
        targeting = try? c.decodeIfPresent(TargetingSummary.self, forKey: .targeting)
        changedFromCrid = try? c.decodeIfPresent(String.self, forKey: .changedFromCrid)
        changedVariable = try? c.decodeIfPresent(String.self, forKey: .changedVariable)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        sendToClaudePrompt = try? c.decodeIfPresent(String.self, forKey: .sendToClaudePrompt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encode(concept, forKey: .concept)
        try c.encodeIfPresent(hypothesis, forKey: .hypothesis)
        try c.encodeIfPresent(headline, forKey: .headline)
        try c.encodeIfPresent(primaryText, forKey: .primaryText)
        try c.encodeIfPresent(ctaType, forKey: .ctaType)
        try c.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try c.encode(dailyBudgetCents, forKey: .dailyBudgetCents)
        try c.encodeIfPresent(targeting, forKey: .targeting)
        try c.encodeIfPresent(changedFromCrid, forKey: .changedFromCrid)
        try c.encodeIfPresent(changedVariable, forKey: .changedVariable)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(sendToClaudePrompt, forKey: .sendToClaudePrompt)
    }

    init(id: String,
         brand: String? = nil,
         concept: String = "",
         hypothesis: String? = nil,
         headline: String? = nil,
         primaryText: String? = nil,
         ctaType: String? = nil,
         thumbnailURL: String? = nil,
         dailyBudgetCents: Int = 0,
         targeting: TargetingSummary? = nil,
         changedFromCrid: String? = nil,
         changedVariable: String? = nil,
         status: String? = nil,
         sendToClaudePrompt: String? = nil) {
        self.id = id
        self.brand = brand
        self.concept = concept
        self.hypothesis = hypothesis
        self.headline = headline
        self.primaryText = primaryText
        self.ctaType = ctaType
        self.thumbnailURL = thumbnailURL
        self.dailyBudgetCents = dailyBudgetCents
        self.targeting = targeting
        self.changedFromCrid = changedFromCrid
        self.changedVariable = changedVariable
        self.status = status
        self.sendToClaudePrompt = sendToClaudePrompt
    }
}

// MARK: - Confidence + lineage + leaderboard + rollup

// Bayesian A/B readout per concept family (bayes.py P(B>A) at the 0.95 bar).
struct FamilyConfidence: Codable, Equatable, Identifiable {
    var crid: String               // family root; id = crid
    var label: String?
    var pBeatsA: Double            // 0...1 P(best variant > control)
    var winnerBar: Double          // default 0.95
    var leaderNodeId: String?      // current best variant
    var controlNodeId: String?
    var conversionsObserved: Int   // gate context
    var decided: Bool              // has it crossed the bar

    var id: String { crid }

    enum CodingKeys: String, CodingKey {
        case crid, label
        case pBeatsA = "p_beats_a"
        case winnerBar = "winner_bar"
        case leaderNodeId = "leader_node_id"
        case controlNodeId = "control_node_id"
        case conversionsObserved = "conversions_observed"
        case decided
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crid = (try? c.decode(String.self, forKey: .crid)) ?? UUID().uuidString
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        pBeatsA = (try? c.decode(Double.self, forKey: .pBeatsA)) ?? 0
        winnerBar = (try? c.decode(Double.self, forKey: .winnerBar)) ?? 0.95
        leaderNodeId = try? c.decodeIfPresent(String.self, forKey: .leaderNodeId)
        controlNodeId = try? c.decodeIfPresent(String.self, forKey: .controlNodeId)
        conversionsObserved = (try? c.decode(Int.self, forKey: .conversionsObserved)) ?? 0
        decided = (try? c.decode(Bool.self, forKey: .decided)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(crid, forKey: .crid)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(pBeatsA, forKey: .pBeatsA)
        try c.encode(winnerBar, forKey: .winnerBar)
        try c.encodeIfPresent(leaderNodeId, forKey: .leaderNodeId)
        try c.encodeIfPresent(controlNodeId, forKey: .controlNodeId)
        try c.encode(conversionsObserved, forKey: .conversionsObserved)
        try c.encode(decided, forKey: .decided)
    }

    init(crid: String,
         label: String? = nil,
         pBeatsA: Double = 0,
         winnerBar: Double = 0.95,
         leaderNodeId: String? = nil,
         controlNodeId: String? = nil,
         conversionsObserved: Int = 0,
         decided: Bool = false) {
        self.crid = crid
        self.label = label
        self.pBeatsA = pBeatsA
        self.winnerBar = winnerBar
        self.leaderNodeId = leaderNodeId
        self.controlNodeId = controlNodeId
        self.conversionsObserved = conversionsObserved
        self.decided = decided
    }
}

// A single node/edge in the lineage tree for the visualizer.
struct LineageNode: Codable, Equatable, Identifiable {
    var id: String                 // node_id
    var crid: String
    var parentId: String?          // nil = gen-0 root
    var generation: Int
    var changedVariable: String?   // edge label
    var variableValue: String?
    var status: String?            // node status for the dot color
    var cpaCents: Int?             // for a quick perf tint
    var label: String?

    enum CodingKeys: String, CodingKey {
        case id = "node_id", crid, parentId = "parent_id", generation
        case changedVariable = "changed_variable", variableValue = "variable_value"
        case status, cpaCents = "cpa_cents", label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        crid = (try? c.decode(String.self, forKey: .crid)) ?? ""
        parentId = try? c.decodeIfPresent(String.self, forKey: .parentId)
        generation = (try? c.decode(Int.self, forKey: .generation)) ?? 0
        changedVariable = try? c.decodeIfPresent(String.self, forKey: .changedVariable)
        variableValue = try? c.decodeIfPresent(String.self, forKey: .variableValue)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        cpaCents = try? c.decodeIfPresent(Int.self, forKey: .cpaCents)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(crid, forKey: .crid)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encode(generation, forKey: .generation)
        try c.encodeIfPresent(changedVariable, forKey: .changedVariable)
        try c.encodeIfPresent(variableValue, forKey: .variableValue)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(cpaCents, forKey: .cpaCents)
        try c.encodeIfPresent(label, forKey: .label)
    }

    init(id: String,
         crid: String = "",
         parentId: String? = nil,
         generation: Int = 0,
         changedVariable: String? = nil,
         variableValue: String? = nil,
         status: String? = nil,
         cpaCents: Int? = nil,
         label: String? = nil) {
        self.id = id
        self.crid = crid
        self.parentId = parentId
        self.generation = generation
        self.changedVariable = changedVariable
        self.variableValue = variableValue
        self.status = status
        self.cpaCents = cpaCents
        self.label = label
    }
}

// Per-brand stats for the fleet-deck leaderboard row + sorting.
struct BrandLeaderboardStat: Codable, Equatable {
    var bestNodeId: String?
    var bestLabel: String?
    var bestCpaCents: Int?
    var worstNodeId: String?
    var worstLabel: String?
    var worstCpaCents: Int?
    var blendedRoas: Double?
    var attentionFlag: Bool        // does this brand need the user
    var oldestAdDays: Int?         // for age sort

    enum CodingKeys: String, CodingKey {
        case bestNodeId = "best_node_id"
        case bestLabel = "best_label"
        case bestCpaCents = "best_cpa_cents"
        case worstNodeId = "worst_node_id"
        case worstLabel = "worst_label"
        case worstCpaCents = "worst_cpa_cents"
        case blendedRoas = "blended_roas"
        case attentionFlag = "attention_flag"
        case oldestAdDays = "oldest_ad_days"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bestNodeId = try? c.decodeIfPresent(String.self, forKey: .bestNodeId)
        bestLabel = try? c.decodeIfPresent(String.self, forKey: .bestLabel)
        bestCpaCents = try? c.decodeIfPresent(Int.self, forKey: .bestCpaCents)
        worstNodeId = try? c.decodeIfPresent(String.self, forKey: .worstNodeId)
        worstLabel = try? c.decodeIfPresent(String.self, forKey: .worstLabel)
        worstCpaCents = try? c.decodeIfPresent(Int.self, forKey: .worstCpaCents)
        blendedRoas = try? c.decodeIfPresent(Double.self, forKey: .blendedRoas)
        attentionFlag = (try? c.decode(Bool.self, forKey: .attentionFlag)) ?? false
        oldestAdDays = try? c.decodeIfPresent(Int.self, forKey: .oldestAdDays)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(bestNodeId, forKey: .bestNodeId)
        try c.encodeIfPresent(bestLabel, forKey: .bestLabel)
        try c.encodeIfPresent(bestCpaCents, forKey: .bestCpaCents)
        try c.encodeIfPresent(worstNodeId, forKey: .worstNodeId)
        try c.encodeIfPresent(worstLabel, forKey: .worstLabel)
        try c.encodeIfPresent(worstCpaCents, forKey: .worstCpaCents)
        try c.encodeIfPresent(blendedRoas, forKey: .blendedRoas)
        try c.encode(attentionFlag, forKey: .attentionFlag)
        try c.encodeIfPresent(oldestAdDays, forKey: .oldestAdDays)
    }

    init(bestNodeId: String? = nil,
         bestLabel: String? = nil,
         bestCpaCents: Int? = nil,
         worstNodeId: String? = nil,
         worstLabel: String? = nil,
         worstCpaCents: Int? = nil,
         blendedRoas: Double? = nil,
         attentionFlag: Bool = false,
         oldestAdDays: Int? = nil) {
        self.bestNodeId = bestNodeId
        self.bestLabel = bestLabel
        self.bestCpaCents = bestCpaCents
        self.worstNodeId = worstNodeId
        self.worstLabel = worstLabel
        self.worstCpaCents = worstCpaCents
        self.blendedRoas = blendedRoas
        self.attentionFlag = attentionFlag
        self.oldestAdDays = oldestAdDays
    }
}

// Cross-brand totals for the empire roll-up tile + Telegram digest hook.
struct EmpireRollup: Codable, Equatable {
    var totalSpendTodayCents: Int
    var totalSpendWeekCents: Int
    var blendedCpaCents: Int?
    var blendedRoas: Double?
    var winnerCount: Int
    var liveAdCount: Int
    var attentionCount: Int

    enum CodingKeys: String, CodingKey {
        case totalSpendTodayCents = "total_spend_today_cents"
        case totalSpendWeekCents = "total_spend_week_cents"
        case blendedCpaCents = "blended_cpa_cents"
        case blendedRoas = "blended_roas"
        case winnerCount = "winner_count"
        case liveAdCount = "live_ad_count"
        case attentionCount = "attention_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalSpendTodayCents = (try? c.decode(Int.self, forKey: .totalSpendTodayCents)) ?? 0
        totalSpendWeekCents = (try? c.decode(Int.self, forKey: .totalSpendWeekCents)) ?? 0
        blendedCpaCents = try? c.decodeIfPresent(Int.self, forKey: .blendedCpaCents)
        blendedRoas = try? c.decodeIfPresent(Double.self, forKey: .blendedRoas)
        winnerCount = (try? c.decode(Int.self, forKey: .winnerCount)) ?? 0
        liveAdCount = (try? c.decode(Int.self, forKey: .liveAdCount)) ?? 0
        attentionCount = (try? c.decode(Int.self, forKey: .attentionCount)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(totalSpendTodayCents, forKey: .totalSpendTodayCents)
        try c.encode(totalSpendWeekCents, forKey: .totalSpendWeekCents)
        try c.encodeIfPresent(blendedCpaCents, forKey: .blendedCpaCents)
        try c.encodeIfPresent(blendedRoas, forKey: .blendedRoas)
        try c.encode(winnerCount, forKey: .winnerCount)
        try c.encode(liveAdCount, forKey: .liveAdCount)
        try c.encode(attentionCount, forKey: .attentionCount)
    }

    init(totalSpendTodayCents: Int = 0,
         totalSpendWeekCents: Int = 0,
         blendedCpaCents: Int? = nil,
         blendedRoas: Double? = nil,
         winnerCount: Int = 0,
         liveAdCount: Int = 0,
         attentionCount: Int = 0) {
        self.totalSpendTodayCents = totalSpendTodayCents
        self.totalSpendWeekCents = totalSpendWeekCents
        self.blendedCpaCents = blendedCpaCents
        self.blendedRoas = blendedRoas
        self.winnerCount = winnerCount
        self.liveAdCount = liveAdCount
        self.attentionCount = attentionCount
    }
}

// Per-brand onboarding-to-live status: the checklist that takes a brand from
// SIMULATE (act_PLACEHOLDER) to a real, tracked, spend-capable Meta ad account.
// Each step is a Bool; nextStep + blockedOn name the immediate action and who
// owns it ("you" = a human Meta-account action, "grux" = Claude can do it).
struct BrandOnboarding: Codable, Equatable {
    var pixelInstalled: Bool   // storefront Pixel + CAPI code shipped
    var deployed: Bool         // shipped live to production
    var domainVerified: Bool   // Meta domain verification for the storefront
    var assetsConnected: Bool  // ad account + page + pixel + ig connected to the engine
    var tokenConfigured: Bool  // system-user access token present
    var capiLive: Bool         // server-side Conversions API firing Purchase
    var bootstrapped: Bool     // engine flipped live-capable (still OBSERVE until armed)
    var nextStep: String?
    var blockedOn: String?     // "you" | "grux" | nil

    enum CodingKeys: String, CodingKey {
        case pixelInstalled = "pixel_installed"
        case deployed
        case domainVerified = "domain_verified"
        case assetsConnected = "assets_connected"
        case tokenConfigured = "token_configured"
        case capiLive = "capi_live"
        case bootstrapped
        case nextStep = "next_step"
        case blockedOn = "blocked_on"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pixelInstalled = (try? c.decodeIfPresent(Bool.self, forKey: .pixelInstalled) ?? nil) ?? false
        deployed = (try? c.decodeIfPresent(Bool.self, forKey: .deployed) ?? nil) ?? false
        domainVerified = (try? c.decodeIfPresent(Bool.self, forKey: .domainVerified) ?? nil) ?? false
        assetsConnected = (try? c.decodeIfPresent(Bool.self, forKey: .assetsConnected) ?? nil) ?? false
        tokenConfigured = (try? c.decodeIfPresent(Bool.self, forKey: .tokenConfigured) ?? nil) ?? false
        capiLive = (try? c.decodeIfPresent(Bool.self, forKey: .capiLive) ?? nil) ?? false
        bootstrapped = (try? c.decodeIfPresent(Bool.self, forKey: .bootstrapped) ?? nil) ?? false
        nextStep = try? c.decodeIfPresent(String.self, forKey: .nextStep)
        blockedOn = try? c.decodeIfPresent(String.self, forKey: .blockedOn)
    }

    init(pixelInstalled: Bool = false, deployed: Bool = false, domainVerified: Bool = false,
         assetsConnected: Bool = false, tokenConfigured: Bool = false, capiLive: Bool = false,
         bootstrapped: Bool = false, nextStep: String? = nil, blockedOn: String? = nil) {
        self.pixelInstalled = pixelInstalled
        self.deployed = deployed
        self.domainVerified = domainVerified
        self.assetsConnected = assetsConnected
        self.tokenConfigured = tokenConfigured
        self.capiLive = capiLive
        self.bootstrapped = bootstrapped
        self.nextStep = nextStep
        self.blockedOn = blockedOn
    }

    // Ordered checklist for the UI: (label, done, owner).
    var steps: [(label: String, done: Bool, owner: String)] {
        [
            ("Storefront pixel + Conversions API installed", pixelInstalled, "grux"),
            ("Shipped to production", deployed, "grux"),
            ("Domain verified with Meta", domainVerified, "grux"),
            ("Meta ad account, Page, Pixel, IG connected", assetsConnected, "you"),
            ("Access token configured", tokenConfigured, "you"),
            ("Purchase events flowing (CAPI)", capiLive, "grux"),
            ("Engine bootstrapped, live capable", bootstrapped, "grux"),
        ]
    }
    var doneCount: Int { steps.filter { $0.done }.count }
    var totalCount: Int { steps.count }
}
