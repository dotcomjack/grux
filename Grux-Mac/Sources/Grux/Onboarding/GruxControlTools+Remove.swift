import Foundation
import GruxMCPCore
import GruxShellCore

// MARK: - grux_remove

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// One thing Grux is tracking, in the shape the CLI draws it in.
    ///
    /// `tracked` is false for something Grux KNOWS ABOUT and is already not tracking, which
    /// only features can be today. It is a third answer, and it exists because "Meetings is
    /// already off" and "there is nothing called Meetings" want opposite replies: the first
    /// changed nothing and is fine, the second is a typo to correct.
    private struct RemovalRow {
        /// What you type, and what comes back as the canonical name.
        let id: String
        /// What you read.
        let label: String
        /// The machine column, dimmed by the caller.
        let detail: String
        /// A second thing you may type, when the id is not unique on its own. Empty when
        /// there is nothing else to offer.
        let alias: String
        let tracked: Bool

        var json: [String: Any] {
            ["id": id, "label": label, "detail": detail, "alias": alias, "tracked": tracked]
        }
    }

    /// The nouns, in the order `docs/cli-grammar.md` lists them under "Nouns for add and
    /// remove". Mirrored from that table rather than from the `grux add` handler, so the two
    /// commands agree with the specification instead of with each other's typos.
    static let removalNouns = ["feature", "project", "brand", "mailbox",
                               "repo", "domain", "schedule", "skill"]

    /// Stop tracking one thing. Never delete the thing.
    ///
    /// ## The promise, and the one place it is enforced rather than described
    ///
    /// "Remove" reads as "delete" to everybody, so every reply here says both halves: what
    /// stopped happening, and what was left alone. A removal that WOULD destroy the only
    /// copy of something a person wrote is refused outright rather than confirmed, which is
    /// why `skill` is a noun you can list and cannot remove: the only removal Grux has for a
    /// skill deletes the folder holding its SKILL.md, and that text exists nowhere else.
    ///
    /// The line is not "does this write to disk". It is whether Grux would take away the
    /// only copy. A mailbox loses its cached messages and its stored password, and both are
    /// copies: the mail is on the server, and a password is retyped. A skill folder is not.
    static func remove(noun: String?, value: String?) -> [String: Any] {
        let wanted = removalNoun(noun)
        let target = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !wanted.isEmpty else {
            return MCPWire.textResult(jsonText(removalIndex()))
        }
        guard removalNouns.contains(wanted) else {
            let typed = (noun ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return MCPWire.textFailure("No noun called \(typed). Grux removes "
                + removalSentence(removalNouns) + ", and removing one stops it being tracked "
                + "rather than deleting it.")
        }
        // THE ONE REFUSAL, and it applies with or without a value so that neither shape of
        // the call implies the other one would have worked.
        if wanted == "skill" { return MCPWire.textFailure(removalSkillRefusal(target)) }

        let rows = removalRows(for: wanted)

        guard !target.isEmpty else {
            return MCPWire.textResult(jsonText([
                "noun": wanted,
                "stops": removalStops(wanted),
                "keeps": removalKeeps(wanted),
                "items": rows.map(\.json),
            ]))
        }

        let hits = rows.filter { removalMatches(target, $0) }
        guard !hits.isEmpty else {
            return MCPWire.textFailure("Grux is not tracking a \(wanted) called \(target). "
                + "Call grux_remove with the noun and no value to see what it is tracking.")
        }
        // A THING ALREADY GONE CANNOT MAKE A LIVE ONE AMBIGUOUS. The memory introduced this:
        // remembered rows keep their label, so `grux remove mailbox Work` against a single
        // live mailbox called Work started refusing as ambiguous once a DIFFERENT mailbox
        // that had also been called Work was remembered. There is nothing to choose between:
        // one of them is tracked and the other is a note that it used to be.
        let tracked = hits.filter(\.tracked)
        let candidates = tracked.isEmpty ? hits : tracked
        guard candidates.count == 1, let row = candidates.first else {
            // NEVER GUESS BETWEEN TWO. Removing the wrong one of a matched pair is the exact
            // mistake a typed confirmation cannot catch, because the word typed is right.
            return MCPWire.textFailure("More than one \(wanted) answers to \(target). Name "
                + "one of these instead: "
                + removalSentence(candidates.map { $0.alias.isEmpty ? $0.id : $0.alias })
                + ".")
        }
        guard row.tracked else {
            // IDEMPOTENT ON PURPOSE. An agent runs a command twice, and the second run must
            // report what is already true rather than fail at it.
            return MCPWire.textResult(jsonText([
                "noun": wanted, "value": target, "id": row.id, "label": row.label,
                "changed": false,
                "stopped": [String](),
                "kept": ["\(row.label) was already not tracked, so nothing changed."],
            ]))
        }
        return removalPerform(noun: wanted, row: row)
    }

    // MARK: - The nouns

    /// Singular and plural both work. Somebody who just read `2 projects` types `projects`.
    ///
    /// MATCHED AGAINST THE PLURAL THE SCREENS PRINT, never against a trailing "s". Dropping
    /// one "s" turned `mailboxes` into `mailboxe`, which is not a noun, so the one plural
    /// the CLI writes with an "es" was the one plural this refused. `grux remove mailbox`
    /// prints "What Grux is tracking as mailboxes" and "1 mailbox", and typing back the word
    /// on the screen came back "No noun called mailboxes", exit 1. The rule below is the
    /// CLI's `Remove.plural` rule, so what is printed and what is accepted cannot drift.
    private static func removalNoun(_ raw: String?) -> String {
        let n = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if removalNouns.contains(n) { return n }
        if let singular = removalNouns.first(where: { removalPlural($0) == n }) {
            return singular
        }
        return n
    }

    /// The plural of a noun, by the rule the CLI prints one with: x, s and ch take "es".
    private static func removalPlural(_ noun: String) -> String {
        if noun.hasSuffix("x") || noun.hasSuffix("s") || noun.hasSuffix("ch") {
            return noun + "es"
        }
        return noun + "s"
    }

    private static func removalIndex() -> [String: Any] {
        let nouns = removalNouns.map { n -> [String: Any] in
            [
                "noun": n,
                "bundles": removalBundles(n),
                "stops": removalStops(n),
                "keeps": removalKeeps(n),
                "tracked": removalRows(for: n).filter(\.tracked).count,
                "removable": n != "skill",
            ]
        }
        return [
            "nouns": nouns,
            "promise": "Removing stops Grux tracking something. It never deletes the thing "
                     + "itself.",
        ]
    }

    private static func removalBundles(_ noun: String) -> String {
        switch noun {
        case "feature":  return "One feature, of the \(FeatureRegistry.rows.count) in the "
                              + "registry."
        case "project":  return "A code root Grux watches and may build."
        case "brand":    return "One rule from your brand attribution ledger."
        case "mailbox":  return "One mail account Grux syncs."
        case "repo":     return "One entry in the repository list."
        case "domain":   return "One host in the list of sites to monitor."
        case "schedule": return "One recurring job."
        case "skill":    return "A folder of instructions the agent may load."
        default:         return ""
        }
    }

    /// What stops happening. Written as the promise for the NOUN, so a person reads it
    /// before they confirm; the specific, measured version comes back after the removal.
    ///
    /// TRUE FOR EVERY ITEM UNDER THE NOUN, because the CLI's LOOK call sends the noun and
    /// never the value, so nothing here can know which project or which account it is about.
    /// A sentence that is only true for the usual one is a promise this screen cannot keep:
    /// the project half claimed the folder stops being watched when the folder may not be on
    /// the allowed list at all, and the mailbox half claimed a keychain password is
    /// forgotten when `grux add mailbox` cannot store one. This is the screen somebody reads
    /// while deciding, so it names what MAY go and the reply after the removal names what
    /// did.
    ///
    /// The project sentence says what `ProjectRegistryStore.remove` does and stops there. It
    /// briefly went on to promise "nothing here builds, runs or ships it", which measures
    /// false for a scaffolded project: `ProjectRegistry.canShipEndToEnd` backfills the
    /// registry from the marker at ~/Projects/<name>/.grux/project.json and returns true
    /// again, which is the very thing the `note` under the result warns about. One screen
    /// cannot say a project can never ship and then say it ships itself back.
    private static func removalStops(_ noun: String) -> [String] {
        switch noun {
        case "feature":
            return ["Grux stops counting that feature when it works out what it needs."]
        case "project":
            return ["The project registry stops naming it, so it drops out of the ship "
                    + "workflow.",
                    "Grux stops watching the folder as well, if that folder is on the "
                    + "allowed list on its own rather than sitting inside a wider one. The "
                    + "reply after the removal says which of those it was."]
        case "brand":
            return ["Time spent there stops being attributed to that brand."]
        case "mailbox":
            return ["Grux stops syncing that account, drops any cached copy of its messages, "
                    + "and forgets any password it kept for it."]
        case "repo":
            return ["The repository list stops naming it."]
        case "domain":
            return ["The list of sites to monitor stops naming it."]
        case "schedule":
            return ["It stops running. Nothing fires on that schedule again."]
        case "skill":
            return ["Nothing. Grux will not remove a skill from here."]
        default:
            return []
        }
    }

    /// What is left alone. Every noun has this half and it is never empty, because the whole
    /// safety story of this command is the difference between the two lists.
    private static func removalKeeps(_ noun: String) -> [String] {
        switch noun {
        case "feature":
            return ["The feature stays listed, and it can be turned back on.",
                    "Every permission you already granted. Turning a feature off never "
                    + "revokes one.",
                    "Anything it already wrote."]
        case "project":
            return ["The folder, everything in it, and its git history."]
        case "brand":
            return ["Every daily report already written, exactly as it is.",
                    "The repositories, apps and sites those rules pointed at."]
        case "mailbox":
            return ["Your mail. Every message is on your mail server, where Grux only ever "
                    + "read it."]
        case "repo":
            return ["The clone on disk, its branches and its remotes.",
                    "Every other entry. Grux writes the list back without this one rather "
                    + "than clearing it."]
        case "domain":
            return ["The domain, its DNS and its registration.",
                    "Every other entry. Grux writes the list back without this one rather "
                    + "than clearing it."]
        case "schedule":
            return ["Everything it already produced."]
        case "skill":
            return ["Everything, which is the problem: the only removal Grux has would "
                    + "delete the folder holding the SKILL.md you wrote."]
        default:
            return []
        }
    }

    private static func removalSentence(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: - What is tracked right now

    /// What is here, plus what this command has already taken off this Mac.
    ///
    /// THE SECOND HALF IS WHAT MAKES THE COMMAND IDEMPOTENT FOR MORE THAN ONE NOUN. A
    /// feature gets that for free: `FeatureRegistry.rows` still holds a row for a feature
    /// that is off, so a second `grux remove feature meetings` finds it marked untracked,
    /// reports what is already true and leaves with 0. The six store backed nouns had no
    /// such row. The entry was gone from the store, so `hits` came back empty and the second
    /// run of a byte identical command answered "Grux is not tracking domain example.com"
    /// and left with 1, which the exit code table in `docs/cli-grammar.md` reads as a
    /// failure an agent must report and not retry: a teardown script that reruns its own
    /// step aborted on a world already exactly as it had asked for. The remembered ids are
    /// the only thing that tells that apart from a misspelling, which still misses every row
    /// and still earns its did you mean.
    private static func removalRows(for noun: String) -> [RemovalRow] {
        let live = removalLiveRows(for: noun)
        return live + removalRemembered(noun, beside: live)
    }

    private static func removalLiveRows(for noun: String) -> [RemovalRow] {
        switch noun {
        case "feature":
            // EVERY row, not just the chosen ones. An off feature has to come back as a row
            // marked untracked, or `grux remove feature meetings` run twice cannot tell the
            // second run apart from a misspelling.
            return FeatureRegistry.rows.map {
                RemovalRow(id: $0.id, label: $0.label, detail: $0.id, alias: "",
                           tracked: FeatureSelection.isOn($0.id))
            }
        case "project":
            return ProjectRegistryStore.load().entries.map {
                RemovalRow(id: $0.name,
                           label: $0.displayName.isEmpty ? $0.name : $0.displayName,
                           detail: $0.root, alias: "", tracked: true)
            }
        case "brand":
            return BrandAttribution.loadConfig().brands.map { rule in
                let patterns = rule.bundleIds.count + rule.appNames.count
                    + rule.titleSubstrings.count + rule.urlDomains.count
                    + rule.urlSubstrings.count + rule.repoPaths.count
                return RemovalRow(id: rule.name, label: rule.name,
                                  detail: "\(patterns) pattern\(patterns == 1 ? "" : "s")",
                                  alias: "", tracked: true)
            }
        case "mailbox":
            return EmailAccountStore.shared.accounts.map {
                RemovalRow(id: $0.emailAddress,
                           label: $0.displayName.isEmpty ? $0.emailAddress : $0.displayName,
                           detail: $0.enabled ? $0.imapHost : "\($0.imapHost), paused",
                           alias: "", tracked: true)
            }
        case "repo":
            return removalList("grux.github.repos").map {
                RemovalRow(id: $0, label: $0, detail: "", alias: "", tracked: true)
            }
        case "domain":
            return removalList("grux.uptime.targets").map {
                RemovalRow(id: $0, label: $0, detail: "", alias: "", tracked: true)
            }
        case "schedule":
            // THE TITLE IS WHAT A PERSON TYPES AND IT IS NOT UNIQUE. Two jobs may share one,
            // so the uuid rides along as an alias and the ambiguous case refuses rather than
            // picking the first match.
            return UserCronStore.shared.jobs.map { job in
                // A job with no title is reachable (nothing rejects one) and would otherwise
                // list as a blank row nobody can name, so it falls back to the id it is
                // always addressable by.
                let name = job.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = name.isEmpty ? job.id.uuidString : name
                return RemovalRow(id: shown, label: shown,
                                  detail: job.enabled ? job.scheduleSummary
                                                      : "\(job.scheduleSummary), paused",
                                  alias: job.id.uuidString, tracked: true)
            }
        case "skill":
            return SkillStore.shared.skills.map {
                RemovalRow(id: $0.name, label: $0.name, detail: "", alias: "", tracked: true)
            }
        default:
            return []
        }
    }

    /// A list valued config key, always as strings and never as nil.
    static func removalList(_ key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func removalMemoryKey(_ noun: String) -> String {
        "grux.remove.removed.\(noun)"
    }

    /// The last few ids this command took off, newest last.
    ///
    /// CAPPED, because a list that only ever grows is a leak with a friendly name, and the
    /// question it answers ("did I already remove this") is only ever asked about a removal
    /// somebody still remembers making.
    /// What makes a removed thing THAT removed thing.
    ///
    /// `id` is what you type and it is NOT unique: a schedule's id is its title, and two
    /// jobs can share one. `alias` is the uuid, which is why the ambiguity refusal offers it.
    /// So identity is the alias when there is one and the id otherwise, and everything that
    /// remembers or matches a removal keys on this rather than on `id`.
    ///
    /// Keying on `id` produced the failure twice over. Removing two schedules both titled
    /// "Daily backup" made the second removal EVICT the first from memory, because the
    /// dedupe saw the same id, and the first uuid became unrecoverable. And a live sibling
    /// sharing the title masked a remembered row, because the collision filter compared
    /// titles. Two things can be called the same thing; only one can have the same uuid.
    /// Internal rather than private so a test can drive it. The two ways this was keyed
    /// wrong both passed every existing test, because nothing could reach the decision.
    static func removalIdentity(id: String, alias: String) -> String {
        (alias.isEmpty ? id : alias).lowercased()
    }

    /// How many removals are remembered per noun.
    ///
    /// 16 was too few for the thing this exists for. A teardown script that removes twenty
    /// domains and is re-run from the top found its first four evicted and exited 1 on them,
    /// which is the orchestration case the whole memory is meant to serve. These are short
    /// strings in a defaults array and 200 of them is nothing; the cap is only here so a
    /// machine that adds and removes forever does not grow an unbounded key.
    static let removalMemoryLimit = 200

    /// BOTH NAMES IN ONE ENTRY, never two entries. A mailbox is listed by its display name
    /// and removed by its address, and somebody who ran the removal by the name on screen
    /// runs it again by the name on screen. Two remembered rows for one removal would answer
    /// the rerun with the "more than one answers to that" refusal, which would be this
    /// convenience breaking the command it was added to soften. U+001F is the ASCII unit
    /// separator, so no title, address or path a person types can collide with it.
    private static let removalMemorySeparator = "\u{1F}"

    /// - Parameter alias: the OTHER name this thing answered to, and the reason a rerun
    ///   used to fail. A schedule is removed by its uuid while its label is its title, and
    ///   the memory stored only (id, label), so the uuid was dropped and `removalMatches`
    ///   could never find the remembered row again. `grux remove schedule <uuid>` exited 0
    ///   and then exited 1 on the byte identical rerun, which is the idempotence rule the
    ///   whole memory exists to keep.
    static func removalRemember(noun: String, id: String, label: String,
                                        alias: String) {
        let key = removalMemoryKey(noun)
        var entry = label.isEmpty || label.lowercased() == id.lowercased()
            ? id
            : id + removalMemorySeparator + label
        if !alias.isEmpty, alias.lowercased() != id.lowercased(),
           alias.lowercased() != label.lowercased() {
            // Three fields now. A two field entry from an older build still reads correctly
            // because the alias is simply absent, which is what it was before.
            if !entry.contains(removalMemorySeparator) {
                entry += removalMemorySeparator + id
            }
            entry += removalMemorySeparator + alias
        }
        // Case insensitively, the way every other list in this pair of handlers matches, so
        // one thing removed, added back and removed again is one entry rather than two.
        let mine = removalIdentity(id: id, alias: alias)
        var entries = removalList(key).filter {
            let p = removalMemoryParts($0)
            return removalIdentity(id: p.id, alias: p.alias) != mine
        }
        entries.append(entry)
        UserDefaults.standard.set(Array(entries.suffix(removalMemoryLimit)), forKey: key)
    }

    static func removalMemoryParts(_ entry: String)
        -> (id: String, label: String, alias: String) {
        let parts = entry.components(separatedBy: removalMemorySeparator)
        let id = parts.first ?? entry
        return (id,
                parts.count > 1 ? parts[1] : id,
                parts.count > 2 ? parts[2] : "")
    }

    /// The remembered removals that are not tracked again, as untracked rows.
    ///
    /// BESIDE THE LIVE ROWS, NEVER OVER THEM. Removing a domain and adding it back leaves
    /// the name in both lists, and the live row is the one that is true.
    private static func removalRemembered(_ noun: String,
                                          beside live: [RemovalRow]) -> [RemovalRow] {
        // MATCHED ON IDENTITY, NOT ON LABEL AND NOT ON ID. Comparing ids dropped a
        // remembered row whenever a live row merely SHARED ITS TITLE, because a schedule's
        // id IS its title: removing one of two jobs called "Daily backup" erased the memory
        // of the one that went, and the rerun said it was never tracked.
        let taken = Set(live.map { removalIdentity(id: $0.id, alias: $0.alias) })
        return removalList(removalMemoryKey(noun))
            .map { removalMemoryParts($0) }
            .filter { !taken.contains(removalIdentity(id: $0.id, alias: $0.alias)) }
            .map { RemovalRow(id: $0.id, label: $0.label, detail: "removed earlier",
                              alias: $0.alias, tracked: false) }
    }

    private static func removalMatches(_ typed: String, _ row: RemovalRow) -> Bool {
        let t = typed.lowercased()
        if row.id.lowercased() == t || row.label.lowercased() == t { return true }
        return !row.alias.isEmpty && row.alias.lowercased() == t
    }

    // MARK: - The removals

    private static func removalPerform(noun: String, row: RemovalRow) -> [String: Any] {
        var stopped: [String] = []
        var kept: [String] = []
        var note = ""
        var restore = ""

        switch noun {
        case "feature":
            guard let f = FeatureRegistry.rows.first(where: { $0.id == row.id }) else {
                return MCPWire.textFailure("No feature with id \(row.id).")
            }
            // WHAT NOBODY ELSE ASKED FOR. A capability wanted only by this feature drops off
            // what Grux says it needs the moment the feature is off, and naming those is the
            // difference between "one row changed" and knowing what changed underneath it.
            let mine = removalDeclared(f)
            let others = FeatureRegistry.rows
                .filter { $0.id != f.id && FeatureSelection.isOn($0.id) }
                .reduce(into: Set<String>()) { $0.formUnion(removalDeclared($1)) }
            let orphaned = mine.subtracting(others)
            FeatureSelection.disable(f.id)

            stopped.append("Grux stops counting \(f.label) when it works out what it needs.")
            if !orphaned.isEmpty {
                let labels = orphaned.compactMap { SetupRequirement(rawValue: $0)?.label }
                    .sorted { $0.lowercased() < $1.lowercased() }
                stopped.append("It stops asking for \(removalSentence(labels)), because "
                    + "nothing else you chose uses \(labels.count == 1 ? "it" : "them").")
            }
            let dependents = FeatureRegistry.rows
                .filter { $0.dependsOn.contains(f.id) && FeatureSelection.isOn($0.id) }
                .map(\.label)
            if !dependents.isEmpty {
                // WARN, NEVER SILENTLY FIX. `FeatureSelection.unmetDependencies` exists for
                // exactly this: a selection that cannot do what was asked is allowed to be
                // expressed while somebody thinks about it.
                stopped.append("\(removalSentence(dependents)) "
                    + "\(dependents.count == 1 ? "is" : "are") still on and needs \(f.label), "
                    + "so \(dependents.count == 1 ? "it" : "they") will say so rather than "
                    + "work.")
            }
            kept = ["Every permission you already granted stays granted. Turning a feature "
                    + "off never revokes one.",
                    "\(f.label) stays listed, and grux add feature \(f.id) turns it back on.",
                    "Anything \(f.label) already wrote is where it was."]

        case "project":
            // THE INVERSE OF `add project`, ALL THREE OF IT. `add` writes the registry, the
            // folder Grux may work in, and the spoken name. This removed the registry entry
            // and then said "Grux stops watching <root>", which was false for the other two:
            // the shell sandbox still allowed that folder and the spoken name still resolved
            // to it. Two sentences on one screen contradicted each other, since the next
            // line said Grux "removed a registry entry and nothing else".
            //
            // An inverse that is not an inverse is worse than no inverse, because the person
            // reading it believes the folder is out.
            let entry = ProjectRegistryStore.load().entries
                .first { $0.name.lowercased() == row.id.lowercased() }
            let root = entry?.root ?? row.detail
            ProjectRegistryStore.remove(name: row.id)
            // SAME SENTENCE AS THE COST SCREEN, and it stops where the registry write stops.
            // The `note` below is the only thing that may say a project comes back, and it
            // says so per project, having looked for the marker.
            stopped = ["The project registry stops naming it, so it drops out of the ship "
                       + "workflow."]
            kept = ["The folder at \(root), everything in it, and its git history. Nothing "
                    + "on disk was touched."]

            // THE ALLOWLIST, and ONLY AN EXACT MATCH. `add` skips the write when a broader
            // root already covers the path, so removing whatever covers this one would
            // silently withdraw every OTHER project underneath it. An exact entry is the
            // one this project put there; anything wider belongs to somebody else.
            let key = ShellAllowlist.watchedRootDefaultsKey
            let standardized = ShellAllowlist.standardize(root)
            let roots = addConfigList(key: key)
            let mine = roots.filter { ShellAllowlist.standardize($0) == standardized }
            if !mine.isEmpty {
                UserDefaults.standard.set(
                    roots.filter { ShellAllowlist.standardize($0) != standardized }, forKey: key)
            }
            // READ THE LIST BACK AFTER THE WRITE, and never as the `else` of it. The two
            // cases are not exclusive: `grux add project ~/Code/secret` appends that path,
            // and a later `grux add project ~/Code` appends ~/Code too, because add asks
            // whether the new path is INSIDE an existing root, not whether it contains one.
            // Removing secret then dropped its own exact entry and reported "Grux stops
            // watching ~/Code/secret, so grux shell refuses to run anything in it" while
            // ~/Code was still on the list, so `ShellSession.start` still allowed a session
            // rooted there. The sentence about what a person can still reach has to be
            // measured against the list as it now is.
            let covering = ShellAllowlist.allowedRoots().first {
                standardized == $0 || standardized.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
            }
            if let covering {
                if !mine.isEmpty {
                    // BOTH HALVES OF ONE FACT. The entry did come off, and the folder is
                    // still reachable through a wider root, so the removal goes under what
                    // stopped and the reach goes under what was left alone. Printing either
                    // half alone is what made this screen read as the opposite of the truth.
                    stopped.append("The allowed list stops naming \(root) on its own.")
                }
                // SAY SO. A folder that stays reachable through a wider root is the case
                // somebody most needs told about, and it is exactly what "stops watching"
                // used to hide.
                kept.append("Grux may still work in \(root), because \(addTilde(covering)) "
                            + "is on the allowed list and covers it. Remove that with grux "
                            + "config if you want the folder out.")
            } else if !mine.isEmpty {
                stopped.append("Grux stops watching \(root), so grux shell refuses to run "
                               + "anything in it.")
            } else {
                // THE THIRD STATE, and it is the common one. A project registered by the
                // scaffold marker rather than by `grux add project` was never on the allowed
                // list, so nothing about the shell changed and saying nothing at all here
                // would leave the noun's promise on the cost screen unanswered.
                kept.append("The allowed list, which never named \(root): grux shell already "
                            + "refused to run there and still does.")
            }

            // The spoken name, and only when it still points here. A name repointed at
            // another folder belongs to that folder now.
            // SAME READER AS `add`, so the same file cannot be read two ways. A `?? [:]`
            // here would drop every other alias on the way to removing one.
            let aliasURL = ProjectsResolver.aliasesURL
            var aliases = addAliases() ?? [:]
            let aliasesReadable = addAliases() != nil
            let aliasKey = row.id.lowercased()
            if !aliasesReadable {
                kept.append("The name \(row.id) still resolves to that folder: "
                            + "\(addTilde(aliasURL.path)) will not parse, and rewriting it "
                            + "would drop every other name in it.")
            } else if let was = aliases[aliasKey],
               ShellAllowlist.standardize(NSString(string: was).expandingTildeInPath)
                   == standardized {
                aliases.removeValue(forKey: aliasKey)
                if let data = try? JSONSerialization.data(withJSONObject: aliases,
                                                          options: [.prettyPrinted, .sortedKeys]),
                   (try? data.write(to: aliasURL, options: .atomic)) != nil {
                    stopped.append("The name \(row.id) stops resolving to that folder.")
                } else {
                    kept.append("The name \(row.id) still resolves to that folder: "
                                + "project-aliases.json would not write.")
                }
            }
            // THE ONE WAY IT COMES BACK, and it is silent. `canShipEndToEnd` backfills the
            // registry from a scaffold marker at ~/Projects/<name>, so a project that was
            // scaffolded there re-registers itself the next time anything ships it by name.
            // Saying the removal is final would be false for exactly those projects.
            let candidate = ProjectRegistryStore.defaultRoot(forName: row.id)
            if let marker = LocalProjectMarker.read(projectDir: candidate),
               marker.projectName.lowercased() == row.id.lowercased() {
                note = "The scaffold marker at \(LocalProjectMarker.path(for: candidate)) "
                     + "stays, because it is inside your own folder. Grux registers this "
                     + "project again by itself the next time something ships it by name."
            }

        case "brand":
            var cfg = BrandAttribution.loadConfig()
            guard let rule = cfg.brands.first(where: {
                $0.name.lowercased() == row.id.lowercased()
            }) else {
                return MCPWire.textFailure("No brand called \(row.id) in "
                    + "\(BrandAttribution.configURL.path).")
            }
            cfg.brands.removeAll { $0.name.lowercased() == row.id.lowercased() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(cfg) else {
                return MCPWire.textFailure("Could not rewrite "
                    + "\(BrandAttribution.configURL.path), so nothing was removed.")
            }
            do {
                try data.write(to: BrandAttribution.configURL, options: .atomic)
            } catch {
                return MCPWire.textFailure("Could not write "
                    + "\(BrandAttribution.configURL.path), so nothing was removed. "
                    + "\(error.localizedDescription)")
            }
            stopped = ["Time spent on \(rule.name) stops being attributed to it. From the "
                       + "next report on it lands in unattributed instead."]
            if UserDefaults.standard.string(forKey: currentBrandKey)?.lowercased()
                == rule.name.lowercased() {
                UserDefaults.standard.removeObject(forKey: currentBrandKey)
                stopped.append("It was the brand commands were about, so no brand is "
                               + "selected now.")
            }
            kept = ["Every daily report already in \(BrandAttribution.outputDir.path), "
                    + "exactly as it is.",
                    "The repositories, apps and sites those rules pointed at. Grux only "
                    + "stopped recognising them."]
            // THE RULE ITSELF IS THE ONE COPY. Nothing else on this Mac holds these
            // patterns, so they come back in the reply rather than going quietly.
            restore = removalBrandPatterns(rule)

        case "mailbox":
            guard let account = EmailAccountStore.shared.accounts.first(where: {
                $0.emailAddress.lowercased() == row.id.lowercased()
            }) else {
                return MCPWire.textFailure("No mail account called \(row.id).")
            }
            let cached = MailStore.shared.messages(for: account.id).count
            // BOTH, AND IN THIS ORDER. The Mailbox window shows every cached message when no
            // account is selected, so dropping the account and keeping its messages would
            // leave mail on screen from an account Grux had stopped reading.
            // READ BEFORE THE REMOVAL. Once the account is out of the store there is
            // nothing left to look the password up by.
            let hadPassword = !EmailAccountStore.shared.password(for: account).isEmpty
            MailStore.shared.remove(accountId: account.id)
            MailStore.shared.saveNow()
            EmailAccountStore.shared.remove(account.id)
            // SAVED NOW rather than on the 0.3 second debounce both stores use. A command
            // returns and a person quits the app; a removal that had not reached disk would
            // be back on the next launch.
            EmailAccountStore.shared.saveNow()
            SetupStatusFile.write()

            stopped = ["Grux stops syncing \(account.emailAddress). Nothing here opens that "
                       + "mailbox again."]
            stopped.append(cached == 0
                ? "Grux had nothing cached from it."
                : "The \(cached) message\(cached == 1 ? "" : "s") Grux had cached "
                  + "\(cached == 1 ? "is" : "are") dropped from its own copy.")
            // TRUE OR NOT SAID. This was unconditional, so an account added by `grux add
            // mailbox` and never opened in the Mailbox window, which is the only place a
            // password can be entered, was told a password had been forgotten that was never
            // there. On a screen whose whole job is naming what was destroyed, an invented
            // loss is the worst possible line.
            stopped.append(hadPassword
                ? "The password it kept in your login keychain is forgotten."
                : "There was no password in your login keychain to forget. Nothing ever "
                  + "entered one for this account.")
            kept = ["Your mail. Every message is on \(account.imapHost), where Grux only "
                    + "ever read it, and none of it was touched."]
            // KEYED ON THE ENABLED ONES, because that is what `endpoint.imap` is satisfied
            // by. "Your last account" would be false with a paused one still configured, and
            // this sentence is true either way.
            if EmailAccountStore.shared.enabledAccounts.isEmpty {
                note = "Grux now has no mail account switched on, so Mailbox, the briefing "
                     + "and email triage go back to needing setup."
            }

        case "repo", "domain":
            let key = noun == "repo" ? "grux.github.repos" : "grux.uptime.targets"
            var entries = removalList(key)
            entries.removeAll { $0.lowercased() == row.id.lowercased() }
            // WRITE THE REST BACK, NEVER CLEAR THE KEY. An empty array and a missing key
            // read the same to the resolver, but clearing would throw away every other
            // entry, which is the removal nobody asked for.
            UserDefaults.standard.set(entries, forKey: key)
            SetupStatusFile.write()

            let left = entries.count
            let listName = noun == "repo" ? "The repository list"
                                          : "The list of sites to monitor"
            let remainder = left == 0
                ? "That was the last entry, so the list is empty and reads as not set again."
                : "\(left) entr\(left == 1 ? "y" : "ies") left."
            stopped = ["\(listName) stops naming \(row.id). " + remainder]
            kept = noun == "repo"
                ? ["The clone on disk, its branches and its remotes. Grux only ever held "
                   + "the name."]
                : ["The domain, its DNS and its registration. Grux only ever held the name."]
            note = noun == "repo"
                ? "Nothing else reads this list yet: there is no GitHub call in the app at "
                + "all, and the pull request digest reads a digest host rather than this. "
                + "So no watcher stopped, and grux status is what changed."
                : "The registrar sweep reads every domain on your account rather than this "
                + "list, so it still reports on \(row.id) until you remove it at your "
                + "registrar. What changed is what grux status reads."

        case "schedule":
            guard let job = UserCronStore.shared.jobs.first(where: {
                $0.id.uuidString == row.alias
            }) else {
                return MCPWire.textFailure("No schedule called \(row.id).")
            }
            let due = job.nextFire()
            UserCronStore.shared.delete(id: job.id)
            let when = due.map { removalStamp($0) }
            stopped = ["\(job.title) stops running. "
                       + (when.map { "It was next due \($0)." }
                          ?? "It was paused, so nothing was due.")]
            // The scheduler reads the store on a 30 second tick rather than holding a timer
            // per job, so there is nothing to cancel and no window where a deleted job can
            // still fire.
            stopped.append("The scheduler reads the list again within thirty seconds.")
            kept = ["Everything it already produced."]
            switch job.action {
            case .runCommand(let definitionId):
                kept.append("The workflow \(definitionId) itself, which you can still start "
                            + "by hand.")
            case .agentPrompt(let prompt):
                // THE PROMPT IS THE ONE COPY. Nothing else stores it, so it comes back here
                // rather than being thrown away by a command that promises not to.
                kept.append("The prompt it ran comes back below, so removing the schedule "
                            + "does not lose the words.")
                restore = prompt
            }

        default:
            return MCPWire.textFailure("No noun called \(noun).")
        }

        // WRITTEN ONLY WHERE THE REMOVAL GOT THIS FAR, since every refusal above returns
        // rather than falling through, and remembering a removal that did not happen would
        // answer the next run with "already not tracked" about a thing still tracked.
        // `feature` needs none of it: its registry row survives and comes back untracked on
        // its own, which is the behaviour the other nouns are borrowing.
        if noun != "feature" {
            removalRemember(noun: noun, id: row.id, label: row.label, alias: row.alias)
        }

        var reply: [String: Any] = [
            "noun": noun,
            "id": row.id,
            "label": row.label,
            "changed": true,
            "stopped": stopped,
            "kept": kept,
        ]
        if !note.isEmpty { reply["note"] = note }
        if !restore.isEmpty { reply["restore"] = restore }
        return MCPWire.textResult(jsonText(reply))
    }

    /// Every capability id a feature declares, blocking or not, including the members of its
    /// any-of groups. The question is "would Grux still have a reason to ask", and an
    /// optional capability is still a reason.
    private static func removalDeclared(_ row: FeatureRow) -> Set<String> {
        var ids = Set<String>()
        for r in row.requires + row.optional + row.steps + row.optionalSteps {
            ids.insert(r.rawValue)
        }
        for group in row.anyOf {
            for r in group.capabilities { ids.insert(r.rawValue) }
        }
        return ids
    }

    private static func removalBrandPatterns(_ rule: BrandAttribution.BrandRule) -> String {
        var parts: [String] = []
        func add(_ name: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            parts.append("\(name): " + values.joined(separator: ", "))
        }
        add("bundle ids", rule.bundleIds)
        add("app names", rule.appNames)
        add("window titles", rule.titleSubstrings)
        add("domains", rule.urlDomains)
        add("url fragments", rule.urlSubstrings)
        add("repo paths", rule.repoPaths)
        return parts.isEmpty ? "no patterns" : parts.joined(separator: " | ")
    }

    private static func removalStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM, h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f.string(from: date)
    }

    // MARK: - The refusal

    /// Why a skill is the one noun this command will not remove.
    ///
    /// `SkillStore.remove` deletes the SKILL.md folder through `SkillFolderBackend
    /// .removeFolder`, and it has to: leaving the folder behind would let `importFolders`
    /// resurrect the skill on the next launch, so the two are one operation by design. That
    /// makes removing a skill a deletion of the only copy of something a person wrote, which
    /// is the one thing this command promises never to do. So it says so, names the folder,
    /// and hands back a path that keeps the text.
    private static func removalSkillRefusal(_ named: String) -> String {
        let folder = Persistence.skillsDir.path
        let known = named.isEmpty ? nil : SkillStore.shared.skill(named: named)
        let subject = known.map { "\($0.name) lives" } ?? "A skill lives"
        return "Grux will not remove a skill from here. \(subject) in two places: the entry "
             + "Grux loads, and a folder under \(folder) holding the SKILL.md you wrote. The "
             + "only removal Grux has deletes both, and this command never deletes your "
             + "work. Move that folder somewhere else first if you want to keep the text, "
             + "then delete the skill in the Skills pane, which is the surface that tells "
             + "you it is deleting it."
    }
}
