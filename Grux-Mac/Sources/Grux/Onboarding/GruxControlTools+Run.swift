import Foundation
import GruxMCPCore

// MARK: - grux_run

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// List what can be run, or run one thing by id or by name.
    ///
    /// Grux keeps TWO registries of runnable things and nothing merged them. `CommandV2Engine`
    /// holds the phase gated workflows the app ships with and draws them in the Workflows tab;
    /// `VoiceMacroRegistry` holds the macros a person built and draws them in the Commands tab.
    /// Neither list knows the other exists, so "what can Grux run" had no answer on any
    /// surface. Answering it is most of what this tool is for.
    static func run(command: String?) async -> [String: Any] {
        // BOTH REGISTRIES LOAD LAZILY AND BOTH GUARD ON A `loaded` FLAG, so asking here costs
        // nothing after the first time and is correct before it. A socket call can land before
        // the app's own launch path has run, and a reply carrying every workflow and none of
        // the macros reads as "my commands are gone" rather than "ask again in a second".
        VoiceMacroRegistry.shared.load()
        CommandV2Engine.shared.load()

        let wanted = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            return MCPWire.textResult(jsonText(["commands": runnableCommands()]))
        }
        let needle = wanted.lowercased()

        // IDS BEFORE DISPLAY NAMES, AND A WORKFLOW ID BEFORE A MACRO NAME.
        //
        // Two registries means one string can name two things, and which one wins has to be
        // decided somewhere rather than falling out of whichever list happened to be searched
        // first. A macro name is sanitised to [a-z0-9_] and every workflow id carries a hyphen,
        // so a real collision needs a hand edited macros.json, but "unlikely" is not "decided"
        // and `grux run` prints this same order back to the reader when it sees one.
        if let def = CommandV2Engine.shared.definitions.first(where: {
            $0.id.lowercased() == needle
        }) {
            return await startWorkflowRun(def)
        }
        if let macro = VoiceMacroRegistry.shared.find(name: wanted) {
            return await runVoiceMacro(macro)
        }
        if let def = CommandV2Engine.shared.definitions.first(where: {
            $0.displayName.lowercased() == needle
        }) {
            return await startWorkflowRun(def)
        }

        // THE LIST TRAVELS WITH THE REFUSAL. This tool answers agents as well as the CLI, and
        // an agent that has to make a second call to find out what it could have said will
        // usually guess again instead.
        let known = runnableCommands().compactMap { $0["id"] as? String }
        return MCPWire.textFailure(known.isEmpty
            ? "Nothing is called \(wanted), and nothing at all is runnable yet. The Commands "
            + "tab in Grux is where a command gets built."
            : "Nothing runnable is called \(wanted). These are: \(known.joined(separator: ", ")).")
    }

    /// Both registries in one list, sorted, each row saying where it came from.
    private static func runnableCommands() -> [[String: Any]] {
        var rows: [[String: Any]] = []

        for def in CommandV2Engine.shared.definitions {
            let needs = def.parameters.map(\.name)
            let written = def.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let phases = def.phases.count
            rows.append([
                "id": def.id,
                "name": def.displayName,
                // Every definition the app ships with carries a description, but `register`
                // is public and a caller can pass one that does not, so the count of its
                // phases stands in. Pluralised for the same reason the macro branch below
                // is: a one phase workflow reading "1 phases" is a sentence this product
                // does not write anywhere else.
                "description": written.isEmpty
                    ? "\(phases) phase\(phases == 1 ? "" : "s"), no description."
                    : written,
                "source": "workflow",
                // A WORKFLOW THAT TAKES A SETTING CANNOT BE STARTED FROM HERE, and the list
                // has to say so before somebody types it. `grux_run` carries one string and
                // its schema has nowhere to put a project name, and a phase interpolates a
                // missing ${param.x} to an empty string rather than stopping, so starting one
                // anyway speaks half a sentence out loud and then fails a phase in. The Orb
                // palette already draws this line the same way: parameterless ones run, the
                // rest open the tab that asks.
                "state": needs.isEmpty ? "ready" : "needs",
                "needs": needs,
                "trigger": def.voiceTriggers.first ?? "",
            ])
        }

        for macro in VoiceMacroRegistry.shared.macros {
            let written = macro.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let steps = macro.actions.count
            rows.append([
                "id": macro.name,
                "name": macro.name,
                // A macro you built yourself is allowed to have no description, so the count
                // of its steps stands in. It is less than a sentence and more than a blank.
                "description": written.isEmpty
                    ? "\(steps) step\(steps == 1 ? "" : "s"), no description."
                    : written,
                "source": "macro",
                "state": !macro.enabled ? "off" : (macro.actions.isEmpty ? "empty" : "ready"),
                "needs": [String](),
                "trigger": macro.triggers.first ?? "",
            ])
        }

        // Sorted here so the reply is byte stable for anything that diffs it, and sorted again
        // by the CLI, which cannot assume the app answering it is this build.
        return rows.sorted {
            (($0["id"] as? String) ?? "").lowercased() < (($1["id"] as? String) ?? "").lowercased()
        }
    }

    private static func startWorkflowRun(_ def: CommandV2Definition) async -> [String: Any] {
        guard def.parameters.isEmpty else {
            let names = def.parameters.map(\.name)
            let asked: String
            if names.count == 1 {
                asked = "a \(names[0])"
            } else {
                let listed = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
                asked = "values for " + listed
            }
            var instead = "The Workflows tab in Grux asks for it."
            if let trigger = def.voiceTriggers.first, !trigger.isEmpty {
                // The braces sentence is only true of a trigger that HAS a slot in it, and
                // most but not all of them do.
                instead += trigger.contains("{")
                    ? " So does saying \"\(trigger)\" to Grux, with the real value where the "
                    + "braces are: it fills the slot in and starts the run."
                    : " So does saying \"\(trigger)\" to Grux."
            }
            let them: String = names.count == 1 ? "one" : "them"
            return MCPWire.textFailure("\(def.id) needs \(asked), and this tool has no way to "
                + "pass \(them). \(instead)")
        }

        switch await CommandV2Engine.shared.start(definitionId: def.id) {
        case .failure(let why):
            // The engine's own sentence. It already covers the case worth having words for,
            // which is a ship run for this project that is running right now, and it names the
            // phase that one is sitting in.
            return MCPWire.textFailure(why.errorDescription
                ?? "Grux would not start \(def.id) and did not say why.")
        case .success(let runId):
            // NOTHING HERE SAYS IT FINISHED. `start` puts the first phase on a Task and returns
            // immediately, so the only claims this can back are that a run now exists and where
            // to watch it. The SHORT id is the one worth handing back: WakeLog prints the first
            // eight characters, so the full uuid greps the log for nothing.
            return MCPWire.textResult(jsonText([
                "started": true,
                "source": "workflow",
                "id": def.id,
                "name": def.displayName,
                "run_id": runId.uuidString,
                "log_tag": String(runId.uuidString.prefix(8)),
                "phases": def.phases.count,
                "first_phase": def.phases.first?.displayName ?? "",
            ]))
        }
    }

    private static func runVoiceMacro(_ macro: Macro) async -> [String: Any] {
        // THE SWITCH IS RESPECTED RATHER THAN OVERRIDDEN. The registry refuses a disabled
        // macro too, and a control plane that quietly did the opposite of the app would make
        // the switch mean two different things depending on which surface you were standing on.
        guard macro.enabled else {
            return MCPWire.textFailure("\(macro.name) is switched off, so Grux left it alone. "
                + "Its switch is in the Commands tab.")
        }
        guard !macro.actions.isEmpty else {
            return MCPWire.textFailure("\(macro.name) has no steps in it yet, so there was "
                + "nothing to run. The Commands tab is where you add one.")
        }

        // COUNTED BEFORE THE RUN, FROM THE DEFINITION. `run(name:)` awaits only the steps
        // marked wait for completion and detaches the rest, so "it ran" is true of some steps
        // of any macro and false of the others. This split is the only place that difference
        // survives, and without it the CLI would have to claim the whole thing finished.
        let live = macro.actions.filter(\.enabled)
        let waited = live.filter(\.waitForCompletion).count

        let report = await VoiceMacroRegistry.shared.run(name: macro.name)

        return MCPWire.textResult(jsonText([
            "started": true,
            "source": "macro",
            "id": macro.name,
            "name": macro.name,
            "steps": macro.actions.count,
            "steps_waited": waited,
            "steps_detached": live.count - waited,
            "steps_off": macro.actions.count - live.count,
            "report": report,
        ]))
    }
}
