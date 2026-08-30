import Foundation
import GruxMCPCore
import GruxShellCore

// MARK: - grux_add

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
///
/// ## Adding is never replacing
///
/// Every noun here lands in a list somebody else is already keeping: the watched folders,
/// the repositories, the brands, the mail accounts. So every write below READS THE LIST,
/// MERGES, AND WRITES IT BACK. A second `grux add project` that dropped the first would be
/// indistinguishable from the command working, right up until the first project stopped
/// being reachable, which is the shape of defect nobody reports because nobody sees it
/// happen.
///
/// ## Each noun says what it actually touched
///
/// `project` is three files and `brand` is two sections of one, so the reply carries a row
/// per thing changed rather than a single sentence that is true about the first of them.
/// Two of the eight nouns land somewhere NOTHING ON THIS MAC READS YET, and they say so in
/// the same breath as reporting success, because a setting that is stored and unread is a
/// different fact from a setting that is working.
extension GruxControlTools {

    /// A noun, its shape, and the honest answer to "what does adding one of these do here".
    ///
    /// `reads` is empty for the two nouns whose list nothing consumes. That was measured
    /// rather than assumed: nothing in this repository calls GitHub (`OnboardingModel`
    /// records the same finding for `key.github`), and `DomainMonitor` sweeps every domain
    /// on the GoDaddy account rather than reading `grux.uptime.targets`.
    private struct AddNoun {
        let noun: String
        /// What follows the noun on the command line, for the usage line and the prompt.
        let shape: String
        /// The designed question, asked when somebody names a noun and no value.
        let question: String
        /// The SHAPE of the answer, in a person's words. Printed under the question.
        let hint: String
        /// What adding one of these touches on this Mac.
        let bundles: String
        /// What reads it afterwards, as a fragment that follows "Read by". EMPTY means
        /// nothing does, and the CLI prints the other sentence instead.
        let reads: String
    }

    private static let addNouns: [AddNoun] = [
        AddNoun(
            noun: "brand",
            shape: "<name> <domain or folder>",
            question: "Which brand, and what should recognise it?",
            hint: "A name, then a website domain or the folder its code sits in, "
                + "like: Acme acme.com",
            bundles: "One rule in brand-attribution.json, plus the folders Grux walks "
                + "looking for repositories.",
            reads: "the daily time report and grux use."),
        AddNoun(
            noun: "domain",
            shape: "<host>",
            question: "Which hostname?",
            hint: "A hostname, like example.com. A full URL is fine and is trimmed to "
                + "its host.",
            bundles: "One entry in the grux.uptime.targets setting, which is what makes "
                + "the sites-to-monitor capability count as satisfied.",
            reads: ""),
        AddNoun(
            noun: "feature",
            shape: "<id>",
            question: "Which feature?",
            hint: "A feature id or its name, like meetings or Meetings. grux list shows "
                + "every one.",
            bundles: "One id in the feature selection, which is what makes Grux ask for "
                + "that feature's permissions.",
            reads: "every surface in the app, and grux status."),
        AddNoun(
            noun: "mailbox",
            shape: "<address> <imap-host>",
            question: "Which address, and which IMAP host?",
            hint: "The address, then its IMAP host, like: you@example.com "
                + "imap.example.com",
            bundles: "One account in the mail store. Never the password, which this "
                + "cannot take.",
            reads: "Mailbox, the briefing and email triage."),
        AddNoun(
            noun: "project",
            shape: "<path>",
            question: "Which folder?",
            hint: "A folder of code on this Mac, like ~/Code/thing.",
            bundles: "Three things: the project registry, the folders Grux may work in, "
                + "and a name you can say out loud.",
            reads: "the shell sandbox, file reads, and every command that takes a "
                + "project name."),
        AddNoun(
            noun: "repo",
            shape: "<path>",
            question: "Which git folder?",
            hint: "A folder with a .git in it, like ~/Code/thing.",
            bundles: "One entry in the grux.github.repos setting, which is what makes the "
                + "repository-list capability count as satisfied.",
            reads: ""),
        AddNoun(
            noun: "schedule",
            shape: "<when> run <workflow> | <when> ask <prompt>",
            question: "When, and what should happen then?",
            hint: "A day and a time, then run and a workflow id, or ask and a sentence: "
                + "weekdays at 9:00 AM ask draft my recap",
            bundles: "One recurring job in the schedules store.",
            reads: "Grux itself, every thirty seconds while it is open."),
        AddNoun(
            noun: "skill",
            shape: "<path>",
            question: "Which skill folder?",
            hint: "A folder holding a SKILL.md, or the SKILL.md itself.",
            bundles: "A copy of that skill in Grux's own store. The folder you named is "
                + "left alone.",
            reads: "Chat, on every turn."),
    ]

    static func add(noun: String?, value: String?) -> [String: Any] {
        let wanted = (noun ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !wanted.isEmpty else { return addListing() }

        // CASE INSENSITIVE, like every list a person reads off a screen and types back.
        guard let n = addNouns.first(where: { $0.noun == wanted.lowercased() }) else {
            return MCPWire.textFailure("There is nothing called \(wanted) to add. The nouns "
                + "are " + addSentence(addNouns.map(\.noun)) + ".")
        }

        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            // NOT A FAILURE. A noun with no value is somebody halfway through a sentence,
            // and the caller is the one that knows whether there is a person to finish it.
            let ask: [String: Any] = [
                "noun": n.noun,
                "needsValue": true,
                "question": n.question,
                "hint": n.hint,
                "shape": "grux add \(n.noun) \(n.shape)",
            ]
            return MCPWire.textResult(jsonText(ask))
        }

        switch n.noun {
        case "brand":    return addBrand(raw)
        case "domain":   return addDomain(raw)
        case "feature":  return addFeature(raw)
        case "mailbox":  return addMailbox(raw)
        case "project":  return addProject(raw)
        case "repo":     return addRepo(raw)
        case "schedule": return addSchedule(raw)
        case "skill":    return addSkill(raw)
        default:
            return MCPWire.textFailure("\(n.noun) is a noun this Grux knows the name of and "
                + "cannot add. That is a bug in Grux rather than something you did.")
        }
    }

    // MARK: - The listing

    /// Every noun, what it bundles ON THIS MAC, and how many there are already.
    ///
    /// This is the whole discoverability surface for the command, so the counts are read
    /// live rather than described. Somebody who has never run it should be able to answer
    /// "what can I tell Grux about" without opening a document.
    private static func addListing() -> [String: Any] {
        let rows: [[String: Any]] = addNouns.map { n in
            let row: [String: Any] = [
                "noun": n.noun,
                "shape": "grux add \(n.noun) \(n.shape)",
                "here": addHere(n.noun),
                "bundles": n.bundles,
                "reads": n.reads,
                "read": !n.reads.isEmpty,
            ]
            return row
        }
        let reply: [String: Any] = ["nouns": rows]
        return MCPWire.textResult(jsonText(reply))
    }

    /// What is already true for one noun, in three or four words.
    private static func addHere(_ noun: String) -> String {
        switch noun {
        case "brand":
            let n = BrandAttribution.loadConfig().brands.count
            return n == 0 ? "none yet" : "\(n) in the ledger"
        case "domain":
            let n = addConfigList(key: "grux.uptime.targets").count
            return n == 0 ? "none yet" : "\(n) listed"
        case "feature":
            let all = FeatureRegistry.rows
            return "\(all.filter { FeatureSelection.isOn($0.id) }.count) of \(all.count) on"
        case "mailbox":
            let n = EmailAccountStore.shared.accounts.count
            return n == 0 ? "none yet" : "\(n) configured"
        case "project":
            let n = ProjectRegistryStore.load().entries.count
            return n == 0 ? "none yet" : "\(n) registered"
        case "repo":
            let n = addConfigList(key: "grux.github.repos").count
            return n == 0 ? "none yet" : "\(n) listed"
        case "schedule":
            let n = UserCronStore.shared.jobs.count
            return n == 0 ? "none yet" : "\(n) recurring"
        case "skill":
            let n = SkillStore.shared.skills.count
            return n == 0 ? "none yet" : "\(n) learned"
        default:
            return ""
        }
    }

    // MARK: - feature

    private static func addFeature(_ raw: String) -> [String: Any] {
        let rows = FeatureRegistry.rows
        let lowered = raw.lowercased()
        // The LABEL as well as the id, because somebody reads "Meetings" off a screen and
        // types that. The ids are for the agent, which already has them.
        guard let row = rows.first(where: { $0.id.lowercased() == lowered })
                ?? rows.first(where: { $0.label.lowercased() == lowered }) else {
            return MCPWire.textFailure("No feature called \(raw). There are \(rows.count) of "
                + "them and grux list shows every one, on or off.")
        }

        // READ BEFORE THE WRITE, both times. Neither fact survives `enable`.
        //
        // `isOn` ANSWERS TRUE WHEN NOBODY HAS EVER CHOSEN, so it cannot stand alone as the
        // pre-existing test. On a never-asked Mac (fresh install, or straight after
        // `grux reset features`) it returns true for all 39 ids while the key
        // `grux.features.selected` does not exist at all, and `enable` on that state
        // materialises the whole registry as an explicit choice: it writes the key, flips
        // `hasChosen`, and suppresses the first run picker that `grux reset features` exists
        // to restore. Reporting that run as pre-existing put the two halves of one reply in
        // contradiction: the note said all 39 features had just been recorded as a choice
        // while `created` said false and the touched row printed "(already there)", so an
        // agent branching on `created` concluded nothing changed on the one run that
        // changed the most.
        //
        // Pre-existing therefore needs BOTH: a choice on file, and this id inside it. That
        // matches what `created` means for every other noun here, which is that the entry
        // was not there before and is now.
        let hadChosen = FeatureSelection.hasChosen
        let wasOn = hadChosen && FeatureSelection.isOn(row.id)
        FeatureSelection.enable(row.id)

        var note = ""
        if !hadChosen {
            note = "Nothing had been chosen on this Mac before, which meant everything was "
                + "on. That is now recorded as a choice: all \(rows.count) features on. Turn "
                + "the ones you do not want off with grux disable."
        }
        // WARN, NEVER SILENTLY FIX. A selection that cannot do what was asked has to stay
        // expressible while somebody thinks about it.
        let unmet = FeatureSelection.unmetDependencies().filter { $0.feature.id == row.id }
        if let first = unmet.first {
            let names = first.needs.map { dep in
                rows.first { $0.id == dep }?.label ?? dep
            }
            let sentence = "\(row.label) needs " + addSentence(names) + ", which "
                + (names.count == 1 ? "is" : "are") + " off, so it has nothing to show yet."
            note = note.isEmpty ? sentence : note + " " + sentence
        }

        let reply: [String: Any] = [
            "noun": "feature", "value": row.id, "created": !wasOn,
            "headline": wasOn ? "\(row.label) was already on." : "\(row.label) is on.",
            "touched": [addRow("Feature selection", "grux.features.selected",
                               already: wasOn)],
            "note": note,
            "verify": "grux which \(row.id)",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    // MARK: - project

    /// Three files, and the report names all three.
    ///
    /// The registry alone would leave the folder unreachable: `ShellAllowlist` is what
    /// decides where a shell session may start and what `fs_read` may open, and it is EMPTY
    /// on a fresh install by design. So a project that was registered and not allowlisted
    /// would look added and refuse every command run inside it.
    private static func addProject(_ raw: String) -> [String: Any] {
        let path = ShellAllowlist.standardize(NSString(string: raw).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return MCPWire.textFailure("There is no folder at \(addTilde(path)). A project is "
                + "a folder that already exists on this Mac, and Grux does not create one.")
        }
        guard isDirectory.boolValue else {
            return MCPWire.textFailure("\(addTilde(path)) is a file. A project is the folder "
                + "your code sits in, not one file inside it.")
        }
        let name = URL(fileURLWithPath: path).lastPathComponent

        // A NAME THAT ALREADY POINTS SOMEWHERE ELSE IS A CONFLICT, NOT AN UPDATE. Two
        // folders cannot share one spoken name, and quietly repointing it would break every
        // command that names the first one without saying anything.
        let existing = ProjectRegistryStore.find(name: name)
        if let existing, ShellAllowlist.standardize(existing.root) != path {
            return MCPWire.textFailure("Grux already has a project called \(name), at "
                + "\(addTilde(existing.root)). Two folders cannot share one name. Remove that "
                + "one first with grux remove project \(name), or rename this folder.")
        }

        // EVERY REFUSAL BEFORE EVERY WRITE, and the order is the whole point.
        //
        // This used to write the registry entry and the shell allowlist root FIRST and only
        // then look at the alias file, so `grux add project ~/elsewhere/Foo` where the name
        // Foo already pointed somewhere else returned a refusal with two writes already on
        // disk. The person reads "nothing was changed" and the folder is in the shell
        // sandbox. A partial write reported as a refusal is worse than either outcome on its
        // own, because it is the one state nobody checks for afterwards.
        //
        // So: resolve everything that can say no, then commit. Three writes, no refusals
        // between them.
        let aliasURL = ProjectsResolver.aliasesURL
        guard var aliases = addAliases() else {
            return MCPWire.textFailure("\(addTilde(aliasURL.path)) is there and will not "
                + "parse, and writing a name into it would replace every alias in it with "
                + "this one. Nothing was changed. Fix or move that file and run this again.")
        }
        let aliasKey = name.lowercased()
        let aliasWas = aliases[aliasKey].map {
            ShellAllowlist.standardize(NSString(string: $0).expandingTildeInPath)
        }
        if let aliasWas, aliasWas != path {
            return MCPWire.textFailure("The name \(name) already points at "
                + "\(addTilde(aliasWas)) in project-aliases.json. Change it there, or use a "
                + "folder with a different name, because a name that answers to two folders "
                + "answers to neither.")
        }

        // ---- past here nothing refuses -------------------------------------------------

        // `createdByGrux` DECIDES WHETHER THE SHIP WORKFLOW MAY REWRITE THE SOURCE, so it is
        // set from a marker on disk and never from the fact that somebody typed the path. An
        // agent once picked the wrong directory and started rewriting a shipping app.
        let marker = LocalProjectMarker.read(projectDir: path)
        ProjectRegistryStore.upsert(ProjectRegistryEntry(
            name: existing?.name ?? name,
            displayName: existing?.displayName ?? name,
            root: path,
            bundleId: existing?.bundleId ?? marker?.bundleId ?? "",
            createdByGrux: existing?.createdByGrux ?? (marker != nil),
            createdAt: existing?.createdAt ?? Date(),
            lastSeenAt: Date()))

        // APPEND. `allowedRoots` accepts a single string or an array, so both shapes are
        // read and an array is always what goes back.
        let defaults = UserDefaults.standard
        let key = ShellAllowlist.watchedRootDefaultsKey
        var roots = addConfigList(key: key)
        let covering = ShellAllowlist.allowedRoots().first {
            path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
        }
        if covering == nil {
            roots.append(path)
            defaults.set(roots, forKey: key)
        }

        aliases[aliasKey] = path
        var aliasOK = false
        if let data = try? JSONSerialization.data(withJSONObject: aliases,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(
                at: aliasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            aliasOK = ((try? data.write(to: aliasURL, options: .atomic)) != nil)
        }

        SetupStatusFile.write()

        var touched: [[String: Any]] = [
            addRow("Project registry", addTilde(ProjectRegistryStore.registryURL.path),
                   already: existing != nil),
        ]
        if let covering {
            touched.append(addRow("Folder Grux may work in", addTilde(covering),
                                  already: true))
        } else {
            touched.append(addRow("Folder Grux may work in", addTilde(path)))
        }
        touched.append(addRow("Spoken name", "\(aliasKey) in project-aliases.json",
                              already: aliasWas != nil, failed: !aliasOK))

        var note = marker == nil
            ? "Grux did not scaffold this one, so the ship workflow will not build or "
                + "rewrite it. Everything else works."
            : "Grux scaffolded this one, so the ship workflow may build it."
        if !aliasOK {
            note += " The alias file would not write, so the folder is watched and "
                + "registered but the name will not resolve yet."
        }

        let reply: [String: Any] = [
            "noun": "project", "value": name, "created": existing == nil,
            "headline": existing == nil
                ? "\(name) is a project Grux knows about."
                : "\(name) was already a project Grux knows about.",
            "touched": touched,
            "note": note,
            "verify": "grux config grux.sandbox.watched_root",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    // MARK: - brand

    /// A brand is a NAME PLUS SOMETHING THAT RECOGNISES IT, and a name on its own is
    /// refused.
    ///
    /// `BrandRule` matches screen time by bundle id, app name, window title, url domain,
    /// url substring or repository path. A rule carrying none of those matches nothing, so
    /// it would appear in `grux use`, contribute zero seconds to every daily report, and
    /// look exactly like a brand Grux was ignoring. Refusing costs one more word on the
    /// command line and is the difference between a ledger entry and a working one.
    private static func addBrand(_ raw: String) -> [String: Any] {
        var words = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var rules: [String] = []
        while let last = words.last, addLooksLikeBrandRule(last) {
            rules.insert(last, at: 0)
            words.removeLast()
        }
        let name = words.joined(separator: " ")
        guard !name.isEmpty else {
            return MCPWire.textFailure("A brand needs a name before its domains and folders: "
                + "grux add brand Acme acme.com")
        }
        guard !rules.isEmpty else {
            return MCPWire.textFailure("A brand needs at least one thing to recognise it by, "
                + "and \(name) has none. Give it a website domain or the folder its code sits "
                + "in: grux add brand \(name) example.com. A name on its own would sit in the "
                + "ledger matching nothing, and the time report would never show it.")
        }

        let domains = rules.filter { !$0.hasPrefix("/") && !$0.hasPrefix("~") }
        // The REPOSITORY NEEDLE IS A PATH SEGMENT, not a full path. The matcher requires the
        // needle to land on a boundary (`/needle/` or a trailing `/needle`), so storing an
        // absolute path here would never match anything.
        let folders = rules.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
            .map { ShellAllowlist.standardize(NSString(string: $0).expandingTildeInPath) }
        let needles = folders.map { URL(fileURLWithPath: $0).lastPathComponent }

        // THE SAME REFUSAL, FOR THE SAME REASON. `loadConfig` answers a failed decode with
        // the built in defaults, which is right for a READER: the app still has a brand list
        // and carries on. It is wrong for a WRITER, because this writes the whole config
        // back, so one unparseable byte turns fifteen of the operator's brands into the
        // defaults plus the one being added, and the run reports success.
        guard BrandAttribution.addConfigIsReadable() else {
            return MCPWire.textFailure("\(addTilde(BrandAttribution.configURL.path)) is "
                + "there and will not parse. Writing a brand into it would replace every "
                + "brand in it with the defaults plus this one, so nothing was changed. Fix "
                + "or move that file and run this again.")
        }
        var config = BrandAttribution.loadConfig()
        let index = config.brands.firstIndex { $0.name.lowercased() == name.lowercased() }
        var rule = index.map { config.brands[$0] } ?? BrandAttribution.BrandRule(
            name: name, bundleIds: [], appNames: [], titleSubstrings: [],
            urlDomains: [], urlSubstrings: [], repoPaths: [])

        // MERGE, NEVER REPLACE. Adding a second domain to a brand must not drop the first,
        // and this is the exact place that defect would live.
        let newDomains = domains.filter { domain in
            !rule.urlDomains.contains(where: { $0.lowercased() == domain.lowercased() })
        }
        let newNeedles = needles.filter { needle in
            !rule.repoPaths.contains(where: { $0.lowercased() == needle.lowercased() })
        }
        rule.urlDomains += newDomains
        rule.repoPaths += newNeedles

        // A REPOSITORY NEEDLE IS DEAD WITHOUT A SEARCH ROOT. `repo_search_roots` is empty on
        // a fresh install, and with none configured no directory is walked at all, so the
        // git half of the report is zero however good the needle is.
        var newRoots: [String] = []
        for folder in folders {
            let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path
            let covered = config.repoSearchRoots.contains { root in
                let expanded = ShellAllowlist.standardize(
                    NSString(string: root).expandingTildeInPath)
                return folder == expanded
                    || folder.hasPrefix(expanded.hasSuffix("/") ? expanded : expanded + "/")
            }
            if !covered, !newRoots.contains(parent) { newRoots.append(parent) }
        }
        config.repoSearchRoots += newRoots

        // NOTHING NEW MEANS NO WRITE. The file is hand editable by design, and rewriting it
        // to say what it already said would be a change with nothing behind it.
        let changed = index == nil || !newDomains.isEmpty || !newNeedles.isEmpty
            || !newRoots.isEmpty
        if changed {
            if let index { config.brands[index] = rule } else { config.brands.append(rule) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(config),
                  (try? data.write(to: BrandAttribution.configURL,
                                   options: .atomic)) != nil else {
                return MCPWire.textFailure("Could not write "
                    + "\(addTilde(BrandAttribution.configURL.path)). Nothing changed. That "
                    + "file is plain JSON and can be edited by hand.")
            }
        }

        var touched: [[String: Any]] = [
            addRow("Brand ledger", addTilde(BrandAttribution.configURL.path),
                   already: !changed),
        ]
        if !newRoots.isEmpty {
            touched.append(addRow("Folders walked for repositories",
                                  addSentence(newRoots.map(addTilde))))
        }

        var recognised: [String] = []
        if !rule.urlDomains.isEmpty {
            recognised.append("time on " + addSentence(rule.urlDomains))
        }
        if !rule.repoPaths.isEmpty {
            recognised.append("commits in " + addSentence(rule.repoPaths))
        }
        let note = "\(rule.name) is now recognised by " + addSentence(recognised)
            + ". Nothing else counts toward it yet, and another domain or folder is another "
            + "grux add brand \(rule.name) away."

        let headline: String
        if index == nil {
            headline = "\(rule.name) is in the brand ledger."
        } else if changed {
            headline = "\(rule.name) was already in the ledger and now knows about more."
        } else {
            headline = "\(rule.name) already knew about all of that."
        }

        let reply: [String: Any] = [
            "noun": "brand", "value": rule.name, "created": index == nil,
            "headline": headline,
            "touched": touched,
            "note": note,
            "verify": "grux use",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    /// A trailing word that is a rule rather than part of the name.
    ///
    /// A dot or a leading slash or tilde. Deliberately crude: the alternative is a flag, and
    /// a flag on the one command a person types while thinking about their own business is
    /// worse than a rule they can see working in the reply.
    private static func addLooksLikeBrandRule(_ token: String) -> Bool {
        if token.hasPrefix("/") || token.hasPrefix("~") { return true }
        return token.contains(".") && !token.hasSuffix(".")
    }

    // MARK: - mailbox

    /// An account, and NEVER its password.
    ///
    /// The password cannot arrive here even if somebody wanted it to: `grux connect` maps
    /// capability ids to fixed Keychain slots and mail accounts are keyed by their own
    /// UUID, so there is no slot for it to land in. It is entered in the Mailbox window,
    /// which puts it straight in the login keychain, and this says so rather than reporting
    /// a working account that cannot sync.
    private static func addMailbox(_ raw: String) -> [String: Any] {
        let parts = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let address = parts.first ?? ""
        guard address.contains("@"), !address.hasPrefix("@"), !address.hasSuffix("@") else {
            return MCPWire.textFailure("\(address.isEmpty ? raw : address) is not an email "
                + "address: grux add mailbox you@example.com imap.example.com")
        }
        guard parts.count > 1 else {
            return MCPWire.textFailure("\(address) needs its IMAP host beside it, because "
                + "nothing here can guess one: grux add mailbox \(address) "
                + "imap.example.com. Microsoft 365 is outlook.office365.com and Gmail is "
                + "imap.gmail.com.")
        }
        let host = parts[1]

        let store = EmailAccountStore.shared
        let existing = store.accounts.first {
            $0.emailAddress.lowercased() == address.lowercased()
        }
        var headline = "\(address) is an account Grux knows about."
        var already = false

        if let existing {
            if existing.imapHost.lowercased() == host.lowercased() {
                already = true
                headline = "\(address) was already an account Grux knows about."
            } else {
                // ADDING THE SAME ADDRESS AGAIN IS HOW A TYPED HOST GETS CORRECTED, and
                // saying which way it moved is the difference between a report and an echo.
                let was = existing.imapHost
                store.update(existing.id) { $0.imapHost = host }
                headline = "\(address) now syncs from \(host) instead of \(was)."
            }
        } else {
            store.upsert(EmailAccount(displayName: address,
                                      emailAddress: address,
                                      imapHost: host), password: "")
        }
        // The store debounces its save by 0.3 seconds, and this reply is a claim that
        // something is on disk, so the claim is made true before it is made.
        store.saveNow()
        SetupStatusFile.write()

        let hasPassword = existing.map { !store.password(for: $0).isEmpty } ?? false
        let note = hasPassword
            ? "That account already has a password in the login keychain, so it syncs."
            : "Nothing asked you for a password and nothing here can take one. Open Grux, "
                + "go to Mailbox, and add it there: it goes straight to the login keychain. "
                + "Until then this account is listed and will not sync."

        let touched: [[String: Any]] = [
            addRow("Mail accounts",
                   addTilde(EmailAccountStore.rootDir.path) + "/accounts.json",
                   already: already),
            // NEEDS A PERSON, not a retry. This handler cannot take a password and says so
            // in its own note: it is entered in the Mailbox window, straight into the login
            // keychain. So the account is listed, will not sync, and no `grux add` can
            // change that.
            addRow("Password", "the login keychain, entered in Grux",
                   already: hasPassword, failed: !hasPassword, needsPerson: !hasPassword),
        ]
        let reply: [String: Any] = [
            "noun": "mailbox", "value": address, "created": existing == nil,
            "headline": headline,
            "touched": touched,
            "note": note,
            "verify": "grux which endpoint.imap",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    // MARK: - repo and domain

    private static func addRepo(_ raw: String) -> [String: Any] {
        let path = ShellAllowlist.standardize(NSString(string: raw).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return MCPWire.textFailure("There is no folder at \(addTilde(path)).")
        }
        guard FileManager.default.fileExists(atPath: path + "/.git") else {
            return MCPWire.textFailure("\(addTilde(path)) has no .git in it, so it is a "
                + "folder rather than a repository. Name the folder your repository's .git "
                + "sits in.")
        }

        let (added, list) = addAppend(key: "grux.github.repos", entry: path)
        let reply: [String: Any] = [
            "noun": "repo", "value": addTilde(path), "created": added,
            "headline": added
                ? "\(addTilde(path)) is on the repository list, which now has \(list.count)."
                : "\(addTilde(path)) was already on the repository list.",
            "touched": [addRow("Repository list", "grux.github.repos", already: !added)],
            // THE HONEST HALF. Measured across this repository: nothing calls GitHub, and
            // nothing reads this key. Reporting it as watched would be the kind of false
            // success that only surfaces weeks later when nothing has been watched.
            "note": "Nothing on this Mac reads that list yet. Grux has no GitHub feature "
                + "behind it, so this is a note to yourself that grux config can read back, "
                + "and it satisfies the repository list capability in grux status.",
            "verify": "grux config grux.github.repos",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    private static func addDomain(_ raw: String) -> [String: Any] {
        // A PASTED URL IS THE COMMON CASE. Storing "https://example.com/pricing" as a
        // hostname would be stored faithfully and be wrong.
        var host = raw
        if host.contains("://") { host = URL(string: host)?.host ?? host }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !host.isEmpty, host.contains("."), !host.contains(" ") else {
            return MCPWire.textFailure("\(raw) is not a hostname: grux add domain "
                + "example.com")
        }

        let entry = host.lowercased()
        let (added, list) = addAppend(key: "grux.uptime.targets", entry: entry)
        let reply: [String: Any] = [
            "noun": "domain", "value": entry, "created": added,
            "headline": added
                ? "\(entry) is on the monitoring list, which now has \(list.count)."
                : "\(entry) was already on the monitoring list.",
            "touched": [addRow("Sites to monitor", "grux.uptime.targets", already: !added)],
            "note": "Nothing on this Mac probes that list yet. The domain monitor watches "
                + "renewal dates for every domain on your GoDaddy account instead, so it "
                + "does not read this and does not need to.",
            "verify": "grux config grux.uptime.targets",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    // MARK: - schedule

    private static func addSchedule(_ raw: String) -> [String: Any] {
        let tokens = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let shape = "grux add schedule \"weekdays at 9:00 AM ask draft my recap\""
        guard let verbIndex = tokens.firstIndex(where: {
            $0.lowercased() == "run" || $0.lowercased() == "ask"
        }), verbIndex + 1 < tokens.count else {
            return MCPWire.textFailure("A schedule needs a time and something to do at it, "
                + "separated by run for a workflow or ask for an agent: " + shape)
        }
        let when = Array(tokens[..<verbIndex])
        let verb = tokens[verbIndex].lowercased()
        let rest = tokens[(verbIndex + 1)...].joined(separator: " ")

        guard !when.isEmpty else {
            return MCPWire.textFailure("A schedule needs a time before \(verb): " + shape)
        }
        guard let time = addTime(in: when) else {
            return MCPWire.textFailure("Nothing in \"" + when.joined(separator: " ")
                + "\" reads as a time. Write it the way you would say it: " + shape)
        }
        let weekdays = addWeekdays(in: when)

        let action: UserCronAction
        let title: String
        if verb == "run" {
            let id = rest.split(separator: " ").map(String.init).first ?? rest
            let known = CommandV2Engine.shared.definitions
            // A DEFINITION LIST THAT IS EMPTY MEANS THE ENGINE HAS NOT LOADED, not that
            // every id is wrong, so an empty list passes the id through rather than
            // refusing everything.
            if !known.isEmpty, !known.contains(where: { $0.id == id }) {
                let ids = known.map(\.id).sorted { $0.lowercased() < $1.lowercased() }
                return MCPWire.textFailure("There is no workflow called \(id). The ones this "
                    + "Grux has are " + addSentence(ids) + ".")
            }
            action = .runCommand(definitionId: id)
            title = known.first(where: { $0.id == id })?.displayName ?? id
        } else {
            action = .agentPrompt(rest)
            title = rest.count > 60 ? String(rest.prefix(59)) + "\u{2026}" : rest
        }

        let store = UserCronStore.shared
        // IDENTITY IS THE JOB, NOT ITS TITLE. Running this twice must not leave two schedules
        // firing the same thing at the same minute.
        if let existing = store.jobs.first(where: {
            $0.action == action && $0.hour == time.hour && $0.minute == time.minute
                && $0.weekdays == weekdays
        }) {
            let reply: [String: Any] = [
                "noun": "schedule", "value": existing.title, "created": false,
                "headline": "That was already scheduled: \(existing.scheduleSummary).",
                "touched": [addRow("Schedules", addTilde(Persistence.userCronURL.path),
                                   already: true)],
                "note": "", "verify": "",
            ]
            return MCPWire.textResult(jsonText(reply))
        }

        let job = store.create(title: title, weekdays: weekdays, hour: time.hour,
                               minute: time.minute, action: action, notifyOnFire: true)

        let reply: [String: Any] = [
            "noun": "schedule", "value": job.title, "created": true,
            "headline": verb == "run"
                ? "\(job.title) runs \(addLowerFirst(job.scheduleSummary))."
                : "An agent gets that prompt \(addLowerFirst(job.scheduleSummary)).",
            "touched": [addRow("Schedules", addTilde(Persistence.userCronURL.path))],
            // MEASURED IN THE SCHEDULER: an occurrence more than ten minutes stale is rolled
            // past rather than fired late, so a Mac that was asleep does not wake up to a
            // backlog. Somebody who leaves Grux closed all morning should know that.
            "note": "Grux checks every thirty seconds while it is open. An occurrence missed "
                + "by more than ten minutes, because Grux was closed or the Mac asleep, is "
                + "skipped rather than fired late.",
            "verify": "",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    /// A time out of the words a person types: `9am`, `9:30am`, `9:30 AM`, `19:30`, `9`.
    ///
    /// No meridiem is read as a 24 hour clock, and the reply prints the resolved time back
    /// in standard time, so an ambiguous `at 9` is answered on screen rather than assumed
    /// silently.
    private static func addTime(in tokens: [String]) -> (hour: Int, minute: Int)? {
        let punctuation = CharacterSet(charactersIn: ",.")
        for (i, token) in tokens.enumerated() {
            var text = token.lowercased().trimmingCharacters(in: punctuation)
            var meridiem: String?
            if text.hasSuffix("am") || text.hasSuffix("pm") {
                meridiem = String(text.suffix(2))
                text = String(text.dropLast(2))
            } else if i + 1 < tokens.count {
                let next = tokens[i + 1].lowercased().trimmingCharacters(in: punctuation)
                if next == "am" || next == "pm" { meridiem = next }
            }
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count <= 2, var hour = Int(parts[0]) else { continue }
            let parsedMinute: Int? = parts.count == 2 ? Int(parts[1]) : 0
            guard let minute = parsedMinute, (0...59).contains(minute) else { continue }
            if meridiem == "am", hour == 12 { hour = 0 }
            if meridiem == "pm", hour < 12 { hour += 12 }
            guard (0...23).contains(hour) else { continue }
            return (hour, minute)
        }
        return nil
    }

    /// Calendar weekday numbers, 1 for Sunday, out of the same words.
    ///
    /// Nothing recognised means every day, which the reply says out loud, because a silent
    /// default that turns out to be wrong is worse than a default somebody can read.
    private static func addWeekdays(in tokens: [String]) -> Set<Int> {
        let names: [String: Int] = [
            "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
            "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thurs": 5, "friday": 6,
            "fri": 6, "saturday": 7, "sat": 7,
        ]
        let punctuation = CharacterSet(charactersIn: ",.")
        var picked: Set<Int> = []
        for token in tokens {
            let text = token.lowercased().trimmingCharacters(in: punctuation)
            switch text {
            case "weekday", "weekdays": picked.formUnion([2, 3, 4, 5, 6])
            case "weekend", "weekends": picked.formUnion([1, 7])
            case "daily", "everyday":   picked.formUnion(1...7)
            default:
                if let day = names[text] { picked.insert(day) }
            }
        }
        return picked.isEmpty ? Set(1...7) : picked
    }

    // MARK: - skill

    /// A COPY, and the reply says so.
    ///
    /// `SkillStore` is the thing chat reads, and it holds text rather than a path, so a
    /// folder cannot be watched in place. Reporting this as "Grux is using that folder"
    /// would be false the first time somebody edited the original.
    private static func addSkill(_ raw: String) -> [String: Any] {
        let path = ShellAllowlist.standardize(NSString(string: raw).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return MCPWire.textFailure("There is nothing at \(addTilde(path)).")
        }
        let file = isDirectory.boolValue ? path + "/SKILL.md" : path
        let folderName = isDirectory.boolValue
            ? URL(fileURLWithPath: path).lastPathComponent
            : URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        guard let text = try? String(contentsOf: URL(fileURLWithPath: file),
                                     encoding: .utf8) else {
            return MCPWire.textFailure(isDirectory.boolValue
                ? "There is no SKILL.md in \(addTilde(path)). A skill is a folder with one "
                    + "of those in it, holding the steps as markdown."
                : "\(addTilde(path)) will not read as text.")
        }
        guard let parsed = SkillFolderBackend.parse(markdown: text, folderName: folderName),
              !parsed.procedure.isEmpty else {
            return MCPWire.textFailure("\(addTilde(file)) has no steps in it. A skill is the "
                + "procedure under the front matter, and Grux has nothing to follow without "
                + "one.")
        }

        let store = SkillStore.shared
        let existing = store.skill(named: parsed.name)
        let unchanged = existing.map {
            $0.procedure == parsed.procedure && $0.trigger == parsed.trigger
        } ?? false
        store.upsert(name: parsed.name, trigger: parsed.trigger, procedure: parsed.procedure)
        // The store debounces by 1.5 seconds and this reply claims the file is written, so
        // the claim is made true first.
        store.flush()

        let touched: [[String: Any]] = [
            addRow("Skills", addTilde(Persistence.skillsURL.path), already: unchanged),
            addRow("Copy on disk", addTilde(Persistence.skillsDir.path), already: unchanged),
        ]
        let count = store.skills.count
        let reply: [String: Any] = [
            "noun": "skill", "value": parsed.name, "created": existing == nil,
            "headline": existing == nil
                ? "\(parsed.name) is a skill Grux can follow."
                : (unchanged ? "\(parsed.name) was already there, unchanged."
                             : "\(parsed.name) is updated."),
            "touched": touched,
            "note": "Grux copied it. The folder you named is untouched and is not watched, "
                + "so editing it later means adding it again. Chat sees \(count) "
                + "skill\(count == 1 ? "" : "s") now.",
            "verify": "",
        ]
        return MCPWire.textResult(jsonText(reply))
    }

    // MARK: - Shared

    /// One row of "what this touched", which is the whole point of the reply.
    /// One row of what an add actually touched.
    ///
    /// `failed` and `needsPerson` are SEPARATE because they are different exit codes, and
    /// the CLI cannot tell them apart from this side. A row that failed because a write did
    /// not land is exit 1: try again, fix the disk, it can succeed. A row that failed
    /// because only a human can finish it is exit 2, which means no invocation of this
    /// command will ever satisfy it. Collapsing the two makes exit 2 useless for the single
    /// decision it exists to inform, which is whether to wake somebody up.
    private static func addRow(_ what: String, _ where_: String,
                               already: Bool = false, failed: Bool = false,
                               needsPerson: Bool = false) -> [String: Any] {
        ["what": what, "where": where_, "already": already, "failed": failed,
         "needsPerson": needsPerson]
    }

    /// A list-shaped setting, read the way `ShellAllowlist` reads its own.
    ///
    /// ONE PATH OR A LIST OF PATHS, because a key set by hand before it was list shaped is a
    /// String, and reading only the array shape would silently drop it on the next write.
    /// The spoken aliases, or nil when the file is there and will not parse.
    ///
    /// ABSENT AND UNPARSEABLE ARE NOT THE SAME ANSWER, and collapsing them is data loss
    /// rather than a rendering problem. Both `add` and `remove` read this file, mutate the
    /// dictionary, and write the WHOLE thing back. A `?? [:]` on a file that exists but will
    /// not decode therefore starts from empty and replaces every alias the operator had with
    /// the one being added, silently, on a run that reports success.
    ///
    /// nil means refuse. A file nobody can read is a file nobody should overwrite: the
    /// content is still in there and a person can fix it, right up until something helpfully
    /// rewrites it.
    static func addAliases() -> [String: String]? {
        let url = ProjectsResolver.aliasesURL
        guard let data = try? Data(contentsOf: url) else { return [:] }   // absent is empty
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: String] else { return nil }
        return map
    }

    /// Internal, not private, BECAUSE REMOVE HAS TO READ THE SAME LIST THE SAME WAY.
    /// Swift private is file scoped, and a second copy of the one-path-or-a-list rule in
    /// the remove handler is the exact drift that made remove stop being an inverse.
    static func addConfigList(key: String) -> [String] {
        let defaults = UserDefaults.standard
        if let list = defaults.array(forKey: key) as? [String] { return list }
        if let single = defaults.string(forKey: key) { return [single] }
        return []
    }

    /// APPEND AND DE-DUPLICATE. Never replace.
    private static func addAppend(key: String, entry: String) -> (added: Bool, list: [String]) {
        var list = addConfigList(key: key)
        // Case insensitively, because a hostname is case insensitive and macOS filesystems
        // are case insensitive by default, so two spellings of one entry are one entry.
        guard !list.contains(where: { $0.lowercased() == entry.lowercased() }) else {
            return (false, list)
        }
        list.append(entry)
        UserDefaults.standard.set(list, forKey: key)
        SetupStatusFile.write()
        return (true, list)
    }

    /// A list a person reads aloud. The renderer has one of these for the CLI side; this is
    /// the same sentence built where the message is written.
    private static func addSentence(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and "
                    + items[items.count - 1]
        }
    }

    /// The home directory back as `~`, because a reader knows which Mac they are on and the
    /// full path costs a third of the line.
    /// Shared with the remove handler, which prints the same paths.
    static func addTilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    /// "Weekdays at 9:00 AM" mid sentence.
    private static func addLowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }
}
