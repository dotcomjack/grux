import Foundation

// Notification triage taxonomy + classifier (blueprint section 03).
//
// Every notification Grux posts is routed through triage before it reaches
// UNUserNotificationCenter. The taxonomy is derived from the existing call
// sites in the app:
//   - reminders:       FocusWatcher drift/refocus, CommitmentScheduler,
//                      daily/energy recaps (GruxReminder kinds)
//   - agentLifecycle:  AgentService paused-for-auth, swarm completions
//   - commandPhases:   CommandV2PhaseNotifier milestones, UserCronStore
//                      schedule fire/finish, IOSDispatcherV2 publish blockers
//   - emailTriage:     EmailTriageEngine support-draft sweeps
//   - meeting:         MeetingCaptureService surfaces (future call sites)
//   - foundry:         Self-Upgrade proposals/landings (FoundryTimelineStore
//                      already mirrors these; banners are optional)
//   - system:          domain expiry, ASC rejections, API key checks,
//                      everything generic that arrives via sendInfo
//
// Classification is rule-based first (kind hints, then keyword map). A Haiku
// escalation seam exists ONLY for uncategorized free-text notifications:
// classification runs async off the hot path, the notification defaults to
// batch meanwhile, and the verdict is cached so the same title shape never
// asks the model twice.
//
// That is the FLOOR, and it is everything a keyless install runs. With a
// decision key (Phase R, P-R-5, surface `notify.triage`), a free-text
// notification is judged on WHAT IT SAYS rather than on which keyword bucket
// it fell into: one choice, interrupt now, batch, or silent, asked once per
// distinct notification and cached. A confident answer replaces the category
// table's base action for that one notification; a blocker the rules catch
// still interrupts, and quiet hours still hold everything. See `judge`.

enum TriageCategory: String, Codable, CaseIterable, Identifiable {
    case reminders
    case agentLifecycle
    case commandPhases
    case emailTriage
    case meeting
    case foundry
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reminders: return "Reminders"
        case .agentLifecycle: return "Agents"
        case .commandPhases: return "Commands"
        case .emailTriage: return "Email triage"
        case .meeting: return "Meetings"
        case .foundry: return "Foundry"
        case .system: return "System"
        }
    }

    var systemImage: String {
        switch self {
        case .reminders: return "bell.badge"
        case .agentLifecycle: return "ant"
        case .commandPhases: return "flag.checkered"
        case .emailTriage: return "envelope.badge"
        case .meeting: return "person.2.wave.2"
        case .foundry: return "hammer"
        case .system: return "gearshape.2"
        }
    }
}

// Rule verdict: the category plus whether the content itself demands action
// (used to upgrade batch/silent to interrupt for blockers like "Apple
// rejected" or "needs your attention").
struct TriageRuleVerdict: Equatable {
    let category: TriageCategory
    let actionRequired: Bool
}

@MainActor
final class TriageClassifier {
    static let shared = TriageClassifier()

    private let cacheURL: URL
    // Normalized-title-pattern -> category raw value. Persisted so Haiku is
    // asked at most once per title shape across launches.
    private var cache: [String: String]
    // Title shapes with an escalation already in flight this session.
    private var inFlight: Set<String> = []

    init(cacheURL: URL = Persistence.supportDir.appendingPathComponent("notification-triage-cache.json")) {
        self.cacheURL = cacheURL
        self.cache = Persistence.load([String: String].self, from: cacheURL, fallback: [:])
    }

    // MARK: - Rule-based classification (pure, unit-tested)

    // Structured kind hints set by the senders themselves. Checked before
    // any keyword sniffing because they are unambiguous.
    nonisolated static func category(forKind kind: String?) -> TriageCategory? {
        switch kind {
        case "supportDrafts": return .emailTriage
        case "agentPaused": return .agentLifecycle
        case "v2PhaseTransition": return .commandPhases
        case "meeting": return .meeting
        case "foundry": return .foundry
        default: return nil
        }
    }

    // Keyword map over title + body for free-text notifications (sendInfo).
    // Order matters: first hit wins. Returns nil when nothing matches so the
    // caller can fall through to the cached/Haiku seam.
    nonisolated static func ruleVerdict(kind: String?, title: String, body: String) -> TriageRuleVerdict? {
        if let cat = category(forKind: kind) {
            return TriageRuleVerdict(category: cat, actionRequired: urgent(title: title, body: body))
        }
        let hay = (title + " " + body).lowercased()
        let rules: [(TriageCategory, [String])] = [
            (.reminders, ["reminder", "commitment", "recap", "back on track", "switched focus", "drift"]),
            (.meeting, ["meeting", "standup", "stand-up", "calendar event"]),
            (.emailTriage, ["support draft", "support inbox", "email triage"]),
            (.commandPhases, ["schedule", "workflow", "phase", "publish", "ship-ios", "cron"]),
            (.agentLifecycle, ["agent", "swarm", "job paused", "job finished", "job done"]),
            (.foundry, ["foundry", "self-upgrade", "proposal", "trust tier", "upgrade branch"]),
            (.system, ["domain", "apple rejected", "app store", "api key", "backup", "disk", "permission", "update available"])
        ]
        for (cat, needles) in rules where needles.contains(where: { hay.contains($0) }) {
            return TriageRuleVerdict(category: cat, actionRequired: urgent(title: title, body: body))
        }
        return nil
    }

    // Content-level urgency: blockers and failures should interrupt even when
    // their category policy says batch or silent.
    //
    // Word-boundary matched, NOT raw substring: the old `contains` flagged
    // "Terror flick" (contains "error") and "all green, no errors" (negated)
    // as urgent, escalating benign notifications to interrupt banners. We
    // anchor on \b and special-case the common negations so a "no errors"
    // status stays calm.
    nonisolated static func urgent(title: String, body: String) -> Bool {
        let hay = (title + " " + body).lowercased()
        // Negated phrasings that explicitly mean "fine": never urgent on
        // their own. Strip them before the urgency scan so "no errors" /
        // "0 errors" / "without errors" don't trip the "error" needle.
        var scan = hay
        for negation in ["no errors", "no error", "0 errors", "zero errors",
                         "without errors", "without error", "error-free", "error free"] {
            scan = scan.replacingOccurrences(of: negation, with: " ")
        }
        // Multi-word phrases are unambiguous; match them as plain substrings.
        let phrases = ["needs your attention", "limit hit", "action required"]
        if phrases.contains(where: { scan.contains($0) }) { return true }
        // Single tokens anchored on word boundaries so "terror"/"mirrored"
        // stop matching "error", and "classified" stops matching nothing
        // relevant. \b on both sides.
        let words = ["rejected", "failed", "expiring", "expired", "blocked", "error"]
        let pattern = #"\b("# + words.joined(separator: "|") + #")\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else {
            return words.contains(where: { scan.contains($0) })
        }
        let range = NSRange(scan.startIndex..., in: scan)
        return rx.firstMatch(in: scan, range: range) != nil
    }

    // Normalization for the escalation cache key: digits become #, whitespace
    // collapses, so "3 new support drafts" and "12 new support drafts" share
    // one cache entry.
    nonisolated static func normalizedKey(forTitle title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastWasHash = false
        var lastWasSpace = false
        for ch in lowered {
            if ch.isNumber {
                if !lastWasHash { out.append("#") }
                lastWasHash = true; lastWasSpace = false
            } else if ch.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true; lastWasHash = false
            } else {
                out.append(ch)
                lastWasHash = false; lastWasSpace = false
            }
        }
        return String(out.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    // MARK: - Hot-path classification (rules, then cache; never the model)

    // Returns nil for genuinely unknown free text. The caller batches the
    // notification under .system and calls scheduleEscalation so the NEXT
    // identical shape resolves from cache.
    func classify(kind: String?, title: String, body: String) -> TriageRuleVerdict? {
        if let verdict = Self.ruleVerdict(kind: kind, title: title, body: body) {
            return verdict
        }
        let key = Self.normalizedKey(forTitle: title)
        if let raw = cache[key], let cat = TriageCategory(rawValue: raw) {
            return TriageRuleVerdict(category: cat, actionRequired: Self.urgent(title: title, body: body))
        }
        return nil
    }

    // MARK: - Content judgment on the decision engine (P-R-5)

    nonisolated static let surface = "notify.triage"

    /// Below this confidence the content answer is not used and the floor
    /// decides. Calibrated 2026-09-21 against the live provider: with the
    /// wording below, every answer at 0.84 or higher was right, and the two
    /// wrong ones ("Grux switched focus" read as interrupt, a routine domain
    /// check with auto-renew on read as interrupt) came back at 0.65 and 0.62.
    nonisolated static let contentConfidenceFloor = 0.7

    nonisolated static let contentInstructions =
        "Grux is about to show the person this notification. How should it reach them? Judge what it says and "
        + "whether they have to do anything about it, not what kind of notification it is."

    /// The three answers are the three `TriageAction`s, by raw value, so the
    /// provider's choice maps straight onto what `route` already consumes.
    nonisolated static let contentCriteria: [String: String] = [
        TriageAction.interrupt.rawValue: "They must act soon and an hour's delay would cost them: something failed, "
            + "is blocked, was rejected, is about to expire or run out, or is waiting on their decision.",
        TriageAction.batch.rawValue: "Worth reading today but needs nothing now: progress, a finished job with "
            + "results, a summary, or news they may want in the hourly digest.",
        TriageAction.silent.rawValue: "Needs nothing and adds nothing: Grux telling them what it just did on their "
            + "behalf, a success or all-clear with no problems, or a routine check that passed."
    ]

    nonisolated static var contentQuestions: [String: DecisionQuestion] {
        ["action": .choice(instructions: contentInstructions, criteria: contentCriteria)]
    }

    nonisolated static func contentState(title: String, body: String) -> String {
        SecretRedactor.redact("Title: \(title.prefix(160))\nBody: \(body.prefix(400))")
    }

    /// The cache key: the notification's own words, case and spacing folded.
    /// A notification is a new item every time it is sent, but the same words
    /// sent twice are the same judgment, so they are asked about once.
    nonisolated static func contentKey(title: String, body: String) -> String {
        (title + "\n" + body).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The action a result supports, or nil when the floor should decide. On
    /// device a choice is keyword overlap on the very text it is judging, so it
    /// never gets a vote; nor does an answer under the confidence floor.
    nonisolated static func action(from result: DecisionResult) -> TriageAction? {
        guard result.provider != .local,
              case .choice(let raw, let confidence, _)? = result.answers["action"],
              confidence >= contentConfidenceFloor else { return nil }
        return TriageAction(rawValue: raw)
    }

    /// Whether free-text notifications are judged on content at all: the
    /// person's switch is on AND a provider that can judge is configured.
    /// Keyless this is false and `sendInfo` never leaves its synchronous path.
    func judgesContent(engine: DecisionEngine, enabled: Bool) -> Bool {
        enabled && engine.hasRemoteKey
    }

    // Content key -> the judgment, `nil` meaning "asked, floor decides". Kept
    // for this session only and capped: repeats are the saving, not history.
    private var contentVerdicts: [String: TriageAction?] = [:]
    private var contentOrder: [String] = []
    private var contentInFlight: [String: Task<TriageAction?, Never>] = [:]
    static let contentCacheCap = 256

    /// A judgment already made for these exact words, if any. The outer
    /// optional is "asked before"; the inner is the answer.
    func cachedContentVerdict(title: String, body: String) -> TriageAction?? {
        contentVerdicts[Self.contentKey(title: title, body: body)]
    }

    /// ONE call for a notification nobody has judged; a cached answer for one
    /// that has. Returns nil when the floor should decide: keyless, provider
    /// failure, or an answer under the confidence floor. Each of those is
    /// cached too, so a notification is asked about once, never retried.
    func judge(title: String, body: String, engine: DecisionEngine) async -> TriageAction? {
        let key = Self.contentKey(title: title, body: body)
        if let cached = contentVerdicts[key] { return cached }
        // The same words sent again while the first call is still out (two
        // schedules failing on one tick) wait for that call rather than paying
        // their own: the cache is only written once the answer is back.
        if let pending = contentInFlight[key] { return await pending.value }
        guard engine.hasRemoteKey else { return nil }
        let call = Task { @MainActor in
            Self.action(from: await engine.decide(surface: Self.surface,
                                                  state: Self.contentState(title: title, body: body),
                                                  questions: Self.contentQuestions))
        }
        contentInFlight[key] = call
        let action = await call.value
        contentInFlight[key] = nil
        if contentVerdicts.updateValue(action, forKey: key) == nil {
            contentOrder.append(key)
            if contentOrder.count > Self.contentCacheCap {
                contentVerdicts.removeValue(forKey: contentOrder.removeFirst())
            }
        }
        return action
    }

    // MARK: - Haiku escalation seam (async, cached, never blocks delivery)

    // Fire-and-forget. Asks Haiku to bucket an unknown free-text notification
    // into the taxonomy and caches the answer. Costs roughly $0.0001 per
    // call; with the cache and the rule map in front, expect well under
    // $0.01 estimated per day even on a chatty day.
    func scheduleEscalation(title: String, body: String) {
        guard TriagePolicyStore.shared.llmEscalationEnabled else { return }
        let key = Self.normalizedKey(forTitle: title)
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        let apiKey = AppState.shared.anthropicKey
        guard !apiKey.isEmpty else { return }
        inFlight.insert(key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(key) }
            let categories = TriageCategory.allCases.map(\.rawValue).joined(separator: ", ")
            let sys = """
            You classify one macOS notification into exactly one category. \
            Categories: \(categories). Reply with the single category token only, nothing else.
            """
            let user = "TITLE: \(title.prefix(120))\nBODY: \(body.prefix(240))\nCategory:"
            do {
                // Local-first: classifying a notification into one token is
                // pure latency-tolerant background work. AmbientLLM uses the
                // local model when enabled and falls back to Claude (Haiku)
                // otherwise; an unknown token is handled safely below either way.
                let reply = try await AmbientLLM.complete(
                    system: sys,
                    messages: [ClaudeMessage(role: "user", content: user)],
                    maxTokens: 12,
                    temperature: 0,
                    featureTag: "notification_triage"
                )
                let token = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let cat = TriageCategory.allCases.first(where: { $0.rawValue.lowercased() == token }) else {
                    WakeLog.shared.log("triage: classifier returned unknown token '\(token.prefix(30))' for '\(key)'")
                    return
                }
                self.cache[key] = cat.rawValue
                Persistence.save(self.cache, to: self.cacheURL)
                WakeLog.shared.log("triage: classified '\(key)' as \(cat.rawValue) (cached)")
            } catch {
                WakeLog.shared.log("triage: haiku escalation failed for '\(key)': \(error.localizedDescription)")
            }
        }
    }
}
