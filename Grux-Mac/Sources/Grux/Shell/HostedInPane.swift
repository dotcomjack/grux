import SwiftUI

/// True when a surface is drawn inside the Command Panel's pane. Chat reads
/// it to fold its threads sidebar (Task 7).
private struct HostedInPaneKey: EnvironmentKey { static let defaultValue = false }

/// The names the surface in the pane goes by: the one its bar prints ("Mail")
/// and its full name ("Mailbox"). Empty outside a pane.
private struct PaneTitlesKey: EnvironmentKey { static let defaultValue: [String] = [] }

extension EnvironmentValues {
    var hostedInPane: Bool {
        get { self[HostedInPaneKey.self] }
        set { self[HostedInPaneKey.self] = newValue }
    }

    var paneTitles: [String] {
        get { self[PaneTitlesKey.self] }
        set { self[PaneTitlesKey.self] = newValue }
    }
}

/// Whether a surface's own heading would print the pane bar's title a second
/// time, 40pt under it (audit 2026-10-13, item 7: Notes, Documents, Labs and
/// Tuning). The bar can use a short name for the same surface, "Mail" over a
/// "Mailbox" header and "Studio" over "Design Studio" (PR 35 review), so both
/// names count. A heading that says something else, a month or a project
/// name, still shows.
enum PaneHeading {
    static func repeats(_ heading: String, paneTitles: [String]) -> Bool {
        paneTitles.contains { heading.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// The bar's name for a surface key, then its full name when that differs.
    static func names(forKey key: String) -> [String] {
        let rail = SidebarIA.railLabel(forKey: key)
        guard let full = SidebarIA.item(forKey: key)?.label, full != rail else { return [rail] }
        return [rail, full]
    }
}
