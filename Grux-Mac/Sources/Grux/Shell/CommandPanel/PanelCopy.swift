import Foundation

/// Every string the Command Panel shows, in one place, so first-run copy,
/// the palette and the panel cannot drift.
enum PanelCopy {
    static let wordmark = "GRUX AI"
    static let placeholder = "Say it or type it"
    static let placeholderMuted = "Type it, or unmute to say it"
    static let placeholderOff = "Type it, or turn listening on"
    static let placeholderWaiting = "Type it, or allow listening to say it"
    static let inputLabel = "Say it or type it"
    static let nothingNeedsYou = "Nothing needs you."
    static let connectModel = "Connect a model"
    static let connectModelDetail = "Chat needs one"
    /// Under the input when Return found no model to send to. The text stays.
    static let connectToSend = "Connect a model to send this."
    /// Computed, because a shortcut override is read from defaults.
    static var paletteHint: String { "\(PaletteHotkeyConfig.spokenShortcut) reaches everything." }
    static let firstRunUnderInput = "Start here, or say what you want."
    static let nowHeading = "Now"
    static let recentHeading = "Recent"
    static let closePane = "Close"
    static let hidePane = "Hide pane"
    static let showPane = "Show last pane"
    static let settings = "Settings"
    static let pin = "Pin"
    static let unpin = "Unpin"
    static let watching = "Watching"
    /// Watching is on but macOS has not granted screen recording, so nothing
    /// is being watched. A clean Mac read "Watching" anyway (W4, 2026-10-13).
    static let needsScreenAccess = "Needs screen access"
    static let grantScreenAccess = "Grant"

    /// What the watching status says: on and granted, on but not granted
    /// (the true state is that nothing is watched), or paused.
    enum WatchingState: Equatable { case watching, needsScreenAccess, paused }
    static func watchingState(watching: Bool, screenAccess: Bool) -> WatchingState {
        guard watching else { return .paused }
        return screenAccess ? .watching : .needsScreenAccess
    }
    static let paused = "Paused"
    static let watch = "Watch"
    static let pause = "Pause"
    static func orbLabel(_ tell: ListeningTell) -> String { "Grux orb, \(tell.label)" }
    static func micLabel(_ tell: ListeningTell) -> String { "Microphone, \(tell.label)" }
    /// The foot's status, named apart from the input's mic: two buttons both
    /// called "Microphone" made "click Microphone" in Voice Control ask which
    /// one (W4 build 10 accessibility probe).
    static func listeningStatusLabel(_ tell: ListeningTell) -> String { "Listening status, \(tell.label)" }
}
