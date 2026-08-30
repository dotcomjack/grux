import Foundation

// Phase 3 OUTPUT GATE: a deterministic, no-LLM final vet of an outbound support
// reply right before it is sent. It is the safety floor for both manual sends and
// (Phase 4) auto-sends. Tier 1 checks (empty, banned offers, em/en dashes) are
// always enforced. Tier 2 (grounding) only runs when there is no human in the
// loop. No model call, never throws.

enum OutputDecision: Equatable {
    case allow
    case block(reason: String)
}

@MainActor
enum OutputGate {
    // Deterministic final vet of outbound reply text. Tier 1 (always enforced):
    // empty -> block; bannedTokensFound non-empty -> block; an em dash (U+2014) or
    // en dash (U+2013) present -> block. Tier 2 (only when enforceGrounding, i.e.
    // auto-send with no human in the loop): GroundingGate.vet not surfaceable ->
    // block. No LLM, never throws.
    static func vet(replyText: String, voice: String, enforceGrounding: Bool) -> OutputDecision {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Empty after trimming.
        if trimmed.isEmpty {
            return .block(reason: "empty reply")
        }

        // 2. Fabricated / banned offers (samples, coupons, etc.).
        let banned = EmailTriageEngine.bannedTokensFound(in: trimmed, voice: voice)
        if !banned.isEmpty {
            return .block(reason: "banned offer: " + banned.joined(separator: ", "))
        }

        // 3. Em dash (U+2014) or en dash (U+2013) in outbound copy.
        if trimmed.contains("\u{2014}") || trimmed.contains("\u{2013}") {
            return .block(reason: "em or en dash in outbound copy")
        }

        // 4. Tier 2: catalog grounding, only when no human is in the loop.
        // NOTE (by design): the catalog only holds ground truth for a brand that
        // has catalog data, so this tier is a no-op for any brand without it
        // (FactGuard finds no brand -> surfaceable). Those brands still get every
        // Tier-1 check above; richer grounding lands if/when they get catalog data.
        if enforceGrounding {
            // The brief names whichever brand is speaking, so GroundingGate can
            // look it up. It used to special-case one brand's token, which sent
            // every other brand to the gate as a bare word it could not
            // recognise. Same line, same reason, as the twin in
            // EmailTriageEngine. A brand with no catalog data still detects
            // nothing and passes, exactly as before.
            let g = GroundingGate.vet(draft: trimmed, brief: "\(voice) support reply")
            if !g.surfaceable {
                return .block(reason: g.refusalLine)
            }
        }

        // 5. Clean.
        return .allow
    }
}
