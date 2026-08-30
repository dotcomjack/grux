import Foundation

// Codable models for the autonomous Meta Ads engine snapshot. These mirror the
// JSON the ads engine emits at
// /api/meta-ads/snapshot and the JSON mirror the Grux app polls. The engine runs
// in SIMULATE / OBSERVE by default: it is fed MOCK Meta insights so the whole loop
// proves out with no live ad account (a brand's config stays act_PLACEHOLDER, so
// it physically cannot act live). The UI never spends a cent; it reads this snapshot.
//
// Hard caps surfaced for the pacing UI are constants here too, matching the engine
// module constants (engine/caps.py): effective daily $16 (1600 cents), weekly $140
// (14000 cents). These are display defaults; the snapshot may also carry per-brand
// pacing caps and the UI prefers those when present.
//
// Lenient/optional throughout so a partial or early-boot snapshot still decodes,
// matching the EmpireSnapshot decode posture.

// MARK: - Hard cap display constants (mirror engine/caps.py)

enum MetaAdsCaps {
    static let effectiveDailyBudgetCents = 1600   // $16 = $20/day cap / 1.25 overspend
    static let weeklySpendCapCents = 14000        // $140 weekly backstop
    static let maxSingleAdsetDailyCents = 10000   // $100 per ad set per day
}

// MARK: - Shared engine enums (single source of truth for the UI units)

// Engine modes, matching the engine's mode ladder. Decoded leniently from the
// snapshot strings ("OBSERVE", "RECOMMEND", ...) so a new or unexpected value
// never crashes the UI; the raw value is the engine spelling.
enum MetaAdsMode: String, Codable, Equatable, CaseIterable {
    case simulate
    case observe
    case recommend
    case autonomous

    // Parse an engine string (any case) into a mode, defaulting to observe.
    init(engine raw: String?) {
        switch (raw ?? "").lowercased() {
        case "simulate": self = .simulate
        case "recommend": self = .recommend
        case "autonomous": self = .autonomous
        default: self = .observe
        }
    }

    // The engine spelling this mode posts back on the control plane (uppercased).
    var engineValue: String { rawValue.uppercased() }
}

// The decision actions the engine logs in its journal. String-backed to match
// the engine spellings (hold | kill | promote_winner | scale | spawn). Decoded
// leniently: unknown actions fall back to hold so the journal never drops a row.
enum MetaAdsDecisionAction: String, Codable, Equatable, CaseIterable {
    case hold
    case kill
    case winner          // engine: promote_winner
    case scale
    case spawn

    // Map an engine action string to a case, accepting the engine's snake_case
    // promote_winner spelling and a few synonyms.
    init(engine raw: String?) {
        switch (raw ?? "").lowercased() {
        case "kill", "killed": self = .kill
        case "promote_winner", "winner", "promote": self = .winner
        case "scale", "scale_up": self = .scale
        case "spawn", "branch": self = .spawn
        default: self = .hold
        }
    }
}

// MARK: - Top-level snapshot

struct MetaAdsSnapshot: Codable, Equatable {
    var generatedAt: String
    var generatedAtEpoch: Double?
    var mode: String                 // OBSERVE | RECOMMEND | AUTONOMOUS (global default mode)
    var killSwitchOn: Bool
    var brands: [MetaAdsBrand]
    var journal: [DecisionEntry]
    var source: MetaAdsSourceMeta?

    // Power-tool top-level additions (both optional/lenient so older snapshots
    // still decode). attention is the empire-wide (brand-spanning) queue; the
    // empireRollup carries the cross-brand totals for the deck roll-up + digest.
    var attention: [AttentionItem]   // key "attention"
    var empireRollup: EmpireRollup?  // key "empire_rollup"

    // CodingKeys mirror the real engine snapshot (engine/snapshot.py), which is
    // snake_case and flat: kill, generated_at (epoch) + generated_iso (string),
    // a top-level families array, per-brand kpis keyed by slug, per_brand_mode,
    // brands_known, and a journal of decisions. The power-tool engine adds sibling
    // by-brand maps (active_ads_by_brand, attention_by_brand, forecast_by_brand,
    // anomalies_by_brand, proposed_campaigns_by_brand, confidence_by_brand,
    // lineage_by_brand, leaderboard_by_brand) plus a top-level attention array and
    // empire_rollup. Both the engine HTTP payload and the
    // ~/.grux/meta-ads-snapshot.json mirror share this shape.
    enum CodingKeys: String, CodingKey {
        case generatedIso = "generated_iso"
        case generatedAt = "generated_at"
        case mode
        case kill
        case journal
        case source
        case families
        case kpis
        case perBrandMode = "per_brand_mode"
        case brandsKnown = "brands_known"
        case attention
        case empireRollup = "empire_rollup"
        // Power-tool by-brand maps the synthesize path threads onto each brand.
        case activeAdsByBrand = "active_ads_by_brand"
        case attentionByBrand = "attention_by_brand"
        case forecastByBrand = "forecast_by_brand"
        case anomaliesByBrand = "anomalies_by_brand"
        case proposedCampaignsByBrand = "proposed_campaigns_by_brand"
        case confidenceByBrand = "confidence_by_brand"
        case lineageByBrand = "lineage_by_brand"
        case leaderboardByBrand = "leaderboard_by_brand"
        case onboardingByBrand = "onboarding_by_brand"
        // Camel-case fallbacks so a hand-built / echoed snapshot still decodes.
        case generatedAtCamel = "generatedAt"
        case killSwitchOn
        case brands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // generated_iso is the human string; generated_at is the epoch int.
        generatedAt = (try? c.decode(String.self, forKey: .generatedIso))
            ?? (try? c.decode(String.self, forKey: .generatedAtCamel))
            ?? ""
        generatedAtEpoch = (try? c.decodeIfPresent(Double.self, forKey: .generatedAt))

        mode = (try? c.decode(String.self, forKey: .mode)) ?? "OBSERVE"

        // The engine flag is "kill"; accept the camel "killSwitchOn" too.
        killSwitchOn = (try? c.decode(Bool.self, forKey: .kill))
            ?? (try? c.decode(Bool.self, forKey: .killSwitchOn))
            ?? false

        journal = (try? c.decode([DecisionEntry].self, forKey: .journal)) ?? []
        source = try? c.decodeIfPresent(MetaAdsSourceMeta.self, forKey: .source)

        // Top-level power-tool fields, lenient.
        attention = (try? c.decodeIfPresent([AttentionItem].self, forKey: .attention) ?? nil) ?? []
        empireRollup = try? c.decodeIfPresent(EmpireRollup.self, forKey: .empireRollup)

        // Prefer an explicit brands array (echoed / hand-built snapshots). When
        // absent (the live engine shape), synthesize per-brand records from the
        // flat families array + per-brand kpis + per_brand_mode, threading the
        // power-tool by-brand maps onto each synthesized brand by slug.
        if let explicit = try? c.decode([MetaAdsBrand].self, forKey: .brands), !explicit.isEmpty {
            brands = explicit
        } else {
            let families = (try? c.decode([ConceptFamily].self, forKey: .families)) ?? []
            let kpisByBrand = (try? c.decode([String: MetaAdsKPIs].self, forKey: .kpis)) ?? [:]
            let modeByBrand = (try? c.decode([String: String].self, forKey: .perBrandMode)) ?? [:]
            let known = (try? c.decode([String].self, forKey: .brandsKnown)) ?? []
            let activeAdsByBrand = (try? c.decodeIfPresent([String: [ActiveAd]].self, forKey: .activeAdsByBrand) ?? nil) ?? [:]
            let attentionByBrand = (try? c.decodeIfPresent([String: [AttentionItem]].self, forKey: .attentionByBrand) ?? nil) ?? [:]
            let forecastByBrand = (try? c.decodeIfPresent([String: BrandForecast].self, forKey: .forecastByBrand) ?? nil) ?? [:]
            let anomaliesByBrand = (try? c.decodeIfPresent([String: [Anomaly]].self, forKey: .anomaliesByBrand) ?? nil) ?? [:]
            let proposedByBrand = (try? c.decodeIfPresent([String: [ProposedCampaign]].self, forKey: .proposedCampaignsByBrand) ?? nil) ?? [:]
            let confidenceByBrand = (try? c.decodeIfPresent([String: [FamilyConfidence]].self, forKey: .confidenceByBrand) ?? nil) ?? [:]
            let lineageByBrand = (try? c.decodeIfPresent([String: [LineageNode]].self, forKey: .lineageByBrand) ?? nil) ?? [:]
            let leaderboardByBrand = (try? c.decodeIfPresent([String: BrandLeaderboardStat].self, forKey: .leaderboardByBrand) ?? nil) ?? [:]
            let onboardingByBrand = (try? c.decodeIfPresent([String: BrandOnboarding].self, forKey: .onboardingByBrand) ?? nil) ?? [:]
            brands = MetaAdsSnapshot.synthesizeBrands(
                families: families,
                kpisByBrand: kpisByBrand,
                modeByBrand: modeByBrand,
                known: known,
                activeAdsByBrand: activeAdsByBrand,
                attentionByBrand: attentionByBrand,
                forecastByBrand: forecastByBrand,
                anomaliesByBrand: anomaliesByBrand,
                proposedByBrand: proposedByBrand,
                confidenceByBrand: confidenceByBrand,
                lineageByBrand: lineageByBrand,
                leaderboardByBrand: leaderboardByBrand,
                onboardingByBrand: onboardingByBrand
            )
        }
    }

    // Explicit encode for the local cache mirror. Writes canonical keys plus an
    // explicit brands array so the cached JSON re-decodes via the explicit path.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generatedAt, forKey: .generatedIso)
        try c.encodeIfPresent(generatedAtEpoch, forKey: .generatedAt)
        try c.encode(mode, forKey: .mode)
        try c.encode(killSwitchOn, forKey: .kill)
        try c.encode(brands, forKey: .brands)
        try c.encode(journal, forKey: .journal)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(attention, forKey: .attention)
        try c.encodeIfPresent(empireRollup, forKey: .empireRollup)
    }

    // Build per-brand records from the engine's flat snapshot pieces. Each brand
    // collects its own concept families (matched on ConceptFamily.brand) and its
    // KPIs / mode from the per-brand maps. Caps come from each KPI's pacing.
    private static func synthesizeBrands(
        families: [ConceptFamily],
        kpisByBrand: [String: MetaAdsKPIs],
        modeByBrand: [String: String],
        known: [String],
        activeAdsByBrand: [String: [ActiveAd]] = [:],
        attentionByBrand: [String: [AttentionItem]] = [:],
        forecastByBrand: [String: BrandForecast] = [:],
        anomaliesByBrand: [String: [Anomaly]] = [:],
        proposedByBrand: [String: [ProposedCampaign]] = [:],
        confidenceByBrand: [String: [FamilyConfidence]] = [:],
        lineageByBrand: [String: [LineageNode]] = [:],
        leaderboardByBrand: [String: BrandLeaderboardStat] = [:],
        onboardingByBrand: [String: BrandOnboarding] = [:]
    ) -> [MetaAdsBrand] {
        // Union of every brand slug we saw anywhere, keeping a stable order.
        var slugs: [String] = []
        func add(_ s: String) { if !s.isEmpty, !slugs.contains(s) { slugs.append(s) } }
        known.forEach(add)
        kpisByBrand.keys.sorted().forEach(add)
        families.compactMap { $0.brand }.forEach(add)
        activeAdsByBrand.keys.sorted().forEach(add)

        return slugs.map { slug in
            let fam = families.filter { $0.brand == slug }
            let kpis = kpisByBrand[slug] ?? MetaAdsKPIs()
            return MetaAdsBrand(
                id: slug,
                slug: slug,
                name: nil,
                mode: modeByBrand[slug],
                bootstrapped: nil,
                kpis: kpis,
                pacing: kpis.derivedPacing,
                families: fam,
                activeAds: activeAdsByBrand[slug] ?? [],
                attention: attentionByBrand[slug] ?? [],
                forecast: forecastByBrand[slug],
                anomalies: anomaliesByBrand[slug] ?? [],
                proposedCampaigns: proposedByBrand[slug] ?? [],
                confidence: confidenceByBrand[slug] ?? [],
                lineageNodes: lineageByBrand[slug] ?? [],
                leaderboard: leaderboardByBrand[slug],
                onboarding: onboardingByBrand[slug]
            )
        }
    }

    init(generatedAt: String,
         generatedAtEpoch: Double? = nil,
         mode: String = "OBSERVE",
         killSwitchOn: Bool = false,
         brands: [MetaAdsBrand] = [],
         journal: [DecisionEntry] = [],
         source: MetaAdsSourceMeta? = nil,
         attention: [AttentionItem] = [],
         empireRollup: EmpireRollup? = nil) {
        self.generatedAt = generatedAt
        self.generatedAtEpoch = generatedAtEpoch
        self.mode = mode
        self.killSwitchOn = killSwitchOn
        self.brands = brands
        self.journal = journal
        self.source = source
        self.attention = attention
        self.empireRollup = empireRollup
    }
}

// MARK: - Snapshot roll-up accessors (read-only convenience for the ops card)

// These compute brand-spanning totals the Empire ops roll-up shows, so the
// section views read one snapshot member each instead of re-summing brands.
extension MetaAdsSnapshot {
    // Alias for the kill flag under the name the ops card uses.
    var killSwitchEngaged: Bool { killSwitchOn }

    // Total spend today across all brands, in cents.
    var spendTodayCents: Int { brands.reduce(0) { $0 + $1.kpis.spendTodayCents } }

    // The effective daily cap to pace against: the max per-brand daily cap, or
    // the display-constant fallback when no brand carries one.
    var effectiveDailyCapCents: Int {
        brands.map { $0.pacing.dailyCapCents }.max() ?? MetaAdsCaps.effectiveDailyBudgetCents
    }

    // Concept-family bucket counts summed across every brand.
    var winnerCount: Int { familyCount(in: .winners) }
    var contenderCount: Int { familyCount(in: .contenders) }
    var graveyardCount: Int { familyCount(in: .graveyard) }

    private func familyCount(in bucket: FamilyBucket) -> Int {
        brands.reduce(0) { $0 + $1.families.filter { $0.bucket == bucket }.count }
    }
}

// MARK: - Attention roll-up accessors (power-tool, attention-first)

// Snapshot-level convenience the attention queue + fleet deck read. The empire
// queue is the snapshot-level attention plus every brand's attention, deduped by
// id and sorted critical-first then most-recent-ish (stable by id as a tiebreak).
extension MetaAdsSnapshot {
    // Snapshot-level attention + every brand's attention, deduped by id, sorted by
    // severity (critical first) then by id for a stable order.
    var allAttention: [AttentionItem] {
        var seen = Set<String>()
        var merged: [AttentionItem] = []
        for item in attention + brands.flatMap({ $0.attention }) {
            if seen.insert(item.id).inserted { merged.append(item) }
        }
        return merged.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return a.id < b.id
        }
    }

    // Total attention items needing the user across every brand.
    var attentionCount: Int { allAttention.count }

    // How many of those are critical (the loud-by-default count).
    var criticalCount: Int { allAttention.filter { $0.severity == .critical }.count }
}

// Engine source / mode badge data. Unknown extra fields are ignored by Codable.
struct MetaAdsSourceMeta: Codable, Equatable {
    var engine: String?       // engine identifier reported by the snapshot
    var simulate: Bool?       // true while fed mock insights
    var bootstrapped: Bool?   // false while act_PLACEHOLDER blocks live action
    var tookMs: Int?
    var note: String?
}

// MARK: - Per-brand

struct MetaAdsBrand: Codable, Equatable, Identifiable {
    var id: String           // brand slug, e.g. "acme"
    var slug: String?
    var name: String?
    var mode: String?        // per-brand mode override; falls back to snapshot.mode
    var bootstrapped: Bool?  // false => cannot act live (double-gate, with mode)
    var kpis: MetaAdsKPIs
    var pacing: MetaAdsPacing
    var families: [ConceptFamily]

    // Power-tool arrays (all optional, default empty, decoded leniently so an
    // OLDER snapshot that lacks any of these keys still decodes). For the explicit
    // -brands decode path the arrays ride inside each MetaAdsBrand object directly;
    // for the synthesize path MetaAdsSnapshot threads the slug-matched slice in.
    var activeAds: [ActiveAd]                  // key "active_ads": the row-level fleet
    var attention: [AttentionItem]             // key "attention": per-brand queue items
    var forecast: BrandForecast?               // key "forecast": burn/runway/projection
    var anomalies: [Anomaly]                   // key "anomalies": drift + outliers
    var proposedCampaigns: [ProposedCampaign]  // key "proposed_campaigns"
    var confidence: [FamilyConfidence]         // key "confidence": P(B>A) per family
    var lineageNodes: [LineageNode]            // key "lineage_nodes": tree edges
    var leaderboard: BrandLeaderboardStat?     // key "leaderboard": rollup row stats
    var onboarding: BrandOnboarding?           // key "onboarding": go-live checklist

    enum CodingKeys: String, CodingKey {
        case id, slug, name, mode, bootstrapped, kpis, pacing, families
        case activeAds = "active_ads"
        case attention
        case forecast
        case anomalies
        case proposedCampaigns = "proposed_campaigns"
        case confidence
        case lineageNodes = "lineage_nodes"
        case leaderboard
        case onboarding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = (try? c.decode(String.self, forKey: .id))
        let decodedSlug = (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? nil
        id = decodedId ?? decodedSlug ?? UUID().uuidString
        slug = decodedSlug ?? decodedId
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        bootstrapped = try? c.decodeIfPresent(Bool.self, forKey: .bootstrapped)
        kpis = (try? c.decode(MetaAdsKPIs.self, forKey: .kpis)) ?? MetaAdsKPIs()
        pacing = (try? c.decode(MetaAdsPacing.self, forKey: .pacing)) ?? MetaAdsPacing()
        families = (try? c.decode([ConceptFamily].self, forKey: .families)) ?? []
        // Lenient power-tool arrays: any missing key defaults to empty / nil.
        activeAds = (try? c.decodeIfPresent([ActiveAd].self, forKey: .activeAds) ?? nil) ?? []
        attention = (try? c.decodeIfPresent([AttentionItem].self, forKey: .attention) ?? nil) ?? []
        forecast = try? c.decodeIfPresent(BrandForecast.self, forKey: .forecast)
        anomalies = (try? c.decodeIfPresent([Anomaly].self, forKey: .anomalies) ?? nil) ?? []
        proposedCampaigns = (try? c.decodeIfPresent([ProposedCampaign].self, forKey: .proposedCampaigns) ?? nil) ?? []
        confidence = (try? c.decodeIfPresent([FamilyConfidence].self, forKey: .confidence) ?? nil) ?? []
        lineageNodes = (try? c.decodeIfPresent([LineageNode].self, forKey: .lineageNodes) ?? nil) ?? []
        leaderboard = try? c.decodeIfPresent(BrandLeaderboardStat.self, forKey: .leaderboard)
        onboarding = try? c.decodeIfPresent(BrandOnboarding.self, forKey: .onboarding)
    }

    // Explicit encode so the cache mirror writes the power-tool arrays back under
    // their snake_case keys (the custom CodingKeys block Encodable synthesis).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(slug, forKey: .slug)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(bootstrapped, forKey: .bootstrapped)
        try c.encode(kpis, forKey: .kpis)
        try c.encode(pacing, forKey: .pacing)
        try c.encode(families, forKey: .families)
        try c.encode(activeAds, forKey: .activeAds)
        try c.encode(attention, forKey: .attention)
        try c.encodeIfPresent(forecast, forKey: .forecast)
        try c.encode(anomalies, forKey: .anomalies)
        try c.encode(proposedCampaigns, forKey: .proposedCampaigns)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(lineageNodes, forKey: .lineageNodes)
        try c.encodeIfPresent(leaderboard, forKey: .leaderboard)
        try c.encodeIfPresent(onboarding, forKey: .onboarding)
    }

    init(id: String,
         slug: String? = nil,
         name: String? = nil,
         mode: String? = nil,
         bootstrapped: Bool? = nil,
         kpis: MetaAdsKPIs = MetaAdsKPIs(),
         pacing: MetaAdsPacing = MetaAdsPacing(),
         families: [ConceptFamily] = [],
         activeAds: [ActiveAd] = [],
         attention: [AttentionItem] = [],
         forecast: BrandForecast? = nil,
         anomalies: [Anomaly] = [],
         proposedCampaigns: [ProposedCampaign] = [],
         confidence: [FamilyConfidence] = [],
         lineageNodes: [LineageNode] = [],
         leaderboard: BrandLeaderboardStat? = nil,
         onboarding: BrandOnboarding? = nil) {
        self.id = id
        self.slug = slug ?? id
        self.name = name
        self.mode = mode
        self.bootstrapped = bootstrapped
        self.kpis = kpis
        self.pacing = pacing
        self.families = families
        self.activeAds = activeAds
        self.attention = attention
        self.forecast = forecast
        self.anomalies = anomalies
        self.proposedCampaigns = proposedCampaigns
        self.confidence = confidence
        self.lineageNodes = lineageNodes
        self.leaderboard = leaderboard
        self.onboarding = onboarding
    }

    // Display name with a sensible fallback to the slug.
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return (slug ?? id).uppercased()
    }

    // Effective mode for this brand: per-brand override wins, else the snapshot default.
    func effectiveMode(default snapshotMode: String) -> String {
        if let m = mode, !m.isEmpty { return m }
        return snapshotMode
    }

    // Convenience aliases the ops roll-up reads directly off the brand record.
    var brandName: String { displayName }
    var isBootstrapped: Bool { bootstrapped ?? false }
    var spendTodayCents: Int { kpis.spendTodayCents }
    var dailyCapCents: Int { pacing.dailyCapCents }
}

// MARK: - Per-brand control-plane state (mode picker view model)

// A lightweight per-brand view model the mode control binds to. Derived from a
// MetaAdsBrand (or synthesized for the snapshot-wide default) so the segmented
// control has a typed mode and the bootstrap gate without re-reading the model.
struct MetaAdsBrandState: Identifiable, Equatable {
    var key: String          // brand slug, e.g. "acme" (the engine control key)
    var displayName: String
    var mode: MetaAdsMode
    var bootstrapped: Bool

    var id: String { key }

    // Build from a decoded brand, resolving its effective mode against the
    // snapshot default.
    init(brand: MetaAdsBrand, snapshotMode: String) {
        self.key = brand.slug ?? brand.id
        self.displayName = brand.displayName
        self.mode = MetaAdsMode(engine: brand.effectiveMode(default: snapshotMode))
        self.bootstrapped = brand.bootstrapped ?? false
    }

    init(key: String, displayName: String, mode: MetaAdsMode, bootstrapped: Bool) {
        self.key = key
        self.displayName = displayName
        self.mode = mode
        self.bootstrapped = bootstrapped
    }

    // A snapshot-wide default state for the embedded ops control, when no single
    // brand is selected: reads the global mode, conservatively not bootstrapped.
    static func global(from snapshot: MetaAdsSnapshot?) -> MetaAdsBrandState {
        if let first = snapshot?.brands.first {
            return MetaAdsBrandState(brand: first, snapshotMode: snapshot?.mode ?? "OBSERVE")
        }
        return MetaAdsBrandState(
            key: "all",
            displayName: "All brands",
            mode: MetaAdsMode(engine: snapshot?.mode),
            bootstrapped: false
        )
    }
}

struct MetaAdsKPIs: Codable, Equatable {
    var spendTodayCents: Int
    var spendWeekCents: Int
    var impressions: Int
    var clicks: Int
    var conversions: Int
    var cpaCents: Int?
    var ctr: Double?
    var roas: Double?

    // Engine pacing block nested inside each per-brand kpis object, used to
    // derive the flat MetaAdsPacing the UI binds to.
    var pacing: MetaAdsPacing?

    // Snake_case keys mirror the engine per-brand kpis object; camel fallbacks
    // keep hand-built snapshots decoding.
    enum CodingKeys: String, CodingKey {
        case spendTodayCents = "spend_today_cents"
        case spendWeekCents = "spend_week_cents"
        case cpaCents = "cpa_cents"
        case impressions, clicks, conversions, ctr, roas, pacing
        case spendTodayCentsCamel = "spendTodayCents"
        case spendWeekCentsCamel = "spendWeekCents"
        case cpaCentsCamel = "cpaCents"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spendTodayCents = (try? c.decode(Int.self, forKey: .spendTodayCents))
            ?? (try? c.decode(Int.self, forKey: .spendTodayCentsCamel)) ?? 0
        spendWeekCents = (try? c.decode(Int.self, forKey: .spendWeekCents))
            ?? (try? c.decode(Int.self, forKey: .spendWeekCentsCamel)) ?? 0
        impressions = (try? c.decode(Int.self, forKey: .impressions)) ?? 0
        clicks = (try? c.decode(Int.self, forKey: .clicks)) ?? 0
        conversions = (try? c.decode(Int.self, forKey: .conversions)) ?? 0
        cpaCents = (try? c.decodeIfPresent(Int.self, forKey: .cpaCents))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .cpaCentsCamel)) ?? nil
        ctr = try? c.decodeIfPresent(Double.self, forKey: .ctr)
        roas = try? c.decodeIfPresent(Double.self, forKey: .roas)
        pacing = try? c.decodeIfPresent(MetaAdsPacing.self, forKey: .pacing)
    }

    // The pacing the UI binds to: the nested engine pacing block when present,
    // else the display-constant fallback.
    var derivedPacing: MetaAdsPacing { pacing ?? MetaAdsPacing() }

    // Explicit encode (canonical engine keys): custom CodingKeys aliases block
    // Encodable synthesis.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(spendTodayCents, forKey: .spendTodayCents)
        try c.encode(spendWeekCents, forKey: .spendWeekCents)
        try c.encode(impressions, forKey: .impressions)
        try c.encode(clicks, forKey: .clicks)
        try c.encode(conversions, forKey: .conversions)
        try c.encodeIfPresent(cpaCents, forKey: .cpaCents)
        try c.encodeIfPresent(ctr, forKey: .ctr)
        try c.encodeIfPresent(roas, forKey: .roas)
        try c.encodeIfPresent(pacing, forKey: .pacing)
    }

    init(spendTodayCents: Int = 0,
         spendWeekCents: Int = 0,
         impressions: Int = 0,
         clicks: Int = 0,
         conversions: Int = 0,
         cpaCents: Int? = nil,
         ctr: Double? = nil,
         roas: Double? = nil,
         pacing: MetaAdsPacing? = nil) {
        self.spendTodayCents = spendTodayCents
        self.spendWeekCents = spendWeekCents
        self.impressions = impressions
        self.clicks = clicks
        self.conversions = conversions
        self.cpaCents = cpaCents
        self.ctr = ctr
        self.roas = roas
        self.pacing = pacing
    }
}

// Spend pacing vs the hard caps. The engine sends the caps it enforced; the UI
// falls back to MetaAdsCaps display constants if a field is absent.
struct MetaAdsPacing: Codable, Equatable {
    var dailyCapCents: Int
    var weeklyCapCents: Int
    var dailyPct: Double      // 0.0 ... 1.0+ (spendToday / dailyCap)
    var weeklyPct: Double     // 0.0 ... 1.0+ (spendWeek / weeklyCap)

    // Snake_case keys mirror the engine pacing block. The engine reports the pct
    // as a whole percentage (e.g. 95.1 or 9512.5); camel fallbacks keep
    // hand-built fractional snapshots working.
    enum CodingKeys: String, CodingKey {
        case dailyCapCents = "daily_cap_cents"
        case weeklyCapCents = "weekly_cap_cents"
        case dailyPctOfCap = "daily_pct_of_cap"
        case weeklyPctOfCap = "weekly_pct_of_cap"
        case dailyPct, weeklyPct
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyCapCents = (try? c.decode(Int.self, forKey: .dailyCapCents)) ?? MetaAdsCaps.effectiveDailyBudgetCents
        weeklyCapCents = (try? c.decode(Int.self, forKey: .weeklyCapCents)) ?? MetaAdsCaps.weeklySpendCapCents
        // Engine sends a whole percentage; normalize to the 0...1+ fraction the
        // UI expects. Fall back to an already-fractional camel key when present.
        if let pctWhole = try? c.decode(Double.self, forKey: .dailyPctOfCap) {
            dailyPct = pctWhole / 100.0
        } else {
            dailyPct = (try? c.decode(Double.self, forKey: .dailyPct)) ?? 0
        }
        if let pctWhole = try? c.decode(Double.self, forKey: .weeklyPctOfCap) {
            weeklyPct = pctWhole / 100.0
        } else {
            weeklyPct = (try? c.decode(Double.self, forKey: .weeklyPct)) ?? 0
        }
    }

    init(dailyCapCents: Int = MetaAdsCaps.effectiveDailyBudgetCents,
         weeklyCapCents: Int = MetaAdsCaps.weeklySpendCapCents,
         dailyPct: Double = 0,
         weeklyPct: Double = 0) {
        self.dailyCapCents = dailyCapCents
        self.weeklyCapCents = weeklyCapCents
        self.dailyPct = dailyPct
        self.weeklyPct = weeklyPct
    }

    // Explicit encode: write the engine's whole-percentage keys (fraction * 100)
    // so a cached snapshot round-trips back through the normalizing decoder.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dailyCapCents, forKey: .dailyCapCents)
        try c.encode(weeklyCapCents, forKey: .weeklyCapCents)
        try c.encode(dailyPct * 100.0, forKey: .dailyPctOfCap)
        try c.encode(weeklyPct * 100.0, forKey: .weeklyPctOfCap)
    }
}

// MARK: - Lineage concept family roll-up

// A concept family (crid lineage root) bucketed for the Winners / Contenders /
// Graveyard roll-up. nodeCount is the size of the single-parent forest under this
// crid; bestCpa is the best CPA achieved across its nodes.
struct ConceptFamily: Codable, Equatable, Identifiable {
    var crid: String
    var brand: String?        // owning brand slug, used to group families per brand
    var label: String?
    var bucket: FamilyBucket
    var nodeCount: Int
    var bestCpaCents: Int?
    var status: String?       // testing | scaling | winner | killed | archived (best node)

    var id: String { crid }

    // Snake_case keys mirror the engine family object: concept -> label,
    // node_count -> nodeCount, cpa_cents -> bestCpaCents, best_node -> status.
    enum CodingKeys: String, CodingKey {
        case crid, brand, bucket, status, label
        case concept
        case nodeCount = "node_count"
        case cpaCents = "cpa_cents"
        case bestNode = "best_node"
        // Camel fallbacks for hand-built / echoed snapshots.
        case nodeCountCamel = "nodeCount"
        case bestCpaCentsCamel = "bestCpaCents"
        case bestCpa
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crid = (try? c.decode(String.self, forKey: .crid)) ?? UUID().uuidString
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        // Label: explicit label wins, else the engine's concept tag.
        label = (try? c.decodeIfPresent(String.self, forKey: .label))
            ?? (try? c.decodeIfPresent(String.self, forKey: .concept)) ?? nil
        bucket = (try? c.decode(FamilyBucket.self, forKey: .bucket)) ?? .contenders
        nodeCount = (try? c.decode(Int.self, forKey: .nodeCount))
            ?? (try? c.decode(Int.self, forKey: .nodeCountCamel)) ?? 0
        // best CPA: engine cpa_cents, or a camel/shorthand fallback.
        if let v = try? c.decodeIfPresent(Int.self, forKey: .cpaCents) {
            bestCpaCents = v
        } else if let v = try? c.decodeIfPresent(Int.self, forKey: .bestCpaCentsCamel) {
            bestCpaCents = v
        } else {
            bestCpaCents = try? c.decodeIfPresent(Int.self, forKey: .bestCpa)
        }
        // Status: explicit status, else the engine's best_node id as a subject.
        status = (try? c.decodeIfPresent(String.self, forKey: .status))
            ?? (try? c.decodeIfPresent(String.self, forKey: .bestNode)) ?? nil
    }

    // Explicit encode: the CodingKeys carry decode-only aliases with no backing
    // property, which blocks Encodable synthesis, so we write canonical keys.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(crid, forKey: .crid)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(bucket, forKey: .bucket)
        try c.encode(nodeCount, forKey: .nodeCount)
        try c.encodeIfPresent(bestCpaCents, forKey: .cpaCents)
        try c.encodeIfPresent(status, forKey: .status)
    }

    init(crid: String,
         brand: String? = nil,
         label: String? = nil,
         bucket: FamilyBucket = .contenders,
         nodeCount: Int = 0,
         bestCpaCents: Int? = nil,
         status: String? = nil) {
        self.crid = crid
        self.brand = brand
        self.label = label
        self.bucket = bucket
        self.nodeCount = nodeCount
        self.bestCpaCents = bestCpaCents
        self.status = status
    }

    var displayLabel: String {
        if let l = label, !l.isEmpty { return l }
        return crid
    }
}

enum FamilyBucket: String, Codable, Equatable, CaseIterable {
    case winners
    case contenders
    case graveyard

    // Lenient decode: unknown / unexpected strings fall back to contenders so the
    // UI never drops a family.
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.lowercased() ?? ""
        self = FamilyBucket(rawValue: raw) ?? .contenders
    }

    // Explicit encode: a custom init(from:) suppresses the synthesized
    // Encodable conformance, so we restore it here (encode the raw string).
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Qwen decision journal

// One entry in the Qwen-driven hypothesis-gated decision journal: a spawn, kill,
// scale, or hold decision, with the rationale and which gates it passed. applied
// is false in OBSERVE / RECOMMEND (logged, not enacted) and true only when an
// AUTONOMOUS run with a bootstrapped account actually pushed the change.
struct DecisionEntry: Codable, Equatable, Identifiable {
    var ts: String
    var brand: String?
    var action: String        // spawn | kill | scale | winner | hold | pause | ...
    var rationale: String?
    var mode: String?         // mode the engine was in when this was decided
    var gatesPassed: [String]
    var applied: Bool
    var nodeId: String?       // optional lineage node id the decision hit
    var crid: String?         // optional concept-family root id

    // Stable-ish identity for ForEach: timestamp + action + brand + a rationale hash.
    var id: String { "\(ts)|\(brand ?? "")|\(action)|\(rationale?.hashValue ?? 0)" }

    // Typed view of the engine's action string for the journal UI.
    var actionKind: MetaAdsDecisionAction { MetaAdsDecisionAction(engine: action) }

    // Non-optional accessors the journal rows render.
    var brandLabel: String { brand ?? "-" }
    var rationaleText: String { rationale ?? "" }

    // Optional lineage subject (node id / crid) the engine may attach to a row.
    var subject: String? {
        if let n = nodeId, !n.isEmpty { return n }
        if let c = crid, !c.isEmpty { return c }
        return nil
    }

    // Epoch seconds for newest-first sorting and relative-time labels. Parses the
    // ISO ts; falls back to 0 so an unparseable stamp sinks to the bottom.
    var atEpoch: Double {
        DecisionEntry.isoParser.date(from: ts)?.timeIntervalSince1970 ?? 0
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // Keys mirror the engine journal entry. gates_passed may be null in OBSERVE.
    enum CodingKeys: String, CodingKey {
        case ts, brand, action, rationale, mode, applied, crid
        case gatesPassed = "gates_passed"
        case nodeId = "node_id"
        case gatesPassedCamel = "gatesPassed"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = (try? c.decode(String.self, forKey: .ts)) ?? ""
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        action = (try? c.decode(String.self, forKey: .action)) ?? "hold"
        rationale = try? c.decodeIfPresent(String.self, forKey: .rationale)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        gatesPassed = (try? c.decodeIfPresent([String].self, forKey: .gatesPassed) ?? nil)
            ?? (try? c.decodeIfPresent([String].self, forKey: .gatesPassedCamel) ?? nil)
            ?? []
        applied = (try? c.decode(Bool.self, forKey: .applied)) ?? false
        nodeId = try? c.decodeIfPresent(String.self, forKey: .nodeId)
        crid = try? c.decodeIfPresent(String.self, forKey: .crid)
    }

    // Explicit encode (canonical engine keys): custom CodingKeys aliases block
    // Encodable synthesis.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(rationale, forKey: .rationale)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encode(gatesPassed, forKey: .gatesPassed)
        try c.encode(applied, forKey: .applied)
        try c.encodeIfPresent(nodeId, forKey: .nodeId)
        try c.encodeIfPresent(crid, forKey: .crid)
    }

    init(ts: String,
         brand: String? = nil,
         action: String,
         rationale: String? = nil,
         mode: String? = nil,
         gatesPassed: [String] = [],
         applied: Bool = false,
         nodeId: String? = nil,
         crid: String? = nil) {
        self.ts = ts
        self.brand = brand
        self.action = action
        self.rationale = rationale
        self.mode = mode
        self.gatesPassed = gatesPassed
        self.applied = applied
        self.nodeId = nodeId
        self.crid = crid
    }
}
