import Foundation

// THE Claude model ids Self-Upgrade runs on, in one place, so a new model is
// one line here and nowhere else (FoundryModelIDsTests scans the Foundry
// sources for any other "claude-" literal).
//
// Measured 2026-10-29 on the Mini's Claude CLI 2.1.284: its model catalog
// knows claude-sonnet-5-5, claude-opus-5-5 and claude-haiku-4-5-20251001 (an
// unknown id prints "isn't described by this version's model catalog"), so the
// worker's `claude --print --model` takes these as they are.
enum FoundryModelIDs {
    // The build worker. Structural and iteration work at Sonnet cost.
    static let standard = "claude-sonnet-5-5"
    // Every worker of a medium or large upgrade escalated to the swarm, and any
    // run whose stakes justify Opus (pass it as RDWorker.Config.model).
    static let highStakes = "claude-opus-5-5"
    // The UX audit's screenshot critic: one cheap vision call per tab.
    static let vision = "claude-haiku-4-5-20251001"
}
