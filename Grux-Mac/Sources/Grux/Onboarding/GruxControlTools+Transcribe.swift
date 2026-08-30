import Foundation
import GruxMCPCore
import WhisperKit

// MARK: - grux_transcribe

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// One audio file, transcribed on this Mac's GPU, by the model the app already has open.
    ///
    /// ## WHY THIS RUNS IN THE APP AND NOT IN THE `grux` BINARY
    ///
    /// The binary carries no second copy of anything the app already has, and this is the
    /// command where that rule earns its keep. Grux links WhisperKit and keeps ONE loaded
    /// instance behind `AmbientListener.shared.sharedWhisperKit()`, shared by dictation,
    /// meeting capture and the corpus ingester. Doing this work in the CLI would mean
    /// linking a machine learning framework into a command line tool and downloading a
    /// SECOND several hundred megabyte model next to the one already on disk, which is the
    /// largest possible violation of that rule and buys nothing: the same recording could
    /// then come back with two different transcripts depending on which copy of Whisper
    /// happened to answer.
    ///
    /// So the samples are read here, decoded here, and never sent anywhere. Going through
    /// the app is what keeps the audio inside it.
    static func transcribe(path: String) async -> [String: Any] {
        let fm = FileManager.default
        let wanted = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !wanted.isEmpty else {
            return MCPWire.textFailure("Name the audio file to transcribe, as a full path.")
        }
        // ABSOLUTE OR REFUSED. Grux's working directory is wherever it was launched from and
        // never the shell the caller typed in, so a relative path here resolves against a
        // directory the caller has never seen: at best nothing is there, at worst a
        // different file with the same name is. `grux transcribe` makes the path absolute
        // before it calls, and anything else that does not is told rather than fed.
        guard wanted.hasPrefix("/") else {
            return MCPWire.textFailure("Give the file as a full path starting with a slash. "
                + "\(wanted) is relative, and Grux would resolve it against its own working "
                + "directory rather than yours.")
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: wanted, isDirectory: &isDirectory) else {
            return MCPWire.textFailure("There is no file at \(wanted).")
        }
        guard !isDirectory.boolValue else {
            return MCPWire.textFailure("\(wanted) is a folder. Name one recording inside it.")
        }
        guard fm.isReadableFile(atPath: wanted) else {
            return MCPWire.textFailure("\(wanted) is there and Grux is not allowed to read "
                + "it. Check the file's own permissions, and whether it sits somewhere macOS "
                + "guards, such as another account's home folder.")
        }

        let name = (wanted as NSString).lastPathComponent
        let bytes = ((try? fm.attributesOfItem(atPath: wanted))?[.size] as? Int) ?? 0
        let looked = looksLike(name: name, bytes: bytes)

        // WhisperKit's own loader, the one the meeting and corpus paths already use, so a
        // file that transcribes here transcribes there. Whatever the container was, what
        // comes back is 16 kHz mono float samples.
        //
        // OFF THE MAIN ACTOR, and that is not a style choice. Every tool handler runs on the
        // main actor, this loader is synchronous, and it decodes and resamples the WHOLE
        // file before it returns, so a two hour recording would hold the app's UI still for
        // as long as that takes. The corpus ingester runs it inside an actor for the same
        // reason. What follows it, `kit.transcribe`, is a non-isolated async function and
        // already leaves the main actor on its own.
        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .userInitiated) {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: wanted)
            }.value
        } catch {
            return MCPWire.textFailure("Nothing in \(name) decoded as audio. \(looked) Grux "
                + "reads what AVFoundation reads: m4a, wav, mp3, caf, aiff and aac.")
        }

        let seconds = Double(samples.count) / Double(WhisperKit.sampleRate)
        // HALF A SECOND IS WHISPER'S OWN FLOOR, the same one `MeetingTranscriber` holds:
        // under it the model returns filler rather than nothing, so a file this short would
        // come back with words in it that nobody said.
        guard seconds >= 0.5 else {
            if samples.isEmpty {
                return MCPWire.textFailure("\(name) opened as audio and there are no samples "
                    + "in it. \(looked)")
            }
            return MCPWire.textFailure("\(name) holds \(String(format: "%.1f", seconds)) "
                + "seconds of audio, which is too short to transcribe. Whisper needs half a "
                + "second.")
        }

        // THE ONE SHARED INSTANCE. This loads the model when nothing has yet, which on a
        // fresh install is a download of a few hundred megabytes and takes minutes. The CLI
        // says so before it calls, because a wait nobody explained looks like a hang.
        guard let kit = await AmbientListener.shared.sharedWhisperKit() else {
            return MCPWire.textFailure("Grux could not load the speech model, so nothing was "
                + "transcribed and nothing was sent anywhere. The first load fetches it and "
                + "needs the network once. grux doctor checks the rest of the speech setup.")
        }

        // The same decode settings the corpus ingester uses on files, prompt biasing
        // included, so uncommon words this Mac hears every day come back spelled right.
        let promptTokens = WhisperVocab.buildPromptTokens(tokenizer: kit.tokenizer)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            promptTokens: promptTokens
        )

        let began = Date()
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        } catch {
            return MCPWire.textFailure("Whisper stopped partway through \(name): "
                + "\(error.localizedDescription). Nothing was written and nothing left this "
                + "Mac. Running it again is safe.")
        }
        let took = Date().timeIntervalSince(began)

        // STRIPPED PER SEGMENT, not once over the joined transcript, and that is the whole
        // point of doing it here. `stripSpecials` removes the special tags and the filler
        // Whisper invents over silence ("Thanks for watching."), and that filler arrives as
        // its OWN segment at the tail of a recording where the speaker has stopped talking.
        // Run over the joined text the junk list can only fire when the entire transcript is
        // filler, which is the short case rather than the common one.
        let text = results
            .flatMap { $0.segments }
            .map { VoiceRecordingsIngester.stripSpecials($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // AN EMPTY TRANSCRIPT IS AN ANSWER, not a failure. Silence transcribes to nothing,
        // and the caller is told how much audio produced that nothing so it can tell this
        // apart from a file it pointed at by mistake.
        let body: [String: Any] = [
            "file": wanted,
            "text": text,
            "words": text.split(separator: " ").count,
            "audio_seconds": (seconds * 10).rounded() / 10,
            "took_seconds": (took * 10).rounded() / 10,
            "model": "\(kit.modelVariant)",
        ]
        return MCPWire.textResult(jsonText(body))
    }

    /// What the file LOOKED like, for a refusal that has to say why without guessing.
    ///
    /// "That is not audio" on its own leaves somebody staring at a filename. The size and
    /// the extension are the two facts that usually settle it: a 4 KB `.wav` is a header
    /// with nothing behind it, and a 2 MB `.png` is a screenshot that was dragged in.
    private static func looksLike(name: String, bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty
            ? "It is \(size) and has no extension."
            : "It is \(size) and its extension is .\(ext)."
    }
}
