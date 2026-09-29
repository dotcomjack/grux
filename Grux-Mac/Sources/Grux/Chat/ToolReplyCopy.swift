import Foundation

/// A tool result is written for the model: `ok: created note 'X' id=...`,
/// `(no documents matched)`, `pending: 'create_note' is waiting in the Jax HQ
/// approval queue for the user's one-tap approval.` When a result reaches the
/// person with no model in between (the PIM card, an approval landing back in
/// Chat, a local model that echoes the result as its whole reply), it goes
/// through here first (operator row D-replycopy, 2026-09-28). The person reads
/// "you", the name on the panel (Approvals), what happened and the one next
/// step; never a tool id, an internal name, or a status line in parentheses.
///
/// A tool id is a name in the tool registry (`ChatService.allTools()`), not any
/// word with an underscore: `my_notes.txt` in a result is the person's own
/// file name and reaches them as written (RV14).
@MainActor
enum ToolReplyCopy {

    /// The line a person reads for `result`, the output of tool `tool` called
    /// with `input`.
    static func forPerson(tool: String, input: [String: Any], result raw: String) -> String {
        let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked first: a held write never reads as done, whatever its tool.
        if result.hasPrefix(JaxToolGate.dryRunStatus) { return heldForDryRun(tool: tool) }
        if result.hasPrefix("pending:") { return pending(tool: tool, input: input) }
        if result.hasPrefix("refused:") {
            let reason = strip(prefix: "refused:", from: result)
                .replacingOccurrences(of: "Nothing was sent or changed.", with: "")
                .trimmingCharacters(in: .whitespaces)
            return sentence("I did not do that. \(readable(reason))") + " Nothing was sent or changed."
        }
        if result.hasPrefix("error:") { return failure(tool: tool, message: strip(prefix: "error:", from: result)) }
        if result.hasPrefix("busy") { return "That is already running. Try again in a moment." }

        let body = result.hasPrefix("ok:") ? strip(prefix: "ok:", from: result) : result
        switch tool {
        case "add_task":
            return "Added \(quoted(firstQuoted(body) ?? (input["title"] as? String))) to your tasks."
        case "complete_task":
            return "Checked off \(quoted(firstQuoted(body)))."
        case "remove_task":
            return "Removed \(quoted(firstQuoted(body))) from your tasks."
        case "focus_on_task":
            return "\(quoted(firstQuoted(body)).capitalizedFirst) is your focus now."
        case "remember_fact":
            let fact = firstQuoted(body) ?? (input["fact"] as? String) ?? ""
            return fact.isEmpty ? "Got it, I will remember that." : "Got it, I will remember: \(fact)"
        case "create_note":
            return "Saved your note \(quoted(firstQuoted(body) ?? (input["title"] as? String)))."
        case "create_event":
            return eventCreated(body: body, input: input)
        case "documents_list":
            return documents(result: result, query: (input["query"] as? String) ?? "")
        default:
            return readable(body)
        }
    }

    /// The model sometimes hands a tool result back as its whole reply (qwen2.5
    /// on the local route does). When the reply is one of this turn's results,
    /// or opens on a result's status word, the person gets the translated line.
    static func replacingEcho(reply: String, results: [(tool: String, input: [String: Any], result: String)]) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = results.last(where: { $0.result.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) {
            return forPerson(tool: hit.tool, input: hit.input, result: hit.result)
        }
        let statusWords = ["pending:", "ok:", "error:", "refused:", JaxToolGate.dryRunStatus]
        if let last = results.last, statusWords.contains(where: { trimmed.hasPrefix($0) }) {
            return forPerson(tool: last.tool, input: last.input, result: trimmed)
        }
        return reply
    }

    /// What a person should never read in a reply. Empty means the line is fine.
    /// The guard tests run every line this type can build through it.
    /// `internalNames` are ids the caller knows are its own (a workflow's step
    /// ids, say), flagged wherever they appear as a whole word.
    /// Acronyms a line may use only next to what they stand for.
    static let unexplainedAcronyms: [(String, String)] = [
        ("ASC", "App Store Connect"), ("TCC", "privacy"), ("MCP", "Model Context Protocol"),
        ("PIM", "personal information"),
    ]

    static func problems(in line: String, internalNames: Set<String> = []) -> [String] {
        var found: [String] = []
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in internalNames.sorted()
        where line.range(of: #"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\w-])"#,
                         options: .regularExpression) != nil {
            found.append("names '\(name)'")
        }
        if line.range(of: #"(?i)\bthe user('s)?\b"#, options: .regularExpression) != nil { found.append("says 'the user'") }
        if !toolIds(in: line).isEmpty || namesAToolIdInWords(line) { found.append("names a tool id") }
        if line.range(of: "Jax HQ", options: .caseInsensitive) != nil { found.append("names Jax HQ") }
        if trimmed.hasPrefix("(") { found.append("opens with a parenthesized status") }
        if let status = ["pending:", "ok:", "error:", "refused:", JaxToolGate.dryRunStatus]
            .first(where: { trimmed.lowercased().hasPrefix($0) }) {
            found.append("opens with '\(status)'")
        }
        if line.range(of: #"\bid=\S"#, options: .regularExpression) != nil { found.append("shows an id") }
        // An acronym a person may not know, with nothing on the line saying
        // what it stands for.
        for (acronym, meaning) in unexplainedAcronyms
        where line.range(of: #"\b"# + acronym + #"\b"#, options: .regularExpression) != nil
            && line.range(of: meaning, options: .caseInsensitive) == nil {
            found.append("uses \(acronym) without saying what it is")
        }
        // A hyphen with a space each side, standing in for a dash. A list
        // item's leading "- " has no word before it and is fine.
        if line.range(of: #"(?<=\S)[ \t]+-[ \t]+(?=\S)"#, options: .regularExpression) != nil {
            found.append("uses a spaced hyphen as a dash")
        }
        // How the engine works, not what the person sees happen.
        if line.range(of: #"(?i)\b(branch on|spawn\w*|swarm\w*|builtin|echo|dedup\w*)\b"#,
                      options: .regularExpression) != nil {
            found.append("uses an engine word")
        }
        // A `{project}` or `${param.project}` nobody filled.
        if line.range(of: #"\$?\{[A-Za-z_][A-Za-z0-9_.]*\}"#, options: .regularExpression) != nil {
            found.append("shows an unfilled placeholder")
        }
        return found
    }

    /// What an approval is about, as the person would name it: `your note
    /// "Groceries"`. The queue's own summary for a gated write is the gate's
    /// `Run tool 'create_note' (unclassified side effect).`
    static func subject(tool: String, input: [String: Any]) -> String {
        let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let named = title.isEmpty ? "" : " \(quoted(title))"
        switch tool {
        case "create_note": return "your note\(named)"
        case "update_note": return "the change to your note\(named)"
        case "create_event": return "your event\(named)"
        case "create_contact": return "the new contact"
        case "compose_email": return (input["to"] as? String).map { "your email to \($0)" } ?? "your email"
        case "shell_run", "shell_run_confirmed", "shell_start":
            return (input["command"] as? String).map { "the command `\($0)`" } ?? "the command"
        default: return "that request"
        }
    }

    /// What Chat hears when a person skips a request in Approvals. An item with
    /// no replay still carries its summary, which can be the gate's fallback
    /// `Run tool 'create_note' (unclassified side effect).` (RV24).
    static func skipped(tool: String?, input: [String: Any], summary: String) -> String {
        if let tool = tool ?? fallbackTool(in: summary) {
            return "Skipped \(subject(tool: tool, input: input)) in Approvals. Nothing was run."
        }
        return sentence("Skipped in Approvals: \(readable(summary))") + " Nothing was run."
    }

    /// The tool named by the gate's fallback summary, `Run tool '<id>' (...)`.
    private static func fallbackTool(in summary: String) -> String? {
        guard summary.hasPrefix("Run tool '") else { return nil }
        return summary.dropFirst("Run tool '".count).split(separator: "'").first.map(String.init)
    }

    /// What Approvals lists for a knowingly gated tool (row A30), in place of the
    /// gate's `Run tool 'create_event' (unclassified side effect).` Nil for a tool
    /// with no wording, which keeps whatever summary it came with.
    static func approvalSummary(tool: String, input: [String: Any]) -> String? {
        func named(_ key: String) -> String {
            let raw = ((input[key] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let readable = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            return readable.isEmpty ? "" : " \(quoted(readable))"
        }
        switch tool {
        case "create_note": return "Save your note\(named("title"))."
        case "update_note": return "Change your note\(named("title"))."
        case "create_event": return "Add your event\(named("title")) to your calendar."
        case "create_contact": return "Add\(named("name").isEmpty ? " a new contact" : named("name")) to your contacts."
        case "documents_create": return "Create the document\(named("title"))."
        case "edit_document": return "Edit your document\(named("document"))."
        case "delete_folder": return "Delete the meeting folder\(named("folder"))."
        case "delete_speaker": return "Delete a saved speaker voice."
        case "backup_now": return "Back up your Grux data now."
        case "pdf_form_fill": return "Fill in a PDF form."
        case "export_audio": return "Export meeting audio to a file."
        case "export_ics": return "Export your events to a calendar file."
        case "export_memory": return "Export your memories to a file."
        case "import_ics": return "Import events from a calendar file."
        case "import_memory": return "Import memories from a file."
        case "save_skill": return "Save a new skill\(named("name"))."
        case "create_folder": return "Create a meeting folder\(named("name"))."
        case "rename_folder": return "Rename the meeting folder\(named("folder"))."
        case "rename_speaker": return "Rename a speaker."
        case "rename_cluster_in_meeting": return "Name a speaker in a meeting."
        case "move_meeting_to_folder": return "Move a meeting to another folder."
        case "classify_meeting_to_folder": return "File a meeting in a folder."
        case "enroll_speaker_from_current_meeting", "enroll_speaker_from_meeting":
            return "Learn a speaker's voice from a meeting."
        case "control_screen": return "Control your screen: click and type for you."
        case "run_macro": return "Run your macro\(named("name"))."
        case "deep_research": return "Start an in-depth research report."
        case "creative_render_image": return "Make an image."
        case "creative_full_bundle": return "Make a full creative bundle."
        case "agent_cancel": return "Stop a running agent."
        case "agent_swarm_start": return "Start a team of agents on a job."
        case "foundry_upgrade_cycle": return "Start a self-upgrade cycle."
        case "start_workflow_v2": return "Start the workflow\(named("command_id"))."
        case "ios_build_verify": return "Build and check an iOS app."
        case "ios_doctor": return "Check your iOS build setup."
        case "ios_scaffold": return "Create a new iOS app project."
        case "ios_simulator_run": return "Run an iOS app in the Simulator."
        case "start_meeting_capture": return "Start recording a meeting."
        case "stop_meeting_capture": return "Stop recording the meeting."
        case "shell_run", "shell_run_confirmed", "shell_start":
            return "Run \(subject(tool: tool, input: input))."
        case "shell_end": return "End the shell session."
        case "shell_undo": return "Undo the last shell change."
        default: return nil
        }
    }

    // MARK: - Pieces

    private static func pending(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "create_note":
            return "Your note is waiting for your OK in Approvals. Nothing is saved until you tap it."
        case "create_event":
            return "Your event is waiting for your OK in Approvals. Nothing goes on your calendar until you tap it."
        case "compose_email":
            let to = (input["to"] as? String).map { " to \($0)" } ?? ""
            return "Your email\(to) is waiting for your OK in Approvals. Nothing is sent until you tap it."
        default:
            return "That is waiting for your OK in Approvals. Nothing happens until you tap it."
        }
    }

    /// A write a dry-run turn held: one plain sentence, per kind of act.
    private static func heldForDryRun(tool: String) -> String {
        let what: String
        switch tool {
        case "create_note", "update_note", "documents_create", "edit_document", "save_skill":
            what = "Nothing was saved"
        case "create_event": what = "Nothing went on your calendar"
        case "compose_email", "slack_send": what = "Nothing was sent"
        case "open_app", "open_url": what = "Nothing was opened"
        case "shell_run", "shell_run_confirmed", "shell_start", "run_macro": what = "Nothing was run"
        default: what = "Nothing was done"
        }
        return "\(what), because this is a dry run."
    }

    private static func failure(tool: String, message: String) -> String {
        if let match = message.range(of: #"no active task matched '([^']*)'"#, options: .regularExpression) {
            let name = firstQuoted(String(message[match])) ?? ""
            return "I did not find a task called \(quoted(name))."
        }
        if let match = message.range(of: #"no (?:document|note) matched '([^']*)'"#, options: .regularExpression) {
            let name = firstQuoted(String(message[match])) ?? ""
            return "I did not find anything called \(quoted(name))."
        }
        return sentence("That did not go through: \(readable(message))")
    }

    /// `created 'Dentist' Tue Sep 29 3:00 PM to 4:00 PM in calendar 'Home' id=...`
    private static func eventCreated(body: String, input: [String: Any]) -> String {
        let title = firstQuoted(body) ?? (input["title"] as? String) ?? "the event"
        var when = ""
        if let open = body.range(of: "'\(title)' "), let cal = body.range(of: " in calendar '") {
            if open.upperBound < cal.lowerBound { when = String(body[open.upperBound..<cal.lowerBound]) }
        }
        var calendar = ""
        if let cal = body.range(of: " in calendar '") {
            calendar = String(body[cal.upperBound...]).components(separatedBy: "'").first ?? ""
        }
        var line = "Added \(quoted(title)) to your calendar"
        if !when.isEmpty { line += ", \(when)" }
        if !calendar.isEmpty { line += ", in \(calendar)" }
        return line + "."
    }

    /// `- id=UUID · Title · Sep 27 3:04 PM · Markdown · starred\n  → preview`
    private static func documents(result: String, query: String) -> String {
        let rows = result.split(separator: "\n").filter { $0.hasPrefix("- ") }
        guard !rows.isEmpty else {
            let q = query.trimmingCharacters(in: .whitespaces)
            return q.isEmpty ? "I did not find any docs." : "I did not find a doc about \(q)."
        }
        let lines = rows.map { row -> String in
            let fields = row.dropFirst(2).components(separatedBy: " · ").filter { !$0.hasPrefix("id=") }
            let title = fields.first ?? ""
            let updated = fields.count > 1 ? ", updated \(fields[1])" : ""
            return "- \(title)\(updated)"
        }
        let head = rows.count == 1 ? "I found 1 doc:" : "I found \(rows.count) docs:"
        return ([head] + lines).joined(separator: "\n")
    }

    /// A model-facing phrase made readable: no tool ids, no internal names.
    private static func readable(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "the Jax HQ approval queue", with: "Approvals")
            .replacingOccurrences(of: "Jax HQ", with: "Approvals")
            .replacingOccurrences(of: #"(?i)\bthe user has\b"#, with: "you have", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bthe user is\b"#, with: "you are", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bthe user's\b"#, with: "your", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bthe user\b"#, with: "you", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\bid=\S+"#, with: "", options: .regularExpression)
        // `'create_note'` and a bare tool id read as "that". Only names in the
        // tool registry: any other snake_case word is the person's own text.
        var named = ""
        var from = out.startIndex
        for range in toolIds(in: out) {
            named += String(out[from..<range.lowerBound]) + "that"
            from = range.upperBound
        }
        out = (named + String(out[from...])).trimmingCharacters(in: .whitespaces)
        if out.hasPrefix("("), out.hasSuffix(")") { out = String(out.dropFirst().dropLast()) }
        return out.capitalizedFirst
    }

    /// Every tool the model can call, by id.
    private static var registry: Set<String> { Set(ChatService.allTools().map(\.name)) }

    /// Where `text` names a registered tool: a whole snake_case word, with its
    /// quotes when quoted, that is not part of a file name or path.
    private static func toolIds(in text: String) -> [Range<String.Index>] {
        let pattern = #"(?<![\w./-])'?([a-z]+(?:_[a-z]+)+)'?(?![\w/-]|\.\w)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let known = registry
        return re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { m in
            guard let id = Range(m.range(at: 1), in: text), known.contains(String(text[id])) else { return nil }
            return Range(m.range, in: text)
        }
    }

    /// A tool id with its underscores read as spaces (`open app`, the old
    /// dry-run fallback's `Use open app.`), or an MCP tool id in either form.
    /// MCP ids are matched by their naming pattern (`MCPToolNaming`), so the
    /// check holds with no server connected. Only the guard uses this: the
    /// person's own words are never rewritten on a guess.
    private static func namesAToolIdInWords(_ text: String) -> Bool {
        let mcp = #"(?<![\w./-])"# + NSRegularExpression.escapedPattern(for: MCPToolNaming.prefix.replacingOccurrences(of: "_", with: ""))
            + #"[_ ][a-z0-9][a-z0-9-]*[_ ][A-Za-z0-9]"#
        if text.range(of: mcp, options: .regularExpression) != nil { return true }
        for id in registry where id.contains("_") {
            let spaced = id.replacingOccurrences(of: "_", with: " ")
            if text.range(of: #"(?<![\w-])"# + NSRegularExpression.escapedPattern(for: spaced) + #"(?![\w-])"#,
                          options: .regularExpression) != nil { return true }
        }
        return false
    }

    private static func strip(prefix: String, from s: String) -> String {
        String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".!?".contains(last) ? t : t + "."
    }

    /// The text inside the first pair of single quotes.
    private static func firstQuoted(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "'") else { return nil }
        let rest = s[s.index(after: open)...]
        guard let close = rest.lastIndex(of: "'") else { return nil }
        let inside = String(rest[..<close])
        // `'A' (NEXT) in 'B'`: keep only the first quoted run.
        if let cut = inside.range(of: "' ") { return String(inside[..<cut.lowerBound]) }
        return inside
    }

    private static func quoted(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "that" : "\"\(t)\""
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
