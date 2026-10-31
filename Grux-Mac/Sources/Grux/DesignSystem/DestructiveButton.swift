import SwiftUI

/// A button for an action that destroys something, which asks first.
///
/// It exists because the app had 33 destructive controls and only 7 files
/// anywhere used a confirmation. `Reset all settings` wiped the entire config on
/// one click. `Clear memory` emptied semantic memory on one click. `Remove` on a
/// credential deleted a key that, for Anthropic, is displayed exactly once at
/// creation and cannot be read back, so a misclick could cost somebody an API key
/// permanently.
///
/// One component rather than 20 hand-written dialogs, for the reason this project
/// has now settled twice: parallel implementations of one idea drift, and the
/// drift is invisible until somebody hits the one that was written differently.
/// A site adopts this by changing `Button` to `DestructiveButton` and adding the
/// question, which is small enough that there is no incentive to skip it.
///
/// ## What a good question looks like
///
/// The dialog must name WHAT IS LOST and, where there is one, THE WAY BACK. "Are
/// you sure?" is not a question, it is a speed bump: it tells the reader nothing
/// they did not already know and trains them to confirm without reading. So
/// `what` is required and is a noun phrase, and `detail` carries the recovery
/// path when one exists.
///
/// ## Where this is NOT the right tool
///
/// Inside a `.contextMenu` or a swipe action. Those dismiss when tapped, taking
/// any dialog attached to their contents with them, so the confirmation never
/// appears. There the correct shape is the deferred one `FoldersView` already
/// uses: the menu item sets a `pendingDelete` value and the dialog hangs off the
/// parent view. That is a different pattern for a different reason, not a second
/// way of doing the same thing.
///
/// And nothing cheap and reversible. Clearing a search box or deselecting a
/// preset loses nothing, and a confirmation there is noise that makes the real
/// ones easier to dismiss unread.
struct DestructiveButton: View {

    /// The button's own label, e.g. "Clear memory".
    let title: String
    /// What is destroyed, as the dialog's question. e.g. "Delete everything Grux
    /// has remembered?"
    let question: String
    /// What happens and how to get back, if there is a way back.
    let detail: String?
    /// The confirming button's label. A verb, never "OK": the destructive button
    /// in a dialog should say what it does so the choice is readable at a glance.
    let confirmLabel: String
    let action: () -> Void

    @State private var asking = false

    init(_ title: String,
         question: String,
         detail: String? = nil,
         confirmLabel: String,
         action: @escaping () -> Void) {
        self.title = title
        self.question = question
        self.detail = detail
        self.confirmLabel = confirmLabel
        self.action = action
    }

    var body: some View {
        Button(title, role: .destructive) { asking = true }
            .confirmationDialog(question, isPresented: $asking, titleVisibility: .visible) {
                Button(confirmLabel, role: .destructive, action: action)
                // Explicit, and first in the reading order that matters: macOS
                // gives Cancel the escape key, but somebody scanning the sheet
                // should see a way out without hunting for it.
                Button("Cancel", role: .cancel) { }
            } message: {
                if let detail { Text(detail) }
            }
    }
}

/// The one confirmation host for destructive actions raised from a MENU.
///
/// `DestructiveButton` cannot be used inside a `.contextMenu`, a `Menu` or a
/// swipe action: those dismiss the moment an item is tapped, and a dialog
/// attached to the item's own view goes with them, so the confirmation never
/// appears and the action fires unguarded. That is not a theoretical concern,
/// it is 8 of the 13 remaining delete buttons in this app.
///
/// The alternative shape is to give every one of those views its own `@State`
/// pending value plus its own dialog, which is eight copies of identical
/// plumbing in eight files, each free to drift. This is one request queue with
/// one dialog hosted at the window root, so a menu item is a single call and
/// there is nothing per-file to get wrong.
@MainActor
final class DestructiveConfirm: ObservableObject {
    static let shared = DestructiveConfirm()

    struct Request: Identifiable {
        let id = UUID()
        let question: String
        let detail: String?
        let confirmLabel: String
        let action: () -> Void
        /// The host window that shows it: the window asked from, when it hosts.
        var window: ObjectIdentifier? = nil
    }

    @Published var pending: Request?

    /// Every host and the window it is drawn in, in the order they came up. The
    /// main window and the Settings window both show Settings, so a request goes
    /// to the window it was raised in, and only that window shows it (wave 24: the
    /// Settings window had no host, so its asks showed nowhere). Kept per host,
    /// not per window: two hosts can share a window for a moment while the shell
    /// swaps roots, and the one leaving must not take the other's window with it.
    private var hosts: [(token: UUID, window: () -> NSWindow?)] = []

    func register(_ token: UUID, in window: NSWindow) {
        hosts.removeAll { $0.token == token || $0.window() == nil }
        hosts.append((token, { [weak window] in window }))
    }

    /// The hosts registered now, for the tests.
    var hostTokens: [UUID] { hosts.map(\.token) }

    func unregister(_ token: UUID) {
        hosts.removeAll { $0.token == token || $0.window() == nil }
    }

    /// The windows that host and are on screen now, in the order they came up. A
    /// closed window kept alive for reuse is not one: a request sent there showed
    /// nowhere (wave 24, the menu-bar Delete with the main window closed).
    var visibleHostWindows: [ObjectIdentifier] {
        hosts.removeAll { $0.window() == nil }
        var seen: [ObjectIdentifier] = []
        for host in hosts {
            guard let w = host.window(), w.isVisible else { continue }
            let id = ObjectIdentifier(w)
            if !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    /// The window a request goes to: the key window when it hosts, else the main
    /// window when it hosts, else the first host. Nil only when nothing on screen
    /// hosts, and then the first host to come up shows it.
    nonisolated static func target(key: ObjectIdentifier?, main: ObjectIdentifier?,
                                   hosts: [ObjectIdentifier]) -> ObjectIdentifier? {
        if let key, hosts.contains(key) { return key }
        if let main, hosts.contains(main) { return main }
        return hosts.first
    }

    /// Whether the host in `window` shows `request`.
    nonisolated static func shows(_ request: Request?, in window: ObjectIdentifier?) -> Bool {
        guard let request else { return false }
        return request.window == nil || request.window == window
    }

    /// A name for a dialog's question, in quotes and cut at 60 characters, or the
    /// fallback when there is none (D99: questions name what is lost).
    static func quoted(_ name: String, or fallback: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return fallback }
        return "\"" + (t.count > 60 ? String(t.prefix(57)) + "..." : t) + "\""
    }

    /// Queue a confirmation. Safe to call from a menu item that is about to
    /// dismiss, because the dialog belongs to the window and not to the menu.
    func ask(question: String, detail: String? = nil,
             confirmLabel: String, action: @escaping () -> Void) {
        let window = Self.target(key: NSApp?.keyWindow.map(ObjectIdentifier.init),
                                 main: NSApp?.mainWindow.map(ObjectIdentifier.init),
                                 hosts: visibleHostWindows)
        pending = Request(question: question, detail: detail,
                          confirmLabel: confirmLabel, action: action, window: window)
    }
}

extension View {
    /// Hosts the shared destructive confirmation. Applied once at a window root.
    func destructiveConfirmHost() -> some View {
        modifier(DestructiveConfirmHost())
    }
}

private struct DestructiveConfirmHost: ViewModifier {
    @ObservedObject private var confirm = DestructiveConfirm.shared
    /// This host's window, once the view is in one.
    @State private var window: ObjectIdentifier?

    func body(content: Content) -> some View {
        content
            .background(HostWindowRegistrar { window = $0 })
            .confirmationDialog(
            confirm.pending?.question ?? "",
            isPresented: Binding(get: { DestructiveConfirm.shows(confirm.pending, in: window) },
                                 set: { if !$0 { confirm.pending = nil } }),
            titleVisibility: .visible
        ) {
            if let p = confirm.pending {
                Button(p.confirmLabel, role: .destructive) { p.action(); confirm.pending = nil }
            }
            Button("Cancel", role: .cancel) { confirm.pending = nil }
        } message: {
            if let d = confirm.pending?.detail { Text(d) }
        }
    }
}

/// Registers the window a host is drawn in, and unregisters it when the view
/// leaves that window.
private struct HostWindowRegistrar: NSViewRepresentable {
    let onWindow: (ObjectIdentifier?) -> Void

    final class Probe: NSView {
        var onWindow: ((ObjectIdentifier?) -> Void)?
        /// This host's own registration, so leaving drops only this host.
        private let token = UUID()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let now = window
            if let now { DestructiveConfirm.shared.register(token, in: now) }
            else { DestructiveConfirm.shared.unregister(token) }
            let id = now.map(ObjectIdentifier.init)
            // Not during the view update that moved it.
            DispatchQueue.main.async { [onWindow] in onWindow?(id) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = onWindow
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.onWindow = onWindow }
}

/// A destructive item for a menu or context menu. Raises the shared dialog
/// rather than owning one, because a menu dismisses and takes its own with it.
struct DestructiveMenuButton: View {
    let title: String
    let question: String
    let detail: String?
    let confirmLabel: String
    let action: () -> Void

    init(_ title: String, question: String, detail: String? = nil,
         confirmLabel: String, action: @escaping () -> Void) {
        self.title = title
        self.question = question
        self.detail = detail
        self.confirmLabel = confirmLabel
        self.action = action
    }

    var body: some View {
        Button(title, role: .destructive) {
            DestructiveConfirm.shared.ask(question: question, detail: detail,
                                          confirmLabel: confirmLabel, action: action)
        }
    }
}
