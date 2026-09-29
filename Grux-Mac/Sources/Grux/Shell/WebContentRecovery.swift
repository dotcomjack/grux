import Foundation

/// What a web view a person can see does when WebKit's content process for it
/// ends (killed, crashed, or reclaimed under memory pressure): one WakeLog line
/// naming the surface, then one reload.
///
/// Before this, nothing in Grux handled `webViewWebContentProcessDidTerminate`,
/// so a lost content process left a blank view and no log line. sweep-9 saw
/// Design Studio's preview draw blank on two opens of an installed build while
/// wake.log had only the tab being opened. That is not proven to be this; it is
/// the failure this makes visible and recoverable.
///
/// A page that loses its process on every load would reload forever, so a second
/// end within `retryWindow` of a reload only logs. Used on the main thread,
/// where WebKit calls its navigation delegates.
final class WebContentRecovery {
    let surface: String
    static let retryWindow: TimeInterval = 30
    private var lastReloadAt: Date?

    init(surface: String) {
        self.surface = surface
    }

    /// Logs the end, then runs `reload` unless it already did so within
    /// `retryWindow`. Returns the line it logged.
    @discardableResult
    func contentProcessEnded(now: Date = Date(), reload: () -> Void) -> String {
        if let last = lastReloadAt, now.timeIntervalSince(last) < Self.retryWindow {
            let line = "web: \(surface) lost its content process again within \(Int(Self.retryWindow)) s of a reload, so it stays blank until reopened"
            WakeLog.shared.log(line)
            return line
        }
        lastReloadAt = now
        let line = "web: \(surface) lost its content process, reloading it once"
        WakeLog.shared.log(line)
        reload()
        return line
    }

    /// For a web view no person sees (an export): the line only.
    @discardableResult
    static func offscreenContentProcessEnded(surface: String) -> String {
        let line = "web: \(surface) lost its content process"
        WakeLog.shared.log(line)
        return line
    }
}
