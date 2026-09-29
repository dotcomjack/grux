import Foundation

/// Whether this install knows where its source checkout is, kept live while
/// the Self-Upgrade pane is on screen.
///
/// The card's Build it depends on it, and a click re-measures it (the
/// checkout can move between the tab appearing and the press). Before this,
/// a click that found the checkout gone flipped the card to "Grux cannot
/// build this here" until the tab was reopened, even after the checkout or
/// `~/.grux/source.json` came back. Live state means it re-arms by itself.
///
/// ## Why a short re-check and not a file watch
///
/// Two things can come back: `source.json` (build.sh rewrites it) and the
/// checkout folder itself (re-cloned, a volume remounted, a worktree
/// restored). A watch on source.json sees only the first, and a watch on a
/// folder that does not exist cannot be opened at all. The check is one
/// small file read and two stats (`FoundryEngine.resolveRepoRoot`), so
/// running it every 2 s while the pane is visible, and never otherwise,
/// costs nothing and covers both.
@MainActor
final class SourceCheckoutWatch: ObservableObject {
    @Published private(set) var available: Bool
    private let resolve: () -> Bool

    /// `resolve` is for tests; the app asks the engine.
    init(resolve: @escaping () -> Bool = { FoundryEngine.resolveRepoRoot() != nil }) {
        self.resolve = resolve
        self.available = resolve()
    }

    func recheck() {
        let now = resolve()
        if now != available { available = now }
    }

    /// A click measured the checkout and found it gone.
    func markMissing() {
        if available { available = false }
    }

    /// Re-checks every `interval` until the calling view's task is cancelled.
    func watch(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            recheck()
            try? await Task.sleep(for: interval)
        }
    }
}
