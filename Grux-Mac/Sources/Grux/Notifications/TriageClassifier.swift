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
