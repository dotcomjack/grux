import SwiftUI
import Combine

// MARK: - ShellStateBus
//
// One canonical answer to "what is the shell doing right now". Today that
// answer is scattered: LaunchRootView, MenuBarView, ChatView, AmbientHUD and
// OrbAnywhereView each recompute their own GruxOrbState from SpeechEngine,
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
