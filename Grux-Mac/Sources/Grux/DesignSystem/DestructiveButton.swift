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
    }

    @Published var pending: Request?

    /// Queue a confirmation. Safe to call from a menu item that is about to
    /// dismiss, because the dialog belongs to the window and not to the menu.
    func ask(question: String, detail: String? = nil,
             confirmLabel: String, action: @escaping () -> Void) {
        pending = Request(question: question, detail: detail,
                          confirmLabel: confirmLabel, action: action)
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

    func body(content: Content) -> some View {
        content.confirmationDialog(
            confirm.pending?.question ?? "",
            isPresented: Binding(get: { confirm.pending != nil },
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
