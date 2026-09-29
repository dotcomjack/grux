import Foundation

/// The words a workflow's run record says for each step, which a person opens
/// in Workflows. SWEEP-12: an agent step showed its raw prompt cut at 120
/// characters, and the rest read as the engine talking to itself
/// (`branch evaluated to true → celebrate`, `setState color = teal`,
/// `[answered: go]`). Every line here is a whole sentence built from a step's
/// own name, never from a prompt, a command or an id.
enum PhaseLogCopy {

    /// What a dry run records for a step that would reach outside the run.
    static func dryRun(_ action: CommandV2Action, step: String) -> String {
        let name = quoted(step)
        switch action {
        case .claudeAgent:
            return "Dry run, so no agent started for \(name). A real run would start one."
        case .claudeAgentSwarm(let prompts, _):
            return "Dry run, so no agents started for \(name). A real run would start \(prompts.count)."
        default:
            return "Dry run, so \(name) did not run. A real run would do it."
        }
    }

    /// A branch: where the run goes next.
    static func next(_ step: String) -> String { "Next: \(sentence(step))" }

    /// A value the run keeps for a later step.
    static func noted(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return "Noted for later: \(sentence(text))"
        case .bool(let b): return "Noted for later: \(b ? "yes" : "no")."
        case .int, .double: return "Noted for later: \(sentence("\(value)"))"
        case .array(let items): return "Noted \(items.count) \(items.count == 1 ? "item" : "items") for later."
        case .object: return "Noted some details for later."
        case .null: return "Noted that there is nothing here yet."
        }
    }

    /// Speech, whole, as it was said (or, in a dry run, not said).
    static func said(_ text: String) -> String { "Said: \"\(text)\"" }

    static let nothingToDo = "Nothing to do in this step."

    /// A gate's answer.
    static func answered(_ text: String, gateWord: String? = nil) -> String {
        if let gateWord { return "No reply came with it, so this took the step's own word, \"\(gateWord)\"." }
        return "You answered \"\(text)\"."
    }

    /// The wait a dry run skips.
    static func dryRunSkippedWait(_ seconds: TimeInterval, then step: String) -> String {
        "Dry run, so there was no wait. A real run would wait \(duration(seconds)), then go on to \(verbPhrase(step))."
    }

    /// A wait a real run schedules.
    static func scheduled(_ seconds: TimeInterval, then step: String) -> String {
        "Waiting \(duration(seconds)), then going on to \(verbPhrase(step))."
    }

    /// Where the loop guard stopped a dry run.
    static let dryRunStoppedHere =
        "Dry run, so it stopped here: this step would run again, waiting for an answer from Apple or a device that a dry run cannot get."

    // MARK: - A real run's outside steps
    //
    // Each lead line names the step and what came of it. What the tool, the
    // command or the agent printed is kept as the record's details, under
    // its own label, never as the step's line.

    /// A tool step (App Store Connect, a device, the simulator).
    static func tool(step: String, ok: Bool, raw: String, appleState: String? = nil) -> String {
        guard ok else { return timedOut(raw) ? ranOutOfTime(step) : "Could not finish \(quoted(step)). The details say why." }
        guard let appleState else { return "Finished \(quoted(step))." }
        let state = appleState.trimmingCharacters(in: .whitespacesAndNewlines)
        // The status script printed nothing Grux could read.
        if state.isEmpty || state.uppercased() == "UNKNOWN" {
            return "Finished \(quoted(step)), but Apple's status for the app could not be read."
        }
        return "Finished \(quoted(step)). Apple says the app is \(stateWords(state))."
    }

    /// A shell command step.
    static func command(step: String, exitCode: Int32) -> String {
        exitCode == 0 ? "Ran the command for \(quoted(step))."
            : "The command for \(quoted(step)) failed with exit code \(exitCode)."
    }

    /// One agent, or a team of `count`.
    static func agent(step: String, count: Int, ok: Bool, seconds: Double, cost: Double,
                      needsSignIn: Bool, raw: String) -> String {
        let who = count > 1 ? "\(count) agents" : "The agent"
        let spent = cost >= 0.005 ? String(format: " and cost $%.2f", cost) : ""
        if ok { return "\(who) finished \(quoted(step)) in \(timeWords(seconds))\(spent)." }
        let working = count > 1 ? "The \(count) agents working on" : "The agent working on"
        if needsSignIn { return "\(working) \(quoted(step)) stopped because Claude needs you to sign in again." }
        if timedOut(raw) { return "\(working) \(quoted(step)) ran out of time after \(timeWords(seconds))." }
        return "\(working) \(quoted(step)) stopped without finishing, after \(timeWords(seconds))\(spent)."
    }

    static func ranOutOfTime(_ step: String) -> String {
        "\(quoted(step)) ran out of time before it finished."
    }

    /// A step that stopped where no outcome came back.
    static let stoppedUnexpectedly = "This step stopped before it could finish."

    /// A step that asks for something this build cannot do.
    static let cannotDo = "This step asks for something this version of Grux cannot do."

    static func timedOut(_ raw: String) -> Bool {
        raw.range(of: #"(?i)\btimed?[ -]?out\b"#, options: .regularExpression) != nil
    }

    /// An App Store Connect state in words: WAITING_FOR_REVIEW becomes
    /// "waiting for review", READY_FOR_SALE "on the App Store".
    static func stateWords(_ state: String) -> String {
        switch state.uppercased() {
        case "READY_FOR_SALE": return "on the App Store"
        case "REJECTED", "METADATA_REJECTED": return "rejected"
        case "DEVELOPER_REJECTED": return "taken out of review"
        case "INVALID_BINARY": return "held back because Apple could not use the uploaded build"
        case "PENDING_DEVELOPER_RELEASE": return "approved and waiting for you to release it"
        default: return state.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "64 seconds", "3 minutes", "2 hours".
    static func timeWords(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if s < 90 { return plural(s, "second") }
        if s < 90 * 60 { return plural(Int((Double(s) / 60).rounded()), "minute") }
        return plural(Int((Double(s) / 3600).rounded()), "hour")
    }

    // MARK: - The run record in Workflows

    /// The header over a run's steps.
    static let stepsHeader = "Steps"
    /// The label over what the run kept for debugging (its raw state).
    static let detailsLabel = "Details"

    /// A step's title: its own person name, never its id. A record whose
    /// workflow or step is gone says so rather than showing the id.
    static func stepTitle(_ phaseId: String, in definition: CommandV2Definition?) -> String {
        definition?.phases.first { $0.id == phaseId }?.displayName ?? "A step this workflow no longer has"
    }

    /// A workflow's kind on its card, in a person word, never the value the
    /// engine stores.
    static func category(_ category: CommandV2Definition.Category) -> String {
        switch category {
        case .ship: return "Shipping"
        case .observe: return "Checking in"
        case .develop: return "Building"
        case .lifestyle: return "Everyday"
        case .system: return "Grux itself"
        }
    }

    /// A workflow card's title: the definition's name with any `{param}`
    /// placeholder read as the thing it stands for, as a run's name reads
    /// with no parameter given ("localize {project}" becomes "Localize your
    /// project"). SWEEP-14: two cards showed the raw placeholder.
    static func cardTitle(_ definition: CommandV2Definition) -> String {
        let filled = CommandV2Engine.runName(definition.displayName, params: [:])
        guard let first = filled.first, first.isLowercase else { return filled }
        return first.uppercased() + filled.dropFirst()
    }

    /// How a step went, in a plain word or two.
    static func status(_ outcome: CommandV2Run.PhaseRecord.Outcome) -> String {
        switch outcome {
        case .running: return "Running"
        case .success, .branched: return "Done"
        case .failure: return "Did not finish"
        case .skipped: return "Skipped"
        case .scheduled: return "Waiting until later"
        case .paused: return "Waiting for your answer"
        }
    }

    // MARK: - Words

    /// "24 hours", "7 days", "1 minute".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if s >= 2 * 86_400, s % 86_400 == 0 { return plural(s / 86_400, "day") }
        if s >= 3_600, s % 3_600 == 0 { return plural(s / 3_600, "hour") }
        if s >= 60, s % 60 == 0 { return plural(s / 60, "minute") }
        return plural(s, "second")
    }

    /// A step's name in quotes, without a period of its own.
    static func quoted(_ step: String) -> String {
        "\"\(step.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))\""
    }

    /// A step's name as the end of a sentence: "Check App Store Connect status"
    /// becomes "check App Store Connect status", "TestFlight feedback" stays.
    static func verbPhrase(_ step: String) -> String {
        let trimmed = step.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let chars = Array(trimmed)
        guard chars.count > 1, chars[0].isUppercase, chars[1].isLowercase else { return trimmed }
        return chars[0].lowercased() + String(chars.dropFirst())
    }

    /// Text that ends as a sentence.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?\"".contains(last) ? trimmed : trimmed + "."
    }
}
