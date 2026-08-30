import Foundation
import WhisperKit

// Transcribes the user's voice recordings via the existing WhisperKit path and
// indexes the transcripts (the user speaking their mind, spoken-voice corpus).
//
// Drop zone: ~/.grux/jax/voice/ (drop .m4a / .wav / .mp3 / .caf voice memos
// here). We load each file as a 16 kHz Float array with WhisperKit's own
// AudioProcessor.loadAudioAsFloatArray (the same loader the meeting/dictation
// paths feed), then run kit.transcribe(audioArray:) with the identical
// DecodingOptions + WhisperVocab prompt biasing used by VoiceInput so uncommon
// vocabulary words ("Grux", "WhisperKit") transcribe correctly.
//
// Model: we reuse the SAME medium.en model VoiceInput downloads (shared on-disk
// cache, so no second download). To avoid mic contention we never start a
// capture; this is file transcription only and runs off the main actor.
//
// Soft dependency: if the integrator exposes VoiceInput's loaded WhisperKit, we
// could borrow it. Until then this ingester lazily loads its own instance from
// the shared model cache. Either way nothing leaves the device.
actor VoiceRecordingsIngester: CorpusIngester {
    nonisolated let source: CorpusSource = .voiceRecording

    private let rag: RAGClient
    private var ledger: CorpusLedger
    private var kit: WhisperKit?

    private let modelName = "openai_whisper-medium.en"
    private let modelRepo = "argmaxinc/whisperkit-coreml"
    private let audioExtensions: Set<String> = ["m4a", "wav", "mp3", "caf", "aiff", "aac"]

    static var voiceDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("jax")
            .appendingPathComponent("voice")
    }

    init(rag: RAGClient) {
        self.rag = rag
        self.ledger = CorpusLedger.load(source: .voiceRecording)
    }

    func probe() async -> CorpusPermission {
        let dir = Self.voiceDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.contains(where: { audioExtensions.contains($0.pathExtension.lowercased()) }) ? .ready : .noData
    }

    func ingest() async -> CorpusRunResult {
        let dir = Self.voiceDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let recordings = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !recordings.isEmpty else { return .blocked(.noData) }

        guard let kit = await loadKit() else {
            return CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown,
                                   note: "Whisper model not loaded; check first-run download")
        }

        let promptTokens = await MainActor.run { WhisperVocab.buildPromptTokens(tokenizer: kit.tokenizer) }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            promptTokens: promptTokens
        )

        var indexed = 0, skipped = 0
        var docs: [RAGClient.Document] = []

        for file in recordings {
            // Dedupe on path + size + mtime so an unchanged file is skipped but a
            // replaced one re-transcribes.
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = "voice-\(file.lastPathComponent)-\(size)-\(Int(mtime))"
            guard ledger.insert(key) else { skipped += 1; continue }

            guard let samples = try? AudioProcessor.loadAudioAsFloatArray(fromPath: file.path), !samples.isEmpty else {
                WakeLog.shared.log("corpus[voice]: could not load \(file.lastPathComponent)")
                skipped += 1
                continue
            }

            do {
                let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                let text = results.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = Self.stripSpecials(text)
                guard cleaned.count >= 12 else { skipped += 1; continue }

                let ts = Int(mtime * 1000)
                await MainActor.run {
                    CorpusIndexer.indexLocal(source: .voiceRecording, text: cleaned, timestampMillis: ts,
                                             extraMetadata: ["file": file.lastPathComponent])
                }
                docs.append(RAGClient.Document(
                    id: CorpusIndexer.docId(source: .voiceRecording, key: key),
                    source: "idea",
                    text: cleaned,
                    ts: ts / 1000,
                    brandHint: ""
                ))
                indexed += 1
            } catch {
                WakeLog.shared.log("corpus[voice]: transcribe failed for \(file.lastPathComponent): \(error)")
                skipped += 1
            }
        }

        let pushed = await CorpusIndexer.pushToRAG(rag, source: .voiceRecording, docs: docs)
        ledger.save(source: .voiceRecording)
        return CorpusRunResult(indexed: indexed, pushedToRAG: pushed, skipped: skipped, permission: .ready,
                               note: "Transcribed \(indexed) recordings (\(skipped) skipped)")
    }

    private func loadKit() async -> WhisperKit? {
        if let kit { return kit }
        do {
            let config = WhisperKitConfig(
                model: modelName,
                modelRepo: modelRepo,
                verbose: false,
                prewarm: false,
                load: true,
                download: true
            )
            let loaded = try await WhisperKit(config)
            self.kit = loaded
            return loaded
        } catch {
            WakeLog.shared.log("corpus[voice]: WhisperKit load failed: \(error)")
            return nil
        }
    }

    // Same special-tag stripping VoiceInput applies on silence/hallucination.
    static func stripSpecials(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"\[[A-Z_ ]+\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<\|[^>]*\|>"#, with: "", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk: Set<String> = ["thanks for watching.", "thank you.", "you", ".", "..", "..."]
        return junk.contains(out.lowercased()) ? "" : out
    }
}
