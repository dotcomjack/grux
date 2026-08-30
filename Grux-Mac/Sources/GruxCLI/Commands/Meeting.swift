import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux meeting

/// Record a meeting, end one, or read what is already recorded.
///
/// ## Starting is the most consequential thing this binary can do
///
/// Every other command in here reads a file or changes a setting. This one turns a
/// microphone on in a room that contains other people, and none of them are holding the
/// keyboard. So it is deliberately the slowest thing here to say yes to. It refuses until
/// the microphone grant AND the recording consent are both already answered inside the app,
/// it says what is captured and where that lands before it asks, and it takes a TYPED
/// confirmation rather than a keystroke.
///
/// A recording that starts from a pipe by accident is the worst outcome in this file, which
/// is why `--no-input` and a closed stdin both refuse rather than defaulting to yes.
///
/// ## Reading works with Grux closed, recording cannot
///
/// `list` opens the meeting files directly, so it answers on a Mac where Grux is not
/// running: that is the moment somebody is most likely to be looking for what was said. The
/// index the app keeps beside those files is used only while it still accounts for every
/// file on disk, because it is written by a process that can be killed between a save and a
/// reindex. `start` and `stop` go through the app, because the app is the only thing that
/// can hold a microphone under its own signature.
struct Meeting: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting",
        abstract: "Record a meeting, end one, or read what is already recorded.",
        discussion: """
            grux meeting list reads the files on this Mac and works with Grux closed. \
            start and stop go through the app.

            Starting records everyone in the room, not only you, so it asks first. \
            Pass --yes only from a script that has already asked.
            """)

    @Argument(help: "start, stop or list.")
    var action: String?

    @Flag(name: .long, help: "Do not ask before recording. For a script that already did.")
    var yes = false

    @Flag(name: .long, help: "Never wait for a person. Fails and names --yes instead.")
    var noInput = false

    @Option(name: .long, help: "How many meetings to list. Default 10.")
    var limit: Int = 10

    @Flag(name: .long, help: "Machine readable. Applies to list.")
    var json = false

    /// The three, with what each one does, in the order somebody meets them.
    private static let actions: [(name: String, does: String)] = [
        ("start", "record this room until you stop it"),
        ("stop", "end the recording and write it down"),
        ("list", "what is already recorded, newest first"),
    ]

    func run() throws {
        let frame = Frame()
        let verb = (action ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch verb {
        case "list": listRecorded(frame)
        case "start": startRecording(frame)
        case "stop": stopRecording(frame)
        default: unknown(verb, frame)
        }
    }

    // MARK: - Neither of the three

    private func unknown(_ verb: String, _ frame: Frame) {
        let r = frame.renderer
        frame.open(.look)
        if verb.isEmpty {
            // NOT DEFAULTED TO LIST. Two of the three change what the microphone is doing,
            // and a command that picks for you is a command that can pick start.
            print(r.prose("grux meeting does three things and will not pick one for you."))
        } else {
            print(r.prose("No meeting action called \(verb)."))
            // A transposed letter neither contains nor is contained by the right answer, so
            // substring matching alone suggests nothing. Same edit distance the capability
            // lookup uses, against three words instead of forty one.
            let near = Self.actions
                .map { ($0.name, Lookup.edits(verb, $0.name)) }
                .filter { $0.1 <= max(2, verb.count / 2) }
                .sorted { $0.1 < $1.1 }
            if let best = near.first {
                print("")
                print(r.style.ink(.dim, r.prose("Did you mean \(best.0)?", indent: 2)))
            }
        }
        print("")
        let width = Self.actions.map { $0.name.count }.max() ?? 5
        for one in Self.actions {
            let pad = String(repeating: " ", count: width - one.name.count)
            print("    " + r.style.ink(.accent, "grux meeting " + one.name) + pad
                  + "   " + r.style.ink(.dim, one.does))
        }
        leave(.failed)
    }

    // MARK: - list

    private func listRecorded(_ frame: Frame) {
        let r = frame.renderer
        let rows = Self.recordedRows()

        if json {
            let out = rows.prefix(max(1, limit)).map { $0.machineReadable }
            if let d = try? JSONSerialization.data(withJSONObject: Array(out),
                                                   options: [.prettyPrinted, .sortedKeys]),
               let t = String(data: d, encoding: .utf8) { print(t) }
            leave(.done)
        }

        frame.open(.look, "Read straight from the meeting files on this Mac, so this answers "
                          + "whether or not Grux is running.")

        guard !rows.isEmpty else {
            // THE EMPTY STATE IS THE NORMAL ONE for anybody who has not recorded yet, so it
            // must not read like a failure. Two wordings, because a missing folder means
            // Grux has never got as far as making one.
            let exists = FileManager.default.fileExists(atPath: Self.meetingsDir.path)
            print(r.prose(exists
                ? "No meetings yet. Grux keeps them in \(Self.tilde(Self.meetingsDir.path)) "
                  + "and that folder is empty."
                : "No meetings yet. Grux has not recorded one on this Mac, so the folder it "
                  + "keeps them in does not exist."))
            print("")
            print(r.style.ink(.dim, r.prose("grux meeting start records one. It asks first.",
                                            indent: 2)))
            leave(.done)
        }

        let shown = Array(rows.prefix(max(1, limit)))
        let stamps = shown.map { Self.stamp($0.startedAt) }
        let stampWidth = stamps.map(\.count).max() ?? 0
        let details = shown.map { row -> String in
            let length = row.endedAt.map { Self.spell($0.timeIntervalSince(row.startedAt)) }
                ?? "no end time"
            guard let lines = row.utteranceCount, lines > 0 else { return length }
            return length + " · " + "\(lines) line\(lines == 1 ? "" : "s")"
        }

        // THE GRID IS SIZED FROM THE WIDEST LABEL PRESENT, never a guess, and the title is
        // the only part that can run long, so it is the only part clipped. Clipped on a
        // terminal, whole in a pipe: a title is data and a machine reading this wants it.
        let detailWidth = details.map(\.count).max() ?? 0
        let room = max(16, r.style.width - stampWidth - detailWidth - 12)
        let titles = shown.map { row -> String in
            let t = row.label
            guard r.style.isTTY, t.count > room else { return t }
            return String(t.prefix(room - 1)) + "\u{2026}"
        }
        let labels = zip(stamps, titles).map { stamp, title in
            stamp + String(repeating: " ", count: stampWidth - stamp.count) + "  " + title
        }
        let labelWidth = labels.map(\.count).max() ?? 20

        var unfinished = 0
        for (i, row) in shown.enumerated() {
            let live = row.endedAt == nil
            if live { unfinished += 1 }
            print(r.row(state: live ? .needed : .satisfied, label: labels[i],
                        detail: details[i], labelWidth: labelWidth, indent: 2))
        }

        print("")
        print(r.legend(unfinished > 0 ? [.satisfied, .needed] : [.satisfied]))
        print("")
        // THE COUNT MATCHES THE LIST ABOVE. Saying "12 meetings" over ten rows is the shape
        // that sends somebody looking for two that were never missing.
        let total = rows.count
        print(r.prose(total == shown.count
            ? "\(total) meeting\(total == 1 ? "" : "s"), newest first."
            : "\(total) meetings, showing the newest \(shown.count)."))

        if unfinished > 0 {
            print("")
            // ONE SHAPE ON DISK, TWO FACTS, and only the app can tell them apart. So this
            // says what each one is instead of promising one command fixes both: stop ends
            // a live capture and has nothing to end for a leftover, and sending somebody to
            // run it against a leftover buys them "nothing was stopped" and no more.
            print(r.prose("\(unfinished == 1 ? "One of them has" : "\(unfinished) have") no "
                + "end time. That is what a recording still running looks like on disk, and "
                + "also what a Grux that quit mid meeting leaves behind. grux meeting stop "
                + "ends a live one. A leftover keeps whatever it had already written.",
                indent: 2))
        }
        if total > shown.count {
            print("")
            print(r.style.ink(.dim, r.prose("grux meeting list --limit \(total) for all of "
                                            + "them.", indent: 2)))
        }
        leave(.done)
    }

    // MARK: - start

    private func startRecording(_ frame: Frame) {
        let r = frame.renderer

        // ---- LOOK. The two gates, from the document the app writes. -----------------------
        //
        // THE APP IS ASKED TO RECOMPUTE FIRST, exactly as grux status does it. Both gates
        // are answered where no terminal can see: a TCC grant in System Settings, the
        // consent in a dialog inside Grux, and Settings > "Ask me again" takes the consent
        // back. The document only says what was true when it was last written, and this is
        // the one command where reading a stale yes starts a microphone. Free to do here
        // because the command already refuses unless the app is running.
        //
        // A SHORT DEADLINE, and a different client from the 120 second one that starts the
        // recording below. Recomputing capabilities is a fast call, and an app too busy to
        // answer it must not turn the first beat into a two minute silence. Not required to
        // succeed either: the file is read whatever happens and the line below states its age.
        let refresher = ControlClient()
        if refresher.isAvailable { _ = refresher.call(tool: "grux_refresh_status") }

        let status: SetupStatus
        switch SetupStatusReader.read() {
        case .success(let s): status = s
        case .failure(let e): leave(frame.explain(e))
        }

        guard let mic = Lookup.capability("perm.microphone", in: status),
              let consent = Lookup.capability("step.recording_consent_acknowledged",
                                              in: status) else {
            frame.open(.look)
            print(r.prose("Grux wrote a setup status with no microphone row or no recording "
                + "consent row in it, so this command cannot tell whether starting is safe, "
                + "and it will not guess about a microphone."))
            print("")
            print(r.style.ink(.dim, r.prose("Run grux doctor.", indent: 2)))
            leave(.selfRepairAvailable)
        }
        let audio = Lookup.capability("perm.system_audio", in: status)

        // FRESHNESS IS PART OF THE ANSWER. This is a document another process wrote, and a
        // grant revoked in System Settings since then is not in it.
        let age = SetupStatusReader.age(of: status).map { "Grux last looked " + Self.ago($0) }
            ?? "Grux does not say when it last looked"
        frame.open(.look, "\(age). The first two have to be answered before anything records, "
                          + "and only Grux itself can ask for either.")

        let gates = [mic, consent] + (audio.map { [$0] } ?? [])
        let width = gates.map(\.label.count).max() ?? 20
        for cap in gates {
            print(r.row(state: cap.satisfied ? .satisfied : .needed, label: cap.label,
                        detail: cap.id, labelWidth: width, indent: 2))
        }
        print("")
        print(r.legend([.satisfied, .needed]))

        let missing = [mic, consent].filter { !$0.satisfied }
        if !missing.isEmpty {
            print("")
            // EXIT 2, AND IT IS THE REAL KIND. Neither of these can be answered from a
            // terminal: TCC keys a grant to the app that asks for it, and the consent is a
            // dialog inside Grux. No invocation of this command succeeds until a person
            // clicks something on this Mac.
            print(r.prose("Nothing was recorded. "
                + r.list(missing.map(\.label)) + (missing.count == 1 ? " is" : " are")
                + " still waiting on you, and only Grux itself can ask."))
            for cap in missing {
                if let why = cap.remediation, !why.isEmpty {
                    print("")
                    print(r.prose(why, indent: 4))
                }
            }
            print("")
            print(r.style.ink(.dim, r.prose("grux permissions shows every grant and who is "
                + "asking for it. Open Grux to answer them.", indent: 2)))
            leave(.waitingOnYou)
        }

        if let audio, !audio.satisfied {
            print("")
            print(r.prose("\(audio.label) is not granted, so Grux will capture your "
                + "microphone and not the other side of the call. macOS grants it under "
                + "Screen Recording, and Grux asks for it when the recording starts.",
                indent: 2))
        }

        let client = ControlClient(timeout: 120)
        guard client.isAvailable else {
            print("")
            print(r.prose("Grux is not running, and only the app can hold a microphone. Open "
                          + "Grux and run this again."))
            leave(.failed)
        }

        // ---- COST. What is captured, and where it lands, before anybody is asked. ---------
        frame.open(.cost, "This records the room until you stop it.")
        print(r.prose("Grux captures both sides: your microphone and everything this Mac "
            + "plays. Everyone on the call is recorded, and Grux has no way to tell them. It "
            + "transcribes here on this Mac, and when you stop, the transcript is sent out "
            + "to write the summary."))
        print("")
        print(r.row(state: .satisfied, label: "Transcript",
                    detail: Self.tilde(Self.meetingsDir.path) + "/", labelWidth: 10, indent: 4))
        print(r.row(state: .satisfied, label: "Audio",
                    detail: Self.tilde(Self.audioDir.path) + "/", labelWidth: 10, indent: 4))
        print("")
        print(r.style.ink(.dim, r.prose("Both stay in those folders until you move them. "
            + "grux meeting stop ends the recording and writes the summary.", indent: 2)))

        if !yes {
            guard !noInput, RawMode.isSupported else {
                print("")
                print(r.prose(noInput
                    ? "You passed --no-input and this starts a recording, so pass --yes as "
                      + "well if you are sure."
                    : "Nothing is attached to this terminal, so there is nobody to ask: pass "
                      + "--yes if you are sure."))
                leave(.failed)
            }
            // TYPED, not a keystroke. `y` is muscle memory and this puts a microphone into a
            // room with other people in it, so the word has to be chosen rather than reached
            // for. Case insensitively: a capital letter is not a different decision.
            let typed = InputPolicy.ask([
                "",
                "  Type record to confirm, or anything else to stop.",
                "  " + r.style.ink(.accent, "record"),
                "",
            ])
            guard typed.lowercased() == "record" else {
                print("")
                print(r.prose("Left everything alone. Nothing was recorded."))
                leave(.done)
            }
        }

        // ---- The write, through the app. -------------------------------------------------
        switch client.call(tool: "grux_meeting", arguments: ["action": "start"]) {
        case .failure(let why):
            frame.open(.prove)
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            renderStart(text, frame: frame)
        }
    }

    private func renderStart(_ text: String, frame: Frame) {
        let r = frame.renderer
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any] else {
            frame.open(.prove)
            print(r.prose(text))
            leave(.failed)
        }
        let title = (obj["title"] as? String) ?? "Meeting"

        switch (obj["outcome"] as? String) ?? "" {
        case "already":
            // NOT A SECOND RECORDING, and not an error either. The one that is running is
            // the answer to the question that was asked.
            frame.open(.prove, "Grux was already recording, so nothing new was started.")
            let elapsed = (obj["elapsed"] as? String) ?? ""
            let width = elapsed.isEmpty ? 9 : 11
            // A CAPTURE THAT IS STILL STARTING HAS NO RECORD YET, so there is no title to
            // show and printing a placeholder one would invent a meeting. The app sends a
            // note instead, and that is the whole answer in that case.
            if (obj["id"] as? String)?.isEmpty == false {
                print(r.row(state: .satisfied, label: "Recording", detail: title,
                            labelWidth: width, indent: 2))
            }
            if !elapsed.isEmpty {
                print(r.row(state: .satisfied, label: "Running for", detail: elapsed,
                            labelWidth: width, indent: 2))
            }
            if let note = obj["note"] as? String, !note.isEmpty {
                print(r.prose(note))
            }
            print("")
            print(r.style.ink(.dim, r.prose("grux meeting stop ends it.", indent: 2)))
            leave(.done)

        case "declined":
            // A DECISION, NOT A FAILURE, and the same one as typing anything but `record` at
            // the prompt above, so it leaves the same way.
            frame.open(.prove)
            print(r.prose((obj["why"] as? String) ?? "Nothing was recorded."))
            leave(.done)

        case "blocked":
            frame.open(.prove)
            print(r.prose((obj["why"] as? String)
                ?? "Grux would not start the recording and did not say why."))
            print("")
            print(r.style.ink(.dim, r.prose("grux permissions shows every grant and who is "
                + "asking for it.", indent: 2)))
            leave(.waitingOnYou)

        case "started":
            frame.open(.prove, "Recording. Everyone in the room is being recorded.")
            let rows: [(String, String?, RowState)] = [
                ("Recording", title, .satisfied),
                ("Started", (obj["startedAt"] as? String).map(Self.readable), .satisfied),
                ("Transcript", (obj["transcript"] as? String).map(Self.tilde), .satisfied),
                ("Audio", (obj["audio"] as? String).map(Self.tilde), .satisfied),
            ]
            let present = rows.filter { $0.1?.isEmpty == false }
            let width = present.map { $0.0.count }.max() ?? 10
            for (label, detail, state) in present {
                print(r.row(state: state, label: label, detail: detail, labelWidth: width,
                            indent: 2))
            }
            if (obj["audioKept"] as? Bool) == false {
                print(r.row(state: .skipped, label: "Audio",
                            detail: "not kept, meeting audio is off in Settings",
                            labelWidth: width, indent: 2))
            }
            print("")
            print(r.prose("grux meeting stop ends it, writes the transcript and asks for a "
                          + "summary."))
            if let id = obj["id"] as? String, !id.isEmpty {
                print("")
                print(r.style.ink(.dim, r.prose(id, indent: 2)))
            }
            leave(.done)

        default:
            // AN ANSWER WITH NO OUTCOME IN IT IS NOT A RECORDING. Reporting one because the
            // call did not fail is how a command claims something it never established, and
            // this is the one command where that claim matters most.
            frame.open(.prove)
            print(r.prose(frame.explain(ControlClient.Failure.badAnswer(text))))
            leave(.failed)
        }
    }

    // MARK: - stop

    private func stopRecording(_ frame: Frame) {
        let r = frame.renderer
        let client = ControlClient(timeout: 120)

        guard client.isAvailable else {
            // NOTHING TO DO HERE, NOT AN ERROR. A capture cannot outlive the app that holds
            // the microphone, so a Grux that is not running is not recording.
            frame.open(.look)
            print(r.prose("Grux is not running, so nothing is being recorded and there is "
                          + "nothing to stop."))
            printUnfinishedHint(r)
            leave(.done)
        }

        frame.open(.look, "Ending the recording and writing down what it heard. The summary "
                          + "can take a moment.")
        switch client.call(tool: "grux_meeting", arguments: ["action": "stop"]) {
        case .failure(let why):
            frame.open(.prove)
            print(r.prose(frame.explain(why)))
            leave(.failed)
        case .success(let text):
            renderStop(text, frame: frame)
        }
    }

    private func renderStop(_ text: String, frame: Frame) {
        let r = frame.renderer
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any] else {
            frame.open(.prove)
            print(r.prose(text))
            leave(.failed)
        }

        switch (obj["outcome"] as? String) ?? "" {
        case "nothing-running":
            frame.open(.prove)
            print(r.prose("Nothing was recording, so nothing was stopped."))
            printUnfinishedHint(r)
            leave(.done)

        case "starting":
            frame.open(.prove)
            print(r.prose((obj["why"] as? String)
                ?? "A recording is still starting up, so there is nothing to stop yet. Run "
                 + "this again in a moment."))
            leave(.failed)

        case "stopped":
            frame.open(.prove, "Stopped. It is written down.")
            var rows: [(String, String)] = []
            if let title = obj["title"] as? String, !title.isEmpty {
                rows.append(("Recorded", title))
            }
            if let seconds = obj["durationSeconds"] as? Int {
                rows.append(("Ran for", Self.spell(TimeInterval(seconds))))
            }
            if let lines = obj["utterances"] as? Int {
                // ZERO IS A REAL ANSWER and the one worth saying out loud: a meeting that
                // heard nothing usually means the wrong input or a muted microphone, and
                // "0 lines" beside "Stopped" reads like success until you go looking.
                rows.append(("Heard", lines == 0
                    ? "nothing, so there is no transcript to read"
                    : "\(lines) line\(lines == 1 ? "" : "s")"))
            }
            if let speakers = obj["speakers"] as? [String], !speakers.isEmpty {
                rows.append(("Voices", r.list(speakers)))
            }
            if let path = obj["transcript"] as? String, !path.isEmpty {
                rows.append(("Transcript", Self.tilde(path)))
            }
            if let path = obj["audio"] as? String, !path.isEmpty {
                rows.append(("Audio", Self.tilde(path)))
            }
            let width = rows.map { $0.0.count }.max() ?? 10
            for (label, detail) in rows {
                print(r.row(state: .satisfied, label: label, detail: detail,
                            labelWidth: width, indent: 2, detailIsTheAnswer: true))
            }

            if let summary = obj["summary"] as? String, !summary.isEmpty {
                print("")
                print(r.rule())
                print("")
                print(r.prose(summary))
            }
            if let items = obj["actionItems"] as? [String], !items.isEmpty {
                print("")
                print("  " + r.heading("WHAT WAS PROMISED"))
                for item in items { print(r.prose(item, indent: 4)) }
            }
            // Said only when there WAS something to summarise. Beside a meeting that heard
            // nothing it would explain the wrong absence, and the row above already accounts
            // for that one.
            if (obj["summary"] as? String)?.isEmpty != false,
               (obj["utterances"] as? Int ?? 0) > 0 {
                print("")
                print(r.style.ink(.dim, r.prose("No summary was written. That happens when no "
                    + "model provider is connected, and the transcript is there either way.",
                    indent: 2)))
            }
            leave(.done)

        default:
            frame.open(.prove)
            print(r.prose(frame.explain(ControlClient.Failure.badAnswer(text))))
            leave(.failed)
        }
    }

    /// The leftover a Grux that quit mid recording leaves behind, mentioned only when there
    /// is one. Saying "nothing to stop" beside a meeting on disk with no end time is true
    /// and unhelpful, because that file is exactly what somebody is worried about.
    private func printUnfinishedHint(_ r: Renderer) {
        let open = Self.recordedRows().filter { $0.endedAt == nil }
        guard let newest = open.first else { return }
        let head = open.count == 1
            ? "One meeting on disk has no end time, from \(Self.stamp(newest.startedAt))."
            : "\(open.count) meetings on disk have no end time, the newest from "
              + "\(Self.stamp(newest.startedAt))."
        print("")
        print(r.prose(head + " A Grux that quit mid recording leaves that behind, and the "
            + "transcript it did write is still there.", indent: 2))
    }

    // MARK: - The files on disk

    static var meetingsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux/meetings")
    }

    static var audioDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grux/meeting-audio")
    }

    /// One shape for both files the app writes.
    ///
    /// The index rows carry `utteranceCount` and `summaryExcerpt`; a full record carries
    /// `summary` and the utterances themselves. Decoding both through one lenient struct is
    /// what lets the fallback scan below produce the same list as the fast path, rather than
    /// a second list that renders differently.
    struct Row: Decodable {
        let id: String
        let startedAt: Date
        var endedAt: Date?
        var title: String?
        var sourceAppName: String?
        var utteranceCount: Int?
        var summaryExcerpt: String?
        var summary: String?

        var label: String {
            if let title, !title.isEmpty { return title }
            if let app = sourceAppName, !app.isEmpty { return "Meeting · \(app)" }
            return "Meeting"
        }

        var machineReadable: [String: Any] {
            var out: [String: Any] = ["id": id, "startedAt": Meeting.iso(startedAt)]
            if let endedAt {
                out["endedAt"] = Meeting.iso(endedAt)
                out["durationSeconds"] = Int(endedAt.timeIntervalSince(startedAt))
            }
            if let title, !title.isEmpty { out["title"] = title }
            if let sourceAppName, !sourceAppName.isEmpty { out["sourceApp"] = sourceAppName }
            if let utteranceCount { out["utterances"] = utteranceCount }
            if let s = summaryExcerpt ?? summary, !s.isEmpty { out["summary"] = s }
            return out
        }
    }

    /// Every meeting on disk, newest first.
    ///
    /// The index is the fast path and the whole reason the app keeps one. It is also written
    /// by a process that can be killed between saving a record and rebuilding the index, so
    /// it is trusted only while it still accounts for every file in the folder. When it does
    /// not, the records themselves are the truth and cost one decode each.
    static func recordedRows() -> [Row] {
        let fm = FileManager.default
        let dir = meetingsDir
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" } ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // what Persistence.save writes

        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let indexed = try? decoder.decode([Row].self, from: data),
           indexed.count == files.count {
            return indexed.sorted { $0.startedAt > $1.startedAt }
        }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Row.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Words for numbers

    /// A date somebody reads, in standard time. `14:32` is a column in a database.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM h:mm a"
        f.timeZone = .current
        return f.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// The app answers in ISO because that is what a machine reads back. A person does not,
    /// so it is turned round here rather than formatted twice on two sides of a socket.
    static func readable(_ isoString: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: isoString) else { return isoString }
        return stamp(date)
    }

    /// "41m 12s", not 2472. Hours appear only when there are any.
    static func spell(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// How old the status document is, as a sentence rather than a timestamp.
    static func ago(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 90 { return "just now" }
        if total < 3600 { return "\(total / 60) minutes ago" }
        if total < 86_400 {
            let h = total / 3600
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = total / 86_400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    /// A path is easier to check when it starts where the reader's home does.
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
