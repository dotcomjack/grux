import Foundation

// What a tool call would be turned down for right now, decided once for the
// three places that meet it: the gate (no card is queued for a call that would
// refuse), the Approvals card (a card queued before says so and holds Approve),
// and the approve path (a yes that would refuse is not recorded as Approved).
// D126: with self-upgrade off, a model's foundry_upgrade_cycle call queued
// "Start a self-upgrade cycle." and approving it two days later marked it
// Approved while the tool answered "not started".
enum CannotRunNow {

    /// The line the tool itself would answer, or nil when it would run.
    nonisolated static func refusal(tool: String, input: [String: Any], foundryEnabled: Bool) -> String? {
        switch tool {
        case "foundry_upgrade_cycle":
            // dispatchTool reads a missing action as a start; a status read runs while off.
            let action = ((input["action"] as? String) ?? "start").lowercased()
            guard action != "status" else { return nil }
            return FoundryEngine.manualCycleRefusal(foundryEnabled: foundryEnabled).map { "foundry: \($0)" }
        default:
            return nil
        }
    }

    /// The card's line for a queued item that would be turned down if approved now.
    nonisolated static func cardLine(for item: PendingApproval, foundryEnabled: Bool) -> String? {
        guard let tool = item.action.detail["__replay_tool"] else { return nil }
        let input = item.action.detail["__replay_input"].flatMap(ApprovalQueue.decodeInput) ?? [:]
        guard refusal(tool: tool, input: input, foundryEnabled: foundryEnabled) != nil else { return nil }
        switch tool {
        case "foundry_upgrade_cycle":
            return "Self-upgrade is off, so this would be turned down. Turn it on in Self-Upgrade (or Settings), or Skip it."
        default:
            return nil
        }
    }
}
