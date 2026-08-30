import Foundation

// CognitionTrace: the HONEST decision/cognition log behind Jax.
//
// This is the data layer for the "Cognition Map" (the brain map). It is NOT a
// neural scan, an fMRI, or a model of biological cognition: Grux has no scanner
// and no neural data, so this never fabricates or implies any of that. What it
// records is the REAL decision provenance the app genuinely has for each Jax
// decision: which JaxProfile heuristics/values were relevant, which corpus /
// semantic memories were retrieved into context, what the decision gate said,
// a computed confidence score, the autonomy mode at the time, the timing, and
// what Jax actually did or asked. Every field is something a caller can point
// to a concrete source for. If a number cannot be sourced from the running app,
// it does not belong here.
//
// House style mirrors GoalPursuitEngine / DecisionGate: @MainActor singleton,
// Codable local persistence under ~/.grux/jax/, newest-first capped log,
// @Published for live UI, zero em/en dashes, dollars as $N.
//
// API SHAPE (reconciled across the data layer + the Cognition Map UI module):
//   * CognitionEvent.Kind is the nested kind enum. The view layer
//     (CognitionMapStyle) owns its label/icon/tint presentation, so this file
//     does NOT define those on Kind (only the raw cases).
//   * CognitionEvent exposes both the data-layer field names (heuristicsFired,
//     memoriesRetrieved, timestamp) AND the UI-facing aliases the map reads
//     (firedHeuristicNames, retrievedMemories, date), so both modules compile
//     against one struct with no parallel state.
//   * rollup is a @Published CognitionRollup the UI binds to directly, AND
//     rollup(topHeuristics:) is kept as a method for callers that want a fresh
//     computed snapshot.

// MARK: - Event kind

// What kind of Jax decision produced this trace. These are the four real entry
// points where Jax decides something: a chat prompt, a directive (a standing
// instruction the user gave), a queued task, or one autonomous goal-pursuit cycle.
// Presentation (label/icon/tint) lives in CognitionMapStyle, NOT here, so the
// view layer can extend it without a redeclaration clash.
enum CognitionEventKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case prompt      // a chat turn the user sent
    case directive   // a standing instruction / directive Jax acted on
    case task        // a queued task Jax worked
    case goalCycle   // one GoalPursuitEngine autonomous cycle

    var id: String { rawValue }
}

// MARK: - Event model

// One honest decision trace. Each array is supplied by the caller from what
// ACTUALLY happened on that turn: the caller already retrieved the memories,
// already rendered the heuristics, already ran the gate, so it passes the real
// values in. CognitionTrace does not re-derive or guess any of them.
struct CognitionEvent: Codable, Identifiable, Hashable {
    // The kind enum is also reachable as CognitionEvent.Kind, which is the name
    // the Cognition Map UI references.
    typealias Kind = CognitionEventKind

    let id: UUID
    var timestamp: Date
    var kind: CognitionEventKind

    // The short label for what set this decision off: the user prompt, the
    // directive text, the task title, or the cycle trigger ("nightly").
    var trigger: String

    // The JaxProfile heuristics / values that were relevant to this decision,
    // by rule text or domain. The caller supplies what genuinely matched, not a
    // guess: empty is honest (no learned heuristic was in play yet).
    var heuristicsFired: [String]

    // Short snippets / ids of the corpus + semantic entries that were retrieved
    // into context for this decision (the .corpus lane and friends). These are
    // the real RELEVANT_MEMORIES that shaped the reply.
    var memoriesRetrieved: [String]

    // The decision gate's verdict when a gate ran on this decision
    // (proceed / queued / refused / clarify), else "" when no gated action
    // happened. Stored as a non-optional string so the UI verdict formatter has
    // a stable value (empty string maps to "No gated action").
    var gateVerdict: String

    // The honest plain-language reason behind the verdict / pause, for the
    // expanded row. Empty when there is nothing to add.
    var gateReason: String

    // A confidence score in 0...1, supplied ONLY when a real comprehension
    // signal exists for this decision (a ConfidenceGate verdict). This is a
    // computed score the app actually measured, not a biological measurement
    // and not a fabricated formula. nil means "no real confidence signal for
    // this decision" (a plain chat-completion trace, or a goal cycle with no
    // planner verdict): the UI renders that honestly as "n/a" and the rollup
    // excludes it from the average rather than inventing a number. Clamped on
    // init so the UI can trust the range when a value is present.
    var confidence: Double?

    // Autonomy mode at the time (simulate / observe / live).
    var mode: String

    // What Jax actually did, planned, or asked, in one line.
    var outcome: String

    // How long the decision took, in seconds. 0 when not measured (the UI hides
    // the timing chip then). Real timing only, never invented.
    var durationSeconds: Double

    // Brand this decision belongs to (a brand slug the user configured), when the
    // decision is brand-scoped (e.g. a support-email triage). nil for decisions
    // with no brand (a general chat turn): those show only under the "All"
    // scope of the Cognition Map brand filter (decision 4).
    var brand: String?

    // Stable id linking this trace back to the artifact it produced, so a UI can
    // deep-link to it (decision 4): for an email decision this is the staged
    // draft's id, so the Jax HQ draft card can jump straight to this node. nil
    // when the decision produced no linkable artifact.
    var correlationId: String?

    // UI-facing aliases. The Cognition Map view reads these names; they map onto
    // the same stored data so there is one source of truth, no parallel fields.
    var date: Date { timestamp }
    var firedHeuristicNames: [String] { heuristicsFired }
    var retrievedMemories: [String] { memoriesRetrieved }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: CognitionEventKind,
        trigger: String,
        heuristicsFired: [String] = [],
        memoriesRetrieved: [String] = [],
        gateVerdict: String = "",
        gateReason: String = "",
        confidence: Double? = nil,
        mode: String,
        outcome: String,
        durationSeconds: Double = 0,
        brand: String? = nil,
        correlationId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.trigger = trigger
        self.heuristicsFired = heuristicsFired
        self.memoriesRetrieved = memoriesRetrieved
        self.gateVerdict = gateVerdict
        self.gateReason = gateReason
        self.confidence = confidence.map { min(1, max(0, $0)) }
        self.mode = mode
        self.outcome = outcome
        self.durationSeconds = max(0, durationSeconds)
        self.brand = brand
        self.correlationId = correlationId
    }

    // Lenient decode so a log written by an older build still loads (defaults
    // rather than a throw that wipes the whole log). gateVerdict tolerates the
    // earlier optional-string shape.
    enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, trigger, heuristicsFired, memoriesRetrieved
        case gateVerdict, gateReason, confidence, mode, outcome, durationSeconds
        case brand, correlationId
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
        kind = (try? c.decode(CognitionEventKind.self, forKey: .kind)) ?? .prompt
        trigger = (try? c.decode(String.self, forKey: .trigger)) ?? ""
        heuristicsFired = (try? c.decode([String].self, forKey: .heuristicsFired)) ?? []
        memoriesRetrieved = (try? c.decode([String].self, forKey: .memoriesRetrieved)) ?? []
        gateVerdict = (try? c.decodeIfPresent(String.self, forKey: .gateVerdict)).flatMap { $0 } ?? ""
        gateReason = (try? c.decode(String.self, forKey: .gateReason)) ?? ""
        // Optional now: a missing or null confidence decodes to nil (honest
        // "no real signal") rather than a fabricated default.
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence))
            .flatMap { $0 }
            .map { min(1, max(0, $0)) }
        mode = (try? c.decode(String.self, forKey: .mode)) ?? AutonomyMode.simulate.rawValue
        outcome = (try? c.decode(String.self, forKey: .outcome)) ?? ""
        durationSeconds = max(0, (try? c.decode(Double.self, forKey: .durationSeconds)) ?? 0)
        // Optional, added in decision 4: older logs decode these to nil cleanly.
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)).flatMap { $0 }
        correlationId = (try? c.decodeIfPresent(String.self, forKey: .correlationId)).flatMap { $0 }
    }

    // Convenience for the UI: is this a low-confidence (clarify-worthy) decision?
    // 0.5 is the threshold under which Jax should lean toward asking rather than
    // acting, matching the gate's PAUSE-and-ask default posture. A decision with
    // no real confidence signal (nil) is NOT counted as low confidence: there is
    // no signal to call low, so it is excluded honestly.
    var isLowConfidence: Bool {
        guard let c = confidence else { return false }
        return c < 0.5
    }
}

// MARK: - Rollups for the UI

// A most-fired heuristic node for the constellation header. most-fired first.
struct CognitionHeuristicStat: Identifiable, Hashable {
    let id: String          // the heuristic name, also the stable identity
    var name: String
    var count: Int

    init(name: String, count: Int) {
        self.id = name
        self.name = name
        self.count = count
    }
}

// Pre-computed summary the Cognition Map header reads. Pure value type so the
// view never recomputes over the whole log on every redraw.
struct CognitionRollup {
    // The events this rollup was computed over (newest first). The UI reads
    // .events.count for the "decisions traced" tile.
    var events: [CognitionEvent]
    var countsByKind: [CognitionEventKind: Int]
    var avgConfidence: Double               // 0...1, 0 when the log is empty
    var lowConfidenceCount: Int             // events Jax was unsure on (clarify)
    var gatedCount: Int                     // events where a gate ran
    var topHeuristics: [CognitionHeuristicStat]  // descending, capped

    static let empty = CognitionRollup(
        events: [], countsByKind: [:], avgConfidence: 0,
        lowConfidenceCount: 0, gatedCount: 0, topHeuristics: []
    )

    // Convenience accessors some call sites prefer.
    var total: Int { events.count }
    var averageConfidence: Double { avgConfidence }
    var mostFiredHeuristics: [(rule: String, count: Int)] {
        topHeuristics.map { (rule: $0.name, count: $0.count) }
    }
}

// MARK: - Store

@MainActor
final class CognitionTrace: ObservableObject {
    static let shared = CognitionTrace()

    // Newest first, for the live Cognition Map feed.
    @Published private(set) var events: [CognitionEvent] = []

    // Pre-computed rollup the Cognition Map binds to directly. Refreshed on
    // every record and on load, so the header tiles + constellation never
    // recompute over the whole log on each redraw.
    @Published private(set) var rollup: CognitionRollup = .empty

    // Keep the log a few hundred entries: enough to read the recent decision
    // history, bounded so the JSON stays small.
    private let maxEvents = 500

    private let storeURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("jax")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cognition-log.json")
    }()

    private init() {
        load()
    }

    // MARK: Record

    // Record one fully-built event. Inserts newest-first, caps the log, persists.
    func record(_ event: CognitionEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents { events = Array(events.prefix(maxEvents)) }
        rollup = computeRollup()
        save()
    }

    // Convenience builder + record in one call, for the integration sites
    // (ChatService after a turn, GoalPursuitEngine after a plan, the gate).
    // The caller passes the REAL provenance it already has on hand. gateVerdict
    // accepts an optional String (nil => no gated action => stored as "").
    @discardableResult
    func note(
        kind: CognitionEventKind,
        trigger: String,
        heuristicsFired: [String] = [],
        memoriesRetrieved: [String] = [],
        gateVerdict: String? = nil,
        gateReason: String = "",
        confidence: Double? = nil,
        mode: String,
        outcome: String,
        durationSeconds: Double = 0,
        brand: String? = nil,
        correlationId: String? = nil
    ) -> CognitionEvent {
        let event = CognitionEvent(
            kind: kind,
            trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
            heuristicsFired: heuristicsFired,
            memoriesRetrieved: memoriesRetrieved,
            gateVerdict: gateVerdict ?? "",
            gateReason: gateReason,
            confidence: confidence,
            mode: mode,
            outcome: outcome.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSeconds: durationSeconds,
            brand: brand,
            correlationId: correlationId
        )
        record(event)
        return event
    }

    // Confidence-signal overload. ConfidenceGate returns a fully-formed
    // ConfidenceVerdict for a turn; this records it as the HONEST confidence
    // provenance (computed score, whether Jax paused to clarify, the plain
    // reason). It does NOT publish anything: a truly-confused turn that asks a
    // clarifying question is recorded as a .prompt with a "clarify" verdict, so
    // the map shows Jax pausing instead of guessing. A confident verdict records
    // the score with no gated action. Real numbers only, no invented data.
    @discardableResult
    func note(confidence verdict: ConfidenceVerdict,
              kind: CognitionEventKind = .prompt,
              trigger: String = "",
              mode: String = AutonomyMode.simulate.rawValue) -> CognitionEvent {
        note(
            kind: kind,
            trigger: trigger,
            gateVerdict: verdict.isTrulyConfused ? "clarify" : nil,
            gateReason: verdict.reason,
            confidence: verdict.confidence,
            mode: mode,
            outcome: verdict.isTrulyConfused
                ? (verdict.clarifyingQuestion ?? "Paused to ask one clarifying question.")
                : "Confident enough to proceed."
        )
    }

    // MARK: Rollups

    // Computed over the live log. Reads the bounded events array; every number
    // traces to a recorded event, none are invented.
    private func computeRollup(topHeuristics: Int = 6) -> CognitionRollup {
        var counts: [CognitionEventKind: Int] = [:]
        var confSum = 0.0
        var confCount = 0          // only events that carry a REAL confidence signal
        var lowCount = 0
        var gated = 0
        var heuristicTally: [String: Int] = [:]

        for e in events {
            counts[e.kind, default: 0] += 1
            // Average over REAL signals only. Events with no confidence signal
            // (nil) are excluded so the rollup never averages in a fabricated
            // number. avgConfidence stays 0 (rendered "n/a") until at least one
            // real ConfidenceGate verdict lands.
            if let c = e.confidence {
                confSum += c
                confCount += 1
            }
            if e.isLowConfidence { lowCount += 1 }
            if !e.gateVerdict.isEmpty { gated += 1 }
            for h in e.heuristicsFired {
                let key = h.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                heuristicTally[key, default: 0] += 1
            }
        }

        let avg = confCount == 0 ? 0 : confSum / Double(confCount)
        let topFired = heuristicTally
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.key < b.key  // stable tie-break
            }
            .prefix(topHeuristics)
            .map { CognitionHeuristicStat(name: $0.key, count: $0.value) }

        return CognitionRollup(
            events: events,
            countsByKind: counts,
            avgConfidence: avg,
            lowConfidenceCount: lowCount,
            gatedCount: gated,
            topHeuristics: Array(topFired)
        )
    }

    // Public method form for callers that want a fresh snapshot on demand.
    func rollup(topHeuristics: Int = 6) -> CognitionRollup {
        computeRollup(topHeuristics: topHeuristics)
    }

    // Convenience computed accessors the UI can bind directly without holding a
    // CognitionRollup. Each reads the published rollup, so they are cheap.
    var countsByKind: [CognitionEventKind: Int] { rollup.countsByKind }
    var averageConfidence: Double { rollup.avgConfidence }
    var lowConfidenceCount: Int { rollup.lowConfidenceCount }
    var mostFiredHeuristics: [(rule: String, count: Int)] { rollup.mostFiredHeuristics }

    func clearAll() {
        events.removeAll()
        rollup = computeRollup()
        save()
    }

    // MARK: Persistence

    // Public so the Cognition Map view can refresh on appear (.onAppear). Loads
    // the persisted log and recomputes the rollup.
    func load() {
        events = Persistence.load([CognitionEvent].self, from: storeURL, fallback: [])
        rollup = computeRollup()
    }
    private func save() {
        Persistence.save(events, to: storeURL)
    }
}
