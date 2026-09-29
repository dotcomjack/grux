import Foundation

/// Every string the Command Panel shows, in one place, so first-run copy,
/// the palette and the panel cannot drift.
enum PanelCopy {
    static let wordmark = "GRUX OS"
    static let placeholder = "Say it or type it"
    static let placeholderMuted = "Type it, or unmute to say it"
    static let placeholderOff = "Type it, or turn listening on"
    static let inputLabel = "Say it or type it"
    static let nothingNeedsYou = "Nothing needs you."
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
    static let paused = "Paused"
    static let watch = "Watch"
    static let pause = "Pause"
    static func orbLabel(_ tell: ListeningTell) -> String { "Grux orb, \(tell.label)" }
    static func micLabel(_ tell: ListeningTell) -> String { "Microphone, \(tell.label)" }
}
