import Foundation

// MARK: - SubscriptionModels
//
// The models a Claude Code run on the user's Claude subscription uses when the
// caller names none. One place, because the old defaults were typed into four
// files (the adapter, two SwarmPlan defaults, RDWorker) and went stale
// together: on 2026-10-30 a subscription job still ran on claude-opus-4-8 two
// releases after Opus 5.5 shipped. All four current models were checked on the
// subscription that day (claude --print, apiKeySource "none", each answered).

public enum SubscriptionModels {

    /// Coding and agent work: swarm workers, terminal sessions, `grux agent`.
    public static let code = "claude-opus-5-5"

    /// Routine structural work where Opus would cost more for no gain:
    /// Foundry upgrade builds and the Design Studio review on the plan.
    public static let routine = "claude-sonnet-5-5"
}
