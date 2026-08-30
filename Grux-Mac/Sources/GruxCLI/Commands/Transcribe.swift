import ArgumentParser
import Foundation
import GruxSetupCore

// MARK: - grux transcribe

/// Speech to text, on this Mac, by the model Grux already has open.
///
/// ## The transcript is the payload, so it goes out on its own
///
/// `grux transcribe interview.m4a > interview.txt` has to leave a file with a transcript in
/// it and nothing else, so on anything that is not a terminal the rail, the rows and the
/// machine detail are all dropped and the text is the entire output. On a terminal the
/// answer still comes first and the numbers under it are dimmed, because the person reading
/// them wanted the words.
///
/// ## Why this asks the app rather than transcribing here
///
/// Grux has WhisperKit linked and one model loaded already. This binary carries no second
/// copy of anything, and a machine learning framework plus a second several hundred megabyte
/// download is the largest second copy there is. So the audio is read, decoded and forgotten
/// inside the app, and nothing about it goes anywhere near a network.
struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file, on this Mac.",
        discussion: """
            The transcript prints on its own, so a redirect gives you a clean file.

              grux transcribe interview.m4a > interview.txt
              grux transcribe ~/Desktop/standup.wav --out standup.txt

            It runs on this Mac's GPU, on the speech model Grux already uses for dictation. \
            The audio is never uploaded, and there is no second model to download.
            """)

    @Argument(help: "The audio file. A relative path is fine, this makes it absolute.")
    var file: String?

    @Option(name: .long, help: "Write the transcript here instead of printing it.")
    var out: String?

    /// The capability the app measures for "is the speech model on this Mac", written into
    /// the status document at launch. Read rather than re-measured: the model's location is
    /// the app's fact and a second copy of the path here would be a second thing to keep in
    /// step with WhisperKit's cache layout.
    static let speechModel = "step.speech_model_downloaded"

    /// THIRTY MINUTES, AND THE DEFAULT TEN SECONDS WOULD REPORT FAILURE OVER SUCCESS.
    ///
    /// Every other command asks the app something it answers from memory. This one decodes
    /// audio and runs it through Whisper, which is minutes of work on an hour of tape, and on
    /// a fresh install the FIRST call downloads a few hundred megabytes of model before any
    /// of that starts. A deadline that expires prints "Grux did not answer" over work that is
    /// still running and will finish, which is the worst kind of wrong: a report of failure
    /// about a success, on a command somebody will now run twice.
    static let deadline: TimeInterval = 1800

    /// Accepted by every command, and it means one thing on all of
    /// them. See InputPolicy.
    @OptionGroup var input: InputPolicy

    func run() throws {
        let frame = Frame()
        let r = frame.renderer

        let typed = (file ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            // A designed empty state rather than a usage dump. Somebody who typed the command
            // and nothing else knows what transcribing is, they just have not named a file.
            frame.open(.look)
            print(r.prose("Nothing to transcribe. Name an audio file and Grux reads it here, "
                          + "on this Mac."))
            print("")
            print("    " + r.style.ink(.accent, "grux transcribe interview.m4a"))
            leave(.failed)
        }

        let url = Self.absolute(typed)
        let fm = FileManager.default

        // EVERY FILE ANSWER IS FOUND HERE, before the socket, because all of them are true
        // with Grux closed and none of them are worth a thirty minute deadline to discover.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            frame.open(.look)
            print(r.prose("There is no file at \(url.path)."))
            let near = Self.nearest(url)
            if !near.isEmpty {
                print("")
                print(r.prose("Did you mean " + r.list(near) + "?"))
            }
            leave(.failed)
        }
        guard !isDirectory.boolValue else {
            frame.open(.look)
            print(r.prose("\(url.path) is a folder, and this transcribes one file. Name the "
                          + "recording inside it."))
            leave(.failed)
        }
        guard fm.isReadableFile(atPath: url.path) else {
            frame.open(.look)
            print(r.prose("\(url.path) is there and this Mac will not let it be read."))
            print("")
            print(r.style.ink(.dim, r.prose("Check the file's own permissions, and whether it "
                + "belongs to another account on this Mac.", indent: 2)))
            leave(.failed)
        }

        let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let client = ControlClient(timeout: Self.deadline)

        // Whether the model is already here, off disk, so the wait can be EXPLAINED BEFORE IT
        // HAPPENS. The status document is a cache of the app's own answer, so failing to read
        // it costs the row and the certainty, never the transcription: the file is still
        // there and the app is still the thing that knows. That is why this is not the usual
        // `leave(frame.explain(e))`.
        var modelHere: Bool?
        if case .success(let status) = SetupStatusReader.read() {
            modelHere = Lookup.capability(Self.speechModel, in: status)?.satisfied
        }

        // The frame is for a person. With --out the transcript went to the file, so what is
        // left on stdout is a report either way and it keeps its frame.
        let decorated = r.style.isTTY || out != nil
        if decorated {
            Self.look(frame: frame, url: url, bytes: bytes, modelHere: modelHere,
                      running: client.isAvailable, socket: client.socketPath)
        }

        switch client.call(tool: "grux_transcribe", arguments: ["path": url.path]) {
        case .failure(let why):
            print(r.prose(frame.explain(why)))
            if case .noAnswer = why {
                print("")
                // NOT "it failed". The app took the call and is very probably still decoding.
                print(r.style.ink(.dim, r.prose("This waits \(Int(Self.deadline / 60)) "
                    + "minutes, which a recording of several hours, or a first run fetching "
                    + "the model on a slow line, can outlast. Nothing was uploaded and your "
                    + "file is untouched, so running it again once Grux settles is safe.",
                    indent: 2)))
            }
            leave(.failed)

        case .success(let payload):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any],
                  let text = obj["text"] as? String else {
                // The app answered something this cannot lay out. Print it whole rather than
                // swallow it: it is still the app's answer and somebody can read it.
                print(r.prose(payload))
                leave(.failed)
            }
            let words = (obj["words"] as? Int) ?? text.split(separator: " ").count
            let audio = (obj["audio_seconds"] as? Double) ?? 0
            let took = (obj["took_seconds"] as? Double) ?? 0
            let model = (obj["model"] as? String) ?? ""
            let detail = Self.machine(r, audio: audio, words: words, model: model, took: took)

            if let out {
                let target = Self.absolute(out)
                do {
                    // One trailing newline, so the file ends the way a text file ends.
                    try (text + "\n").write(to: target, atomically: true, encoding: .utf8)
                } catch {
                    frame.open(.prove)
                    print(r.prose("Transcribed it, and could not write \(target.path): "
                                  + error.localizedDescription))
                    print("")
                    print(r.style.ink(.dim, r.prose("Those \(words) words are not saved "
                        + "anywhere. Run this again with a path you can write to, or without "
                        + "--out to print the transcript instead.", indent: 2)))
                    leave(.failed)
                }
                frame.open(.prove)
                print(r.row(state: .satisfied, label: "Written", detail: target.path,
                            labelWidth: 7, detailIsTheAnswer: true))
                print(r.row(state: words > 0 ? .satisfied : .skipped, label: "Words",
                            detail: "\(words)", labelWidth: 7, detailIsTheAnswer: true))
                print("")
                // Only the glyphs actually on screen. A legend for a state nothing printed
                // is a key to a map with no such symbol on it.
                let states: [RowState] = words > 0 ? [.satisfied] : [.satisfied, .skipped]
                print(r.legend(states))
                if words == 0 {
                    print("")
                    print(r.prose(Self.silence(audio)))
                }
                if r.style.isTTY {
                    print("")
                    print(r.style.ink(.dim, r.prose(detail, indent: 2)))
                }
                leave(.done)
            }

            guard decorated else {
                // The whole point of the redirect: the transcript, one newline, nothing else.
                print(text)
                leave(.done)
            }

            frame.open(.prove)
            guard !text.isEmpty else {
                print(r.row(state: .skipped, label: "No speech in it", labelWidth: 0))
                print("")
                print(r.prose(Self.silence(audio)))
                print("")
                print(r.style.ink(.dim, r.prose(detail, indent: 2)))
                leave(.done)
            }
            // THE ANSWER FIRST. Everything under the rule is a number about the answer.
            print(r.prose(text))
            print("")
            print(r.rule())
            print(r.style.ink(.dim, r.prose(detail, indent: 2)))
            leave(.done)
        }
    }

    // MARK: - LOOK

    /// What is already true, printed BEFORE the call, because the call can take minutes.
    private static func look(frame: Frame, url: URL, bytes: Int, modelHere: Bool?,
                             running: Bool, socket: String) {
        let r = frame.renderer
        frame.open(.look, "This runs on this Mac's GPU. The audio is never uploaded, and "
                        + "nothing is kept anywhere you did not ask for.")

        // Sized from the labels that will actually be printed. The speech model row is left
        // out when this Mac would not say, so it is left out of the grid too.
        var labels = ["File", "Size", "Grux is running"]
        if modelHere != nil { labels.append("Speech model") }
        let width = labels.map(\.count).max() ?? 15
        // Sized from where the path actually LANDS, which is not the same place on every
        // terminal. Below 60 columns the File row stacks its value on its own line at
        // indent 4 (Renderer.row, detailIsTheAnswer), so charging it for the label column
        // clips a path that had room: measured at COLUMNS=40, the clamp's floor, that is 17
        // characters kept out of the 36 the stacked line can hold.
        let room = r.style.isNarrow
            ? max(16, r.style.width - 4)
            : max(16, r.style.width - width - 8)
        // A path is clipped from the LEFT on a terminal and kept whole in a pipe: the end of
        // a path identifies it and the start is the same home directory every time.
        let shown = (r.style.isTTY && url.path.count > room)
            ? "\u{2026}" + String(url.path.suffix(room - 1)) : url.path
        // THE PATH AND THE SIZE ARE THE ANSWER HERE, so they stack rather than being dropped
        // with the machine detail below 60 columns. This screen exists to confirm which file
        // is about to take up to thirty minutes, and at COLUMNS=50 it printed "+ File" and
        // "+ Size" with no path and no number, which confirms nothing and leaves the size
        // available from no other line. The two rows under them keep the default: a
        // capability id and a socket path are detail beside a label that already said it.
        print(r.row(state: .satisfied, label: "File", detail: shown, labelWidth: width,
                    detailIsTheAnswer: true))
        print(r.row(state: .satisfied, label: "Size",
                    detail: ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                                      countStyle: .file),
                    labelWidth: width, detailIsTheAnswer: true))
        switch modelHere {
        case .some(true):
            print(r.row(state: .satisfied, label: "Speech model", detail: speechModel,
                        labelWidth: width))
        case .some(false):
            print(r.row(state: .needed, label: "Speech model", detail: speechModel,
                        labelWidth: width))
        case .none:
            // The status document would not read. Saying nothing about the model is honest;
            // guessing it is here, and then going quiet for ten minutes, is not.
            break
        }
        print(r.row(state: running ? .satisfied : .needed, label: "Grux is running",
                    detail: socket, labelWidth: width))
        print("")
        // Only the glyphs actually on screen, which is why this is read off the rows rather
        // than written out once and left to drift.
        let missing = (modelHere == false) || !running
        let states: [RowState] = missing ? [.satisfied, .needed] : [.satisfied]
        print(r.legend(states))

        guard let warning = firstRun(modelHere) else { return }
        print("")
        print(r.style.ink(.dim, r.prose(warning, indent: 2)))
    }

    /// The sentence that stops a first run looking like a hang.
    ///
    /// A download of a few hundred megabytes with no output is indistinguishable from a
    /// wedged command, and somebody who does not know it is coming kills it at the two minute
    /// mark and starts it again, which downloads nothing twice. So it is said in advance,
    /// including the case where this Mac would not say whether the model is here.
    private static func firstRun(_ modelHere: Bool?) -> String? {
        switch modelHere {
        case .some(true):
            return nil
        case .some(false):
            return "Grux has not fetched the speech model yet, so this run fetches it first. "
                 + "That is a few hundred megabytes and takes minutes on an ordinary "
                 + "connection, it happens once, and nothing prints until the transcript is "
                 + "ready."
        case .none:
            return "This Mac's setup status would not read, so whether the speech model is "
                 + "already here is not known. If it is not, this run fetches it first, which "
                 + "takes minutes and happens once."
        }
    }

    // MARK: - Words for the states underneath

    /// Silence, said as a result rather than as an error.
    private static func silence(_ audio: Double) -> String {
        "Whisper found nothing to transcribe in \(span(audio)) of audio. An empty transcript "
            + "is the honest answer to silence, so nothing was invented to fill it. If you "
            + "expected words, check that the recording has the microphone track in it."
    }

    /// The dim line under the answer: everything worth checking, nothing anybody has to read.
    private static func machine(_ r: Renderer, audio: Double, words: Int, model: String,
                                took: Double) -> String {
        var parts = [span(audio) + " of audio", words == 1 ? "1 word" : "\(words) words"]
        if !model.isEmpty { parts.append("Whisper \(model) on this Mac's GPU") }
        parts.append("done in " + span(took))
        return r.list(parts) + "."
    }

    private static func span(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    // MARK: - Paths

    /// An absolute path, resolved HERE.
    ///
    /// Grux's working directory is not this shell's, so a relative path sent over the socket
    /// would be resolved against a directory the person typing has never seen. Every path
    /// this command sends or writes goes through here.
    static func absolute(_ typed: String) -> URL {
        let expanded = (typed as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/")
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
        return URL(fileURLWithPath: full).standardizedFileURL
    }

    /// The closest filenames in the same folder, for a name that is nearly right.
    ///
    /// `Lookup.edits` is the same Levenshtein every other did-you-mean in this binary uses.
    /// `Lookup.nearest` itself is scoped to the capabilities in the status document, so only
    /// the distance is shared. A misspelt or half remembered filename is the ordinary way
    /// this command fails, and "no such file" on its own sends somebody back to ls.
    static func nearest(_ url: URL, limit: Int = 3) -> [String] {
        let wanted = url.lastPathComponent.lowercased()
        let folder = url.deletingLastPathComponent().path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        // Scaled to what was typed, so a miss on a short name does not suggest the whole
        // folder. The same cutoff Lookup.nearest uses on capability ids.
        let cutoff = max(2, wanted.count / 3)
        return names
            .filter { !$0.hasPrefix(".") }
            .map { (name: $0, distance: Lookup.edits(wanted, $0.lowercased())) }
            .filter { $0.distance <= cutoff }
            // CASE INSENSITIVE. A plain < on a String is an ASCII sort, which files every
            // lowercase name after every uppercase one.
            .sorted { ($0.distance, $0.name.lowercased()) < ($1.distance, $1.name.lowercased()) }
            .prefix(limit)
            .map { $0.name }
    }
}
