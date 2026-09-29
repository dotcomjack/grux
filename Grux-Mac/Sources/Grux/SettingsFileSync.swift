import Foundation

/// A settings file edited on disk outside Grux applies live, with no quit and
/// no relaunch (Grux-Mac CLAUDE.md, "live state, never a manual refresh").
/// AppState keeps config.json in step through one of these and ThemeConfig
/// keeps theme.json.
///
/// It watches the file and its folder through `FileWatch`, because an
/// in-place write (`echo > config.json`) fires on the file and an atomic save
/// (an editor, `mv`, Grux's own `Persistence.save`) fires on the folder.
///
/// ## No feedback loop with Grux's own writes
///
/// The owner calls `noteOwnWrite()` right after it saves, which records the
/// bytes now on disk. The event that save raises then finds the same bytes
/// and does nothing. Only bytes Grux did not write reach `apply`, and a
/// successful apply records them too, so applying never re-triggers itself
/// even when applying makes the owner save again.
///
/// A file that does not decode (half written, hand edited wrong) is left
/// alone: `apply` returns false, nothing changes, nothing is quarantined, and
/// the next good write applies. Deliberately NOT `Persistence.load`, whose
/// quarantine is right at launch and wrong for a file caught mid-write.
@MainActor
final class SettingsFileSync {
    let url: URL
    /// How many times bytes from outside Grux were applied, for tests.
    private(set) var applied = 0
    /// How many file events were handled, applied or not, for tests that wait on one.
    private(set) var events = 0
    private var lastSynced: Data?
    private var watch: FileWatch?
    private let apply: (Data) -> Bool

    /// `apply` decodes and applies the file's bytes, and returns false when
    /// they do not decode.
    init(url: URL, apply: @escaping (Data) -> Bool) {
        self.url = url
        self.apply = apply
        lastSynced = try? Data(contentsOf: url)
        watch = FileWatch { [weak self] in self?.fileChanged() }
        rewatch()
        // A write that landed between the read and the watch fires nothing,
        // so look once more now that the watch is armed.
        if (try? Data(contentsOf: url)) != lastSynced { fileChanged() }
    }

    /// Grux just wrote the file itself.
    func noteOwnWrite() {
        lastSynced = try? Data(contentsOf: url)
        rewatch()
    }

    private func rewatch() {
        watch?.watch([url.deletingLastPathComponent(), url])
    }

    private func fileChanged() {
        events += 1
        // Re-arm first: an atomic replace killed the file's descriptor.
        rewatch()
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data != lastSynced else { return }
        guard apply(data) else { return }
        // Read back rather than keep `data`: if applying made the owner save,
        // the file now holds the owner's bytes, and those are what its event
        // will find.
        lastSynced = (try? Data(contentsOf: url)) ?? data
        applied += 1
    }
}
