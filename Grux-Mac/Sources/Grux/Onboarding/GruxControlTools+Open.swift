import AppKit
import Foundation
import GruxMCPCore

// MARK: - grux_open

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// Bring one Grux surface forward, or name the ones there are.
    ///
    /// ## An unknown name is REFUSED here, and that is the defect being fixed
    ///
    /// `LaunchRootView.applyTab` falls back to `.chat` for any string it does not recognise,
    /// so `grux open notez` used to open Chat and report that it had. A command describing
    /// what it did in words that are false for what it did is worse than one that fails,
    /// because nothing about the reply gives the reader a reason to go and look.
    /// `LaunchRootView.tab(forKey:)` returns nil for an unknown key precisely so a caller can
    /// pick its own answer, and the answer here is no.
    ///
    /// ## The names come from the enum, never from a list written beside it
    ///
    /// `LaunchRootView.Tab` is the only thing entitled to say what a surface is called, and
    /// this repo's own CLAUDE.md has already been wrong about the count and omitted a tab.
    /// `SidebarIA` supplies the GROUPING, the order and the human labels, and every row is
    /// still checked against the enum on the way out, so a sidebar key the enum stopped
    /// knowing is dropped rather than advertised as a window that will never arrive.
    ///
    /// ## Validation lives here because the enum does
    ///
    /// The `grux` binary cannot see `LaunchRootView`, and giving it a second copy of thirty
    /// five names would be a second thing to keep in step. It asks; this answers.
    static func open(surface: String?) -> [String: Any] {
        let typed = (surface ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let catalogue = surfaceCatalogue()

        // NO NAME MEANS NO WINDOW. Listing is a read, and opening something because somebody
        // asked what there was to open is the same lie in the other direction.
        guard !typed.isEmpty else { return MCPWire.textResult(jsonText(catalogue)) }

        guard let found = resolveSurface(typed) else {
            let count = (catalogue["count"] as? Int) ?? 0
            return MCPWire.textFailure(
                "Grux has no surface called \(typed), so nothing was opened. There are "
                + "\(count) of them, and grux_open with no surface names every one.")
        }

        guard let delegate = AppDelegate.shared else {
            // Reachable, and it is not the same state as Grux being closed: the control
            // socket comes up inside applicationDidFinishLaunching, so a call that lands in
            // that window reaches a Grux with nothing yet to hold a window open with.
            return MCPWire.textFailure(
                "Grux is still starting up and has no windows to bring forward yet. Give it "
                + "a few seconds and ask again.")
        }
        delegate.openLaunchWindow(tab: found.key)

        // ASKED, NOT SHOWN, and the distinction is measured rather than cautious.
        // openLaunchWindow orders the window front and calls NSApp.activate, and the comment
        // recorded beside that code says neither is enough from a background app: the window
        // is created, CGWindowList lists it, and it never becomes on screen. Reporting
        // "opened" would be a claim this process has no way to check.
        return MCPWire.textResult(jsonText([
            "surface": found.key,
            "label": found.label,
            "typed": typed,
            "note": "Grux was asked to bring that window forward. Whether it reached the "
                  + "front is not something this can see, because a background app cannot "
                  + "always put itself in front of what somebody is looking at.",
        ]))
    }

    /// What somebody typed, turned into a canonical surface, or nil for no such thing.
    ///
    /// Three passes, and the order carries weight. The exact string first, so a correctly
    /// typed `metaAds` never has to survive being lowercased. Then the lowercased string,
    /// which is how both aliases are spelled in `tab(forKey:)`. Then the sidebar keys and
    /// LABELS, case insensitively, because the window says "Local Models" while the key is
    /// `cookbook`: refusing the name that is on the screen would be teaching somebody the
    /// schema for no reason.
    ///
    /// Every path finishes at `tab(forKey:)`, so the enum decides, including for the sidebar
    /// row: a label match on a key the enum no longer knows resolves to nothing.
    static func resolveSurface(_ typed: String) -> (key: String, label: String)? {
        let lowered = typed.lowercased()
        let bySidebar = SidebarIA.allItems.first(where: {
            $0.key.lowercased() == lowered || $0.label.lowercased() == lowered
        })
        guard let tab = LaunchRootView.tab(forKey: typed)
            ?? LaunchRootView.tab(forKey: lowered)
            ?? bySidebar.flatMap({ LaunchRootView.tab(forKey: $0.key) })
        else { return nil }

        let key = LaunchRootView.tabKey(for: tab)
        return (key, SidebarIA.item(forKey: key)?.label ?? key)
    }

    /// Every surface, in the window's own grouping and order.
    ///
    /// Alphabetical would be worse here and the sidebar is why: somebody looking for the
    /// place their mail lives finds it under Workspace beside Calendar and Contacts, which
    /// is where they last saw it. A flat sort files Mailbox between Local Models and Media
    /// Studio and teaches nothing about what any of them are.
    static func surfaceCatalogue() -> [String: Any] {
        var groups: [[String: Any]] = []
        var count = 0
        for group in SidebarIA.groups {
            let surfaces = group.items.compactMap { item -> [String: String]? in
                guard LaunchRootView.tab(forKey: item.key) != nil else { return nil }
                return ["key": item.key, "label": item.label]
            }
            guard !surfaces.isEmpty else { continue }
            count += surfaces.count
            groups.append(["id": group.id, "title": group.title, "surfaces": surfaces])
        }

        // VERIFIED, NOT ASSERTED. An alias is one line inside `tab(forKey:)` and nothing
        // stops it being removed there; advertising a name that no longer resolves would
        // send somebody to type a word that fails.
        let aliases: [String: String] = [
            "design": "designStudio", "foundry": "selfUpgrade",
        ].filter { pair in
            guard let tab = LaunchRootView.tab(forKey: pair.key) else { return false }
            return LaunchRootView.tabKey(for: tab) == pair.value
        }

        return [
            "aliases": aliases,
            "count": count,
            // Where Grux lands when it opens on its own, from the cold-boot path in
            // GruxApp.applicationDidFinishLaunching, which passes "home" explicitly. Not the
            // "chat" default on openLaunchWindow(tab:), which every call site overrides and
            // which no launch actually takes.
            "default": "home",
            "groups": groups,
        ]
    }
}
