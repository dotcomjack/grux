import Foundation
import SwiftUI
import Combine

// MARK: - Domain types

enum AmbientMemoryKind: String, Codable, CaseIterable {
    case intent       // "I'm going to work on X"
    case commitment   // "I said I'd ship Y today"
    case fact         // "My agent name is Grux"
    case reminder     // "Remind me to call mom"
}

struct AmbientChunk: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let timestamp: Date
    init(id: UUID = UUID(), text: String, timestamp: Date = Date()) {
        self.id = id; self.text = text; self.timestamp = timestamp
    }
}

struct AmbientMemory: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: AmbientMemoryKind
    var text: String
    var project: String?
    var timestamp: Date
    init(id: UUID = UUID(), kind: AmbientMemoryKind, text: String, project: String? = nil, timestamp: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.project = project; self.timestamp = timestamp
    }
}

struct AmbientDetectedAction: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var project: String
    var priority: TaskPriority
    var rationale: String
    var timestamp: Date
    var promoted: Bool
    var dismissed: Bool
    init(id: UUID = UUID(), title: String, project: String = "", priority: TaskPriority = .next,
         rationale: String = "", timestamp: Date = Date(), promoted: Bool = false, dismissed: Bool = false) {
        self.id = id; self.title = title; self.project = project; self.priority = priority
        self.rationale = rationale; self.timestamp = timestamp; self.promoted = promoted; self.dismissed = dismissed
    }
}

struct AmbientCoachNudge: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var currentTaskTitle: String
    var driftRationale: String
    var timestamp: Date
    init(id: UUID = UUID(), text: String, currentTaskTitle: String, driftRationale: String, timestamp: Date = Date()) {
        self.id = id; self.text = text; self.currentTaskTitle = currentTaskTitle
        self.driftRationale = driftRationale; self.timestamp = timestamp
    }
}

// MARK: - Persistence

extension Persistence {
    static var ambientDir: URL {
        let d = supportDir.appendingPathComponent("ambient", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var ambientTranscriptURL: URL { ambientDir.appendingPathComponent("transcript.json") }
    static var ambientMemoriesURL: URL { ambientDir.appendingPathComponent("memories.json") }
    static var ambientActionsURL: URL { ambientDir.appendingPathComponent("actions.json") }
    static var ambientNudgesURL: URL { ambientDir.appendingPathComponent("nudges.json") }
}

// MARK: - State

@MainActor
final class AmbientState: ObservableObject {
    static let shared = AmbientState()

    // Live capture state
    @Published var isEnabled: Bool = false
    @Published var isCapturing: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var isExtracting: Bool = false
    @Published var liveLevel: Float = 0
    @Published var status: String = "Idle"
    @Published var error: String?
    @Published var whisperReady: Bool = false
    // Set by SingingDetector when the SoundAnalysis v1 classifier reports
    // sustained music/singing confidence above speech. While true,
    // AmbientListener suppresses command dispatch but keeps transcribing
    // so the user can still see what Whisper heard. See SingingDetector.swift.
    @Published var isSinging: Bool = false

    // Data
    @Published var recentChunks: [AmbientChunk] = []          // newest last, capped
    @Published var memories: [AmbientMemory] = []             // newest first
    @Published var detectedActions: [AmbientDetectedAction] = []
    @Published var nudges: [AmbientCoachNudge] = []           // newest first
    @Published var lastExtractionAt: Date?
    @Published var lastCoachNudgeAt: Date?

    // HUD
    @Published var hudVisible: Bool = false
    @Published var coachIsSpeaking: Bool = false

    // Wake-mode conversation gate. In FOCUS mode this is always true while
    // ambient is enabled (full-time listening). In WAKE mode this flips to
    // true only when the user says "hey grux" and flips back to false when the
    // conversation ends (DONE TALKING tap, 30s post-reply silence, or a
    // dismissal phrase like "go away" / "we'll chat later"). Drives whether
    // AmbientListener runs (heavy mic + VP + Whisper pipeline) or
    // WakeWordListener runs (lightweight SFSpeechRecognizer phrase detector).
    @Published var conversationActive: Bool = false
    // When the DONE TALKING button is tapped mid-reply we flush + extract
    // immediately, but we want the conversation itself to end only AFTER
    // Grux finishes speaking - otherwise we'd cut Grux off mid-sentence.
    // Observer on gruxSpeechDidStop consumes this flag.
    var pendingExitAfterSpeech: Bool = false

    private let maxChunks = 200
    private let maxMemories = 100
    private let maxActions = 40
    private let maxNudges = 40

    private init() {
        load()
    }

    // MARK: Load / save

    func load() {
        self.recentChunks = Persistence.load([AmbientChunk].self, from: Persistence.ambientTranscriptURL, fallback: [])
        self.memories = Persistence.load([AmbientMemory].self, from: Persistence.ambientMemoriesURL, fallback: [])
        self.detectedActions = Persistence.load([AmbientDetectedAction].self, from: Persistence.ambientActionsURL, fallback: [])
        self.nudges = Persistence.load([AmbientCoachNudge].self, from: Persistence.ambientNudgesURL, fallback: [])
    }

    func saveAll() {
        Persistence.save(recentChunks, to: Persistence.ambientTranscriptURL)
        Persistence.save(memories, to: Persistence.ambientMemoriesURL)
        Persistence.save(detectedActions, to: Persistence.ambientActionsURL)
        Persistence.save(nudges, to: Persistence.ambientNudgesURL)
    }

    // MARK: Chunks

    func appendChunk(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let chunk = AmbientChunk(text: clean)
        recentChunks.append(chunk)
        if recentChunks.count > maxChunks {
            recentChunks.removeFirst(recentChunks.count - maxChunks)
        }
        Persistence.save(recentChunks, to: Persistence.ambientTranscriptURL)
    }

    func transcriptWindow(minutes: Int = 10) -> String {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        return recentChunks
            .filter { $0.timestamp >= cutoff }
            .map { "- \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: Memories

    func addMemory(_ m: AmbientMemory) {
        // Dedup exact text matches
        guard !memories.contains(where: { $0.text.caseInsensitiveCompare(m.text) == .orderedSame }) else { return }
        memories.insert(m, at: 0)
        if memories.count > maxMemories { memories = Array(memories.prefix(maxMemories)) }
        Persistence.save(memories, to: Persistence.ambientMemoriesURL)
    }

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        Persistence.save(memories, to: Persistence.ambientMemoriesURL)
    }

    func updateMemory(_ id: UUID, text: String? = nil, project: String? = nil, kind: AmbientMemoryKind? = nil) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        var m = memories[idx]
        if let text { m.text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let project {
            let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
            m.project = trimmed.isEmpty ? nil : trimmed
        }
        if let kind { m.kind = kind }
        memories[idx] = m
        Persistence.save(memories, to: Persistence.ambientMemoriesURL)
    }

    // MARK: Actions

    func addAction(_ a: AmbientDetectedAction) {
        guard !detectedActions.contains(where: { $0.title.caseInsensitiveCompare(a.title) == .orderedSame && !$0.dismissed }) else { return }
        detectedActions.insert(a, at: 0)
        if detectedActions.count > maxActions { detectedActions = Array(detectedActions.prefix(maxActions)) }
        Persistence.save(detectedActions, to: Persistence.ambientActionsURL)
    }

    func promoteAction(_ id: UUID) {
        guard let idx = detectedActions.firstIndex(where: { $0.id == id }) else { return }
        var a = detectedActions[idx]
        AppState.shared.addTask(a.title, project: a.project, priority: a.priority)
        a.promoted = true
        detectedActions[idx] = a
        Persistence.save(detectedActions, to: Persistence.ambientActionsURL)
    }

    func dismissAction(_ id: UUID) {
        guard let idx = detectedActions.firstIndex(where: { $0.id == id }) else { return }
        var a = detectedActions[idx]
        a.dismissed = true
        detectedActions[idx] = a
        Persistence.save(detectedActions, to: Persistence.ambientActionsURL)
    }

    var activeActions: [AmbientDetectedAction] {
        detectedActions.filter { !$0.dismissed && !$0.promoted }
    }

    // MARK: Nudges

    func addNudge(_ n: AmbientCoachNudge) {
        nudges.insert(n, at: 0)
        if nudges.count > maxNudges { nudges = Array(nudges.prefix(maxNudges)) }
        lastCoachNudgeAt = n.timestamp
        Persistence.save(nudges, to: Persistence.ambientNudgesURL)
    }

    // MARK: - Enable / disable

    func enable() async {
        // ASKED BEFORE THE MICROPHONE IS TAKEN, AT THE ONE FUNCTION EVERY DOOR
        // GOES THROUGH. Settings, the menu bar row and the ambient HUD capture
        // pill all land here; only Settings used to ask, so two of the three
        // doors took the device with no disclosure at all.
        //
        // A decline is an answer, not a failure: return without touching the
        // preference so the toggle springs back and nothing is persisted.
        guard MicConsent.ensureAcknowledged(for: .ambient) else { return }
        isEnabled = true
        AppState.shared.config.ambientEnabled = true
        AppState.shared.saveConfig()
        AmbientCoach.shared.start()
        if AppState.shared.config.ambientHUDVisible { AmbientPanelController.shared.show() }

        // Two sub-modes live under the same "ambient enabled" umbrella now:
        //
        //   FOCUS: heavy pipeline runs continuously. Every utterance flows to
        //          ChatService; FocusWatcher needs the uninterrupted stream.
        //
        //   WAKE:  start IDLE - only the cheap WakeWordListener (SFSpeechRecognizer)
        //          runs. No VoiceProcessing, no Whisper, no music ducking. When
        //          "hey grux" fires, we flip into conversationActive and the
        //          full AmbientListener takes over. When the conversation
        //          ends, we drop back to idle.
        if AppState.shared.config.ambientMode == .focus {
            conversationActive = true
            WakeWordListener.shared.stop()
            await AmbientListener.shared.start()
        } else {
            conversationActive = false
            AmbientListener.shared.stop()
            status = "Wake idle - say 'Hey Grux'"
            if AppState.shared.config.wakeWordEnabled {
                await WakeWordListener.shared.start()
            }
        }
    }

    func disable() {
        isEnabled = false
        conversationActive = false
        AppState.shared.config.ambientEnabled = false
        AppState.shared.saveConfig()
        AmbientListener.shared.stop()
        AmbientCoach.shared.stop()
        // Restart wake listener if user had it enabled
        if AppState.shared.config.wakeWordEnabled {
            Task { @MainActor in await WakeWordListener.shared.start() }
        }
    }

    // MARK: - Wake-mode conversation lifecycle

    /// Fired when "hey grux" is detected (WakeWordListener) OR when the user
    /// switches into FOCUS mode. Stops the wake listener, starts the full
    /// AmbientListener pipeline (which engages VoiceProcessingIO / AEC), and
    /// arms the ambient wake window so the FIRST chunk captured after this
    /// flip is treated as the command - no second "hey grux" required.
    func enterConversation(reason: String) async {
        guard isEnabled else { return }
        guard !conversationActive else { return }
        conversationActive = true
        pendingExitAfterSpeech = false
        WakeLog.shared.log("ambient: ENTER conversation (\(reason))")
        WakeWordListener.shared.stop()
        // Prime ambient's armed-wake window BEFORE starting the engine so the
        // very first transcribed chunk post-wake is routed straight to chat.
        AmbientListener.shared.armForConversationStart()
        await AmbientListener.shared.start()
    }

    /// Tear down the AmbientListener and drop back to wake-idle. Called by:
    ///   • dismissal phrases ("go away", "we'll chat later")
    ///   • the DONE TALKING button (post-reply)
    ///   • the silence timer (30s after Grux's last reply with no follow-up)
    ///   • mode flip to OFF
    /// In FOCUS mode this is a no-op - focus listens full-time.
    func exitConversation(reason: String) {
        guard isEnabled else { return }
        guard AppState.shared.config.ambientMode == .wake else { return }
        guard conversationActive else { return }
        conversationActive = false
        pendingExitAfterSpeech = false
        WakeLog.shared.log("ambient: EXIT conversation (\(reason))")
        AmbientListener.shared.stop()
        status = "Wake idle - say 'Hey Grux'"
        if AppState.shared.config.wakeWordEnabled {
            Task { @MainActor in await WakeWordListener.shared.start() }
        }
    }

    /// Called by AmbientHUD when the user flips the WAKE/FOCUS segmented control
    /// live. Persists the choice and transitions listener state to match.
    func setMode(_ mode: AmbientMode) async {
        let previous = AppState.shared.config.ambientMode
        guard previous != mode else { return }
        AppState.shared.config.ambientMode = mode
        AppState.shared.saveConfig()
        WakeLog.shared.log("hud: mode → \(mode.rawValue)")
        guard isEnabled else { return }
        if mode == .focus {
            // Any time we enter FOCUS, the full pipeline should be up.
            conversationActive = true
            WakeWordListener.shared.stop()
            await AmbientListener.shared.start()
        } else {
            // WAKE: drop to idle. Wake listener handles "hey grux".
            conversationActive = false
            AmbientListener.shared.stop()
            status = "Wake idle - say 'Hey Grux'"
            if AppState.shared.config.wakeWordEnabled {
                await WakeWordListener.shared.start()
            }
        }
    }

    func toggleHUD() {
        hudVisible.toggle()
        AppState.shared.config.ambientHUDVisible = hudVisible
        AppState.shared.saveConfig()
        if hudVisible {
            AmbientPanelController.shared.show()
        } else {
            AmbientPanelController.shared.hide()
        }
    }

    // MARK: - Reset

    func clearAll() {
        recentChunks = []
        memories = []
        detectedActions = []
        nudges = []
        saveAll()
    }
}
