import Foundation

/// What "Copy handoff for your agent" hands to the one work order line: a
/// Self-Upgrade proposal as a request and a detail. It formats nothing on its
/// own. `WorkOrderStore.createAndCopy` writes the order (id, order.json,
/// work-order.md, progress.log) and the template supplies the stations, the
/// rules, the build, the install and the cleanup, so a proposal copied here
/// ends at live like any other order (Grux-Mac CLAUDE.md, "one work order
/// line").
///
/// Everything the card shows is here in full: every evidence line rather than
/// the two the card folds to, the whole rationale, the pinned paths, the gain
/// and the cost. Model-written prose is scrubbed of typographic dashes at this
/// boundary for the same reason the card scrubs at render: proposals already
/// on disk were never cleaned.
@MainActor
enum ProposalHandoff {

    /// The order's request: the proposal, in one line.
    static func request(for card: FoundryProposalCardModel) -> String {
        "Build the Self-Upgrade proposal: \(DashSanitizer.stripDashesOnly(card.title))"
    }

    /// Everything Grux already knows about the proposal, for the template.
    static func detail(for card: FoundryProposalCardModel) -> String {
        let clean = DashSanitizer.stripDashesOnly
        var out: [String] = []
        out.append("Grux watched how this person uses it and proposed this change to itself. Grux cannot make it; you can.")
        out.append("")
        out.append("- Category: \(clean(card.lane)). Area: \(clean(card.domain)). "
                   + "\(FoundryFormat.riskLabel(card.risk)). \(FoundryFormat.tierPlain(card.tierRequired)).")
        if !card.expectedGain.isEmpty { out.append("- \(clean(card.expectedGain)).") }
        out.append("- \(FoundryFormat.costLine(usd: card.estimatedCostUSD)) if Grux built it; "
                   + "with you it costs whatever your own agent costs.")
        out.append("")
        out.append("### Why Grux proposed it, from what it measured")
        out.append("")
        if card.evidence.isEmpty {
            out.append("- No recorded signals. Treat the request as the evidence.")
        } else {
            for line in card.evidence { out.append("- " + FoundryFormat.evidenceLabel(clean(line))) }
        }
        out.append("")
        out.append("### Files")
        out.append("")
        if card.touchedPaths.isEmpty {
            out.append("- No files are pinned. Find the smallest set that does it and name them in your plan before you edit.")
        } else {
            out.append("- Files Grux expects this to touch:")
            for path in card.touchedPaths { out.append("  - \(clean(path))") }
        }
        out.append("- Never touch the wire protocol, the Keychain code or Security for a Self-Upgrade proposal; those are protected.")
        out.append("")
        out.append("### The change, in Grux's own words")
        out.append("")
        let prompt = clean(card.readyPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(prompt.isEmpty ? "(Grux wrote no detail; work from the title and the evidence.)" : prompt)
        out.append("")
        out.append("### Done means all of these are true")
        out.append("")
        for line in acceptance { out.append("- " + line) }
        return out.joined(separator: "\n")
    }

    static let acceptance: [String] = [
        "The behaviour in the request is visible in the running app.",
        "A test covers it, and you watched that test fail before your change.",
        "Every existing test still passes.",
        "The Self-Upgrade evidence above no longer describes the app.",
    ]
}
