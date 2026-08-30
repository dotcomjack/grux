import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux support-bundle

/// A folder somebody can read, then attach to a bug report.
///
/// ## Named first, written second
///
/// Every file is built in memory and printed with the size it will have BEFORE anything
/// lands on disk. A manifest printed from a plan is a guess, and a file added between the
/// plan and the write is a file nobody was shown. So the sizes on the screen are the bytes
/// that get written, and the count under them counts that same list.
///
/// ## Safe by construction, not by redaction
///
/// Nothing here reads a folder and filters it. Every source is named one at a time below
/// with the reason it counts as diagnostics, and the documents that mix diagnostics with
/// content travel as a list of FIELDS rather than as a copy.
///
/// The difference is measurable rather than theoretical. Neither folder this reads from is
/// a diagnostics folder. On the Mac this was written on, `~/.grux` holds files whose names
/// end in `-creds.json` and `-token.txt` sitting beside the state documents, and the app's
/// support folder holds the chat threads, the workday logs and the ambient captures beside
/// the app log. A sweep of either one is an exfiltration, and a sweep that redacts
/// afterwards is a promise about every file and every field somebody adds later. Nobody can
/// keep that promise, so this command does not make it.
///
/// ## No socket
///
/// It reads files and never talks to the app, so it works with Grux closed. The moment
/// somebody most wants a bundle is the moment the app has stopped.
struct SupportBundle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "support-bundle",
        abstract: "A folder you can read, then attach to a bug report.",
        discussion: """
            Every file is named and sized before anything is written, and nothing goes in \
            that Grux did not write about itself. It reads files and never talks to the app, \
            so it works with Grux closed, which is usually the state somebody is reporting.
            """)

    @Option(name: .long, help: "The folder to put the bundle in. Default the current folder.")
    var out: String?

    @Flag(name: .long, help: "Do not ask before writing.")
    var yes = false

    @Flag(name: .long, help: "Print the manifest and write nothing.")
    var dryRun = false

    // MARK: - What is allowed in

    /// A document Grux writes about itself, and the fields of it that travel.
    ///
    /// A LIST OF FIELDS, not a copy of the file, and the reason is measured rather than
    /// imagined. `phone-receiver-status.json` carries `latestTranscript`, which is the last
    /// thing somebody said out loud, and a `hostname` which on a stock Mac is the owner's
    /// own name. Both sit in the same small object as the port number and the frame count a
    /// bug report actually needs. Copying the document takes all four.
    struct StateDoc {
        let file: String
        let what: String
        let fields: [String]
    }

    static let stateDocs: [StateDoc] = [
        StateDoc(file: "mic-status.json",
                 what: "which listening features are on, and which are actually running",
                 fields: ["at", "ambientEnabledPreference", "ambientListening",
                          "ambientCapturing", "wakeWordEnabledPreference",
                          "wakeWordListening", "meetingCapturing", "meetingInitializing",
                          "micMuted", "voiceInputRecording"]),
        StateDoc(file: "phone-receiver-status.json",
                 what: "whether the iPhone companion is listening, and whether it connected",
                 fields: ["isRunning", "isConnected", "listenerPort", "audioFramesReceived",
                          "pairingSecretConfigured", "lastError"]),
        StateDoc(file: "screen-control-status.json",
                 what: "whether screen control is granted, and whether it is turned on",
                 fields: ["accessibilityGranted", "screenControlEnabled", "bundleID",
                          "keyboardLayout", "gruxIsFrontmost", "resolvedTargetIsSelf",
                          "writtenAtEpoch"]),
    ]

    /// How much of each log travels.
    ///
    /// The tail, not the file. `wake.log` here is over twenty five thousand lines and a bug
    /// report is about the last few minutes, so the whole file makes the bundle harder to
    /// read without making it more useful. The manifest says which it took, every time.
    static let logTail = 500

    /// `~/.grux`, resolved from the one place that already resolves it.
    ///
    /// A second literal path is a second thing to keep in step with the app.
    static var gruxDir: URL { SetupStatusReader.defaultURL.deletingLastPathComponent() }

    /// One file that is going into the bundle, with its bytes already decided.
    struct Item {
        let name: String
        let what: String
        let text: String
        var bytes: Int { text.utf8.count }
        var size: String {
            ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
        }
    }

    // MARK: - Run

    /// The log keys this bundle may carry, and the whole list is the argument.
    ///
    /// A log is in here because somebody read it and established that its CONTENT is
    /// diagnostics, never because it is called a log. `security-audit.log` is one permission
    /// check per line with a verdict; `fs-audit.log` is one file operation per line with a
    /// path and an outcome. Neither holds anything a person said or wrote.
    ///
    /// `wake.log` is deliberately absent and it is the reason this list exists.
    ///
    /// ADDING A KEY HERE IS THE DECISION. `Logs.sources` is where a log gets a name; this is
    /// where one gets permission to leave the machine, and the two are separate on purpose.
    static let included: Set<String> = ["security", "files"]

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer
        let taken = Date()

        frame.open(.look, "Every file that would go in, named and sized before anything is "
                          + "written.")

        // THE DESIGNED SENTENCE, NOT A HALF BUNDLE. Without the setup document there is
        // almost nothing to collect, and each way of failing to read it wants a different
        // thing from a person: open Grux once, run doctor, or install a matching binary.
        // `frame.explain` already writes all three and returns the exit code that matches.
        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e): leave(frame.explain(e))
        }

        var items: [Item] = []
        var absent: [String] = []
        // COUNTED, NEVER GUESSED. The number of files WRITTEN and the number of files READ
        // are different numbers: versions.txt and setup.txt both come out of the one setup
        // document, and state.json can come from three. Saying "reads 7 files" because 7
        // files come out is the kind of sentence that is false for part of what it covers.
        var sourcesRead = 1

        items.append(Item(name: "versions.txt",
                          what: "this binary, the app, and whether they match",
                          text: versionsText(status, taken: taken)))
        items.append(Item(name: "setup.txt",
                          what: "every capability and feature, as ids and states",
                          text: setupText(status, taken: taken, r: r)))

        if let state = stateText(taken: taken) {
            sourcesRead += state.present
            items.append(Item(name: "state.json",
                              what: "\(state.present) of \(Self.stateDocs.count) state "
                                  + "documents, named fields only",
                              text: state.text))
        } else {
            absent.append("any state document")
        }

        // THE LOG DIRECTORY IS NOT A LOG DIRECTORY. `Logs.dir` also holds the chat threads,
        // the workday logs, the agent transcripts and the ambient captures, so the bundle
        // takes only files `grux logs` names and never the folder they sit in.
        //
        // AND NAMING A LOG IS NOT ENOUGH EITHER, which is the part the first version got
        // wrong. It took all three of `Logs.sources` on the reasoning that a log is
        // diagnostics, and `wake.log` is not: it carries `ambient chunk:` and
        // `ambient (focus): -> chat:` lines holding VERBATIM SPEECH picked up in the room.
        // Measured on this Mac: 2.1 MB of wake.log with transcript lines through the middle
        // of it, while this command printed "Never in it, and never read: ... anything from
        // your notes, chat threads, meetings, journal or ambient captures."
        //
        // That promise was false, and the shape of the mistake is the one this whole command
        // is built to avoid: it INCLUDED A CATEGORY and trusted the category, rather than
        // including a file because somebody established what that file holds. Filtering the
        // transcript lines back out would be redaction, which is a blocklist, which is
        // exactly what `Self.included` refuses to be.
        for source in Logs.sources where Self.included.contains(source.key) {
            let url = Logs.dir.appendingPathComponent(source.file)
            guard let log = tail(of: url) else {
                absent.append("the \(source.key) log")
                continue
            }
            sourcesRead += 1
            let extent = log.kept == log.lines
                ? "all \(log.lines) lines"
                : "last \(log.kept) of \(log.lines) lines"
            items.append(Item(name: source.file,
                              what: firstClause(source.what) + " (\(extent))",
                              text: log.text))
        }

        let others = otherEntriesInGruxDir()
        items.insert(Item(name: "README.txt",
                          what: "what this bundle is, and what it leaves out",
                          text: readme(rest: items, absent: absent, status: status,
                                       taken: taken, others: others, r: r)),
                     at: 0)

        // ---- the manifest ----------------------------------------------------------------
        let nameWidth = items.map(\.name.count).max() ?? 12
        let sizeWidth = items.map(\.size.count).max() ?? 8
        for item in items {
            let size = item.size.padding(toLength: sizeWidth, withPad: " ", startingAt: 0)
            print(r.row(state: .satisfied, label: item.name,
                        detail: size + "  " + item.what, labelWidth: nameWidth + 2))
        }
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(items.reduce(0) { $0 + $1.bytes }), countStyle: .file)
        print("")
        print(r.prose("\(items.count) files, \(total). That is the whole bundle. Nothing is "
                      + "added to this list while it writes."))

        if !absent.isEmpty {
            let sorted = absent.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            print("")
            print(r.style.ink(.dim, r.prose(
                "Grux has not written \(r.list(sorted)) on this Mac, so "
                + "\(sorted.count == 1 ? "it is" : "they are") not in the list.", indent: 2)))
        }

        // ---- what it costs, and what it never takes --------------------------------------
        frame.open(.cost, "This asks for nothing and sends nothing. It reads \(sourcesRead) "
                          + "files Grux wrote about itself, and writes "
                          + (dryRun ? "nothing." : "a folder."))

        let containerPath = out.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.currentDirectoryPath
        let container = URL(fileURLWithPath: containerPath, isDirectory: true)
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: container.path,
                                                    isDirectory: &isFolder)
        guard exists, isFolder.boolValue else {
            print(r.prose("There is no folder at \(display(container)) to put this in."))
            print("")
            print(r.style.ink(.dim, r.prose("Make it first, or leave --out off and the bundle "
                + "lands in the folder you are standing in.", indent: 2)))
            leave(.failed)
        }

        let name = "grux-support-" + Self.fileStamp(taken)
        let destination = container.appendingPathComponent(name, isDirectory: true)
        // RELATIVE WHEN IT CAN BE. The default lands in the folder somebody is standing in,
        // and printing `/Users/<their name>/...` at them puts their home folder's name into
        // every screenshot of this screen for no gain.
        let shown = out == nil ? "./" + name : display(destination)
        // A SPACE MUST NOT SWALLOW THE TILDE. Wrapping the whole path in quotes is the
        // obvious move and it breaks the one path that most needs quoting: a shell expands
        // `~` only while it is unquoted, so `cat "~/Bug Reports/grux-support-.../"*` reports
        // no such file and the PROVE line stops being something anybody can paste. The
        // quotes start after the tilde instead.
        let quoted: String
        if !shown.contains(" ") {
            quoted = shown
        } else if shown.hasPrefix("~/") {
            quoted = "~/\"" + shown.dropFirst(2) + "\""
        } else {
            quoted = "\"" + shown + "\""
        }

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            print(r.prose("There is already something at \(shown), and this will not write "
                + "over it. The name carries the minute, so running this again in a minute "
                + "picks a new one."))
            leave(.failed)
        }

        print(r.row(state: .satisfied, label: "Lands at", detail: shown, labelWidth: 12))
        print("")
        print(r.prose("Never in it, and never read: any Keychain item, the app's own "
            + "config.json, and anything from your notes, chat threads, meetings, journal or "
            + "ambient captures. Those are not filtered out at the end. No line in this "
            + "command names them."))
        print("")
        // NAMED, NOT SILENTLY MISSING. wake.log is the file somebody debugging Grux would
        // most expect here, and it is the one file whose content is not diagnostics, so
        // saying nothing would read as an oversight and get "fixed" by the next person.
        print(r.style.ink(.dim, r.prose("wake.log is not here either, and it is the one "
            + "somebody would expect. Grux writes what it hears into it, so it holds speech "
            + "picked up in the room. It is at " + display(Logs.dir) + "/wake.log if a "
            + "maintainer asks for it, and reading it before you send it is your call to "
            + "make, not this command's.", indent: 2)))
        // COUNTED FROM THE LIST ABOVE, not written as "the three logs". On a Mac Grux was
        // installed on this morning there may be one, and a warning about files that are
        // not in the bundle sends somebody looking for them.
        let logs = items.filter { $0.name.hasSuffix(".log") }.count
        if logs > 0 {
            print("")
            print(r.style.ink(.attention, r.prose(
                "What it does carry is \(logs) log file\(logs == 1 ? "" : "s"), copied as "
                + "written. A log names files Grux touched and commands it ran, and it "
                + "carries the full path to your home folder. Read \(logs == 1 ? "it" : "them") "
                + "before you send this anywhere.", indent: 2)))
        }

        if dryRun {
            frame.open(.prove)
            print(r.prose("Nothing was written. Every file above was built to get its real "
                          + "size and then dropped, so that manifest is what you would get."))
            print("")
            print(r.style.ink(.dim, r.prose("Run it again without --dry-run to write it to "
                + "\(shown).", indent: 2)))
            leave(.done)
        }

        if !yes {
            guard input.canAsk else {
                print("")
                print(r.prose("Nothing is attached to this terminal, so there is nobody to "
                    + "ask. Pass --yes to write it, or --dry-run to see this list only."))
                leave(.failed)
            }
            // TYPED, not a keystroke. The decision being confirmed is not "make a folder",
            // it is "collect these files to send to a stranger", and that is worth a word.
            let typed = InputPolicy.ask([
                "",
                "  Type write to confirm, or anything else to stop.",
                "",
            ])
            guard typed == "write" else {
                print("")
                print(r.prose("Left everything alone. Nothing was written."))
                leave(.done)
            }
        }

        // ---- the write -------------------------------------------------------------------
        do {
            // NOT `withIntermediateDirectories`. The folder above was checked and reported
            // on the screen before this point, so creating a missing one here would be
            // building a path somebody was just told did not exist.
            // 0700 AND 0600, NOT THE DEFAULTS. The bundle carries every permission check
            // Grux made and every file it touched, with full paths, and it lands in whatever
            // folder somebody happened to be standing in. The source logs are 0644 today, so
            // this is not restoring a tighter mode that existed: it is declining to make a
            // second world readable copy of an audit trail, in a folder chosen for
            // convenience, that exists to be sent to somebody else.
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            for item in items {
                let file = destination.appendingPathComponent(item.name)
                try item.text.write(to: file, atomically: true, encoding: .utf8)
                // AFTER the write, not before. `write(atomically:)` writes a temporary file
                // and renames it, so anything set on the destination beforehand is replaced
                // along with the file.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: file.path)
            }
        } catch {
            // HALF A BUNDLE IS WORSE THAN NONE. The manifest above promised a list, and a
            // folder holding some of it would still be attached to a bug report and read as
            // complete. This only ever removes a folder created moments ago in this run:
            // an existing one was refused above rather than written into.
            try? FileManager.default.removeItem(at: destination)
            print("")
            print(r.prose("Could not write \(shown): \(error.localizedDescription)"))
            print("")
            print(r.style.ink(.dim, r.prose("Nothing was left behind. A half written bundle "
                + "would not match the list above.", indent: 2)))
            leave(.failed)
        }

        frame.open(.prove)
        print(r.row(state: .satisfied, label: "Written", detail: shown, labelWidth: 12))
        print(r.row(state: .satisfied, label: "Holds",
                    detail: "\(items.count) files, \(total)", labelWidth: 12))
        print("")
        print(r.prose("It is a folder, not an archive, so every byte of it can be read "
                      + "before it goes anywhere:"))
        print("")
        print("    " + r.style.ink(.accent, "cat \(quoted)/*"))
        print("")
        print(r.style.ink(.dim, r.prose("Zip it yourself once you are happy with it. Nothing "
            + "in it is a credential, so there is nothing to rotate after you send it.",
            indent: 2)))
        leave(.done)
    }

    // MARK: - The files

    private func versionsText(_ status: SetupStatus, taken: Date) -> String {
        // THE SAME THREE-WAY VERDICT `grux version` PRINTS. A local build is not a fault
        // and must not be reported as one, which is the distinction that makes a version
        // line in a bug report worth reading at all.
        let matches = Version.cliVersion == status.appVersion
        let isDev = Version.cliVersion == "dev"
        let verdict: String
        if isDev {
            verdict = "not expected, this grux is a local build"
        } else if matches {
            verdict = "yes"
        } else {
            verdict = "NO, these came from different builds"
        }
        let installed = FileManager.default.fileExists(atPath: "/Applications/Grux.app")
            ? "installed at /Applications/Grux.app"
            : "not at /Applications/Grux.app"
        let age = SetupStatusReader.age(of: status, now: taken).map(Status.ago) ?? "age unknown"
        return """
            VERSIONS

              grux             \(Version.cliVersion)
              Grux.app         \(status.appVersion), as the app last reported itself
              match            \(verdict)

            THIS MAC

              macOS            \(ProcessInfo.processInfo.operatingSystemVersionString)
              Grux.app         \(installed)
              setup written    \(status.generatedAt), \(age)
              bundle taken     \(Self.readableStamp(taken))

            A mismatch above is worth reporting on its own. The binary inside
            Grux.app/Contents/MacOS always matches the app it shipped with, so a grux on
            PATH that disagrees is usually a symlink left behind by an older install.

            """
    }

    /// Every capability and feature, as ids and states.
    ///
    /// IDS AND STATES ONLY. The document also carries a label and a remediation sentence for
    /// every row, and leaving both behind is what lets this file be described exactly:
    /// every value in it is an id, a state, a tier or a count, so no free text at all
    /// travels and there is no field here that could hold something somebody typed.
    private func setupText(_ status: SetupStatus, taken: Date, r: Renderer) -> String {
        let age = SetupStatusReader.age(of: status, now: taken).map(Status.ago) ?? "age unknown"
        let s = status.summary
        // Built by hand rather than through `r.legend`, which inks its glyphs: on a terminal
        // that would write escape sequences into a file somebody opens in an editor.
        let legend = [RowState.satisfied, .needed, .attested, .skipped]
            .map { "\($0.glyph) \($0.word)" }.joined(separator: "   ")

        var out = """
            SETUP, as Grux last wrote it to ~/.grux/setup-status.json
            Written \(status.generatedAt), \(age). Schema \(status.schema), Grux \
            \(status.appVersion).

            Ids and states only. The labels and the remediation sentences are left behind, so
            every value below is an id, a state, a tier or a count.

              \(legend)

            SUMMARY

              capabilities   \(s.capabilities) known, \(s.satisfied) satisfied, \
            \(s.selfAttested) taken on your word
              features       \(s.featuresChosen) chosen, \(s.featuresReady) ready, \
            \(s.featuresNeedingSetup) needing setup

            CAPABILITIES


            """

        // CASE INSENSITIVE. A plain `<` on a String is an ASCII sort, which files every
        // lowercase id after every uppercase one for no reason a reader can see.
        let caps = status.capabilities.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        let capWidth = caps.map(\.id.count).max() ?? 20
        let kindWidth = caps.map(\.kind.count).max() ?? 8
        for cap in caps {
            let state: RowState = cap.satisfied
                ? (cap.selfAttested ? .attested : .satisfied)
                : .needed
            out += "  \(state.glyph) "
                + cap.id.padding(toLength: capWidth, withPad: " ", startingAt: 0) + "  "
                + cap.kind.padding(toLength: kindWidth, withPad: " ", startingAt: 0) + "  "
                + state.word + "\n"
        }

        out += "\nFEATURES\n\n"
        let features = status.features.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        let featWidth = features.map(\.id.count).max() ?? 20
        let tierWidth = features.map(\.tier.count).max() ?? 6
        for feature in features {
            // NOT CHOSEN IS AN ANSWER, not a fault. A feature somebody deliberately left out
            // wearing the same glyph as one that is blocked would send whoever reads this
            // bundle looking for a problem that nobody has.
            let state: RowState = !feature.chosen ? .skipped
                : (feature.state == "ready" ? .satisfied : .needed)
            var line = "  \(state.glyph) "
                + feature.id.padding(toLength: featWidth, withPad: " ", startingAt: 0) + "  "
                + feature.tier.padding(toLength: tierWidth, withPad: " ", startingAt: 0) + "  "
                + feature.state
            if !feature.chosen { line += ", not chosen" }
            if !feature.missing.isEmpty {
                let missing = feature.missing.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                line += ", missing " + r.list(missing)
            }
            out += line + "\n"
        }
        return out
    }

    /// The state documents, as named fields.
    ///
    /// Returns nil when none of the three exists, which is an ordinary state rather than a
    /// fault: a Mac where Grux has never listened, never paired a phone and never been
    /// asked to drive the screen has written none of them. An empty document in the bundle
    /// would be a row in the manifest that says nothing.
    private func stateText(taken: Date) -> (text: String, present: Int)? {
        var documents: [String: Any] = [:]
        var present = 0
        for doc in Self.stateDocs {
            let url = Self.gruxDir.appendingPathComponent(doc.file)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // ABSENCE IS DIAGNOSTIC. "The phone receiver never wrote a status" is an
                // answer to most phone bug reports, and dropping the row loses it.
                documents[doc.file] = ["present": false, "what": doc.what]
                continue
            }
            present += 1
            // Field by field, by name. Never the object, so a field added to one of these
            // documents later cannot ride out of the machine on this command.
            var values: [String: Any] = [:]
            for field in doc.fields {
                if let value = object[field] { values[field] = value }
            }
            documents[doc.file] = ["present": true, "what": doc.what,
                                   "fields": doc.fields, "values": values]
        }
        guard present > 0 else { return nil }

        let root: [String: Any] = [
            "takenAt": ISO8601DateFormatter().string(from: taken),
            "note": "Each document below is quoted field by field. `fields` is what this "
                  + "command takes, `values` is what was there. Nothing outside that list "
                  + "was read, so a field added to one of these documents later cannot "
                  + "appear here without somebody naming it first.",
            "documents": documents,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text + "\n", present)
    }

    private func readme(rest: [Item], absent: [String], status: SetupStatus,
                        taken: Date, others: Int, r: Renderer) -> String {
        let width = (rest.map(\.name.count).max() ?? 12) + 2
        var contents = "  README.txt".padding(toLength: width + 2, withPad: " ", startingAt: 0)
            + "this file\n"
        for item in rest {
            contents += ("  " + item.name).padding(toLength: width + 2, withPad: " ",
                                                   startingAt: 0) + item.what + "\n"
        }

        var missing = ""
        if !absent.isEmpty {
            let sorted = absent.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            missing = "\n  Grux has not written \(r.list(sorted)) on this Mac, so "
                + "\(sorted.count == 1 ? "it is" : "they are") not here.\n"
        }

        // The warning about the logs is only true while there ARE logs. On a Mac where Grux
        // has not written one yet, printing it sends the reader looking for a file that the
        // manifest above does not list.
        let logs = rest.filter { $0.name.hasSuffix(".log") }.count

        // COUNTED, AND NEVER NAMED. "89 other files" tells whoever receives this that it is
        // a selection rather than a sweep. Their names would tell them what somebody keeps
        // on their Mac, which is the thing this command exists to leave behind.
        let elsewhere: String
        switch others {
        case 0: elsewhere = "There is nothing else in ~/.grux."
        case 1: elsewhere = "One other file in ~/.grux was not opened."
        default: elsewhere = "\(others) other files and folders in ~/.grux were not opened."
        }
        var carries = """
            HOW TO READ IT

              Every file here is plain text and this folder is not an archive, so nothing
              has to be unpacked to be read.

            """
        if logs > 0 {
            carries = """
                WHAT IT CARRIES THAT IS STILL YOURS

                  Each log file here is copied as it was written. A log names files Grux
                  touched and commands it ran, and it carries the full path to a home
                  folder. Read them before sending this to anybody. Every file here is
                  plain text and this folder is not an archive, so nothing has to be
                  unpacked to be read.

                """
        }

        return """
            GRUX SUPPORT BUNDLE

            Taken \(Self.readableStamp(taken)) by grux \(Version.cliVersion), from Grux \
            \(status.appVersion).

            WHAT IS IN IT, \(rest.count + 1) files

            \(contents)\(missing)
            WHAT IS NOT IN IT, AND WAS NEVER READ

              No Keychain item. Grux keeps its API keys in the login keychain, this command
              never asks macOS for one, and there is no path here that could return one.

              Not the app's own config.json. It carries fields named anthropicApiKey and
              elevenLabsApiKey, which should be empty now that the keys live in the login
              keychain, and an older Grux wrote real keys into them in the clear. A bundle
              that copied that file and blanked those two fields would be making a promise
              about every field somebody adds to it afterwards.

              Not every field of the state documents. phone-receiver-status.json records the
              last thing said out loud and the name of this Mac in the same small object as
              the port number and the frame count, so this takes the port and the frame
              count. state.json lists, for each document, the fields that travelled.

              Nothing from the notes, the chat threads, the meetings, the journal or the
              ambient captures. Those are what somebody wrote and what they said, not what
              Grux did, and none of them is named anywhere in this command.

              Not wake.log, which is the one a maintainer would ask for first. Grux writes
              what it hears into it, so it holds speech picked up in the room alongside
              what the app was doing. Being called a log is not the same as being
              diagnostics, and this bundle carries a file because somebody read that file,
              never because of what it is called.

              \(elsewhere)

              No folder, ever. Every file above is named one at a time in the source of
              grux support-bundle, with the reason it counts as diagnostics. Nothing here
              reads a folder and filters it afterwards, which is the only version of this
              promise that stays true as the app grows.

            \(carries)
            """
    }

    // MARK: - Reading

    /// The tail of a log, or nil when there is nothing in it.
    ///
    /// An empty log and an absent one are the same fact to somebody reading a manifest:
    /// Grux has not written that one yet. Both are ordinary on a Mac that was set up this
    /// week, and neither is worth a row.
    private func tail(of url: URL) -> (text: String, lines: Int, kept: Int)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let kept = Array(lines.suffix(Self.logTail))
        return (kept.joined(separator: "\n") + "\n", lines.count, kept.count)
    }

    /// How many other things are in `~/.grux`, counted and never named.
    ///
    /// The count is the honest half of "what else is down there": it tells whoever receives
    /// the bundle that this was a selection rather than a sweep, and it tells the person
    /// running it that the rest stayed home. The NAMES are not printed and not stored,
    /// because a file name is content too.
    private func otherEntriesInGruxDir() -> Int {
        let named = Set(Self.stateDocs.map(\.file)
                        + [SetupStatusReader.defaultURL.lastPathComponent])
        let all = (try? FileManager.default.contentsOfDirectory(atPath: Self.gruxDir.path)) ?? []
        return all.filter { !named.contains($0) }.count
    }

    // MARK: - Words

    /// `Logs.sources` writes a second sentence for the reader of `grux logs`. A manifest row
    /// wants one clause.
    private func firstClause(_ text: String) -> String {
        guard let stop = text.firstIndex(of: ".") else { return text }
        return String(text[text.startIndex..<stop])
    }

    /// A path somebody can read, and paste, without their home folder's name in it.
    private func display(_ url: URL) -> String {
        let home = NSHomeDirectory()
        if url.path == home { return "~" }
        guard url.path.hasPrefix(home + "/") else { return url.path }
        return "~" + String(url.path.dropFirst(home.count))
    }

    /// The folder name. Minute resolution, so two bundles in one day do not collide.
    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        // POSIX, because a filename must not change shape with the reader's calendar.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    private static func readableStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd h:mm a"
        return f.string(from: date)
    }
}
