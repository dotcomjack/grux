import Foundation

/// P-R-6, `approvals.risk`: how much could go wrong if a pending approval runs.
///
/// RAISE ONLY. The score can put a flag on the approval card and nothing else.
/// It never approves, skips, reorders or re-reasons an item, never clears
/// `urgent`, and a low score is never shown, because a card that says "low
/// risk" reads as permission. Whatever the gates queued stays queued.
///
/// Judged ONCE, when the item enters the queue (`ApprovalQueue.enqueue`), and
/// stored on the item, so a render or a list read never pays for it. Without a
/// key nothing is asked and the item is stored byte for byte as before.
///
/// Calibrated 2026-09-21 against jev-latest (grux-ecosystem key) on invented
/// items shaped like the ones the gates queue. The first wording ("high: spends
/// money, reaches other people, deletes data or cannot be undone") put 8 of 10
/// in their band but flagged only 3 of the 5 high items above 0.70 (a $12 spend
/// at 0.55, a Notion push judged medium). This wording put 10 of 10 in band and
/// flagged all 5 high items at 0.94 to 0.99 with none of the other 5 flagged,
/// and the queued tool's own input on the state separated `rm -rf` (high,
/// 0.93) from `npm run build` and a calendar event (medium, not flagged).
struct ApprovalRisk: Codable, Equatable {
    /// The expected level on `ApprovalRiskJudgment.levels`, 0 low to 2 high.
    let score: Double
    let confidence: Double
    /// Judged high at or above the threshold by a provider that read the item.
    /// The only thing the card acts on.
    let raised: Bool
}

enum ApprovalRiskJudgment {
    static let surface = "approvals.risk"
    static let instructions = "How much could go wrong if this action runs? Judge what the action does, "
        + "not how calmly it is worded."
    static let levels = [
        "low: stays on this Mac, touches nothing important and is easy to undo",
        "medium: changes files, settings or plans on this Mac in a way that takes effort to undo",
        "high: spends any money, sends anything to another person or an outside service, "
            + "deletes data, or cannot be undone",
    ]
    static let highLevel = 2
    /// A queued tool's input can be a whole email body; the first part says
    /// what the call does.
    static let maxValueLength = 400

    static func state(for item: PendingApproval) -> String {
        let a = item.action
        var s = "An action is waiting for the person's approval.\nAction: \(a.summary)\nTarget: \(a.target)"
        let details = a.detail.filter { !$0.key.hasPrefix("__") }.sorted { $0.key < $1.key }
            .map { "\($0.key) \(clip($0.value))" }
        if !details.isEmpty { s += "\nDetails: \(details.joined(separator: ", "))" }
        if !item.reason.isEmpty { s += "\nWhy it paused: \(item.reason)" }
        if let input = a.detail["__replay_input"], !input.isEmpty { s += "\nInput: \(clip(input))" }
        return s
    }

    private static func clip(_ s: String) -> String {
        s.count > maxValueLength ? String(s.prefix(maxValueLength)) + "..." : s
    }

    static let question = DecisionQuestion.score(instructions: instructions, levels: levels)

    /// One call for one new item, or nil when nothing could judge it. An item
    /// whose event already asked (a held agent job) arrives with its risk set
    /// and is not asked again.
    @MainActor
    static func judge(_ item: PendingApproval, engine: DecisionEngine, threshold: Double) async -> ApprovalRisk? {
        guard engine.hasRemoteKey else { return nil }
        let result = await engine.decide(surface: surface, state: state(for: item), questions: ["risk": question])
        return risk(from: result.answers["risk"], provider: result.provider, threshold: threshold)
    }

    /// On device a score answers 0 at confidence 0: "cannot judge", never "low
    /// risk". Nothing is stored for it.
    static func risk(from answer: DecisionAnswer?, provider: DecisionProviderKind?,
                     threshold: Double) -> ApprovalRisk? {
        guard let provider, provider != .local, case .score(let score, let confidence)? = answer else { return nil }
        let level = Int(score.rounded())
        return ApprovalRisk(score: score, confidence: confidence,
                            raised: level >= highLevel && confidence >= threshold)
    }
}
