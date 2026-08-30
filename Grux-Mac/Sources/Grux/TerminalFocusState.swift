import Foundation
import AppKit
import Combine

// MARK: - Domain types

enum OverlayCorner: String, CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight
}

enum OverlayViewMode: String, Codable, CaseIterable {
    case grid, focused
    var label: String { self == .grid ? "2×2 Grid" : "Focused" }
}

enum SessionTaskStatus: String, Codable {
    case completed, inProgress = "in_progress", pending
}

struct SessionTask: Codable, Identifiable {
    var id: String { title }
    let title: String
    let status: SessionTaskStatus
}

// Claude-emitted out-of-session suggestion. Rendered faintly in the cell with a "+"
// button that promotes it into the Grux focus-task stack via AppState.addTask(…).
struct SuggestedTask: Codable, Identifiable, Hashable {
    var id: String { title }
    let title: String
    let rationale: String
}

// A single tool-call observed by the hook (Read, Edit, Bash, etc.). Rendered in the
// cell footer as a rolling activity trail so the user can see live session rhythm.
struct ActivityEvent: Codable, Identifiable, Hashable {
    let tool: String
    let ts: Date
    var id: String { "\(tool)-\(ts.timeIntervalSince1970)" }

    var ageString: String {
        let secs = Int(Date().timeIntervalSince(ts))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }
}

struct TerminalSession: Identifiable {
    let tty: String
    var id: String { tty }
    var summary: String
    var tasks: [SessionTask]
    var lastUpdated: Date
    var isSynthetic: Bool = false   // true = live terminal title, no hook data yet
    var suggestions: [SuggestedTask] = []
    var recentActivity: [ActivityEvent] = []   // newest last

    var latestTool: String? { recentActivity.last?.tool }

    var isActive: Bool { isSynthetic || Date().timeIntervalSince(lastUpdated) < 8 }

    func isStuck(thresholdMinutes: Int) -> Bool {
        let hasPending = tasks.contains { $0.status == .inProgress || $0.status == .pending }
        return hasPending && Date().timeIntervalSince(lastUpdated) > Double(thresholdMinutes * 60)
    }

    var ageString: String {
        let secs = Int(Date().timeIntervalSince(lastUpdated))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }

    // Derived display name from summary ("Project · task" → "Project")
    var projectName: String {
        let parts = summary.components(separatedBy: " · ")
        return parts.first ?? tty
    }
}

// MARK: - State

@MainActor
final class TerminalFocusState: ObservableObject {
    static let shared = TerminalFocusState()

    @Published var isEnabled: Bool = true
    @Published var isVisible: Bool = false
    @Published var isFaded: Bool = false
    @Published var isGruxFront: Bool = false
    // User-initiated dismiss. Distinct from isEnabled (feature kill-switch):
    // userHidden = "overlay is parked until the user re-summons it (voice / menu / hotkey)".
    // Persisted so a click-to-hide survives relaunch. Cleared by any explicit
    // show path (showOverlay, voice "overlay on", menu toggle, settings flip).
    @Published var userHidden: Bool = false
    // Auto-hide whenever Terminal isn't the frontmost app. Off by default -
    // preserves the original always-visible behavior. Opt-in from settings.
    @Published var autoHideWhenTerminalInactive: Bool = false
    // Tracks whether Terminal is the current frontmost app. Updated by the
    // workspace observer + poll ticks so updateVisibility() can react without
    // re-querying NSWorkspace each time.
    @Published private(set) var isTerminalFront: Bool = false
    @Published var viewMode: OverlayViewMode = .grid
    @Published var stuckThresholdMinutes: Int = 10
    @Published var fadeOpacity: Double = 0.78
    @Published var showInfoPanel: Bool = false
    @Published var showSettingsPanel: Bool = false
    @Published var cornerSessions: [OverlayCorner: TerminalSession] = [:]
    @Published var allSessions: [TerminalSession] = []

    // Adaptive grid: inferred from the actual count + positions of visible
    // Terminal windows. Drives TaskGridView's renderer when the cockpit is
    // not the legacy 2×2 (e.g. six-pack 3×2, dual 1×2, solo 1×1). Defaults to
    // (2, 2) so the existing corner-based rendering path stays unchanged when
    // no windows are open or window inference fails.
    @Published var gridCols: Int = 2
    @Published var gridRows: Int = 2
    // Sessions in row-major slot order matching the inferred grid. nil = empty
    // tile (window present, no Claude session resolved). Length always equals
    // gridCols * gridRows.
    @Published var gridSlots: [TerminalSession?] = []
    @Published var hookInstalled: Bool = false
    @Published var pinnedCorners: [OverlayCorner: String] = [:]  // corner → TTY
    @Published var isResyncing: Bool = false
    @Published var historyEntries: [SessionHistoryEntry] = []
    @Published var showHistoryPanel: Bool = false

    // Maps TTY → last time the user focused that Terminal window. Used to compute
    // `needsReview`: a session whose hook fired more recently than the user last looked
    // at the window. Reset when that window becomes frontmost again.
    @Published var lastFocusedTTYAt: [String: Date] = [:]
    // Titles of suggestions the user has already promoted into Grux - hidden from the
    // cell so they don't keep re-appearing after "+" clicks. Keyed by TTY.
    @Published var promotedSuggestions: [String: Set<String>] = [:]

    // v1 Terminal-Focus bridge: tails Claude Code's native JSONL logs and maps
    // sessionId → OverlayCorner. Auto-detects based on the current Space's
    // Terminal windows (TTY → cwd → session), with manual cfg.slotMapping as
    // a fallback for corners with no matching visible window. Independent of
    // the legacy .grux/focus hook path.
    @Published var cornerSnapshots: [OverlayCorner: ClaudeSessionSnapshot] = [:]
    // Adaptive overlay: per-slot Claude session snapshots in row-major order,
    // length == gridCols * gridRows. Populated alongside cornerSnapshots in
    // refreshClaudeCornerMapping; nil entries indicate Terminal-window-present
    // but no Claude session resolved (or session not yet tailed). The 2x2
    // overlay path keeps reading cornerSnapshots; the adaptive renderer for
    // any other shape reads slotSnapshots.
    @Published var slotSnapshots: [ClaudeSessionSnapshot?] = []
    @Published var terminalFocusCfg: TerminalFocusConfig = .default

    // Descriptors that back the Settings "Claude session mapping" pickers.
    // Maintained ONLY off the main thread (see refreshClaudeSessionIndexIfStale).
    // The settings view reads this @Published list instead of calling
    // ClaudeSessionIndex.recentSessions() itself: that scan reads and parses
    // the 50 newest ~/.claude/projects JSONL files (hundreds of MB combined,
    // single files >200MB), and doing it synchronously in the view's .onAppear
    // wedged the main thread for ~30s during the launch window's first layout,
    // so the terminalFocus window never composited (the "no window on
    // --open-tab=terminalFocus" bug).
    @Published private(set) var sessionPickerDescriptors: [ClaudeSessionDescriptor] = []

    private var claudeTailerSub: AnyCancellable?
    private var cfgChangeSub: AnyCancellable?
    /// Observers for the three start conditions. Non-empty means the gate is armed.
    private var gateSubs: Set<AnyCancellable> = []
    /// One-way latch, so the machinery starts once no matter which observer fires first.
    private var hasStartedWatching = false

    // Cache of `ClaudeSessionIndex.recentSessions(...)`. The index scans every
    // JSONL under ~/.claude/projects which is too expensive to re-run on every
    // 1.5s poll. Refreshed in the background every indexCacheTTL seconds.
    private var claudeSessionIndexCache: [ClaudeSessionDescriptor] = []
    private var claudeSessionIndexCacheAge: Date = .distantPast
    private let claudeSessionIndexCacheTTL: TimeInterval = 30
    private var claudeSessionIndexRefreshing = false

    // Cached corner → sessionId mapping, rebuilt by `refreshClaudeCornerMapping`
    // and re-read by the tailer sink when new JSONL bytes arrive. Keeps the
    // expensive CG window enumeration off the tailer's hot path.
    private var cornerBySessionId: [OverlayCorner: String] = [:]
    private var cornerDescriptorCache: [OverlayCorner: ClaudeSessionDescriptor] = [:]
    // Mirrors of cornerBySessionId / cornerDescriptorCache, but keyed by
    // row-major slot index instead of OverlayCorner. Powers slotSnapshots for
    // non-2x2 cockpits. Built by refreshClaudeCornerMapping using the same
    // CWD→ClaudeDescriptor lookup.
    private var slotBySessionId: [Int: String] = [:]
    private var slotDescriptorCache: [Int: ClaudeSessionDescriptor] = [:]
    // Last-seen set of tracked sessionIds, so we only call
    // `ClaudeSessionTailer.track()` (which emits on @Published) when the set
    // actually changes - breaks the feedback loop that hung the main thread.
    private var lastTrackedSessionIds: Set<String> = []

    private let focusDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/focus")
    private var dirFD: Int32 = -1
    private var dirWatchSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var workspaceObserver: Any?
    private var spaceObserver: Any?
    private var pendingResyncCorner: OverlayCorner?
    private var resyncObserver: Any?
    private static var syntheticFirstSeen: [String: Date] = [:]
    private var prevSessionDates: [String: Date] = [:]

    private init() {
        loadConfig()
        terminalFocusCfg = TerminalFocusConfig.load()
        checkHookInstalled()
    }

    /// TWO DIALOGS USED TO COME OUT OF THIS FUNCTION ON A FIRST LAUNCH, and neither had a
    /// word of explanation in front of it.
    ///
    /// The first was Screen Recording. Line 210 called `CGRequestScreenCaptureAccess()`
    /// unconditionally, so about a second after onboarding painted, macOS put "Grux would
    /// like to record this computer's screen and audio" on top of it. `terminal.focus` is a
    /// LABS feature. Worse than the surprise: that prompt is a ONE SHOT, so spending it here
    /// spends the one onboarding and the Terminal Focus setup card depend on, both of which
    /// ask for it with a reason on screen. Preflighting never prompts; requesting is left to
    /// `CapabilityRequest.request(.permScreenRecording)`, which has somewhere to say why.
    ///
    /// The second was Automation. `refresh()` begins with a tty cache refresh whose age
    /// starts at `.distantPast`, so it always fired, and it shells osascript at Terminal.app.
    /// macOS asked to control Terminal, and approving it LAUNCHES Terminal to answer.
    ///
    /// So the whole body now waits for the same three conditions `restoreOverlayAtLaunch`
    /// waits for. A Labs feature nobody has been told about does not get to speak to the
    /// system on its behalf.
    func start() {
        // The two harmless halves stay unconditional. Neither raises UI, neither reaches
        // outside Grux's own folder, and the hook script has to be on disk before a shell
        // that already has the hook installed can source it.
        try? FileManager.default.createDirectory(at: focusDir, withIntermediateDirectories: true)
        syncHookScriptIfNeeded()

        // AND THE GATE HAS TO BE ABLE TO OPEN LATER, which is the half a bare `guard` gets
        // wrong. `start()` is called from exactly one place, GruxApp.swift:989, once per
        // launch. Returning early there and stopping would mean somebody who reads the
        // Terminal Sessions card and switches the feature on sees nothing happen until they
        // quit and reopen Grux, and that is a worse bug than the dialog this replaced.
        //
        // So the conditions are OBSERVED rather than sampled, the same correction
        // `startWhenOnboardingIsDone()` carries in GruxApp for the other watchers.
        // `markStepCompleted` posts no notification, so the Terminal Sessions pane calls
        // `startIfAllowed()` itself after it writes the step.
        if gateSubs.isEmpty {
            $isEnabled
                .removeDuplicates()
                .sink { [weak self] _ in
                    // On the NEXT tick: this fires from inside the publisher's own send,
                    // before `isEnabled` has been assigned, so reading it here would read
                    // the old value and the feature would need two flips to start.
                    DispatchQueue.main.async { self?.startIfAllowed() }
                }
                .store(in: &gateSubs)
            OnboardingModel.shared.$stage
                .removeDuplicates()
                .sink { [weak self] _ in DispatchQueue.main.async { self?.startIfAllowed() } }
                .store(in: &gateSubs)
        }
        startIfAllowed()
    }

    /// The three conditions, pure so a test can drive all eight combinations without an
    /// onboarding model, a defaults domain, or a Mac.
    ///
    /// `nonisolated` because the enclosing type is `@MainActor`, which would otherwise make
    /// this static main-actor isolated and unreachable from a plain test method.
    nonisolated static func mayStartWatching(isEnabled: Bool,
                                             onboardingDone: Bool,
                                             sessionsExplained: Bool) -> Bool {
        isEnabled && onboardingDone && sessionsExplained
    }

    /// Idempotent. Safe to call from the launch path, from either observer above, and from
    /// the Terminal Sessions settings pane, which is the point: whichever of the three
    /// conditions lands last is the one that starts the machinery.
    func startIfAllowed() {
        guard !hasStartedWatching else { return }
        guard Self.mayStartWatching(
            isEnabled: isEnabled,
            onboardingDone: OnboardingModel.shared.stage == .done,
            sessionsExplained: CapabilityResolver.isSatisfied(.stepTerminalSessionsExplained))
        else { return }
        hasStartedWatching = true

        // Seed isTerminalFront before any activation notification fires so
        // the auto-hide rule gets the right answer on the very first poll.
        isTerminalFront = NSWorkspace.shared.frontmostApplication?.localizedName == "Terminal"
        startDirWatch()
        startPollTimer()
        setupWorkspaceObserver()
        startClaudeSessionBridge()
        refresh()
    }

    // MARK: - Claude session bridge (v1)

    private func startClaudeSessionBridge() {
        // Tailer → view binding. Uses the CACHED corner → sessionId mapping
        // (rebuilt only when refreshClaudeCornerMapping() is called on the
        // 1.5s poll timer) so the hot path here is a cheap dictionary walk.
        // `.removeDuplicates()` also short-circuits no-op emissions from the
        // tailer's `track()` call.
        claudeTailerSub = ClaudeSessionTailer.shared.$snapshotsBySessionId
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in
                self?.rebuildCornerSnapshotsFromTailer(snapshots: snapshots)
            }

        // Re-run the (expensive) CG-window scan only when the user changes the
        // manual slot mapping or hotkey.
        cfgChangeSub = $terminalFocusCfg
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshClaudeCornerMapping() }

        refreshClaudeSessionIndexIfStale()
        refreshClaudeCornerMapping()
        ClaudeSessionTailer.shared.start()
    }

    // Computes the current Space's 4 corners → ClaudeSessionSnapshot mapping by:
    //   1. Enumerating the visible Terminal windows on the active Space, and
    //      finding each one's TTY (title-matched via AppleScript cache).
    //   2. Resolving each TTY to a cwd (cached ps+lsof lookup).
    //   3. Matching that cwd to the most-recently-active Claude session.
    //   4. Falling back to the persisted `slotMapping` for corners without a
    //      visible Terminal window (e.g. if the user has fewer than 4 open,
    //      or has explicitly pinned a session to a corner).
    //
    // Tracks the resulting set in `ClaudeSessionTailer` ONLY when the set
    // actually changes - otherwise the @Published emission from track() feeds
    // back into `claudeTailerSub` and re-enters this method, creating a tight
    // CPU loop that hangs the main thread (ANR).
    func refreshClaudeCornerMapping() {
        let frame = overlayFrame()

        let ttyByCorner = TerminalWindowMapper.currentSpaceTTYsByCorner(overlayFrame: frame)
        TerminalWindowMapper.scheduleRefreshCwdCache(ttys: Set(ttyByCorner.values))

        var cwdByCorner: [OverlayCorner: String] = [:]
        for (corner, tty) in ttyByCorner {
            if let cwd = TerminalWindowMapper.cachedCwd(forTTY: tty) {
                cwdByCorner[corner] = cwd
            }
        }

        refreshClaudeSessionIndexIfStale()
        let recent = claudeSessionIndexCache

        var bestByCwd: [String: ClaudeSessionDescriptor] = [:]
        for desc in recent {
            guard let cwd = desc.cwd else { continue }
            if let existing = bestByCwd[cwd], existing.lastActiveAt > desc.lastActiveAt { continue }
            bestByCwd[cwd] = desc
        }

        var cornerDescriptor: [OverlayCorner: ClaudeSessionDescriptor] = [:]
        for (corner, cwd) in cwdByCorner {
            if let desc = bestByCwd[cwd] { cornerDescriptor[corner] = desc }
        }
        for corner in OverlayCorner.allCases where cornerDescriptor[corner] == nil {
            if let sid = terminalFocusCfg.slotMapping.sessionId(for: corner),
               let desc = recent.first(where: { $0.sessionId == sid }) {
                cornerDescriptor[corner] = desc
            }
        }

        cornerDescriptorCache = cornerDescriptor
        cornerBySessionId = cornerDescriptor.mapValues { $0.sessionId }

        // Adaptive plumbing: build the parallel slot-indexed maps using the
        // row-major TTY→CWD list from TerminalWindowMapper. Each slot index
        // (0 = top-left, then reading order) gets the ClaudeDescriptor for
        // the matching CWD if one is recent.
        let shape = TerminalWindowMapper.inferGridShape()
        var slotDescriptor: [Int: ClaudeSessionDescriptor] = [:]
        let cwdsRowMajor = TerminalWindowMapper.cwdsRowMajor(shape: shape)
        for (i, cwd) in cwdsRowMajor.enumerated() {
            if let cwd, let desc = bestByCwd[cwd] {
                slotDescriptor[i] = desc
            }
        }
        slotDescriptorCache = slotDescriptor
        slotBySessionId = slotDescriptor.mapValues { $0.sessionId }

        // Tailer subscription must cover BOTH paths (2x2 corner cells AND any
        // adaptive slots) so all rendered cells get live tailing data.
        let newIds = Set(cornerDescriptor.values.map { $0.sessionId })
            .union(Set(slotDescriptor.values.map { $0.sessionId }))
        if newIds != lastTrackedSessionIds {
            lastTrackedSessionIds = newIds
            let combined = Array(cornerDescriptor.values) + Array(slotDescriptor.values)
            ClaudeSessionTailer.shared.track(sessions: combined)
        }

        rebuildCornerSnapshotsFromTailer(
            snapshots: ClaudeSessionTailer.shared.snapshotsBySessionId
        )
    }

    // Cheap map from cached cornerBySessionId + the latest tailer snapshots
    // to cornerSnapshots. Called on every tailer emission (via claudeTailerSub)
    // WITHOUT re-enumerating Terminal windows - that happens only on the poll
    // tick or cfg change.
    private func rebuildCornerSnapshotsFromTailer(snapshots: [String: ClaudeSessionSnapshot]) {
        var next: [OverlayCorner: ClaudeSessionSnapshot] = [:]
        for (corner, sid) in cornerBySessionId {
            if let snap = snapshots[sid] {
                next[corner] = snap
            } else if let desc = cornerDescriptorCache[corner] {
                next[corner] = Self.stubSnapshot(from: desc)
            }
        }
        if next != cornerSnapshots {
            cornerSnapshots = next
        }

        // Adaptive grid: rebuild slotSnapshots row-major. Length must equal
        // gridCols * gridRows so the overlay's LazyVGrid renders a clean
        // rectangular grid even when some slots have no resolved session.
        let total = max(1, gridCols * gridRows)
        var slots = [ClaudeSessionSnapshot?](repeating: nil, count: total)
        for (idx, sid) in slotBySessionId where idx < total {
            if let snap = snapshots[sid] {
                slots[idx] = snap
            } else if let desc = slotDescriptorCache[idx] {
                slots[idx] = Self.stubSnapshot(from: desc)
            }
        }
        if slots != slotSnapshots {
            slotSnapshots = slots
        }
    }

    private static func stubSnapshot(from desc: ClaudeSessionDescriptor) -> ClaudeSessionSnapshot {
        ClaudeSessionSnapshot(
            sessionId: desc.sessionId,
            cwd: desc.cwd,
            gitBranch: nil,
            title: desc.title,
            lastMessageAt: desc.lastActiveAt,
            currentTool: nil,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0,
            totalCostUSD: 0,
            lastAssistantSummary: "",
            model: nil
        )
    }

    // Background refresh of the recent-sessions list. `refreshClaudeCornerMapping`
    // reads `claudeSessionIndexCache` synchronously on the main thread; this
    // only updates that cache when stale to avoid blocking the UI loop.
    private func refreshClaudeSessionIndexIfStale() {
        guard !claudeSessionIndexRefreshing,
              Date().timeIntervalSince(claudeSessionIndexCacheAge) >= claudeSessionIndexCacheTTL
        else { return }
        claudeSessionIndexRefreshing = true
        claudeSessionIndexCacheAge = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fresh = ClaudeSessionIndex.recentSessions(limit: 200)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.claudeSessionIndexCache = fresh
                // Feed the Settings picker off the same background scan so the
                // view never has to read session JSONL on the main thread.
                self.sessionPickerDescriptors = fresh
                self.claudeSessionIndexRefreshing = false
            }
        }
    }

    // Settings entry point. Serves whatever the background-maintained cache
    // already holds so the picker paints instantly, then kicks a stale-guarded
    // background refresh. NEVER reads session JSONL on the main thread - that
    // is what wedged the launch window for the terminalFocus tab.
    func loadSessionPickerDescriptorsIfNeeded() {
        if sessionPickerDescriptors.isEmpty && !claudeSessionIndexCache.isEmpty {
            sessionPickerDescriptors = claudeSessionIndexCache
        }
        refreshClaudeSessionIndexIfStale()
    }

    // "Refresh" button in Settings. Forces the (background) scan to re-run even
    // if the cache is still within its TTL.
    func reloadSessionPicker() {
        claudeSessionIndexCacheAge = .distantPast
        refreshClaudeSessionIndexIfStale()
    }

    // Called by settings when the user picks / clears a session for a corner.
    func setSessionMapping(_ sessionId: String?, for corner: OverlayCorner) {
        var cfg = terminalFocusCfg
        cfg.slotMapping.set(sessionId, for: corner)
        terminalFocusCfg = cfg
        cfg.save()
    }

    // Called by the settings hotkey recorder when the user captures a new
    // combo. The GruxApp lifecycle observes terminalFocusCfg changes and
    // re-registers the OS-level hotkey - the state layer just owns the value.
    func setHotkey(_ hotkey: HotkeyConfig) {
        var cfg = terminalFocusCfg
        cfg.hotkey = hotkey
        terminalFocusCfg = cfg
        cfg.save()
    }

    // If the user previously installed the hook, silently refresh the script contents
    // when the app's bundled version is newer AND re-merge the settings entry so the
    // matcher reflects the current hookMatcher. Avoids making the user re-run the Install
    // UI for every app update that changes hook logic. Idempotent when up to date.
    private func syncHookScriptIfNeeded() {
        guard FileManager.default.fileExists(atPath: hookScriptURL.path) else { return }
        let expected = "GRUX_HOOK_VERSION=\(Self.hookScriptVersion)"
        if let contents = try? String(contentsOf: hookScriptURL, encoding: .utf8),
           contents.contains(expected),
           settingsMatcherIsCurrent() {
            return
        }
        do {
            try hookScript.write(to: hookScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
            try mergeHookIntoSettings()
        } catch {
            // Silent: user can always re-install from Settings if this fails.
        }
    }

    // Returns true if settings.json already has exactly our script registered under
    // the current `hookMatcher`. Used to skip redundant writes on every launch.
    private func settingsMatcherIsCurrent() -> Bool {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any],
              let postToolUse = hooks["PostToolUse"] as? [[String: Any]]
        else { return false }
        let scriptPath = hookScriptURL.path
        return postToolUse.contains { entry in
            guard (entry["matcher"] as? String) == Self.hookMatcher else { return false }
            let subhooks = entry["hooks"] as? [[String: Any]] ?? []
            return subhooks.contains { ($0["command"] as? String) == scriptPath }
        }
    }

    func stop() {
        dirWatchSource?.cancel()
        dirWatchSource = nil
        if dirFD >= 0 { close(dirFD); dirFD = -1 }
        pollTimer?.invalidate()
        pollTimer = nil
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        if let obs = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceObserver = nil
        }
    }

    // MARK: - Internals

    private func startDirWatch() {
        dirFD = open(focusDir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.loadSessions() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.dirFD)
            self.dirFD = -1
        }
        source.resume()
        dirWatchSource = source
    }

    /// Start or stop the 1.5s poll depending on whether the overlay can actually change.
    ///
    /// This used to be an unconditional repeating timer armed at launch, and `start()` is
    /// called from `GruxApp` on every launch whether or not anyone uses Terminal Focus,
    /// which is a `labs` feature. Each tick runs `refresh()`, and that is six calls deep
    /// including several CGWindowList enumerations. A `sample` of the shipping build made
    /// it the single largest Grux-attributed block on the main thread.
    ///
    /// Nothing it computes can change while the overlay is hidden and Terminal is not
    /// frontmost, so in that state the timer is torn down rather than early-returning: a
    /// timer that wakes to do nothing still wakes. The state is event driven for exactly
    /// this reason, `startDirWatch()` for session files and `setupWorkspaceObserver()` for
    /// activation, and both call back here to arm it again.
    private func syncPollTimer() {
        let needed = isEnabled && (isVisible || isTerminalFront)
        if needed {
            guard pollTimer == nil else { return }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        } else if pollTimer != nil {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func startPollTimer() {
        syncPollTimer()
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.isGruxFront = app?.bundleIdentifier == Bundle.main.bundleIdentifier
                self.isTerminalFront = app?.localizedName == "Terminal"
                // Terminal coming forward is the event that arms the poll again.
                self.syncPollTimer()
                // When auto-hide is armed, activation changes flip visibility -
                // react immediately so the overlay disappears the moment the user
                // clicks into Safari / VS Code / etc., not on the next poll tick.
                if self.autoHideWhenTerminalInactive {
                    self.updateVisibility()
                }
            }
        }
        // Refresh visibility when user switches Spaces
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        TerminalWindowMapper.scheduleRefreshTTYCache()
        loadSessions()
        updateVisibility()
        updateCornerAssignments()
        refreshClaudeCornerMapping()
        updateFocusTracking()
    }

    // Updates lastFocusedTTYAt for the currently-frontmost Terminal window.
    // Called on every poll tick so window-level focus (Cmd+` within Terminal)
    // is captured without relying on app-level activation.
    private func updateFocusTracking() {
        if let tty = TerminalWindowMapper.frontmostWindowTTY() {
            lastFocusedTTYAt[tty] = Date()
        }
    }

    // A session "needs review" when its hook fired more recently than the user last
    // looked at the Terminal window - AND the session has settled (not actively
    // streaming updates) - AND it's a real TodoWrite session (not a synthetic stub).
    func needsReview(_ session: TerminalSession) -> Bool {
        guard !session.isSynthetic, !session.isActive else { return false }
        if session.isStuck(thresholdMinutes: stuckThresholdMinutes) { return false }
        let focusedAt = lastFocusedTTYAt[session.tty] ?? session.lastUpdated
        return session.lastUpdated > focusedAt
    }

    // Promote a suggestion into Grux's focus-task stack. Records the title locally
    // so it doesn't keep reappearing in the cell if the hook regenerates the same idea.
    func promoteSuggestion(_ suggestion: SuggestedTask, from session: TerminalSession) {
        AppState.shared.addTask(suggestion.title, project: session.projectName, priority: .next)
        var set = promotedSuggestions[session.tty] ?? []
        set.insert(suggestion.title)
        promotedSuggestions[session.tty] = set
    }

    private func loadSessions() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: focusDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        // Pass 1: index suggestion + activity sidecar files by TTY.
        var suggestionsByTTY: [String: [SuggestedTask]] = [:]
        var activityByTTY: [String: [ActivityEvent]] = [:]
        for file in files {
            let name = file.lastPathComponent
            if name.hasSuffix(".suggestions.json") {
                guard let data = try? Data(contentsOf: file),
                      let parsed = try? JSONDecoder().decode(SuggestionsPayload.self, from: data) else { continue }
                let base = name.replacingOccurrences(of: ".suggestions.json", with: "")
                suggestionsByTTY[base] = parsed.suggestions
            } else if name.hasSuffix(".activity.jsonl") {
                let base = name.replacingOccurrences(of: ".activity.jsonl", with: "")
                if let raw = try? String(contentsOf: file, encoding: .utf8) {
                    var events: [ActivityEvent] = []
                    for line in raw.split(separator: "\n") {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let tool = obj["tool"] as? String,
                              let ts = obj["ts"] as? Double else { continue }
                        events.append(ActivityEvent(tool: tool, ts: Date(timeIntervalSince1970: ts)))
                    }
                    activityByTTY[base] = events
                }
            }
        }

        var loaded: [TerminalSession] = []
        var seenTTYs = Set<String>()

        // Pass 2: emit sessions for every TTY that has a session JSON (real TodoWrite state).
        for file in files where file.pathExtension == "json"
            && !file.lastPathComponent.hasPrefix("grux-")
            && !file.lastPathComponent.hasSuffix(".suggestions.json") {
            guard let data = try? Data(contentsOf: file),
                  let parsed = try? JSONDecoder().decode(SessionPayload.self, from: data) else { continue }
            let mdate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let tty = file.deletingPathExtension().lastPathComponent
            seenTTYs.insert(tty)
            let rawSuggestions = suggestionsByTTY[tty] ?? []
            let alreadyAdded = promotedSuggestions[tty] ?? []
            let suggestions = rawSuggestions.filter { !alreadyAdded.contains($0.title) }
            let activity = activityByTTY[tty] ?? []
            // Use max of the two sources so any tool call (not just TodoWrite) refreshes liveness.
            let latestActivityTs = activity.last?.ts ?? .distantPast
            loaded.append(TerminalSession(
                tty: tty,
                summary: parsed.summary,
                tasks: parsed.tasks,
                lastUpdated: max(mdate, latestActivityTs),
                suggestions: suggestions,
                recentActivity: activity
            ))
        }

        // Pass 3: emit sessions for TTYs that have activity logs but no TodoWrite JSON yet -
        // hook is firing, just no todo plan recorded. These show activity-only until TodoWrite.
        for (tty, activity) in activityByTTY where !seenTTYs.contains(tty) && !activity.isEmpty {
            seenTTYs.insert(tty)
            let rawSuggestions = suggestionsByTTY[tty] ?? []
            let alreadyAdded = promotedSuggestions[tty] ?? []
            let suggestions = rawSuggestions.filter { !alreadyAdded.contains($0.title) }
            let latest = activity.last?.ts ?? Date()
            loaded.append(TerminalSession(
                tty: tty,
                summary: "",
                tasks: [],
                lastUpdated: latest,
                suggestions: suggestions,
                recentActivity: activity
            ))
        }

        // Synthetic sessions for on-screen windows with no JSON file yet.
        // Use stable first-seen timestamps so the sort order doesn't flicker every 1.5s.
        let jsonTTYs = Set(loaded.map(\.tty))
        let liveSummaries = TerminalWindowMapper.liveWindowSummaries()
        let liveTTYs = Set(liveSummaries.map(\.tty))
        Self.syntheticFirstSeen = Self.syntheticFirstSeen.filter { liveTTYs.contains($0.key) }
        for (tty, title) in liveSummaries where !jsonTTYs.contains(tty) {
            let date: Date = {
                if let d = Self.syntheticFirstSeen[tty] { return d }
                let d = Date(); Self.syntheticFirstSeen[tty] = d; return d
            }()
            let summary = Self.parseTerminalTitle(title)
            loaded.append(TerminalSession(tty: tty, summary: summary, tasks: [], lastUpdated: date, isSynthetic: true))
        }

        // Detect changed hook-driven sessions → add history entries
        for session in loaded where !session.isSynthetic {
            let prev = prevSessionDates[session.tty]
            if prev == nil || session.lastUpdated > prev! {
                if !session.tasks.isEmpty {
                    let entry = SessionHistoryEntry(tty: session.tty, summary: session.summary,
                                                   tasks: session.tasks, timestamp: session.lastUpdated)
                    historyEntries.insert(entry, at: 0)
                    if historyEntries.count > 40 { historyEntries = Array(historyEntries.prefix(40)) }
                }
            }
            prevSessionDates[session.tty] = session.lastUpdated
        }

        // Seed focus times for TTYs we're seeing for the first time so they don't flash
        // REVIEW on startup. Initial value = session.lastUpdated (treat "seen as of now").
        for session in loaded where lastFocusedTTYAt[session.tty] == nil {
            lastFocusedTTYAt[session.tty] = session.lastUpdated
        }

        allSessions = loaded.sorted { $0.lastUpdated > $1.lastUpdated }
    }

    private static func parseTerminalTitle(_ title: String) -> String {
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return title }
        let task = parts[1]
        // Strip Claude Code status icon (non-ASCII char + space at start)
        guard let first = task.first, !first.isASCII, task.count > 2,
              task.dropFirst().first == " " else { return task }
        return String(task.dropFirst(2))
    }

    private func updateVisibility() {
        defer { syncPollTimer() }
        let count = TerminalWindowMapper.terminalWindowCount()
        // Five gates, any of which can hide:
        //   - feature kill-switch (isEnabled)
        //   - user-initiated dismiss (userHidden)
        //   - no Terminal windows open AND no Claude sessions mapped
        //   - opt-in auto-hide when Terminal isn't frontmost
        // The "has something to show" rule is OR'd: the v1 Claude-session
        // path satisfies it even when the legacy Terminal-window count is 0.
        let hiddenByAutoRule = autoHideWhenTerminalInactive && !isTerminalFront
        let hasAnythingToShow = count >= 1 || !terminalFocusCfg.slotMapping.assigned.isEmpty
        // Onboarding gate, and it belongs HERE rather than on the launch path.
        // Fixing only the boot call left the overlay appearing anyway, because
        // the poll timer computes visibility independently and a fresh install
        // satisfies every other condition the moment any Terminal window is
        // open. This is the one place every trigger passes through, so it is
        // the only place the gate cannot be routed around.
        let onboarded = OnboardingModel.shared.stage == .done
        let shouldBeVisible = isEnabled && !userHidden && hasAnythingToShow
            && !hiddenByAutoRule && onboarded
        guard shouldBeVisible != isVisible else { return }
        isVisible = shouldBeVisible
        if shouldBeVisible {
            TerminalFocusOverlayController.shared.show()
        } else {
            TerminalFocusOverlayController.shared.hide()
        }
    }

    // MARK: - Explicit show / hide (public API)

    // User-initiated dismiss. Persists so the overlay doesn't re-appear on its
    // own via the next poll tick. Cleared by showOverlay().
    func hideOverlay() {
        guard !userHidden else { return }
        userHidden = true
        saveConfig()
        updateVisibility()
    }

    // Re-summon path. Called from: × button (no-op unless userHidden), voice
    // macros ("overlay on"), menu bar toggle, settings "Show" button, and the
    // global Option-Cmd-T hotkey. Also auto-enables the feature if the
    // kill-switch was off.
    //
    // THE HOTKEY IS THE REASON THIS FUNCTION HAS A GATE NOW. Holding the launch
    // path was not enough: `GlobalHotkey.register` claims Option-Cmd-T
    // unconditionally, and pressing it landed here, which force-set
    // `isEnabled = true` and called `refresh()` straight past `startIfAllowed()`.
    // `refresh()` shells osascript at Terminal, so on a Mac where Terminal
    // happens to be running that is the same Automation consent dialog the launch
    // fix removed, reached by a key combination nobody has been told about, for a
    // Labs feature nobody has been told about.
    //
    // Force-enabling the kill-switch stays: somebody who presses the hotkey or
    // says "overlay on" is ASKING for the feature, and that is a real answer.
    // What does not follow from it is permission to speak to another app on
    // their behalf before the step that explains what this does. So the switch
    // flips, and the machinery still waits for `startIfAllowed()`.
    func showOverlay() {
        var dirty = false
        if !isEnabled { isEnabled = true; dirty = true }
        if userHidden { userHidden = false; dirty = true }
        if dirty { saveConfig() }
        // Always call refresh so the panel (and underlying session data) comes
        // back fresh, not just a stale last-frame render. Via startIfAllowed so
        // it cannot outrun the consent step; once the machinery is already
        // running that call is a cheap latch check and refresh happens below.
        startIfAllowed()
        guard hasStartedWatching else { return }
        refresh()
    }

    /// Launch-time restore. Shows the overlay ONLY if it was already both
    /// enabled and unhidden, and never touches either flag.
    ///
    /// Boot used to call `showOverlay()`, which is the user-intent path and
    /// therefore carries `if !isEnabled { isEnabled = true }`. That override is
    /// right when a person says "overlay on" and wrong when a timer says it:
    /// every launch silently re-armed the feature kill-switch, so turning the
    /// overlay off did not survive a restart. That is the behaviour reported as
    /// "it turns on at boot".
    ///
    /// It also stays away during onboarding. A floating terminal overlay
    /// appearing over a setup flow, on a machine whose owner has not opened a
    /// terminal yet, reads as the app malfunctioning.
    ///
    /// AND IT STAYS AWAY UNTIL SOMEBODY HAS BEEN TOLD WHAT IT IS. The contract already
    /// carries `step.terminal_sessions_explained`, labelled "Understand terminal sessions",
    /// and seven features in the registry list it. It gated NOTHING: the only code that read
    /// it was the Settings pane that also writes it, so a declared step existed purely to be
    /// ticked. Reported from a fresh install: four terminal windows were taken over at boot
    /// with no dialog, no explanation of what the workspace is, and no visible way to turn
    /// it off.
    ///
    /// `isEnabled` defaults to true, which is the right default for somebody who knows what
    /// this is and the wrong first impression for somebody who does not. The step is the
    /// difference between the two, so the step is what this now waits for.
    func restoreOverlayAtLaunch() {
        guard isEnabled, !userHidden else { return }
        guard OnboardingModel.shared.stage == .done else { return }
        guard CapabilityResolver.isSatisfied(.stepTerminalSessionsExplained) else { return }
        refresh()
    }

    // Convenience for menu bar / keyboard toggle. Flips user-dismiss state.
    func toggleOverlay() {
        userHidden ? showOverlay() : hideOverlay()
    }

    private func updateCornerAssignments() {
        guard isVisible else {
            cornerSessions = [:]
            gridSlots = []
            return
        }
        var assignments = TerminalWindowMapper.assignCorners(sessions: allSessions, overlayFrame: overlayFrame())

        // Only apply pinned overrides when that session's window is visible on the current Space.
        // Prevents sessions pinned on Space A from bleeding into Space B.
        let onScreenTTYs = TerminalWindowMapper.onScreenTTYs()
        for (corner, tty) in pinnedCorners where onScreenTTYs.contains(tty) {
            if let session = allSessions.first(where: { $0.tty == tty }) {
                assignments[corner] = session
            }
        }
        cornerSessions = assignments

        // Adaptive grid plumbing: re-infer shape every refresh, recompute the
        // row-major slot array. Cheap (just walks the same window list we've
        // already been polling for assignCorners), and isolated to TaskGridView
        // - corner-based rendering paths still read cornerSessions directly.
        let shape = TerminalWindowMapper.inferGridShape()
        let slots = TerminalWindowMapper.gridSlotsRowMajor(sessions: allSessions, shape: shape)
        if shape.cols != gridCols { gridCols = shape.cols }
        if shape.rows != gridRows { gridRows = shape.rows }
        gridSlots = slots
    }

    func pinCorner(_ corner: OverlayCorner, tty: String?) {
        if let tty {
            pinnedCorners[corner] = tty
        } else {
            pinnedCorners.removeValue(forKey: corner)
        }
        saveConfig()
        updateCornerAssignments()
    }

    // MARK: - Resync (Mission Control window picker)

    func beginResync(corner: OverlayCorner) {
        guard !isResyncing else { return }
        isResyncing = true
        pendingResyncCorner = corner

        // Make the overlay click-through so user clicks reach the terminal windows behind it
        TerminalFocusOverlayController.shared.setClickThrough(true)

        // Snapshot the frontmost Terminal window before MC so we can detect the change
        let beforeID = frontmostTerminalWindowID()

        // Trigger Mission Control via AppleScript key code 160 (the Mission Control key).
        // `open -a "Mission Control"` doesn't reliably trigger the expose animation.
        let mcProc = Process()
        mcProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        mcProc.arguments = ["-e", "tell application \"System Events\" to key code 160"]
        mcProc.standardError = Pipe()
        try? mcProc.run()

        // Dual detection:
        // (A) Activation notification - fires when Terminal wasn't already the frontmost app
        resyncObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.localizedName == "Terminal" else { return }
            self?.completeResync()
        }

        // (B) Poll every 200ms - fires when Terminal was ALREADY frontmost (window ID changes).
        // Skips the first 5 ticks (1 second) to let Mission Control animate in.
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, self.isResyncing else { timer.invalidate(); return }
            ticks += 1
            if ticks > 300 { self.cancelResync(); timer.invalidate(); return }
            guard ticks > 5 else { return }
            guard NSWorkspace.shared.frontmostApplication?.localizedName == "Terminal" else { return }
            let afterID = self.frontmostTerminalWindowID()
            if let afterID, afterID != beforeID {
                timer.invalidate()
                self.completeResync()
            }
        }
    }

    func cancelResync() {
        guard isResyncing else { return }
        TerminalFocusOverlayController.shared.setClickThrough(false)
        if let obs = resyncObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        resyncObserver = nil
        pendingResyncCorner = nil
        isResyncing = false
    }

    private func completeResync() {
        guard let corner = pendingResyncCorner, isResyncing else { return }
        TerminalFocusOverlayController.shared.setClickThrough(false)
        if let obs = resyncObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        resyncObserver = nil
        pendingResyncCorner = nil
        isResyncing = false

        // Get frontmost Terminal window's TTY
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            tell application "Terminal"
                try
                    set w to front window
                    repeat with t in tabs of w
                        if selected of t then
                            return tty of t
                        end if
                    end repeat
                end try
            end tell
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { return }
            proc.waitUntilExit()
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let tty = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/dev/", with: "")
            guard !tty.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                self?.pinCorner(corner, tty: tty)
                self?.refresh()
            }
        }
    }

    private func frontmostTerminalWindowID() -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return list.first {
            ($0[kCGWindowOwnerName as String] as? String) == "Terminal" &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    func overlayFrame() -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let sf = screen.visibleFrame
        let w = (sf.width * 0.60).rounded()
        let h = (sf.height * 0.60).rounded()
        let x = (sf.minX + (sf.width - w) / 2).rounded()
        let y = (sf.minY + (sf.height - h) / 2).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var activeCount: Int { allSessions.filter(\.isActive).count }
    var stuckCount: Int { allSessions.filter { $0.isStuck(thresholdMinutes: stuckThresholdMinutes) }.count }
    var focusedSession: TerminalSession? { allSessions.first }

    // MARK: - Hook

    var hookScriptURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/hooks/terminal-focus.sh")
    }

    func checkHookInstalled() {
        hookInstalled = FileManager.default.fileExists(atPath: hookScriptURL.path)
    }

    func installHook() throws {
        let dir = hookScriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = hookScript
        try script.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
        try mergeHookIntoSettings()
        hookInstalled = true
    }

    // Writes/rewrites the PostToolUse entry in ~/.claude/settings.json so it points to
    // our script and uses the broad matcher defined by `hookMatcher`. If an older
    // narrower matcher (e.g. "TodoWrite") already registered our script, we upgrade
    // it in place so cells refresh on every tool - not just TodoWrite.
    private func mergeHookIntoSettings() throws {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var postToolUse = hooks["PostToolUse"] as? [[String: Any]] ?? []

        let scriptPath = hookScriptURL.path
        func entryMatches(_ e: [String: Any]) -> Bool {
            guard let subhooks = e["hooks"] as? [[String: Any]] else { return false }
            return subhooks.contains { ($0["command"] as? String) == scriptPath }
        }

        // Remove any previous entries for our script (narrow or wrong matcher) so we
        // end up with exactly one entry using the current hookMatcher.
        postToolUse.removeAll(where: entryMatches)
        let fresh: [String: Any] = [
            "matcher": Self.hookMatcher,
            "hooks": [["type": "command", "command": scriptPath]]
        ]
        postToolUse.append(fresh)

        hooks["PostToolUse"] = postToolUse
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL)
    }

    // Bumped whenever `hookScript` changes. On app launch, if the installed script has
    // an older version marker, we silently overwrite it so the user always runs the current logic.
    private static let hookScriptVersion = 5

    // Regex matcher registered in ~/.claude/settings.json. Fires the hook on every tool
    // call (not just TodoWrite) so cells update continuously during session activity.
    private static let hookMatcher = ".*"

    private var hookScript: String {
        """
        #!/bin/bash
        # Terminal Focus hook - fires on every PostToolUse and writes session context
        # to ~/.grux/focus/{tty}.*. Registered by Grux Terminal Focus feature.
        # GRUX_HOOK_VERSION=\(Self.hookScriptVersion)

        set -euo pipefail

        # When this hook's own `claude -p` sub-invocation uses a tool (rare, but possible),
        # skip the recursive hook firing to avoid runaway loops.
        if [ "${GRUX_SKIP_HOOK:-}" = "1" ]; then exit 0; fi

        FOCUS_DIR="$HOME/.grux/focus"
        mkdir -p "$FOCUS_DIR"

        # Claude Code runs hooks with stdin piped, so `tty` returns "not a tty".
        # Walk the process tree to find the real terminal TTY.
        TTY_RAW=$(python3 - <<'PYEOF'
        import subprocess, os, sys
        pid = os.getpid()
        for _ in range(10):
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "tty=,ppid="],
                capture_output=True, text=True
            )
            parts = result.stdout.strip().split()
            if not parts:
                break
            tty = parts[0]
            ppid = parts[1] if len(parts) > 1 else "0"
            if tty and tty not in ("??", "?", ""):
                if not tty.startswith("tty"):
                    tty = "tty" + tty
                print(tty)
                sys.exit(0)
            if ppid in ("0", "1", ""):
                break
            pid = int(ppid)
        sys.exit(1)
        PYEOF
        )
        [ -z "$TTY_RAW" ] && exit 0

        export GRUX_PAYLOAD
        GRUX_PAYLOAD=$(cat)

        TOOL=$(echo "$GRUX_PAYLOAD" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")
        [ -z "$TOOL" ] && exit 0

        SESSION_FILE="$FOCUS_DIR/$TTY_RAW.json"
        SUGG_FILE="$FOCUS_DIR/$TTY_RAW.suggestions.json"
        ACTIVITY_FILE="$FOCUS_DIR/$TTY_RAW.activity.jsonl"

        # --- Always: append tool event to rolling activity log (last 20 lines) -----
        python3 - "$ACTIVITY_FILE" "$TOOL" <<'PYEOF'
        import os, sys, time, json
        path, tool = sys.argv[1], sys.argv[2]
        line = json.dumps({"tool": tool, "ts": time.time()})
        existing = []
        if os.path.exists(path):
            try:
                with open(path) as f:
                    existing = [l.rstrip("\\n") for l in f.readlines() if l.strip()]
            except Exception:
                pass
        existing.append(line)
        existing = existing[-20:]
        with open(path, "w") as f:
            f.write("\\n".join(existing) + "\\n")
        PYEOF

        # If this tool isn't TodoWrite, we're done after logging activity.
        if [ "$TOOL" != "TodoWrite" ]; then exit 0; fi

        # --- TodoWrite: write rich session state -----------------------------------
        python3 - "$SESSION_FILE" <<'PYEOF'
        import json, sys, os, time
        output_path = sys.argv[1]
        raw = os.environ.get("GRUX_PAYLOAD", "")
        try:
            d = json.loads(raw)
            todos = d.get("tool_input", {}).get("todos", [])
        except Exception:
            sys.exit(0)
        tasks = [{"title": t.get("content", ""), "status": t.get("status", "pending")} for t in todos]
        summary = ""
        for t in todos:
            if t.get("status") == "in_progress":
                summary = t.get("content", "")[:60]; break
        if not summary:
            for t in todos:
                if t.get("status") == "pending":
                    summary = t.get("content", "")[:60]; break
        out = {"summary": summary, "tasks": tasks, "ts": time.time()}
        with open(output_path, "w") as f:
            json.dump(out, f)
        PYEOF

        # --- TodoWrite: background claude -p for out-of-session suggestions -------
        CLAUDE_BIN="$HOME/.local/bin/claude"
        if [ -x "$CLAUDE_BIN" ]; then
            now_ts=$(python3 -c "import time; print(int(time.time()))")
            stale=1
            if [ -f "$SUGG_FILE" ]; then
                file_ts=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$SUGG_FILE" 2>/dev/null || echo 0)
                if [ $((now_ts - file_ts)) -lt 180 ]; then stale=0; fi
            fi
            if [ "$stale" = "1" ]; then
                (
                    PROMPT=$(python3 - "$SESSION_FILE" <<'PYEOF'
        import json, sys
        try:
            with open(sys.argv[1]) as f:
                d = json.load(f)
        except Exception:
            sys.exit(0)
        summary = d.get("summary", "")
        tasks = d.get("tasks", [])
        lines = [f"- [{t.get('status','pending')}] {t.get('title','')}" for t in tasks]
        ctx = "\\n".join(lines) if lines else "(no tasks)"
        print(f\"\"\"You are helping the user manage work across multiple Claude Code sessions.
        Their current session is focused on: "{summary}"
        Current todo list:
        {ctx}

        Suggest 1-3 tasks the user might want to tackle OUTSIDE this session - different work streams,
        higher-leverage items, or strategic follow-ups that do NOT belong inside this session's plan.

        Constraints:
        - Avoid duplicating anything in the current todo list
        - Avoid micro-tasks that fit inside this session
        - Prefer tasks that would live in their separate focus-task stack
        - Each title must be under 60 characters, phrased as an imperative
        - rationale is a single short sentence (under 100 chars)

        Return STRICTLY valid JSON, no markdown fences, no commentary. Schema:
        [{{"title": "...", "rationale": "..."}}]\"\"\")
        PYEOF
                    )
                    [ -z "$PROMPT" ] && exit 0
                    RESPONSE=$(GRUX_SKIP_HOOK=1 "$CLAUDE_BIN" -p "$PROMPT" 2>/dev/null || true)
                    [ -z "$RESPONSE" ] && exit 0
                    python3 - "$SUGG_FILE" "$RESPONSE" <<'PYEOF'
        import json, sys, time, re
        out_path = sys.argv[1]
        raw = sys.argv[2]
        m = re.search(r"\\[.*\\]", raw, re.DOTALL)
        if not m: sys.exit(0)
        try:
            arr = json.loads(m.group(0))
        except Exception:
            sys.exit(0)
        cleaned = []
        for item in arr if isinstance(arr, list) else []:
            if not isinstance(item, dict): continue
            title = (item.get("title") or "").strip()
            rationale = (item.get("rationale") or "").strip()
            if not title: continue
            cleaned.append({"title": title[:80], "rationale": rationale[:140]})
            if len(cleaned) >= 3: break
        out = {"suggestions": cleaned, "ts": time.time()}
        with open(out_path, "w") as f:
            json.dump(out, f)
        PYEOF
                ) </dev/null >/dev/null 2>&1 &
                disown 2>/dev/null || true
            fi
        fi
        """
    }

    // MARK: - Config persistence

    private var configURL: URL {
        focusDir.appendingPathComponent("grux-focus-config.json")
    }

    private struct FocusConfig: Codable {
        var isEnabled: Bool
        var viewMode: OverlayViewMode
        var stuckThresholdMinutes: Int
        var fadeOpacity: Double
        var pinnedCorners: [String: String]
        // Added 2026-04: user-dismiss + auto-hide. Optional so older configs
        // (pre-dismiss) decode cleanly and default to the original behavior.
        var userHidden: Bool? = nil
        var autoHideWhenTerminalInactive: Bool? = nil
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(FocusConfig.self, from: data) else { return }
        isEnabled = cfg.isEnabled
        viewMode = cfg.viewMode
        stuckThresholdMinutes = cfg.stuckThresholdMinutes
        fadeOpacity = cfg.fadeOpacity
        userHidden = cfg.userHidden ?? false
        autoHideWhenTerminalInactive = cfg.autoHideWhenTerminalInactive ?? false
        pinnedCorners = Dictionary(uniqueKeysWithValues: cfg.pinnedCorners.compactMap { k, v in
            guard let corner = OverlayCorner(rawValue: k) else { return nil }
            return (corner, v)
        })
    }

    func saveConfig() {
        let pinnedRaw = Dictionary(uniqueKeysWithValues: pinnedCorners.map { ($0.key.rawValue, $0.value) })
        let cfg = FocusConfig(isEnabled: isEnabled, viewMode: viewMode,
                              stuckThresholdMinutes: stuckThresholdMinutes, fadeOpacity: fadeOpacity,
                              pinnedCorners: pinnedRaw,
                              userHidden: userHidden,
                              autoHideWhenTerminalInactive: autoHideWhenTerminalInactive)
        try? JSONEncoder().encode(cfg).write(to: configURL)
    }
}

// MARK: - Session history

struct SessionHistoryEntry: Identifiable {
    let id = UUID()
    let tty: String
    let summary: String
    let tasks: [SessionTask]
    let timestamp: Date

    var ageString: String {
        let secs = Int(Date().timeIntervalSince(timestamp))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }

    var inProgressTask: SessionTask? { tasks.first { $0.status == .inProgress } }
    var completedCount: Int { tasks.filter { $0.status == .completed }.count }
}

// MARK: - JSON payloads

private struct SessionPayload: Codable {
    let summary: String
    let tasks: [SessionTask]
    let ts: TimeInterval?
}

private struct SuggestionsPayload: Codable {
    let suggestions: [SuggestedTask]
    let ts: TimeInterval?
}
