import SwiftUI
import Combine

// MARK: - ShellStateBus
//
// One canonical answer to "what is the shell doing right now". Today that
// answer is scattered: LaunchRootView, MenuBarView, ChatView and AmbientHUD
// each recompute their own GruxOrbState from SpeechEngine,
// WakeWordListener and AppState, while the glow border and Stage take ad-hoc
// pushes. The bus collapses those into a single published ShellMoment so
// every surface (orb, glow, HUD pill, menu bar) tells the same story at the
// same instant.
//
// Publishing model: producers call publish(). The bus arbitrates with a pure
// priority + hold + same-source rule (ShellStateBus.resolve) so a transient
// low-priority signal cannot stomp an in-flight high-priority one, but the
// source that owns the current moment can always downgrade itself (speech
// ends, thinking finishes). Views subscribe via @ObservedObject or the
// `moments` Combine publisher.
//
// Nothing in the existing subsystems was modified to feed this. The
// translation from their notifications and @Published state lives in
// ShellStateAdapters.swift.

/// Canonical shell mode. Superset of GruxOrbState that also carries the
/// focus-watcher story (onTask / drifting) and a hard `alert` tier.
enum ShellMode: String, Codable, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case onTask
    case drifting
    case alert

    /// Arbitration weight. Higher wins while the current moment's hold is
    /// live. Speaking and alert sit on top: those are the signals the user must
    /// never miss; ambient idle chatter sits at the bottom.
    var priority: Int {
        switch self {
        case .idle:      return 0
        case .onTask:    return 1
        case .listening: return 2
        case .drifting:  return 3
        case .thinking:  return 4
        case .speaking:  return 5
        case .alert:     return 6
        }
    }

    /// Accent token for any surface that wants a single tint, sourced from
    /// GruxTheme so palette drift stays impossible.
    var accent: Color {
        switch self {
        case .idle:      return GruxTheme.accentPrimary
        case .listening: return GruxTheme.successMint
        case .thinking:  return GruxTheme.warnAmber
        case .speaking:  return GruxTheme.accentCo
        case .onTask:    return GruxTheme.successMint
        case .drifting:  return GruxTheme.warnAmber
        case .alert:     return GruxTheme.destructiveRose
        }
    }

    /// Bridge to the existing orb enum so OrbView keeps rendering untouched.
    /// onTask reads as calm (idle), drifting and alert reuse thinking's amber
    /// pulse, matching OrbHintBus.parseState's alias for "alert".
    var orbState: GruxOrbState {
        switch self {
        case .idle:      return .idle
        case .listening: return .listening
        case .thinking:  return .thinking
        case .speaking:  return .speaking
        case .onTask:    return .idle
        case .drifting:  return .thinking
        case .alert:     return .thinking
        }
    }

    /// Short pill label, uppercase-ready.
    var label: String {
        switch self {
        case .idle:      return "idle"
        case .listening: return "listening"
        case .thinking:  return "thinking"
        case .speaking:  return "speaking"
        case .onTask:    return "on task"
        case .drifting:  return "drifting"
        case .alert:     return "alert"
        }
    }
}

/// A single canonical shell state sample. Value type, Sendable, no UI
/// payloads stored (accent is derived from mode), so it can cross actors and
/// sit in tests without MainActor ceremony.
struct ShellMoment: Equatable, Sendable {
    var mode: ShellMode
    /// One-line state headline, e.g. "Speaking", "Drifting".
    var headline: String
    /// Optional second line, e.g. the active task title or frontmost app.
    var detail: String
    /// Stable producer id ("speech", "wake", "focus", "workflow", ...). The
    /// source that owns the current moment may always replace it, even with
    /// a lower-priority mode; that is how "speaking ended, back to idle"
    /// flows without fighting the hold window.
    var source: String
    var timestamp: Date
    /// Seconds this moment defends its slot against lower-priority,
    /// different-source candidates. 0 means freely replaceable.
    var hold: TimeInterval

    init(
        mode: ShellMode,
        headline: String,
        detail: String = "",
        source: String,
        timestamp: Date = Date(),
        hold: TimeInterval = 0
    ) {
        self.mode = mode
        self.headline = headline
        self.detail = detail
        self.source = source
        self.timestamp = timestamp
        self.hold = hold
    }

    var accent: Color { mode.accent }
    var priority: Int { mode.priority }

    func isExpired(at now: Date) -> Bool {
        now >= timestamp.addingTimeInterval(hold)
    }

    static let initial = ShellMoment(mode: .idle, headline: "Idle", source: "bus")
}

@MainActor
final class ShellStateBus: ObservableObject {
    static let shared = ShellStateBus()

    /// The single canonical moment. Views bind to this (or to `moments`).
    @Published private(set) var current: ShellMoment = .initial

    /// Combine feed for non-SwiftUI consumers (controllers, loggers).
    var moments: AnyPublisher<ShellMoment, Never> {
        $current.eraseToAnyPublisher()
    }

    /// Internal (not private) so tests can spin isolated instances; app code
    /// uses .shared.
    init() {}

    /// Offer a candidate moment. The pure resolve() rule decides whether it
    /// lands; rejected candidates are dropped silently (the producer keeps
    /// emitting on its own cadence, so a dropped sample self-heals).
    func publish(_ candidate: ShellMoment) {
        if let next = Self.resolve(current: current, candidate: candidate, now: Date()) {
            current = next
        }
    }

    /// Convenience for one-line call sites.
    func publish(
        mode: ShellMode,
        headline: String,
        detail: String = "",
        source: String,
        hold: TimeInterval = 0
    ) {
        publish(ShellMoment(mode: mode, headline: headline, detail: detail, source: source, hold: hold))
    }

    // MARK: - Arbitration (pure, testable)

    /// Decide whether `candidate` replaces `current`. Returns the moment to
    /// install, or nil to keep the current one. Rules, in order:
    /// 1. Coalesce: identical content (mode + headline + detail + source) is
    ///    dropped so repeated producer ticks do not churn @Published.
    /// 2. Equal or higher priority always wins.
    /// 3. An expired hold opens the slot to anyone.
    /// 4. The owning source may always replace its own moment (downgrade on
    ///    completion: speaking -> idle, thinking -> idle).
    /// 5. Otherwise the candidate is dropped.
    nonisolated static func resolve(
        current: ShellMoment,
        candidate: ShellMoment,
        now: Date = Date()
    ) -> ShellMoment? {
        if candidate.mode == current.mode
            && candidate.headline == current.headline
            && candidate.detail == current.detail
            && candidate.source == current.source {
            return nil
        }
        if candidate.priority >= current.priority { return candidate }
        if current.isExpired(at: now) { return candidate }
        if candidate.source == current.source { return candidate }
        return nil
    }
}

// MARK: - ListeningTell
//
// The one word the orb, the menu bar, the HUD and the floating focus card
// all show at the same instant. Before this, each surface reasoned from
// micMuted, WakeWordListener.isListening and SpeechEngine.isSpeaking on its
// own, so the sidebar orb could read LISTENING while the menu bar read IDLE.
// The tell is a pure function of three flags plus the saved mode, so the
// surfaces cannot disagree and a test can enumerate every combination.

/// What Grux is doing with your microphone, in one word.
enum ListeningTell: String, CaseIterable, Sendable {
    /// Listening is on and the microphone is live.
    case armed
    /// The user muted the microphone. Listening resumes when they unmute.
    case muted
    /// Grux is talking.
    case speaking
    /// Grux is working on something you already said.
    case thinking
    /// Listening is switched off in Tuning, not muted.
    case off
    /// Listening is on, but the microphone is sending no sound. Grux keeps
    /// retrying on its own, and a tap on the orb retries now.
    case notHearing

    var label: String { self == .notHearing ? "NOT HEARING" : rawValue.uppercased() }

    /// Priority, highest first: speaking and thinking are things happening
    /// right now, and you must not miss them; muted beats the configured
    /// mode because it is the thing the user most recently did.
    /// `notHearing` comes from `MicHealth`: an ARMED that is not hearing
    /// anything is the one word here that would be a lie.
    static func resolve(mode: ListeningMode, micMuted: Bool, isSpeaking: Bool, isThinking: Bool,
                        notHearing: Bool = false) -> ListeningTell {
        if isSpeaking { return .speaking }
        if isThinking { return .thinking }
        if micMuted { return .muted }
        if mode == .off { return .off }
        return notHearing ? .notHearing : .armed
    }

    /// The glow the orb wears while showing this word.
    var orbState: GruxOrbState {
        switch self {
        case .armed:    return .listening
        case .muted:    return .muted
        case .speaking: return .speaking
        case .thinking: return .thinking
        case .off:      return .idle
        case .notHearing: return .muted
        }
    }

    /// One sentence for a tooltip, so the word is never the only explanation.
    var help: String {
        switch self {
        case .armed:    return "Listening. Just talk, no wake word needed."
        case .muted:    return "Muted. Tap the orb to listen again."
        case .speaking: return "Grux is speaking."
        case .thinking: return "Grux is working on it."
        case .off:      return "Listening is off. Turn it on in Tuning."
        case .notHearing: return "The microphone is not sending any sound. Grux keeps trying; tap the orb to try now."
        }
    }
}

extension ListeningTell {
    /// The tell from the live objects, so both shells compute it the same
    /// way: the mode in effect, the mute, speech, thinking and whether the
    /// microphone is heard. `notHearing` is a value so the caller's own
    /// observation of `MicHealth` is what redraws it.
    @MainActor
    static func resolve(state: AppState, speech: SpeechEngine, notHearing: Bool) -> ListeningTell {
        resolve(mode: state.config.listeningModeInEffect,
                micMuted: state.micMuted,
                isSpeaking: speech.isSpeaking || speech.isBuffering,
                isThinking: state.isThinking,
                notHearing: notHearing)
    }
}

extension GruxConfig {
    /// The listening mode that can actually be running, which is what the tell
    /// shows. Not the preference.
    ///
    /// Listening is on by default, by decision, and launch never opens a
    /// consent dialog over the first screen (`ListeningController.applyAtLaunch`),
    /// so a fresh install holds `.alwaysOn` with the microphone closed until the
    /// person agrees. Resolving the tell from the preference made that install
    /// read ARMED while nothing was listening, which is the one word the tell
    /// must never say falsely. Each mode counts only once its own consent is
    /// given: agreeing to ambient is not agreeing to the wake word, whose audio
    /// can leave the Mac.
    var listeningModeInEffect: ListeningMode {
        switch listeningMode {
        case .alwaysOn: return ambientConsentAcknowledged ? .alwaysOn : .off
        case .wakeWord: return wakeWordConsentAcknowledged ? .wakeWord : .off
        case .off: return .off
        }
    }
}
