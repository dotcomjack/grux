import Foundation

// The three "you got this" suffixes the user wants auto-appended to every
// worker's prompt. Editable via Settings; defaults baked in here.
//
// These are deliberately NOT instructions the model can refuse - they're tone
// + autonomy framing. The Grux philosophy is "trust the model to ship the
// whole thing in one turn" so we lean into that.

public enum MegapromptScaffold {

    public static let defaultPolish = """
    You're more than capable of this. I expect the polished final product in front of me by the end of this turn. Do end-to-end verification, validation and testing before you finish. Thanks :)
    """

    public static let defaultParallel = """
    Use multiple swarms of parallel subagents (the Task tool) for independent sub-tasks. I expect to see the final result in front of me. Full end-to-end testing and verification to make sure it works. Use only agent tools (CLI based) - I will not intervene or perform any manual action. Thank you.
    """

    public static let defaultVibe = """
    Please enjoy the process and don't feel rushed :) It's a calm, lovely night and the investors are excited.
    """

    // Technical guardrails that close known hallucination classes the swarm
    // has hit in production. Empirically tighter than vibe / polish - these
    // are concrete "do/don't" rules. Add new entries here as we burn-in more
    // bugs; this is the right place for "DO NOT pass flag X to tool Y unless
    // condition Z" kind of rules.
    public static let defaultTechnicalGuardrails = """
    TECHNICAL GUARDRAILS (must follow):

    iOS / xcodebuild: When running tests via `xcodebuild test`, do NOT pass the `-testPlan <name>` flag unless you have FIRST inspected the project's `<scheme>.xcscheme` XML file and confirmed it contains a `<TestPlans>` element. xcodegen-generated schemes have NO test plans by default - invoking `-testPlan` against such a scheme fails immediately with "The flag -testPlan <name> cannot be used since the scheme does not use test plans." Default to plain: `xcodebuild test -project Path/To.xcodeproj -scheme YourScheme -destination "platform=iOS Simulator,id=<UDID>"` with NO -testPlan flag. To find an available simulator UDID: `xcrun simctl list devices available -j | jq -r '.devices | to_entries[] | .value[] | select(.name | startswith("iPhone")) | .udid' | head -1`.
    """

    /// Returns the full scaffold block, suitable for `claude --append-system-prompt`.
    public static func block(
        polish: String = defaultPolish,
        parallel: String = defaultParallel,
        vibe: String = defaultVibe,
        technicalGuardrails: String = defaultTechnicalGuardrails
    ) -> String {
        var parts: [String] = []
        if !polish.isEmpty { parts.append(polish) }
        if !parallel.isEmpty { parts.append(parallel) }
        if !vibe.isEmpty { parts.append(vibe) }
        if !technicalGuardrails.isEmpty { parts.append(technicalGuardrails) }
        guard !parts.isEmpty else { return "" }
        return "\n\n- GRUX AGENT SCAFFOLD -\n\n" + parts.joined(separator: "\n\n")
    }

    /// Convenience: wrap a worker prompt with role context + scaffold.
    public static func wrap(
        rolePrompt: String,
        userGoal: String,
        polish: String = defaultPolish,
        parallel: String = defaultParallel,
        vibe: String = defaultVibe,
        technicalGuardrails: String = defaultTechnicalGuardrails
    ) -> String {
        let scaffold = block(
            polish: polish,
            parallel: parallel,
            vibe: vibe,
            technicalGuardrails: technicalGuardrails
        )
        return """
        \(rolePrompt)

        ORIGINAL GOAL: \(userGoal)
        \(scaffold)
        """
    }
}
