import Foundation
import AppKit
import ScreenCaptureKit
import WhisperKit

// Orchestrator. Owns the mic + system captures, the mixer, the transcriber,
// the in-flight MeetingRecord, and the wall-clock timer that drives chunk
// flushes and the "00:12:47 - capturing Zoom" menu-bar pill.
//
// Lifecycle:
//   start() → pause ambient → load / share WhisperKit → SCShareableContent
//             permission preflight → SystemAudioCapture.start + MeetingMicCapture.start
//             → timer flushes every `chunkSeconds` (10s) → transcribe → append
//   stop()  → flush remaining → stop captures → summarize → finalize record
//             → resume ambient
//
// This is the single observable-source-of-truth the UI subscribes to. Menu
// bar + panel read `isCapturing`, `activeMeeting`, `elapsedSeconds`, and the
// tail of `liveUtterances` for the rolling preview.
@MainActor
final class MeetingCaptureService: ObservableObject {
    static let shared = MeetingCaptureService()

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var isInitializing: Bool = false
    @Published private(set) var activeMeeting: MeetingRecord?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var liveUtterances: [MeetingUtterance] = []  // ring-buffered preview
    @Published private(set) var lastError: String?
    @Published var autoCaptureOffered: Bool = false   // UI consumes to show the banner

    // System-audio availability gate. macOS 14.0 SCStream audio is available
    // everywhere Grux supports. Kept as a computed property so the UI can show
    // a "requires 14.0+" notice on the off chance Grux is booted on an older
    // ventura slice (even though the bundle minimum already blocks that).
    var isSystemAudioSupported: Bool {
        if #available(macOS 14.0, *) { return true } else { return false }
    }

    private let systemAudio: SystemAudioCapture
    private let micCapture = MeetingMicCapture()
    private let mixer = MeetingAudioMixer(chunkSeconds: 10)
    private var transcriber: MeetingTranscriber?
    // Voice-based diarizer for in-room speakers. Fresh per meeting so cluster
    // numbering ("Speaker 1", "Speaker 2"...) resets correctly. Optional so
    // we can gate on the config flag without touching the hot path.
    private var diarizer: SpeakerDiarizer?
    // Diarization runs on the mic-only buffer (set by the mixer's onMicChunk
    // callback, popped alongside the mixed chunk's transcription below).
    private var pendingMicChunk: [Float]?

    // v2 name-detection: cluster UUID → [candidate name : count]. Fed by
    // SpeakerNameDetector on each utterance's text. A cluster with two
    // matching hints for the same name becomes a UI nudge ("call this
    // Speaker 2 'Sarah'?"). Exposed via `nameHint(for:)`.
    private var nameHints: [UUID: [String: Int]] = [:]

    // Streaming WAV writer for full-session audio export. One per active
    // meeting; opened on start(), every mixer chunk is appended, closed on
    // stop(). Separate from AudioWAL (which is a rolling crash-safe PCM log
    // retention-capped at ~90 s - useless for "save the whole meeting").
    private var meetingAudioStream: WAVWriter.Stream?

    private var elapsedTimer: Timer?
    private var flushTimer: Timer?
    private var transcribeInFlight = false

    // Auto-offer state. When we detect a meeting app becoming frontmost AND
    // capture isn't already running, we fire this once per app-enter event so
    // UI can surface a "Zoom detected - start capture?" confirmation. The
    // detector is cold-boot-started from GruxApp.
    private var pendingAutoOffer: (bundleId: String, name: String)?

    private init() {
        self.systemAudio = SystemAudioCapture()
        bindCaptureCallbacks()
        bindMeetingAppDetector()
    }

    private func bindCaptureCallbacks() {
        systemAudio.onSamples = { [weak self] samples in
            self?.mixer.appendSystem(samples)
        }
        systemAudio.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.lastError = error.localizedDescription
                WakeLog.shared.log("meeting: systemAudio error \(error.localizedDescription)")
                // If SCK fails mid-capture, stop gracefully so the user isn't
                // stuck in a half-broken state.
                await self?.stop()
            }
        }
        micCapture.onSamples = { [weak self] samples in
            self?.mixer.appendMic(samples)
        }
        mixer.onMicChunk = { [weak self] micSamples in
            // Arrives right BEFORE onMixedChunk for the same time window.
            // We stash it and the transcribe step reads it back so the
            // utterance we persist gets its diarization labels in a single
            // write - no late back-fill.
            self?.pendingMicChunk = micSamples
        }
        mixer.onMixedChunk = { [weak self] chunk in
            guard let self else { return }
            Task { @MainActor in
                // Persist the mixed PCM chunk to the WAL BEFORE we hand
                // it to Whisper. That way a crash during transcription
                // still leaves the audio durable on disk for recovery.
                if AppState.shared.config.crashSafeAudioEnabled {
                    AudioWAL.shared.appendChunk(chunk)
                }
                // Append to the full-session streaming WAV (for "Export
                // audio" in the meeting panel). Gated by the same
                // crash-safe toggle since both are local disk writes the user
                // opted into; keeps a single privacy lever.
                if AppState.shared.config.crashSafeAudioEnabled {
                    self.meetingAudioStream?.append(chunk)
                }
                self.transcribeChunk(chunk)
            }
        }
    }

    private func bindMeetingAppDetector() {
        MeetingAppDetector.shared.onMeetingAppEntered = { [weak self] bundleId, name in
            guard let self else { return }
            guard !self.isCapturing, !self.isInitializing else { return }
            self.pendingAutoOffer = (bundleId, name)
            self.autoCaptureOffered = true
            WakeLog.shared.log("meeting: auto-offer \(name)")
            // Push a passive hint via the orb so the user sees it without context-switching.
            OrbHintBus.shared.show(
                message: "\(name) detected - ⌘⇧M to record",
                state: .listening,
                duration: 5.0
            )
        }
        MeetingAppDetector.shared.onMeetingAppExited = { [weak self] in
            guard let self else { return }
            if !self.isCapturing { self.autoCaptureOffered = false }
        }
    }

    // Consumed by the menu-bar pill when the user clicks "Start".
    var pendingOffer: (bundleId: String, name: String)? { pendingAutoOffer }
    func clearPendingOffer() { pendingAutoOffer = nil; autoCaptureOffered = false }

    // MARK: - Lifecycle

    @discardableResult
    func start(title: String? = nil, sourceApp: String? = nil, sourceAppName: String? = nil) async -> MeetingRecord? {
        guard !isCapturing, !isInitializing else { return activeMeeting }
        guard isSystemAudioSupported else {
            lastError = "System audio capture requires macOS 14.0 or later."
            return nil
        }

        // Consent gate. Placed here, at the one function every path goes through, rather
        // than at the five call sites: the menu bar pill, the Meetings tab, the panel, the
        // keyboard shortcut, and the model-callable start_meeting_capture tool. Five gates
        // would be five chances to miss one, and the next caller written would miss it for
        // free. Same reasoning that put the capture-privacy check inside captureMainDisplay.
        //
        // Checked AFTER the cheap guards so a repeat call during an active capture, or on
        // an unsupported OS, does not put a dialog in front of someone for no reason.
        guard await RecordingConsent.ensureAcknowledged() else {
            lastError = "Recording needs your confirmation first."
            return nil
        }

        isInitializing = true
        defer { isInitializing = false }
        lastError = nil

        // Pause ambient listener so it releases the mic and its WhisperKit
        // is free. Returns immediately if ambient wasn't running.
        AmbientListener.shared.pauseForMeeting()

        // Resolve a WhisperKit instance. Prefer AmbientListener's; if that
        // isn't loaded, trigger a lazy load (cached after first use).
        guard let kit = await AmbientListener.shared.sharedWhisperKit() else {
            lastError = "Whisper model failed to load - check network + WhisperKit cache."
            AmbientListener.shared.resumeFromMeeting()
            return nil
        }
        self.transcriber = MeetingTranscriber(whisperKit: kit)
        // Fresh diarizer per meeting. Uses the shared profile store so
        // enrolled voices get labeled across every meeting.
        self.diarizer = SpeakerDiarizer()

        // Resolve source app. If caller didn't specify, use the current
        // frontmost meeting app, else the frontmost app generally.
        let (resolvedBundle, resolvedName) = resolveSource(sourceApp: sourceApp, sourceAppName: sourceAppName)

        // MADE, NOT SAVED. This used to call `create`, which writes the file and
        // reindexes immediately, so every failure below (mic denied, system
        // audio failed, muted mid-start) left a permanent empty meeting in the
        // user's list. It is committed once capture is genuinely live.
        var rec = MeetingStore.shared.make(
            title: title,
            sourceApp: resolvedBundle,
            sourceAppName: resolvedName
        )

        // Start captures. SC permission is preflighted here (also covered by
        // the existing ScreenCapturer path but we re-check to surface a
        // clear error).
        if !CGPreflightScreenCaptureAccess() {
            WakeLog.shared.log("meeting: SC preflight failed - prompting")
            _ = CGRequestScreenCaptureAccess()
        }

        // Route mic auth through the central controller so a fresh-launch
        // "start meeting" (e.g. MeetingAppDetector auto-offer on cold boot)
        // can't slip past the TCC warm-up and silently fail on .notDetermined.
        guard await MicController.ensureAuthorized() else {
            lastError = "Microphone denied. Open Settings → Privacy → Microphone and enable Grux."
            AmbientListener.shared.resumeFromMeeting()
            return nil
        }

        do {
            try micCapture.start()
        } catch {
            lastError = "Mic start failed: \(error.localizedDescription)"
            AmbientListener.shared.resumeFromMeeting()
            return nil
        }

        do {
            try await systemAudio.start()
            // RE-CHECK AFTER THE SUSPENSION. The mic guard ran before this
            // await; a mute that lands during ScreenCaptureKit setup must not
            // be overtaken by the capture it was trying to stop. Belt and
            // braces with the isInitializing gate in MicController.mute().
            if AppState.shared.micMuted {
                micCapture.stop()
                await systemAudio.stop()
                throw NSError(domain: "Grux.Meeting", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The microphone was muted while the meeting was starting."
                ])
            }
        } catch {
            lastError = "System audio start failed: \(error.localizedDescription)"
            micCapture.stop()
            AmbientListener.shared.resumeFromMeeting()
            return nil
        }

        self.activeMeeting = rec
        self.isCapturing = true
        // Capture is live, so the record now describes something real.
        MeetingStore.shared.commit(rec)
        self.liveUtterances = []
        startTimers()
        clearPendingOffer()

        // Open the crash-safe audio WAL for this session. Cheap - creates
        // a subdir and writes a single meta.json. Chunks flow in as the
        // mixer emits them. Gated by user config so power users who want
        // zero disk footprint can opt out.
        if AppState.shared.config.crashSafeAudioEnabled {
            AudioWAL.shared.begin(
                meetingId: rec.id,
                sourceApp: resolvedBundle,
                sourceAppName: resolvedName,
                title: rec.title
            )
            // Open the full-session streaming WAV. Retention is NOT capped
            // (unlike AudioWAL); the whole meeting's PCM lands here for
            // later export. ~1.9 MB/min at 16 kHz mono Int16, so a 60-min
            // meeting = ~110 MB - acceptable for an infrequent local file.
            let audioURL = AudioExportStore.meetingAudioURL(for: rec.id)
            do {
                self.meetingAudioStream = try WAVWriter.Stream(url: audioURL)
            } catch {
                self.meetingAudioStream = nil
                WakeLog.shared.log("meeting: meeting-audio stream open failed: \(error.localizedDescription)")
            }
        }
        WakeLog.shared.log("meeting: STARTED id=\(rec.id.uuidString) app=\(resolvedName ?? "?")")

        // Passive UI nudge so the user sees capture is live.
        OrbHintBus.shared.show(
            message: "Meeting capture started",
            state: .thinking,
            duration: 3.0
        )
        // Cross-reference event so workday logs know a meeting occurred.
        AppState.shared.appendChat(ChatMessage(
            role: .system,
            content: "📞 Meeting capture started\((resolvedName.map { " - \($0)" } ?? ""))."
        ))

        _ = rec
        return rec
    }

    func stop(summarize: Bool = true) async {
        guard isCapturing else { return }
        isCapturing = false
        stopTimers()

        // Flush any in-flight audio.
        mixer.flushFinalChunk()
        // Wait briefly for a last-in-flight transcription to finish.
        var wait = 0
        while transcribeInFlight && wait < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            wait += 1
        }

        await systemAudio.stop()
        micCapture.stop()
        mixer.reset()

        guard var rec = activeMeeting else {
            AmbientListener.shared.resumeFromMeeting()
            return
        }
        rec.endedAt = Date()

        // Freeze diarizer clusters INTO the record. This survives the
        // next `self.diarizer = SpeakerDiarizer()` reset so retroactive
        // enrollment ("I forgot to enroll Speaker 2 while the meeting
        // was live") keeps working from a stored MeetingRecord.
        rec.speakerClusters = self.snapshotClusters()

        if summarize, !rec.utterances.isEmpty {
            if let summary = await MeetingSummarizer.summarize(rec) {
                rec.summary = summary.tldr
                rec.actionItems = summary.actionItems
            }
        }

        MeetingStore.shared.finalize(rec)
        self.activeMeeting = rec

        // Fire-and-forget folder classification. Only runs when the user
        // hasn't already manually assigned the meeting (folderId == nil),
        // has at least one folder, and a summary exists to classify against.
        // Skipped silently if no Anthropic key / low confidence.
        let needsClassification = rec.folderId == nil
            && !rec.utterances.isEmpty
            && (rec.summary?.isEmpty == false)
        if needsClassification {
            let snapshot = rec
            Task { @MainActor in
                guard let assignment = await FolderClassifier.classify(record: snapshot) else { return }
                guard assignment.confidence >= FolderClassifier.minConfidence else {
                    WakeLog.shared.log("folder-classifier: low confidence \(assignment.confidence) - skipping")
                    return
                }
                // Re-load the latest version before writing in case the user
                // already manually assigned the folder while the classifier
                // round-tripped.
                guard var latest = MeetingStore.shared.loadRecord(id: snapshot.id) else { return }
                if latest.folderId != nil { return }
                latest.folderId = assignment.folderId
                MeetingStore.shared.save(latest)
                MeetingStore.shared.reindex()
                if let folder = FolderStore.shared.folder(id: assignment.folderId) {
                    WakeLog.shared.log("folder-classifier: \(snapshot.id.uuidString) → \(folder.name) (\(assignment.confidence))")
                }
                if self.activeMeeting?.id == latest.id {
                    self.activeMeeting = latest
                }
            }
        }

        // Close the full-session WAV before the crash-safe WAL teardown so
        // the header sizes are fixed up on disk. `meetingAudioStream` is
        // nil-safe - no-op if audio capture was disabled this session.
        if let stream = self.meetingAudioStream {
            let url = stream.close()
            self.meetingAudioStream = nil
            if let url {
                WakeLog.shared.log("meeting: audio saved (\(Int(stream.durationSeconds))s) → \(url.lastPathComponent)")
            }
        }

        // MeetingRecord is durably saved; we can safely delete the
        // crash-safe audio WAL. Done here (not before finalize) so a
        // crash between MeetingStore.finalize and AudioWAL.finalize
        // falls on the correct side - we'd still recover the audio,
        // not orphan a ghost record.
        AudioWAL.shared.finalize(clean: true)

        // Long-meeting STT offload to the companion service's whisper queue. Additive,
        // best-effort, and fired AFTER the WAV header was fixed up by
        // stream.close() above so the file is fully readable. Falls back to
        // the local live transcript (already on `rec`) if the companion is down.
        maybeOffloadLongMeeting(rec)

        // Surface a chat bubble so the transcript + summary are easy to find.
        let mins = Int(rec.durationSeconds / 60)
        let secs = Int(rec.durationSeconds) % 60
        let duration = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
        let actionsLine: String = {
            guard !rec.actionItems.isEmpty else { return "" }
            let top = rec.actionItems.prefix(5).map { "• \($0)" }.joined(separator: "\n")
            return "\n\nAction items:\n\(top)"
        }()
        let summaryText: String = {
            if let s = rec.summary, !s.isEmpty { return "\n\n\(s)" }
            if rec.utterances.isEmpty { return "\n\n(no speech detected)" }
            return ""
        }()
        let content = "📝 Meeting capture ended - \(duration), \(rec.utterances.count) utterances.\(summaryText)\(actionsLine)"
        AppState.shared.appendChat(ChatMessage(role: .system, content: content))

        // Post-meeting nudge: if the name detector picked up a clear
        // self-introduction for any anonymous cluster, surface it via the
        // orb so it can be enrolled with one click instead of discovered
        // buried in the transcript later. Skipped for clusters that already
        // matched an enrolled profile (no nudge needed for known voices).
        if let nudge = self.bestUnclaimedNameHint(in: rec) {
            OrbHintBus.shared.show(
                message: "Heard \"\(nudge.name)\" - open Meetings to enroll \(nudge.clusterLabel)",
                state: .listening,
                duration: 6.0
            )
        }

        AmbientListener.shared.resumeFromMeeting()
        WakeLog.shared.log("meeting: STOPPED id=\(rec.id.uuidString) dur=\(Int(rec.durationSeconds))s utt=\(rec.utterances.count)")
    }

    // Build the snapshot list by pairing the live diarizer's cluster
    // centroids with the accumulated name hints. Returns an empty array
    // (not nil) when the diarizer exists but produced no clusters so the
    // record clearly distinguishes "diarized, silent" from "pre-diarization
    // legacy".
    private func snapshotClusters() -> [SpeakerClusterSnapshot]? {
        guard let diarizer = self.diarizer else { return nil }
        let live = diarizer.clusterCentroids
        return live.map { c in
            // `label` may be an enrolled profile name if the cluster was
            // recognized, else "Speaker N". Look up the matched profile id
            // by re-checking the store - cheaper than plumbing it through.
            let profile = SpeakerProfileStore.shared.bestMatch(
                for: c.centroid,
                minSim: SpeakerDiarizer.profileThreshold
            )?.profile
            // Pick the best name hint for this cluster.
            let hint = self.nameHint(for: c.id)
            return SpeakerClusterSnapshot(
                speakerId: c.id,
                label: c.label,
                profileId: profile?.id,
                centroid: c.centroid,
                sampleCount: c.count,
                nameHint: hint
            )
        }
    }

    // Highest-priority post-meeting nudge candidate: an unidentified cluster
    // (no profileId) with a confirmed name hint (≥2 detector hits). Returns
    // nil when every cluster is either already enrolled or produced no
    // self-introduction - no spurious "enroll Speaker 3" toasts.
    fileprivate struct UnclaimedHint { let name: String; let clusterLabel: String }
    private func bestUnclaimedNameHint(in rec: MeetingRecord) -> UnclaimedHint? {
        guard let clusters = rec.speakerClusters else { return nil }
        var best: (count: Int, hint: UnclaimedHint)?
        for cluster in clusters where cluster.profileId == nil {
            guard let hint = cluster.nameHint, !hint.isEmpty else { continue }
            // Surface the most-discussed cluster's hint first.
            let candidate = UnclaimedHint(name: hint, clusterLabel: cluster.label)
            if best == nil || cluster.sampleCount > best!.count {
                best = (cluster.sampleCount, candidate)
            }
        }
        return best?.hint
    }

    // MARK: - Companion whisper-queue offload (long meetings)

    // Minimum meeting length to bother offloading. Short meetings are already
    // well-served by the live local transcript; the round trip plus model
    // warmup isn't worth it under ~5 min. Override with
    // GRUX_WHISPER_OFFLOAD_MIN_SECONDS.
    private var offloadMinSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["GRUX_WHISPER_OFFLOAD_MIN_SECONDS"],
           let v = TimeInterval(raw) { return v }
        return 300
    }

    // Fire-and-forget high-quality re-transcription on the companion service. Non-destructive:
    // stores `remoteTranscript` on the record and regenerates the summary from
    // it, leaving the live diarized utterances intact. Any failure (companion asleep,
    // network down, short meeting, no audio) is a silent no-op that keeps the
    // local transcript.
    func maybeOffloadLongMeeting(_ rec: MeetingRecord) {
        guard AppState.shared.config.crashSafeAudioEnabled else { return }  // no WAV without it
        guard ProcessInfo.processInfo.environment["GRUX_WHISPER_QUEUE_DISABLED"] != "1" else { return }
        let duration = rec.durationSeconds
        guard duration >= offloadMinSeconds else { return }
        let audioURL = AudioExportStore.meetingAudioURL(for: rec.id)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            WakeLog.shared.log("whisper-queue: no meeting WAV for \(rec.id.uuidString.prefix(8)), skipping offload")
            return
        }

        let meetingId = rec.id.uuidString
        let sourceName = rec.sourceAppName
        // turbo runs faster than real time on M-series; 2x duration plus 2 min
        // slack covers queue wait and a cold model download on the first job.
        let pollDeadline = max(240.0, duration * 2 + 120)

        Task.detached(priority: .utility) {
            let result = await WhisperQueueClient.shared.transcribe(
                audioFileURL: audioURL,
                meetingId: meetingId,
                pollDeadlineSeconds: pollDeadline
            )

            // Fallback path: local live transcript stands.
            guard let result else { return }

            // Persist the remote transcript on the latest version of the record
            // (the folder classifier may have written to it while we polled).
            await MainActor.run {
                guard var latest = MeetingStore.shared.loadRecord(id: rec.id) else { return }
                latest.remoteTranscript = result.text
                latest.remoteTranscriptModel = result.model
                latest.remoteTranscriptAt = Date()
                MeetingStore.shared.save(latest)
                if self.activeMeeting?.id == latest.id { self.activeMeeting = latest }
                WakeLog.shared.log("whisper-queue: stored remote transcript for \(rec.id.uuidString.prefix(8)) (\(result.text.count) chars, model=\(result.model), fallback=\(result.usedFallback))")
            }

            // Regenerate the summary from the cleaner transcript.
            if let summary = await MeetingSummarizer.summarize(
                transcript: result.text,
                durationSeconds: duration,
                sourceName: sourceName
            ) {
                await MainActor.run {
                    guard var latest = MeetingStore.shared.loadRecord(id: rec.id) else { return }
                    latest.summary = summary.tldr
                    latest.actionItems = summary.actionItems
                    MeetingStore.shared.save(latest)
                    MeetingStore.shared.reindex()
                    if self.activeMeeting?.id == latest.id { self.activeMeeting = latest }
                }
            }
        }
    }

    // MARK: - Chunk → transcribe → append

    private func transcribeChunk(_ samples: [Float]) {
        guard let transcriber else { return }
        guard var rec = activeMeeting else { return }
        transcribeInFlight = true
        let startT = rec.utterances.last?.t ?? 0
        let chunkOffset = Date().timeIntervalSince(rec.startedAt)
        // Pull the matching mic-only chunk that the mixer stashed for us.
        // Non-fatal if nil (e.g. only system audio had samples this window);
        // we just skip diarization for that utterance.
        let micChunk = self.pendingMicChunk
        self.pendingMicChunk = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.transcribeInFlight = false }
            let result = await transcriber.transcribe(chunk: samples)
            guard let result else { return }
            let chunkStartAbsT = max(chunkOffset - Double(samples.count) / MeetingAudioMixer.sampleRate, startT)

            // v2 sub-chunk diarization. If we have mic audio + per-word
            // timestamps, segment the chunk and emit one utterance per
            // speaker run. Otherwise fall back to v1: one utterance per
            // chunk with a single diarizer.assign() on the whole mic slice.
            let subs: [SubSplit] = self.computeSubSplits(
                result: result,
                micChunk: micChunk,
                chunkStartAbsT: chunkStartAbsT
            )

            guard !subs.isEmpty else { return }

            rec = self.activeMeeting ?? rec
            for sub in subs {
                let utt = MeetingUtterance(
                    t: sub.t,
                    speaker: .mixed,
                    text: sub.text,
                    confidence: result.confidence,
                    speakerId: sub.speakerId,
                    speakerLabel: sub.speakerLabel,
                    speakerProfileId: sub.speakerProfileId
                )
                rec.utterances.append(utt)
                // Ring-buffer last 30 in live preview.
                self.liveUtterances.append(utt)
                if self.liveUtterances.count > 30 {
                    self.liveUtterances.removeFirst(self.liveUtterances.count - 30)
                }
                // Name-hint capture. Two hits on the same name → the UI will
                // suggest enrolling the cluster as <name>.
                if let sid = sub.speakerId,
                   let hint = SpeakerNameDetector.detect(in: sub.text) {
                    var bucket = self.nameHints[sid] ?? [:]
                    bucket[hint.name, default: 0] += 1
                    self.nameHints[sid] = bucket
                }
            }
            self.activeMeeting = rec
            MeetingStore.shared.save(rec)
        }
    }

    // Internal shape that drops out of sub-chunk diarization.
    private struct SubSplit {
        let t: Double
        let text: String
        let speakerId: UUID?
        let speakerLabel: String?
        let speakerProfileId: UUID?
    }

    private func computeSubSplits(
        result: MeetingTranscriber.Result,
        micChunk: [Float]?,
        chunkStartAbsT: Double
    ) -> [SubSplit] {
        // Happy path: mic buffer + word timings → sub-chunk segmentation.
        if let mic = micChunk, !result.words.isEmpty, let diarizer = self.diarizer {
            let subs = SpeakerSegmenter.segment(
                micSamples: mic,
                words: result.words,
                diarizer: diarizer
            )
            if !subs.isEmpty {
                return subs.map {
                    SubSplit(
                        t: chunkStartAbsT + $0.startT,
                        text: $0.text,
                        speakerId: $0.speakerId,
                        speakerLabel: $0.speakerLabel,
                        speakerProfileId: $0.speakerProfileId
                    )
                }
            }
        }

        // Fallback: no word stamps (old model) or no mic chunk. One utterance
        // per chunk, diarized from the whole mic slice.
        var speakerId: UUID? = nil
        var speakerLabel: String? = nil
        var profileId: UUID? = nil
        if let mic = micChunk, let assignment = self.diarizer?.assign(samples: mic) {
            speakerId = assignment.speakerId
            speakerLabel = assignment.label
            profileId = assignment.matchedProfile?.id
        }
        return [SubSplit(
            t: chunkStartAbsT,
            text: result.text,
            speakerId: speakerId,
            speakerLabel: speakerLabel,
            speakerProfileId: profileId
        )]
    }

    // Exposed to the UI so the "enroll this speaker" sheet can pre-fill a
    // name when the transcript has self-introductions for that cluster.
    func nameHint(for speakerId: UUID) -> String? {
        guard let bucket = nameHints[speakerId], !bucket.isEmpty else { return nil }
        // Require ≥2 hits to surface, to cut accidental quotes ("my name is
        // George of the Jungle"). Returns the most-frequent above-threshold
        // candidate.
        let confirmed = bucket.filter { $0.value >= 2 }
        let best = (confirmed.isEmpty ? bucket : confirmed).max(by: { $0.value < $1.value })
        return best?.key
    }

    // Exposed to SpeakerTool so post-meeting "enroll this speaker" flows can
    // read the diarizer's final cluster centroids. Returns nil between
    // meetings / after reset.
    var currentDiarizerCentroids: [(id: UUID, label: String, centroid: [Float], count: Int)]? {
        diarizer?.clusterCentroids
    }

    // MARK: - Timers

    private func startTimers() {
        elapsedSeconds = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCapturing else { return }
                self.elapsedSeconds += 1
            }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCapturing else { return }
                self.mixer.flushReadyChunks()
            }
        }
    }

    private func stopTimers() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        flushTimer?.invalidate(); flushTimer = nil
    }

    // MARK: - Source resolution

    private func resolveSource(sourceApp: String?, sourceAppName: String?) -> (String?, String?) {
        if let sourceApp, !sourceApp.isEmpty {
            let name = sourceAppName ?? MeetingAppDetector.displayName(for: sourceApp)
            return (sourceApp, name)
        }
        if let pending = pendingAutoOffer {
            return (pending.bundleId, pending.name)
        }
        if let front = MeetingAppDetector.currentFrontmostMeetingApp() {
            return (front.bundleId, front.name)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            return (front.bundleIdentifier, front.localizedName)
        }
        return (nil, nil)
    }

    // MARK: - Display helpers

    var elapsedDisplay: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        if m >= 60 {
            let h = m / 60
            return String(format: "%d:%02d:%02d", h, m % 60, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
