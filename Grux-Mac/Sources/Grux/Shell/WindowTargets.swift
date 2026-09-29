import AppKit

/// Apps as things you can say: bring one forward, hide one, or clear the screen.
///
/// Reversible only. Focus and hide, never quit: "close everything" HIDES every
/// other app and leaves Grux up, so nothing said out loud can lose unsaved
/// work, and one Cmd-Tab brings any of it back. Quit is absent from the
/// vocabulary by construction.
///
/// The scope of "close everything" is deliberately NOT a judgment on the
/// decision engine (Phase R acceptance criterion 2 asks for a recorded reason
/// when a decision point stays off it): every regular app except Grux is
/// hidden, which is reversible, instant, and exactly what was said. A
/// per-app "should this one stay?" question would add a round trip to a sweep
/// with no safety to buy.
enum WindowTargets {
    static let closeEverythingVerb = "hide"

    /// Regular (Dock) apps that are running, by name, never Grux itself.
    @MainActor
    static func runningAppNames() -> [String] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != me }
            .compactMap(\.localizedName)
            .filter { seen.insert($0).inserted }
    }

    static func focusPhrases(forApp name: String) -> [String] {
        let n = name.lowercased()
        return ["open \(n)", "switch to \(n)", "focus \(n)", "bring up \(n)", "go to \(n)"]
    }

    static func hidePhrases(forApp name: String) -> [String] {
        let n = name.lowercased()
        return ["hide \(n)", "minimize \(n)", "minimise \(n)"]
    }

    static let closeEverythingPhrases = ["close everything", "hide everything", "clear my screen"]

    @MainActor @discardableResult
    static func focus(appNamed name: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            return false
        }
        return WindowFacade.activate(app, options: [.activateAllWindows])
    }

    @MainActor @discardableResult
    static func hide(appNamed name: String) -> Bool {
        NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }).map(WindowFacade.hide) ?? false
    }

    @MainActor @discardableResult
    static func hideAllExceptGrux() -> Int {
        let me = Bundle.main.bundleIdentifier
        var n = 0
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.bundleIdentifier != me {
            if WindowFacade.hide(app) { n += 1 }
        }
        return n
    }
}
