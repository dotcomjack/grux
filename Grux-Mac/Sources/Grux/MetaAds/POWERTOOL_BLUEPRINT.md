# Meta Ads Power Tool: Architecture Blueprint

The Meta Ads tab is being upgraded from a single-brand OBSERVE console into a
multi-brand OVERSIGHT COCKPIT over the autonomous engine. Grux drives the ship:
it crafts and (in AUTONOMOUS, when bootstrapped) publishes campaigns, ad sets,
ads, and full targeting. The operator oversees and overrides only. The default
view is CALM: attention-first, progressive disclosure, nothing that does not need
you is hidden behind a drill.

This blueprint is the authoritative contract for a parallel build. Phases:

- DATA-LAYER phase owns `MetaAdsSnapshot.swift` edits + a new `MetaAdsModels.swift`
  (section 1). It is the ONLY phase that touches those two files.
- INTEGRATION phase owns the root `MetaAdsView.swift` rewrite, the new
  `pendingChatPrompt` field on `AppState.swift`, and the `ChatView.swift`
  `.onChange` consumer (sections 2 + 4).
- COMPONENT phases each own exactly ONE new file from section 3. No shared-file
  edits between component phases.

Hard rules carried into every phase: native SwiftUI, GruxTheme tokens only,
zero em/en dashes, dollars as `$N`, no git commit/push, SIMULATE/OBSERVE posture
(nothing spends; `brand-a` is `act_PLACEHOLDER`).

The engine reality this maps to (read from the engine source, `engine/`): a
single-parent lineage FOREST where every node carries `node_id`, `crid` (family root),
`parent_id`, `generation`, `changed_variable` (one of hook | headline |
primary_text | scene | format | aspect_ratio | cta | audience), `variable_value`,
`status`, `hypothesis`, a `stats` blob (spend, impressions, clicks, conversions,
cpa, ctr, frequency), and `brand`. `bayes.py` produces P(B>A) per family at the
0.95 winner bar. `bandit.py` produces a Thompson allocation map (node -> weight,
the impression share, with a 0.15 explore floor). `decisions.py` emits a typed
intent per node (hold | kill | scale | promote_winner | spawn) with a 7-day
do-not-judge learning window and frequency/CTR kill rules. `meta_bridge.py`
builds CBO campaign + ad sets (with a `targeting` dict) + creative (headline,
primary_text, cta_type, product-in-scene image). All of that is now surfaced.

---

## 1. DATA MODEL (authoritative contract)

All new structs live in a NEW file `Sources/Grux/MetaAds/MetaAdsModels.swift`
so the existing `MetaAdsSnapshot.swift` stays small. The existing structs gain a
few optional arrays (additive, lenient decode, default `[]`/`nil` so old
snapshots still decode). Every new struct follows the existing house style:
custom `CodingKeys` with snake_case primary + camel fallbacks, lenient
`init(from:)`, explicit `encode(to:)`, sensible memberwise init, `Equatable`,
`Identifiable` where listed.

### 1a. Existing structs gain arrays (edit `MetaAdsSnapshot.swift`)

`MetaAdsBrand` gains (all optional, default empty, decoded leniently):

```swift
var activeAds: [ActiveAd]            // key "active_ads"   -> the row-level fleet
var attention: [AttentionItem]       // key "attention"    -> per-brand queue items
var forecast: BrandForecast?         // key "forecast"     -> burn/runway/projection
var anomalies: [Anomaly]             // key "anomalies"    -> drift + outliers
var proposedCampaigns: [ProposedCampaign]  // key "proposed_campaigns"
var confidence: [FamilyConfidence]   // key "confidence"   -> P(B>A) per family
var lineageNodes: [LineageNode]      // key "lineage_nodes"-> tree edges for the visualizer
var leaderboard: BrandLeaderboardStat?  // key "leaderboard" -> rollup row stats
```

`MetaAdsSnapshot` gains:

```swift
var attention: [AttentionItem]       // key "attention" -> empire-wide queue (brand-spanning)
var empireRollup: EmpireRollup?      // key "empire_rollup" -> cross-brand totals for the digest hook
```

`MetaAdsSnapshot` also gains computed roll-up accessors (extension, no new
stored state): `allAttention` (snapshot-level + every brand's, deduped by id,
sorted by severity then recency), `attentionCount`, `criticalCount`.

The synthesize path in `MetaAdsSnapshot.init(from:)` must thread the new
per-brand arrays through `synthesizeBrands(...)` by reading them from the flat
engine payload keyed by brand slug (the engine emits `active_ads_by_brand`,
`attention_by_brand`, etc.; the synthesizer maps slug -> array exactly like it
already does for `kpis` and `per_brand_mode`). For the explicit-brands decode
path the arrays ride inside each `MetaAdsBrand` object directly.

### 1b. ActiveAd (the fleet row + higher-level signals)

Backs the active-ad rows AND the creative gallery AND ad detail. One struct per
real Meta ad (a lineage node mapped to its published ad).

```swift
struct ActiveAd: Codable, Equatable, Identifiable {
    var id: String                  // node_id (engine lineage node id), stable
    var crid: String                // owning concept-family root
    var brand: String?              // owning brand slug
    var name: String?               // human ad name (engine node name)
    var status: AdStatus            // learning | winner | contender | killing | paused
    var changedVariable: String?    // the ONE tested variable: hook|headline|primary_text|scene|format|aspect_ratio|cta|audience
    var variableValue: String?      // the value of that variable on this node
    var hypothesis: String?         // the engine hypothesis this node tests

    // Creative (for the gallery + thumbnails)
    var thumbnailURL: String?       // creative image url (engine emits an http url or file path)
    var headline: String?           // creative headline
    var primaryText: String?        // creative primary text
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
    var daysRunning: Int            // age in days
    var impressionSharePct: Double? // 0...1 Thompson allocation weight for this node
    var learningProgress: Double?   // 0...1 toward exiting the 7-day do-not-judge window
    var frequency: Double?          // avg impressions per person (fatigue signal)
    var fatigueLevel: FatigueLevel? // ok | watch | fatigued (derived from frequency)
    var pBeatsBaseline: Double?     // 0...1 P(this variant > family baseline)
    var bestAudienceSegment: String? // top-performing segment label (e.g. "Women 35-44, US")
    var engineIntent: EngineIntent  // hold | scale | kill | spawn | promote
    var proposedNextAction: String? // human one-liner: "scale to $19/day", "kill: 3x CPA no conv"

    // Targeting summary (what the engine published; you drill in to verify)
    var targeting: TargetingSummary?

    // Cost-per-result sparkline series, oldest -> newest, cents per result.
    var costPerResultSeries: [Int]  // key "cost_per_result_series"

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
        // camel fallbacks for id and the money/series keys
        case idCamel = "id"
    }
}

enum AdStatus: String, Codable, Equatable, CaseIterable {
    case learning, winner, contender, killing, paused
    init(engine raw: String?) { /* lenient: map testing->contender, scaling->winner, archived/killed->killing, default contender */ }
    // presentation (tint/icon/label) lives in the component file, NOT here
}

enum FatigueLevel: String, Codable, Equatable { case ok, watch, fatigued }

enum EngineIntent: String, Codable, Equatable, CaseIterable {
    case hold, scale, kill, spawn, promote
    init(engine raw: String?) { /* map promote_winner->promote, scale_up->scale, default hold */ }
}
```

### 1c. TargetingSummary (the engine-crafted targeting you verify)

```swift
struct TargetingSummary: Codable, Equatable {
    var locations: [String]    // key "locations": ["US", "CA"] person-location
    var ageMin: Int?           // key "age_min"
    var ageMax: Int?           // key "age_max"
    var genders: [String]      // key "genders": ["all"] | ["women"]
    var devices: [String]      // key "devices": ["mobile","desktop"]
    var placements: [String]   // key "placements": ["feed","reels","stories"]
    var dayParting: [String]   // key "day_parting": ["18:00-23:00"]
    var interests: [String]    // key "interests": audience interest labels
    var advantageAudience: Bool? // key "advantage_audience" (Meta Advantage+)
    var summaryLine: String?   // key "summary_line": engine one-liner of the whole targeting
}
```

### 1d. AttentionItem (the queue, the heart of attention-first)

```swift
struct AttentionItem: Codable, Equatable, Identifiable {
    var id: String                 // engine-stable id (key "id")
    var kind: AttentionKind        // approval | anomaly | drift | fatigue | budget | winner | kill_proposed | proposed_campaign
    var severity: AttentionSeverity// critical | warning | info
    var brand: String?
    var title: String              // short headline ("Approve scale to $19/day")
    var message: String            // one or two sentence detail
    var target: AttentionTarget?   // what this points at (ad / family / brand)
    var suggestedAction: SuggestedAction? // the one-click action the engine proposes
    var sendToClaudePrompt: String?// pre-baked deep-audit prompt for the Send to Claude button

    enum CodingKeys: String, CodingKey {
        case id, kind, severity, brand, title, message, target
        case suggestedAction = "suggested_action"
        case sendToClaudePrompt = "send_to_claude_prompt"
    }
}

enum AttentionKind: String, Codable, Equatable {
    case approval, anomaly, drift, fatigue, budget, winner, killProposed = "kill_proposed", proposedCampaign = "proposed_campaign"
    init(engine raw: String?) { /* lenient default .info-ish bucket -> .anomaly */ }
}

enum AttentionSeverity: String, Codable, Equatable, Comparable {
    case info, warning, critical
    // Comparable so the queue sorts critical-first
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    var rank: Int { switch self { case .info: 0; case .warning: 1; case .critical: 2 } }
    init(engine raw: String?) { /* lenient default .warning */ }
}

// What an attention item / Send-to-Claude points at, so the UI can deep-link.
struct AttentionTarget: Codable, Equatable {
    var type: TargetType       // brand | family | ad
    var brand: String?
    var crid: String?          // for family
    var nodeId: String?        // for ad
    var label: String?         // display label
    enum TargetType: String, Codable, Equatable { case brand, family, ad }
    enum CodingKeys: String, CodingKey { case type, brand, crid, nodeId = "node_id", label }
}

// The one-click action a queue item or row offers. The UI maps verb -> the real
// MetaAdsService control call (section 4). actId stays a placeholder in SIMULATE.
struct SuggestedAction: Codable, Equatable {
    var verb: ActionVerb       // approve | veto | pause | scale | kill | spawn | flip_mode
    var label: String          // button copy ("Approve scale")
    var brand: String?
    var nodeId: String?        // key "node_id"
    var crid: String?
    var paramCents: Int?       // key "param_cents" (e.g. proposed new daily budget)
    var paramMode: String?     // key "param_mode" (for flip_mode)
    var requiresConfirm: Bool  // key "requires_confirm" (default true; never silently spends)

    enum ActionVerb: String, Codable, Equatable {
        case approve, veto, pause, scale, kill, spawn, flipMode = "flip_mode"
    }
}
```

### 1e. BrandForecast (pacing + forecast)

```swift
struct BrandForecast: Codable, Equatable {
    var burnRateCentsPerDay: Int    // key "burn_rate_cents_per_day" (trailing avg)
    var runwayDays: Double?         // key "runway_days" (days until weekly cap at current burn)
    var projectedMonthCents: Int    // key "projected_month_cents" (burn x 30)
    var projectedMonthVsBudgetPct: Double? // key "projected_vs_budget_pct" (0...1+)
    var spendSeries: [Int]          // key "spend_series" daily spend cents, oldest->newest, for the chart
    var capLineCents: Int?          // key "cap_line_cents" the daily cap to draw as a reference line
}
```

### 1f. Anomaly (anomaly + drift)

```swift
struct Anomaly: Codable, Equatable, Identifiable {
    var id: String              // key "id"
    var brand: String?
    var metric: String          // "cpa" | "ctr" | "spend" | "frequency"
    var kind: String            // "spike" | "drop" | "drift" | "flatline"
    var severity: AttentionSeverity
    var message: String         // human description
    var nodeId: String?         // key "node_id" affected ad, if scoped
    var deltaPct: Double?       // key "delta_pct" how far off the baseline (signed)
    var detectedAt: String?     // key "detected_at" iso
}
```

### 1g. ProposedCampaign (the engine-crafted campaign you approve)

```swift
struct ProposedCampaign: Codable, Equatable, Identifiable {
    var id: String                 // key "id"
    var brand: String?
    var concept: String            // the new concept/angle (gen-0 root idea)
    var hypothesis: String?        // why the engine wants to run it
    var headline: String?
    var primaryText: String?
    var ctaType: String?           // key "cta_type"
    var thumbnailURL: String?      // key "thumbnail_url" the proposed product-in-scene
    var dailyBudgetCents: Int      // key "daily_budget_cents" (clamped <= effective cap)
    var targeting: TargetingSummary?
    var changedFromCrid: String?   // key "changed_from_crid" if spun off a winner
    var changedVariable: String?   // key "changed_variable" the one variable being branched
    var status: String?            // "pending_approval" | "approved" | "vetoed"
    var sendToClaudePrompt: String?// key "send_to_claude_prompt"
}
```

### 1h. Confidence + lineage + leaderboard + rollup

```swift
// Bayesian A/B readout per concept family (bayes.py P(B>A) at the 0.95 bar).
struct FamilyConfidence: Codable, Equatable, Identifiable {
    var crid: String               // family root; id = crid
    var id: String { crid }
    var label: String?
    var pBeatsA: Double            // key "p_beats_a" 0...1 P(best variant > control)
    var winnerBar: Double          // key "winner_bar" default 0.95
    var leaderNodeId: String?      // key "leader_node_id" current best variant
    var controlNodeId: String?     // key "control_node_id"
    var conversionsObserved: Int   // key "conversions_observed" (gate context)
    var decided: Bool              // key "decided" has it crossed the bar
}

// A single edge in the lineage tree for the visualizer (root -> variant, labeled
// with the one changed variable). The whole forest for one brand is [LineageNode].
struct LineageNode: Codable, Equatable, Identifiable {
    var id: String                 // node_id
    var crid: String
    var parentId: String?          // key "parent_id" (nil = gen-0 root)
    var generation: Int
    var changedVariable: String?   // key "changed_variable" edge label
    var variableValue: String?     // key "variable_value"
    var status: String?            // node status for the dot color
    var cpaCents: Int?             // key "cpa_cents" for a quick perf tint
    var label: String?
    enum CodingKeys: String, CodingKey {
        case id = "node_id", crid, parentId = "parent_id", generation
        case changedVariable = "changed_variable", variableValue = "variable_value"
        case status, cpaCents = "cpa_cents", label
    }
}

// Per-brand stats for the fleet-deck leaderboard row + sorting.
struct BrandLeaderboardStat: Codable, Equatable {
    var bestNodeId: String?        // key "best_node_id"
    var bestLabel: String?         // key "best_label"
    var bestCpaCents: Int?         // key "best_cpa_cents"
    var worstNodeId: String?       // key "worst_node_id"
    var worstLabel: String?        // key "worst_label"
    var worstCpaCents: Int?        // key "worst_cpa_cents"
    var blendedRoas: Double?       // key "blended_roas"
    var attentionFlag: Bool        // key "attention_flag" does this brand need you
    var oldestAdDays: Int?         // key "oldest_ad_days" (for age sort)
}

// Cross-brand totals for the empire roll-up tile + Telegram digest hook.
struct EmpireRollup: Codable, Equatable {
    var totalSpendTodayCents: Int  // key "total_spend_today_cents"
    var totalSpendWeekCents: Int   // key "total_spend_week_cents"
    var blendedCpaCents: Int?      // key "blended_cpa_cents"
    var blendedRoas: Double?       // key "blended_roas"
    var winnerCount: Int           // key "winner_count"
    var liveAdCount: Int           // key "live_ad_count"
    var attentionCount: Int        // key "attention_count"
}
```

### 1i. Matching JSON the engine emits (shape reference)

The engine snapshot (`engine/snapshot.py`) keeps its current flat shape and adds
sibling keys. Illustrative slice:

```json
{
  "generated_iso": "2026-06-14T13:00:00Z",
  "generated_at": 1750000000,
  "mode": "OBSERVE",
  "kill": false,
  "brands_known": ["brand-a", "brand-b", "brand-c", "brand-d"],
  "per_brand_mode": { "brand-a": "OBSERVE" },
  "kpis": { "brand-a": { "spend_today_cents": 1240, "spend_week_cents": 8730, "impressions": 41200, "clicks": 612, "conversions": 19, "cpa_cents": 653, "ctr": 0.0148, "roas": 2.1, "pacing": { "daily_cap_cents": 2000, "weekly_cap_cents": 14000, "daily_pct_of_cap": 62.0, "weekly_pct_of_cap": 62.4 } } },
  "families": [ { "crid": "brand-a-product-one", "brand": "brand-a", "concept": "Product One concept", "bucket": "winners", "node_count": 6, "cpa_cents": 512, "best_node": "n_ab12" } ],
  "active_ads_by_brand": { "brand-a": [
    { "node_id": "n_ab12", "crid": "brand-a-product-one", "brand": "brand-a", "name": "Product One / hook B", "status": "winner",
      "changed_variable": "hook", "variable_value": "before-after", "hypothesis": "before/after hook lifts CTR",
      "thumbnail_url": "http://host:3857/adimages/n_ab12.png", "headline": "Glow you can feel", "primary_text": "...", "cta_type": "SHOP_NOW",
      "spend_cents": 480, "cpa_cents": 512, "roas": 2.6, "impressions": 18200, "clicks": 311, "conversions": 11, "ctr": 0.0171,
      "days_running": 9, "impression_share_pct": 0.34, "learning_progress": 1.0, "frequency": 1.8, "fatigue_level": "ok",
      "p_beats_baseline": 0.97, "best_audience_segment": "Women 35-44, US", "engine_intent": "scale",
      "proposed_next_action": "Scale to $19/day, P(B>A) 0.97 over 11 conversions",
      "targeting": { "locations": ["US"], "age_min": 28, "age_max": 55, "genders": ["women"], "devices": ["mobile"], "placements": ["feed","reels"], "day_parting": ["17:00-23:00"], "interests": ["natural skincare"], "advantage_audience": true, "summary_line": "Women 28-55, US, mobile feed+reels, evenings" },
      "cost_per_result_series": [820, 740, 690, 600, 512] } ] },
  "attention_by_brand": { "brand-a": [
    { "id": "att_scale_n_ab12", "kind": "approval", "severity": "warning", "brand": "brand-a", "title": "Approve scale to $19/day",
      "message": "Product One hook B cleared P(B>A) 0.97 on 11 conversions. Engine wants to scale 20%.",
      "target": { "type": "ad", "brand": "brand-a", "node_id": "n_ab12", "label": "Product One / hook B" },
      "suggested_action": { "verb": "scale", "label": "Approve scale", "brand": "brand-a", "node_id": "n_ab12", "param_cents": 1900, "requires_confirm": true },
      "send_to_claude_prompt": "Fully audit ad n_ab12 ..." } ] },
  "forecast_by_brand": { "brand-a": { "burn_rate_cents_per_day": 1180, "runway_days": 6.2, "projected_month_cents": 35400, "projected_vs_budget_pct": 0.59, "spend_series": [900,1020,1180,1240], "cap_line_cents": 2000 } },
  "anomalies_by_brand": { "brand-a": [ { "id": "an_freq_1", "brand": "brand-a", "metric": "frequency", "kind": "spike", "severity": "warning", "message": "Ad n_cd34 frequency 3.1, fatigue risk", "node_id": "n_cd34", "delta_pct": 0.45, "detected_at": "2026-06-14T11:00:00Z" } ] },
  "proposed_campaigns_by_brand": { "brand-a": [ { "id": "pc_p3_1", "brand": "brand-a", "concept": "Product Three night ritual", "hypothesis": "...", "headline": "...", "daily_budget_cents": 1600, "cta_type": "SHOP_NOW", "thumbnail_url": "...", "changed_from_crid": "brand-a-product-one", "changed_variable": "scene", "status": "pending_approval", "send_to_claude_prompt": "..." } ] },
  "confidence_by_brand": { "brand-a": [ { "crid": "brand-a-product-one", "label": "Product One concept", "p_beats_a": 0.97, "winner_bar": 0.95, "leader_node_id": "n_ab12", "control_node_id": "n_root", "conversions_observed": 11, "decided": true } ] },
  "lineage_by_brand": { "brand-a": [ { "node_id": "n_root", "crid": "brand-a-product-one", "parent_id": null, "generation": 0, "changed_variable": "concept", "status": "scaling", "label": "Product One concept" }, { "node_id": "n_ab12", "crid": "brand-a-product-one", "parent_id": "n_root", "generation": 1, "changed_variable": "hook", "variable_value": "before-after", "status": "winner", "cpa_cents": 512 } ] },
  "leaderboard_by_brand": { "brand-a": { "best_node_id": "n_ab12", "best_label": "Product One / hook B", "best_cpa_cents": 512, "worst_node_id": "n_cd34", "worst_label": "Product Two / cta A", "worst_cpa_cents": 1840, "blended_roas": 2.1, "attention_flag": true, "oldest_ad_days": 14 } },
  "empire_rollup": { "total_spend_today_cents": 1240, "total_spend_week_cents": 8730, "blended_cpa_cents": 653, "blended_roas": 2.1, "winner_count": 2, "live_ad_count": 7, "attention_count": 3 },
  "attention": [],
  "journal": [ ... existing shape ... ]
}
```

The DATA-LAYER phase mirrors this in `synthesizeBrands`: read `active_ads_by_brand`,
`attention_by_brand`, `forecast_by_brand`, `anomalies_by_brand`,
`proposed_campaigns_by_brand`, `confidence_by_brand`, `lineage_by_brand`,
`leaderboard_by_brand` as `[String: [...]]` / `[String: ...]` and hand the
slug-matched slice to each `MetaAdsBrand`.

---

## 2. IA + NAVIGATION

Two-level navigation inside the tab, never a Meta Ads Manager clone.

LEVEL 0, FLEET COMMAND DECK (landing, the default calm view). The root
`MetaAdsView` renders, top to bottom:

1. A slim COMMAND BAR (eyebrow microCaps "AUTONOMOUS ENGINE", title "Meta Ads",
   engine/SIMULATE/updated subtitle, global kill switch state, refresh). Reuses
   `MetaAdsKillSwitch` semantics in a compact form.
2. An EMPIRE ROLL-UP strip (`MetaAdsEmpireRollupBar`): total spend today/week,
   blended CPA/ROAS, winner count, live-ad count, attention count, plus the
   Telegram digest "send now" affordance (`MetaAdsDigestControl`, reused). One
   "Send to Claude" on the whole empire sits here.
3. The ATTENTION QUEUE (`MetaAdsAttentionQueue`), ONLY rendered when non-empty.
   This is what makes the view attention-first: if nothing needs you, the deck
   is calm and this section is absent (replaced by a single calm "All clear"
   line). Each item has its one-click action + a Send to Claude.
4. The FLEET DECK (`MetaAdsFleetDeck`): one sortable row per brand
   (`MetaAdsBrandFleetRow`). All brands at once. `brand-a` populated; the others
   render empty-ready. A segmented sort control (brand | spend | CPA | ROAS |
   status | age | attention | concept family). Tapping a brand row drills in.

LEVEL 1, BRAND DRILL (`MetaAdsBrandDetailView`, pushed via a selection state in
the root, shown in place with a back affordance). A segmented control switches
between calm sub-surfaces so the brand view is never a wall:

- OVERVIEW: KPI strip (reuse existing `kpiStrip` look), pacing bars (reuse
  `MetaAdsPacingBar`), forecast (`MetaAdsForecastCard`), this brand's attention
  slice, mode control (`MetaAdsModeControl`, reused).
- ADS: the active-ad fleet table (`MetaAdsActiveAdTable` -> rows
  `MetaAdsActiveAdRow`), filterable by status. Tapping a row drills to ad detail.
- CREATIVE: thumbnail gallery with perf overlay (`MetaAdsCreativeGallery`).
- LINEAGE: family tree visualizer (`MetaAdsLineageTree`) + the A/B confidence
  readout (`MetaAdsConfidenceReadout`) side by side.
- JOURNAL: the decision timeline (reuse `MetaAdsJournalView`, full mode), with a
  brand + action filter.

LEVEL 2, AD DETAIL (`MetaAdsAdDetailView`, pushed from an ADS row or a CREATIVE
tile or an attention target). Shows the full creative, the one tested variable
and its value, the full `TargetingSummary` (person location, age, genders,
devices, placements, day-parting, interests), all KPIs, the cost-per-result
sparkline, learning progress, frequency/fatigue, P(B>A), best audience segment,
engine intent + proposed next action, the override-actions control
(`MetaAdsActionBar`), the variant spawner (`MetaAdsVariantSpawner`), and a Send
to Claude scoped to this ad.

CALM POSTURE rules: the attention queue and the per-brand attention slice are
the ONLY always-loud surfaces. Everything else uses muted tints until the data
itself is hot (over-cap spend, a `critical` anomaly, a fatigued ad). Progressive
disclosure: the fleet deck rows are dense one-liners; detail is one tap away;
nothing auto-expands. The brand sub-segments default to OVERVIEW.

Navigation state lives in the root `MetaAdsView` as `@State` (selected brand,
selected sub-segment, selected ad), since the store already carries every brand
in one snapshot. No new store, no new routing system.

---

## 3. COMPONENT LIST (parallel-buildable, no shared-file edits)

Each file is self-contained: it reads `MetaAdsStore.shared` and/or takes typed
model values as init args, uses GruxTheme tokens, owns its own presentation
extensions (tints/icons/labels) so no two files edit the same enum extension.
Owner-of-truth structs (section 1) and the root `MetaAdsView` are NOT in this
list. Reused existing files (`MetaAdsPacingBar`, `MetaAdsModeControl`,
`MetaAdsKillSwitch`, `MetaAdsFamilyRow`, `MetaAdsJournalView`,
`MetaAdsDigestControl`) are NOT rebuilt; new files compose them.

1. `Sources/Grux/MetaAds/MetaAdsFleetDeck.swift`
   - View: `MetaAdsFleetDeck` (+ private `MetaAdsBrandFleetRow`, + the sort
     `enum MetaAdsFleetSort`).
   - Purpose: the landing fleet table. One sortable row per brand showing mode,
     spend vs cap, winner/contender/graveyard counts, best + worst performer,
     attention flag. Empty-ready rows for brands with no ads.
   - Reads: `[MetaAdsBrand]` (slug, displayName, effectiveMode, kpis, pacing,
     families bucket counts) + `MetaAdsBrand.leaderboard` (BrandLeaderboardStat:
     bestLabel, bestCpaCents, worstLabel, worstCpaCents, blendedRoas,
     attentionFlag, oldestAdDays). Calls back a `onSelectBrand(String)` closure.

2. `Sources/Grux/MetaAds/MetaAdsAttentionQueue.swift`
   - View: `MetaAdsAttentionQueue` (+ private `MetaAdsAttentionRow`).
   - Purpose: attention-first queue. Critical-first, severity-tinted rows; each
     carries its one-click `SuggestedAction` (routed through `MetaAdsActionBar`
     semantics) and a `SendToClaudeButton`. Renders an "All clear" calm line
     when the queue is empty.
   - Reads: `[AttentionItem]` (kind, severity, title, message, target,
     suggestedAction, sendToClaudePrompt). Calls `onSelectTarget(AttentionTarget)`.

3. `Sources/Grux/MetaAds/MetaAdsBrandDetailView.swift`
   - View: `MetaAdsBrandDetailView` (+ the `enum MetaAdsBrandSegment`).
   - Purpose: the LEVEL 1 brand drill with the OVERVIEW/ADS/CREATIVE/LINEAGE/
     JOURNAL segmented control; composes the sibling components for each segment;
     back affordance. OVERVIEW composes the reused KPI/pacing/mode pieces plus
     `MetaAdsForecastCard`.
   - Reads: one `MetaAdsBrand` (all arrays) + snapshot mode. Calls
     `onBack()` and `onSelectAd(ActiveAd)`.

4. `Sources/Grux/MetaAds/MetaAdsActiveAdTable.swift`
   - View: `MetaAdsActiveAdTable` (+ `MetaAdsActiveAdRow`, + `AdStatus`
     presentation extension owned here, + a status filter `enum`).
   - Purpose: the active-ad fleet for one brand. Each row: thumbnail, status
     badge, the one tested variable, spend, CPA, ROAS, days running, impression
     share, engine intent, plus learning progress + fatigue + P(B>A) + proposed
     next action where space allows (compact secondary line). Status filter chips.
   - Reads: `[ActiveAd]`. Calls `onSelectAd(ActiveAd)`.

5. `Sources/Grux/MetaAds/MetaAdsAdDetailView.swift`
   - View: `MetaAdsAdDetailView`.
   - Purpose: the LEVEL 2 full ad readout: creative, tested variable + value,
     full targeting summary, all KPIs, cost-per-result sparkline (composes
     `MetaAdsSparkline`), learning/fatigue/confidence/best-segment, engine intent
     + proposed next action; embeds `MetaAdsActionBar`, `MetaAdsVariantSpawner`,
     and a `SendToClaudeButton`.
   - Reads: one `ActiveAd` (every field incl. `targeting`, `costPerResultSeries`).
     Calls `onBack()`.

6. `Sources/Grux/MetaAds/MetaAdsCreativeGallery.swift`
   - View: `MetaAdsCreativeGallery` (+ `MetaAdsCreativeTile`).
   - Purpose: thumbnail grid with a perf overlay (CPA/ROAS/status badge on each
     tile). Uses `AsyncImage` for `thumbnailURL` with a glass placeholder.
   - Reads: `[ActiveAd]` (thumbnailURL, status, cpaCents, roas, name,
     changedVariable). Calls `onSelectAd(ActiveAd)`.

7. `Sources/Grux/MetaAds/MetaAdsLineageTree.swift`
   - View: `MetaAdsLineageTree` (+ a layout helper + edge label chips).
   - Purpose: the lineage visualizer: family root -> variant nodes, edges labeled
     with the one `changedVariable`. A horizontal indented-tree layout (gen 0
     root, children indented), each node a dot tinted by status + a CPA tag, each
     edge a small chip naming the changed variable. Self-contained layout (no new
     deps), reuses the FlowChips pattern style.
   - Reads: `[LineageNode]` (id, crid, parentId, generation, changedVariable,
     variableValue, status, cpaCents, label). Optional `onSelectNode(String)`.

8. `Sources/Grux/MetaAds/MetaAdsConfidenceReadout.swift`
   - View: `MetaAdsConfidenceReadout` (+ `MetaAdsConfidenceRow`).
   - Purpose: the Bayesian A/B readout: per family a P(B>A) bar against the 0.95
     winner bar, a "DECIDED"/"gathering" badge, leader vs control labels,
     conversions observed. Bar turns mint past the bar, amber approaching it.
   - Reads: `[FamilyConfidence]`.

9. `Sources/Grux/MetaAds/MetaAdsForecastCard.swift`
   - View: `MetaAdsForecastCard` (+ composes `MetaAdsSparkline`).
   - Purpose: spend pacing forecast: burn rate, cap runway (days), projected
     month vs budget, a daily-spend area chart with a cap reference line.
   - Reads: one `BrandForecast` (burnRateCentsPerDay, runwayDays,
     projectedMonthCents, projectedMonthVsBudgetPct, spendSeries, capLineCents).

10. `Sources/Grux/MetaAds/MetaAdsSparkline.swift`
    - View: `MetaAdsSparkline`.
    - Purpose: a tiny reusable line/area sparkline (a `[Int]` series -> a path),
      tintable, optional cap reference line, optional last-point dot. Used by the
      ad row cost-per-result trend, the ad detail, and the forecast card.
    - Reads: `series: [Int]`, `tint: Color`, `capLine: Int?` (init args only,
      no store dependency).

11. `Sources/Grux/MetaAds/MetaAdsVariantSpawner.swift`
    - View: `MetaAdsVariantSpawner`.
    - Purpose: spin a new A/B test off a winner by changing exactly ONE variable.
      A picker over the 8-value variable enum (hook | headline | primary_text |
      scene | format | aspect_ratio | cta | audience) + a value field, gated by
      mode + a confirm, routed through `MetaAdsService` (a new `spawnVariant`
      control call, section 4). Never silently spends; SIMULATE shows "queued".
    - Reads: the source `ActiveAd` (crid, changedVariable already used, brand) +
      `MetaAdsStore.shared` for mode/kill gating.

12. `Sources/Grux/MetaAds/MetaAdsActionBar.swift`
    - View: `MetaAdsActionBar` (+ a confirm sheet, + the `MetaAdsActionRunner`
      helper that maps a `SuggestedAction.verb` to the real `MetaAdsService` call).
    - Purpose: the reusable OVERRIDE-ACTIONS control. Approve / veto the engine's
      pending move; pause / force-scale / kill an individual ad; flip a brand
      mode. Every action gated by current mode + an explicit confirm; disabled +
      explained when the kill switch is on; "PLACEHOLDER, simulated" tag when the
      brand is not bootstrapped. Never silently spends.
    - Reads: a `SuggestedAction` (or an explicit verb + target) + `MetaAdsStore`
      (mode, killSwitchOn, isMutating). Calls `MetaAdsService` control endpoints.

13. `Sources/Grux/MetaAds/SendToClaudeButton.swift`
    - View: `SendToClaudeButton`.
    - Purpose: the SIGNATURE CTA, a small native glass pill ("Send to Claude",
      sparkles icon, violet accent) droppable on a brand, family, ad, or
      attention item. Builds the deep-audit prompt (from the model's
      `sendToClaudePrompt` when present, else a generated template, section 4),
      then sets `AppState.shared.requestedTab = "chat"` and
      `AppState.shared.pendingChatPrompt = prompt`.
    - Reads: an `AttentionTarget` OR a typed `(kind, label, brand, nodeId?, crid?)`
      and an optional pre-baked prompt string (init args only).

14. `Sources/Grux/MetaAds/MetaAdsEmpireRollupBar.swift`
    - View: `MetaAdsEmpireRollupBar`.
    - Purpose: the empire roll-up strip on the fleet deck: total spend, blended
      CPA/ROAS, winners, live ads, attention count, plus a brand-spanning Send to
      Claude and the reused `MetaAdsDigestControl`.
    - Reads: `EmpireRollup` + the empire-wide attention count.

That is 14 new files. If a phase budget caps at 12, fold `MetaAdsSparkline` into
`MetaAdsForecastCard` and `MetaAdsEmpireRollupBar` into the root view; the
structured output below lists the core 12 that must be standalone for parallel
builds (sparkline kept standalone because three components depend on it; rollup
bar kept since it is the only Send-to-Claude host on the deck).

Service additions (DATA-LAYER / INTEGRATION phase, in `MetaAdsService.swift` +
`MetaAdsStore.swift`, NOT a component file): `approveMove(id:)`, `vetoMove(id:)`,
`pauseAd(brand:nodeId:)`, `scaleAd(brand:nodeId:cents:)`, `killAd(brand:nodeId:)`,
`spawnVariant(brand:crid:variable:value:)`, each POSTing to
`/api/meta-ads/<verb>` mirroring the existing `setMode`/`setKill` pattern and
returning the echoed snapshot. All are no-ops spend-wise while `brand-a` is
`act_PLACEHOLDER`.

---

## 4. SEND-TO-CLAUDE + ACTIONS

### Send to Claude (the real wiring on main)

Mechanism, simplest real path that already exists:

1. `AppState` gains one field (INTEGRATION phase owns this edit):
   ```swift
   // Set by the Meta Ads "Send to Claude" button. ChatView consumes it once,
   // pre-fills the composer, then clears it. Transient (never persisted).
   @Published var pendingChatPrompt: String? = nil
   ```
2. `ChatView` consumes it (INTEGRATION phase, an additive `.onChange` + an
   `.onAppear` so a prompt set before the tab is shown still lands):
   ```swift
   .onChange(of: state.pendingChatPrompt) { _, new in
       guard let p = new, !p.isEmpty else { return }
       draft = draft.isEmpty ? p : draft + "\n\n" + p
       inputFocused = true
       state.pendingChatPrompt = nil   // consume once
   }
   .onAppear {
       if let p = state.pendingChatPrompt, !p.isEmpty {
           draft = p; inputFocused = true; state.pendingChatPrompt = nil
       }
   }
   ```
   The button does NOT auto-send; it stages the prompt and focuses the composer so
   you can edit before sending (matches the existing voice-draft pattern and the
   `chatRecovery` composer convention). This mirrors how `AgentsView`,
   `HomeView`, and `GruxApp` already set `requestedTab = "chat"`.
3. `SendToClaudeButton.action`:
   ```swift
   AppState.shared.pendingChatPrompt = prompt
   AppState.shared.requestedTab = "chat"
   ```

### Prompt templates

When the model carries a `sendToClaudePrompt`, use it verbatim. Otherwise the
button generates from a per-target template (zero em/en dashes, dollars as `$N`):

- BRAND:
  > Fully audit, analyze, and research the Meta ads for {BRAND}. Review every
  > active ad, the concept-family lineage, spend pacing against the $N daily and
  > $N weekly caps, the winners and the graveyard, and the open A/B tests. Pull
  > firm outside research on what is working for this category right now. Then
  > decide whether we should act: scale, kill, reallocate budget, or spin up new
  > A/B tests, and name the exact one-variable changes to test next. Recommend
  > concrete moves with the reasoning and the risk.

- FAMILY:
  > Fully audit the concept family {FAMILY} for {BRAND}. Walk the lineage from the
  > root through every variant, the one variable each branch changed, the CPA and
  > ROAS trend, and the Bayesian P(B>A) standing. Research comparable angles in
  > the market. Then decide: promote a winner, kill the laggards, or branch a new
  > one-variable test, and say which variable and value.

- AD:
  > Fully audit ad {NODE_ID} ({LABEL}) for {BRAND}. Look at the creative, the
  > one tested variable {CHANGED_VARIABLE}={VALUE}, the targeting (person
  > location, age, gender, device, placement, day-parting), the spend, CPA, ROAS,
  > frequency and fatigue, learning progress, the cost-per-result trend, and the
  > best-performing audience segment. Research whether this angle has room to
  > scale. Then decide whether we should hold, scale, kill, or spawn a new A/B
  > test off it, and name the single variable to change next.

- ATTENTION ITEM: use its `message` as the lead, then append the AD or FAMILY
  template for its `target`.

- EMPIRE: same as BRAND but across every brand, leading with the roll-up totals.

### Override actions

`MetaAdsActionBar` maps each `SuggestedAction.verb` to a real `MetaAdsService`
call (added per section 3), every one gated:

| verb | call | gate |
|---|---|---|
| approve | `approveMove(id:)` | confirm sheet |
| veto | `vetoMove(id:)` | confirm sheet |
| pause | `pauseAd(brand:nodeId:)` | confirm sheet |
| scale | `scaleAd(brand:nodeId:cents:)` | confirm + mode != OBSERVE warning + cap echo |
| kill | `killAd(brand:nodeId:)` | rose confirm sheet |
| spawn | `spawnVariant(brand:crid:variable:value:)` | confirm sheet |
| flip_mode | `MetaAdsStore.setMode(brand:mode:)` | the existing mode gate (AUTONOMOUS locked unless bootstrapped) |

Universal gates: if `killSwitchOn`, the whole bar is disabled with the "Clear the
halt first" line. If the brand is not bootstrapped, every spend-affecting verb
shows a "SIMULATED, act_PLACEHOLDER" tag and the engine treats it as a no-op.
`requiresConfirm` (default true) means no action ever fires on a single tap.
After any action, the bar calls `store.refresh()` so the UI reflects engine truth.

---

## 5. SIMULATE DATA PLAN (engine seed for a fully-populated tab)

The engine (`engine/simulator.py` + `engine/snapshot.py`) must seed one brand
(`brand-a`) so the tab renders every surface populated, with the other three
brands present but empty (empty-ready). Seed targets:

- `brand-a`: 3 concept families across buckets:
  - `brand-a-product-one` WINNERS: a gen-0 root + 5 variants (each branching ONE
    variable: hook, headline, scene, cta, audience). One variant `n_ab12` is the
    decided winner (P(B>A) 0.97, 11 conversions, engine intent `scale`, learning
    progress 1.0, frequency 1.8, best segment "Women 35-44, US").
  - `brand-a-product-two` CONTENDERS: a root + 2 variants still LEARNING (learning
    progress 0.4, no verdict, engine intent `hold`), one with rising frequency
    3.1 -> a fatigue anomaly + an attention item.
  - `brand-a-product-three` GRAVEYARD: a root + 1 killed variant (3x CPA, zero
    conversions, engine intent `kill`, a journal kill entry with rationale).
- 7 total active ads for `brand-a` across `learning | winner | contender | killing |
  paused`, each with a `thumbnail_url` (served from the engine's `/adimages`
  fixture so `AsyncImage` resolves), a full `targeting` summary, and a
  `cost_per_result_series` of 4 to 6 points trending down for winners, up for
  the killed one.
- An attention queue of 3 items: (1) `approval` warning, approve scale to $19/day
  on `n_ab12`; (2) `fatigue` warning on the frequency-3.1 ad; (3)
  `proposed_campaign` info, the engine wants to launch `brand-a-product-three` night
  ritual. Each with a pre-baked `send_to_claude_prompt`.
- A `forecast_by_brand[brand-a]`: burn $11.80/day, runway 6.2 days, projected month
  $354 at 59% of the authorized budget line, a 4-point `spend_series`, cap line
  $20.
- 2 anomalies: the frequency spike (warning) and one CPA-drift (info) on a
  contender.
- 1 `proposed_campaign` pending approval (the Product Three night ritual, spun off
  the Product One winner by changing `scene`, daily budget $16, full targeting).
- `confidence_by_brand[brand-a]`: the Product One family decided (0.97), Product Two
  gathering (0.61).
- `lineage_by_brand[brand-a]`: the full forest edges for all 3 families so the tree
  visualizer has real root -> variant edges labeled with the changed variable.
- `leaderboard_by_brand[brand-a]`: best = Product One hook B ($5.12 CPA), worst =
  Product Two cta A ($18.40 CPA), blended ROAS 2.1, `attention_flag` true, oldest
  ad 14d.
- `empire_rollup`: today $12.40, week $87.30, blended CPA $6.53, ROAS 2.1,
  2 winners, 7 live ads, 3 attention items.
- `brand-b` / `brand-c` / `brand-d`: present in `brands_known` and
  `per_brand_mode` with empty `active_ads`, empty `attention`, no forecast, so
  their fleet rows render the calm empty-ready state and the deck still lists all
  four.

Everything stays SIMULATE/OBSERVE: `source.simulate = true`,
`source.bootstrapped = false`, `brand-a` mode OBSERVE, kill switch off, every journal
entry `applied: false` (RECORDED), every `suggested_action.requires_confirm`
true. Nothing spends; the act id stays the placeholder.
