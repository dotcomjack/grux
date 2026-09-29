import Foundation

/// P-R-6, `agent.worthStarting`: is an agent job worth starting before it
/// spends money and time.
///
/// WHERE IT IS ASKED. Only where Grux would start a paid job on its own with
/// nobody's yes: `GoalPursuitEngine` in LIVE mode. Every other way into
/// `AgentService.startSwarm` already carries a person's decision (the chat tool
/// is queued by the Jax gate and replays only on an approval, Foundry builds
/// only accepted proposals, the MCP `grux_agent` tool is an explicit request),
/// and a model second-guessing a person's yes would lower their authority, not
/// raise caution.
///
/// THE FLOOR IS TODAY: LIVE starts the job. The answer can only HOLD it, which
/// means queueing the plan for one tap exactly as OBSERVE mode does, and only
/// when a provider that read the plan says no at or above the threshold. It
/// never starts anything. On device a yes/no answers 0.5, "cannot judge", so a
/// keyless install starts the job as it always has.
///
/// Calibrated 2026-09-21 against jev-latest (grux-ecosystem key), nine invented
/// plans, two wordings. Every answer fell on the right side of 0.5 in both
/// rounds. With this wording four of the five plans that should not run were
/// held (a job only the person can do, "approve the queue", a duplicate of a
/// running job, an ungrounded one at 0.17 to 0.23) and a vague "improve the
/// app" at 0.36 was left to the floor; none of the four good plans was held
/// (0.63 to 0.87). 319 to 379 ms.
enum AgentWorthJudgment {
    static let surface = "agent.worthStarting"
    static let instructions = "Is this job worth starting now, with nobody watching? Yes when it is concrete work "
        + "a coding agent can do in a project folder and it advances one of the real signals listed. No when "
        + "it is vague and names no project, feature or file, repeats a job already running, or needs "
        + "something only the person can do."

    static func state(title: String, goal: String, budgetUSD: Double, rationale: String,
                      signals: [String], running: [String]) -> String {
        "Grux is about to start a background agent job on its own, with nobody's approval.\n"
            + "Job: \(title)\nGoal: \(goal)\nBudget: up to \(dollars(budgetUSD))\nWhy Grux chose it: \(rationale)\n"
            + "The real signals it planned from:\n" + signals.map { "- \($0)" }.joined(separator: "\n") + "\n"
            + "Agent jobs already running: \(running.isEmpty ? "none" : running.joined(separator: ", "))"
    }

    static func dollars(_ usd: Double) -> String {
        usd == usd.rounded() ? "$\(Int(usd))" : String(format: "$%.2f", usd)
    }

    struct Verdict: Equatable {
        /// Queue the plan for a tap instead of starting it.
        let hold: Bool
        /// The held item's risk, asked on the same call, so queueing it does
        /// not open a second round trip. Nil unless held.
        let risk: ApprovalRisk?
        static let start = Verdict(hold: false, risk: nil)
    }

    /// ONE event, one call: the worth question, and the risk question about
    /// the approval item the plan becomes if it is held (its own state rides
    /// in front of its own instructions, never in the shared state). Holds
    /// only when a provider that can read the plan says it is not worth
    /// starting, at or above the threshold. Everything else starts it.
    @MainActor
    static func judge(state: String, heldItem: PendingApproval, engine: DecisionEngine,
                      threshold: Double) async -> Verdict {
        guard engine.hasRemoteKey else { return .start }
        let event = engine.open(origin: "agent job", state: state,
                                covering: [surface, ApprovalRiskJudgment.surface])
        event.ask(surface, ["worth": .noul(instructions: instructions)])
        event.ask(ApprovalRiskJudgment.surface, context: ApprovalRiskJudgment.state(for: heldItem),
                  ["risk": ApprovalRiskJudgment.question])
        await engine.resolve(event)
        engine.close(event)
        guard event.provider != .local, case .noul(let p)? = event.answer(surface, "worth"),
              1 - p >= threshold else { return .start }
        return Verdict(hold: true, risk: ApprovalRiskJudgment.risk(from: event.answer(ApprovalRiskJudgment.surface, "risk"),
                                                                   provider: event.provider, threshold: threshold))
    }

    /// How a running job reads on the state: its title and how long it has run.
    static func runningLine(title: String, startedAt: Date?, now: Date = Date()) -> String {
        guard let startedAt else { return title }
        let minutes = max(0, Int(now.timeIntervalSince(startedAt) / 60))
        return "\(title) (running \(minutes) minute\(minutes == 1 ? "" : "s"))"
    }
}
