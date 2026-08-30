import Foundation

/// A prompt the user hands to their own coding agent so it can finish setting
/// Grux up for them.
///
/// ## Why this exists
///
/// Setup is nine credentials, eight macOS permissions and a handful of installs.
/// The onboarding flow front-loads only the one thing that blocks everything
/// (a model key) and defers the rest to the point of use, which is right. But
/// "deferred" still means the work is waiting, and a lot of it is mechanical:
/// installing a CLI, fetching a model, writing a config file. Anybody using Grux
/// already has an agent that does exactly that kind of work.
///
/// So rather than walking them through it, hand them one paragraph they can
/// paste into that agent.
///
/// ## The split, and why the line is where it is
///
/// The generated prompt has two lists and the boundary is the whole point.
///
/// AN AGENT MAY NOT CONSENT ON SOMEBODY'S BEHALF. Four setup steps are not
/// installs at all, they are decisions: "Confirm you will tell people" is about
/// recording other humans, "Confirm what stays private" and "Choose what gets
/// indexed" decide what Grux may read of somebody's own writing, and "Review the
/// first capture" only means anything if a person actually looked. An agent that
/// ticks those has not completed setup, it has removed the point of the step.
///
/// Credentials and macOS permissions are out for a duller reason: they need a
/// browser session, a card, or a click in System Settings, and an agent has none
/// of those. Saying so plainly is better than watching it try.
// @MainActor because it reads live capability state: CapabilityResolver checks
// the Keychain and the real permission status, and FeatureRegistry is isolated
// for the same reason. Both call sites are UI.
@MainActor
enum AgentHandoff {

    /// Requirements a coding agent can genuinely satisfy, by hand and by name.
    ///
    /// Derived from a LIST rather than from `kind`, because `kind == .step` is
    /// not the same question. Four of the nine steps are consent or judgement
    /// and belong to the person, and no property on the enum distinguishes
    /// "install a binary" from "decide what stays private".
    /// NARROWED after review, to the two whose real work is INSTALLING SOFTWARE
    /// on this Mac. The first draft listed five and three of them were wrong.
    ///
    /// `stepSpeechModelDownloaded` remediates to "open Meetings once" and
    /// `stepYoutubeTranscriptsEnabled` to "turn it on in Settings". Both are
    /// actions INSIDE Grux, which is precisely what this prompt reserves for the
    /// person. Asking an agent to do them would have it either fail or reach
    /// into an app it cannot drive. `stepTerminalFocusHookInstalled` is Grux
    /// writing the hook itself, not the agent.
    static let delegable: Set<SetupRequirement> = [
        .stepAgentCliInstalled,
        // Ollama is the one endpoint an agent really can stand up: it is an
        // install and a local server, with no account and no credential.
        .endpointOllama,
    ]

    /// Everything still unsatisfied on this machine, split by who can do it.
    ///
    /// ## Only features the owner CHOSE
    ///
    /// CR-36 gave a feature an off state and this function was not told. It enumerated all
    /// thirty nine rows regardless, so a handoff generated right after somebody picked four
    /// features listed ten credentials and permissions belonging to the thirty five they had
    /// just declined. Driving `grux setup --preset minimal` showed three screens of one run
    /// disagreeing: COST called those capabilities optional, PROVE said "0 still waiting on
    /// you", and the prompt in between told an agent to go and fetch Slack, Notion and
    /// Telegram tokens.
    ///
    /// Asking for a credential because of a feature the owner turned OFF is the exact
    /// over-asking this whole flow exists to stop, and it would have been done by somebody
    /// else's agent, on their account, at their expense.
    static func outstanding() -> (agent: [SetupRequirement], human: [SetupRequirement]) {
        // Only capabilities a CHOSEN feature actually claims. Offering to set up a
        // credential nothing reads is how a setup list becomes noise.
        let claimed = FeatureRegistry.rows
            .filter { FeatureSelection.isOn($0.id) }
            .flatMap { $0.blocking + $0.optional + $0.optionalSteps }
        var seen = Set<SetupRequirement>()
        let unique = claimed.filter { seen.insert($0).inserted }
        let missing = unique.filter { !CapabilityResolver.isSatisfied($0) }
        return (missing.filter { delegable.contains($0) },
                missing.filter { !delegable.contains($0) })
    }

    /// The text the button copies.
    ///
    /// Addressed to the agent, not to the user, because that is where it is
    /// going. It names the machine's real state so the agent is not guessing,
    /// and it says what NOT to do, since the most expensive mistake here is an
    /// agent helpfully writing an API key into a dotfile.
    /// The four steps that are CONSENT rather than setup, named individually.
    ///
    /// The same list `delegable` is derived from, and for the same reason: no
    /// property on the enum distinguishes "decide what stays private" from
    /// "fetch a speech model". `kind == .step` is not that question, and reading
    /// it as though it were is what put five errands under a heading that told
    /// the agent not to touch them.
    static let consentSteps: Set<SetupRequirement> = [
        .stepRecordingConsentAcknowledged,
        .stepCaptureExclusionsConfirmed,
        .stepCorpusSourcesConfirmed,
        .stepFirstFrameReviewed,
    ]

    /// How the human list is presented, as DATA rather than as text, so the
    /// boundary between "a decision" and "an errand" can be asserted directly
    /// instead of by grepping a generated paragraph.
    ///
    /// ## The bug
    ///
    /// This grouped on `kind`, so all nine `.step` cases printed under
    /// "Decisions that are mine to make. Please do not answer these for me".
    /// Five of them are nothing of the sort: fetching a speech model,
    /// installing the terminal hook, pairing a phone, turning on YouTube
    /// transcripts, and the agent CLI when it is not delegable. An agent reading
    /// that is told a download is a personal decision, so it correctly refuses
    /// work it could have done, and the user does it by hand for no reason.
    ///
    /// Consent is LAST on purpose. It is the strongest framing in the prompt and
    /// it reads best immediately before the closing rules, rather than buried
    /// between two lists of errands.
    static func groups(for human: [SetupRequirement]) -> [(heading: String, items: [SetupRequirement])] {
        let all: [(String, [SetupRequirement])] = [
            // SHORT LABELS, because these are sub-headings under MINE now rather than
            // standalone paragraphs. As full sentences they wrapped to two lines each and
            // repeated the framing MINE had already given one line above.
            ("Credentials to fetch, each needing an account and sometimes a card:",
             human.filter { $0.kind == .key }),
            ("macOS permissions, granted in System Settings:",
             human.filter { $0.kind == .perm }),
            ("Addresses that need my own details:",
             human.filter { $0.kind == .endpoint }),
            // Mechanical, and every one of them happens INSIDE Grux, which is
            // why they are mine rather than the agent's. Not decisions.
            ("Steps inside Grux, mechanical but mine because they live in the app:",
             human.filter { $0.kind == .step && !consentSteps.contains($0) }),
            ("Decisions that are mine to make. Please do not answer these for me:",
             human.filter { consentSteps.contains($0) }),
        ]
        return all.filter { !$0.1.isEmpty }.map { (heading: $0.0, items: $0.1) }
    }

    static func prompt() -> String {
        let split = outstanding()
        return promptFor(agent: split.agent, human: split.human)
    }

    /// A handoff scoped to named features rather than to everything outstanding.
    ///
    /// `grux handoff meetings chat` answers "what would it take to get THESE working", which
    /// is the question somebody has when they are adding one thing rather than setting up
    /// from scratch. Scoping is derived from the same registry rows the rest of this file
    /// uses, so a scoped handoff can never name something the unscoped one would not.
    ///
    /// An unknown id is REPORTED BY THE CALLER, not silently dropped here. Dropping it would
    /// produce a confident, shorter document for a feature that does not exist.
    static func promptFor(features ids: Set<String>) -> String {
        let rows = FeatureRegistry.rows.filter { ids.contains($0.id) }
        let claimed = rows.flatMap { $0.blocking + $0.optional + $0.optionalSteps }
        var seen = Set<SetupRequirement>()
        let unique = claimed.filter { seen.insert($0).inserted }
        let missing = unique.filter { !CapabilityResolver.isSatisfied($0) }
        return promptFor(agent: missing.filter { delegable.contains($0) },
                         human: missing.filter { !delegable.contains($0) })
    }

    // MARK: - The six headings

    /// The only headings this document has, in the only order it has them.
    ///
    /// A person who has read one handoff can skim any other, and that is the entire value of
    /// fixing them. `EXTRA` exists as a pressure valve for a command that genuinely has
    /// something else to say, and `HandoffShapeTests` counts its use, so growing a seventh
    /// heading by habit is visible rather than gradual.
    static let headings = ["CONTEXT", "YOURS", "MINE", "NEVER", "VERIFY", "REPORT"]

    /// PASTED INTO A TERMINAL, so it wraps at 76.
    ///
    /// The previous version wrapped nothing at all: its hardcoded paragraphs sat at roughly
    /// 80 because somebody had hand-broken them, and every generated line ran to whatever
    /// length the remediation string happened to be. In a terminal only the generated ones
    /// looked wrong, which reads as the machine-written half being sloppy.
    static let width = 76

    /// `hanging` indents every line after the first by that many EXTRA spaces, so a wrapped
    /// bullet sits under its own text rather than under the dash. Without it the second line
    /// of "- Slack token. Connect Slack..." starts in the same column as the dash and reads
    /// as a new item, which is the nested-things-indent-under-their-parent rule breaking in
    /// the one document that is pasted somewhere else and read by a stranger.
    static func wrap(_ text: String, indent: Int = 0, hanging: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let hangPad = String(repeating: " ", count: indent + hanging)
        let limit = width - indent - hanging
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
                continue
            }
            var line = ""
            var first = true
            for word in paragraph.split(separator: " ") {
                if line.isEmpty { line = String(word) }
                else if line.count + 1 + word.count <= limit { line += " " + word }
                else {
                    lines.append((first ? pad : hangPad) + line)
                    first = false
                    line = String(word)
                }
            }
            if !line.isEmpty { lines.append((first ? pad : hangPad) + line) }
        }
        return lines.joined(separator: "\n")
    }

    /// The renderer, over an explicit split, so the generated text can be asserted against a
    /// fixed machine state instead of whatever this one happens to be missing today.
    static func promptFor(agent: [SetupRequirement], human: [SetupRequirement]) -> String {
        var out: [String] = []

        // ---- CONTEXT ---------------------------------------------------------------------
        out.append("CONTEXT")
        out.append(wrap("""
            I am setting up Grux OS on my Mac and I would like you to do the parts you can. \
            Grux is a native macOS assistant. It reads the window I am working in and handles \
            my mail, calendar, notes and files from this machine. It has no account and no \
            server: every credential lives in the macOS Keychain and every model call goes \
            from my Mac straight to the provider I chose.
            """))

        // ---- YOURS -----------------------------------------------------------------------
        out.append("\nYOURS")
        if agent.isEmpty {
            out.append(wrap("Nothing. Everything on this Mac that an agent can set up is "
                            + "already in place, so there is no work for you in this list."))
        } else {
            out.append(wrap("Work through these and tell me what you changed. "
                            + "Numbered so you can report against them."))
            out.append("")
            for (i, r) in agent.enumerated() {
                // The number, then the label, then the remediation, wrapped under a hanging
                // indent so a long remediation does not start a new column of its own.
                out.append(wrap("\(i + 1). \(r.label). \(r.remediation)",
                                indent: 0, hanging: 3))
            }
        }

        // ---- MINE ------------------------------------------------------------------------
        out.append("\nMINE")
        if human.isEmpty {
            out.append(wrap("Nothing is waiting on me either."))
        } else {
            out.append(wrap("Please do not attempt any of these, and tell me when it is my "
                            + "turn, naming which one."))
            // FOUR KINDS OF BLOCKED THING, FOUR HEADINGS. The first draft of this document
            // printed one flat list, and "Slack token, Automation, Choose what gets indexed"
            // read as a jumble of one kind of errand. They need four different actions from
            // me, and the consent items in particular have to carry their own framing rather
            // than sitting among API tokens.
            for group in groups(for: human) {
                out.append("")
                out.append(wrap(group.heading, indent: 2))
                for r in group.items {
                    out.append(wrap("- \(r.label). \(r.remediation)",
                                    indent: 4, hanging: 2))
                }
            }
        }

        // ---- NEVER -----------------------------------------------------------------------
        out.append("\nNEVER")
        var prohibitions = [
            "Never write an API key, token or password into a file. Grux reads credentials "
            + "from the macOS Keychain only, and the way in is the Settings window inside the "
            + "app, which I will do myself. If you find a key sitting in a file anywhere, "
            + "tell me about it and leave it alone.",
            "Never turn on anything that listens or records. The wake word and ambient mode "
            + "both ship switched off and that is deliberate; they are mine to enable.",
            "Never tick a consent step on my behalf. Those are decisions about what Grux may "
            + "read and who I have told about recording, and an agent answering them has not "
            + "completed setup, it has removed the point of the step.",
        ]
        if !agent.isEmpty {
            prohibitions.append("Never install anything that is not named under YOURS. If "
                                + "something there needs a dependency, tell me first.")
        }
        prohibitions.append("Never run anything with sudo without showing me the command "
                            + "first. Prefer the official installer or Homebrew.")
        for p in prohibitions { out.append(wrap("- " + p, indent: 0, hanging: 2)) }

        // ---- VERIFY ----------------------------------------------------------------------
        out.append("\nVERIFY")
        out.append(wrap("Run this, and every id named above appears in its output:"))
        out.append("")
        out.append("    grux status --json")
        out.append("")
        // HONEST ABOUT WHAT GRUX CAN SEE, and this paragraph used to be wrong.
        //
        // It said Grux "does not go looking to see whether you installed them", flatly, for
        // every step. That stopped being true when four steps became detected: the agent CLI,
        // the speech model, the terminal hook and the paired phone are all measured on disk
        // now. Telling an agent its work will not be noticed when it WILL is how somebody
        // ends up ticking a box by hand that was already true.
        let detected = CapabilityResolver.detectedSteps.count
        let attested = CapabilityResolver.selfAttestedSteps.count
        out.append(wrap("""
            Of the \(detected + attested) setup steps, \(detected) are ones Grux measures for \
            itself, so if you install them they go green on their own and neither of us has \
            to do anything else. The other \(attested) are consent and settings decisions \
            that nothing can detect, so they stay open until I tick them inside Grux, under \
            Settings. That is expected, not a failure of yours.
            """))

        // ---- REPORT ----------------------------------------------------------------------
        out.append("\nREPORT")
        out.append(wrap("When you are done, give me a short list:"))
        out.append("")
        out.append(wrap("- What you installed, by name, and where it went.",
                        indent: 2, hanging: 2))
        out.append(wrap("- What is still waiting on me, and which of the groups above it is "
                        + "in.", indent: 2, hanging: 2))
        out.append(wrap("- Anything you found that looked wrong, especially a credential "
                        + "sitting in a file.", indent: 2, hanging: 2))

        return out.joined(separator: "\n") + "\n"
    }
}
