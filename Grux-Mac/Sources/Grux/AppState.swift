import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var tasks: [FocusTask] = []
    @Published var currentTaskId: UUID?
    @Published var events: [FocusEvent] = []
    // Active chat thread's messages, mirrored here so SwiftUI reacts to
    // appends/clears without every view having to subscribe to the store.
    // On disk, the source of truth is ChatThreadStore - this array is
    // re-written whenever `switchThread` picks a different thread.
    @Published var chat: [ChatMessage] = []
    // Currently selected chat thread. nil briefly on first launch before
    // `load()` picks or creates a thread. All appends flow through this id.
    @Published var activeThreadId: UUID?
    // Rolling summary of the active thread (if compaction has run). The
    // volatile system block injects this into the Claude prompt so old
    // context isn't lost after messages are pruned.
    @Published var activeThreadSummary: String?
    // Light projection of every thread on disk. Sidebar + thread picker
    // read from here, not from the store, so list renders stay cheap.
    @Published var threads: [ChatThreadIndexEntry] = []
    @Published var config: GruxConfig = .default
    @Published var watching: Bool = false
    @Published var lastTick: Date?
    @Published var lastVerdict: FocusVerdict?
    @Published var lastActiveApp: String = ""
    @Published var lastWindowTitle: String = ""
    @Published var screenPermissionGranted: Bool = false
    @Published var consecutiveDrifts: Int = 0
    @Published var snoozedUntil: Date?
    @Published var isThinking: Bool = false
    @Published var lastOcrSnippet: String = ""
    // Capture privacy, surfaced rather than silent. A privacy control the user
    // cannot see working is one they cannot trust, and the failure mode of a
    // silent one is the worst available: they assume it is on, it is not, and
    // nothing ever tells them. See CapturePrivacy.swift.
    @Published var lastCaptureBlockedApp: String = ""
    @Published var lastCaptureBlockedReason: String = ""
    @Published var lastCaptureBlockedAt: Date?
    @Published var captureBlockedCount: Int = 0
    /// How many windows were cut out of the most recent frame.
    @Published var lastCaptureExcludedWindowCount: Int = 0
    /// Frames actually sent to a vision model, this launch. The honest counter
    /// behind "Grux watches my screen": it counts transmissions, not ticks.
    @Published var framesSentToModel: Int = 0
    @Published var lastFrameSentAt: Date?

    func noteCaptureBlocked(app: String, reason: String) {
        lastCaptureBlockedApp = app
        lastCaptureBlockedReason = reason
        lastCaptureBlockedAt = Date()
        captureBlockedCount += 1
    }

    func noteFrameSentToModel() {
        framesSentToModel += 1
        lastFrameSentAt = Date()
    }
    @Published var requestedTab: String = "chat"
    // Set by the Meta Ads "Send to Claude" button. ChatView consumes it once,
    // pre-fills the composer (does NOT auto-send), then clears it. Transient.
    @Published var pendingChatPrompt: String?
    // Cognition Map deep-link (approved UI/UX decision 4). When non-nil, the
    // Cognition Map scrolls to and expands the decision whose correlationId
    // matches, then clears it so a stale value does not re-fire. Set by the Jax
    // HQ draft card "Why this draft?" action together with
    // requestedTab = "cognitionMap".
    @Published var cognitionFocus: String?
    // Settings sub-tab automation hook (parallels requestedTab). Set by the
    // --open-settings-tab=<name> launch arg; SettingsView observes it,
    // switches its TabView selection, then clears it back to nil so a stale
    // value never re-fires the next time Settings opens.
    @Published var requestedSettingsTab: String?
    // When non-nil, the Agents tab pops the Resume sheet for this jobId as
    // soon as it appears. Set by GruxApp.handleAction when the user taps an
    // "agent paused" notification (or the phone "Resume on Mac" button).
    // AgentsView clears it after presenting the sheet so a stale tab switch
    // doesn't redundantly re-prompt.
    @Published var pendingResumeJobId: String?
    // In-session "hard mute" toggle - when true, BOTH the wake-word listener
    // and the ambient listener are stopped and won't auto-restart. Flipped
    // by tapping the orb. Intentionally NOT persisted to config - if the user
    // quits Grux muted, the next launch starts listening again per their
    // normal ambient/wake config.
    @Published var micMuted: Bool = false
    // In-session chat-voice mute. When true, Grux skips ALL TTS playback for
    // chat replies (ElevenLabs + system fallback) while still displaying text
    // normally. Toggled by the speaker icon in ChatView's hero header. Mirrors
    // `micMuted` in that it's intentionally NOT persisted - quitting muted
    // doesn't carry the mute across launches (config.speakRepliesAloud stays
    // the persistent default).
    @Published var voiceMuted: Bool = false
    // Single-flight guard for rolling thread compaction. autoCompactIfNeeded
    // fires from a fire-and-forget Task on every appendChat - without this
    // flag, two rapid user turns can each detect "thread is big" and each
    // round-trip Haiku, double-charging us and racing on replaceMessages.
    // Manual-compact callers (the chat UI's "Compact" action and the new
    // compact_thread_now agent tool) respect the same flag.
    @Published var compactionInFlight: Bool = false

    // Phase 1 (Model Foundation) - single switch that routes chat through a
    // discovered local model instead of Anthropic. Read by ModelRegistry.active()
    // on every send(). PERSISTED into GruxConfig: the
    // mode survives relaunch. Safety against the flaky-server case that originally
    // motivated keeping it transient - ModelRegistry.active() falls back to
    // Anthropic whenever no local server is discovered, so a persisted true with
    // Ollama down degrades to cloud rather than stranding the user offline. Flipping it
    // on re-runs best-effort local discovery via the didSet. Restores are applied
    // through `isRestoringState` so launch doesn't emit a toggle event or re-save.
    @Published var offlineMode: Bool = false {
        didSet {
            guard offlineMode != oldValue else { return }
            if !isRestoringState {
                config.offlineMode = offlineMode
                saveConfig()
                // THE SWITCH HAS TO MOVE THE ROUTER, NOT JUST THE FLAG.
                //
                // The active provider is an explicit stored choice that falls
                // back to this switch ONLY while nothing has ever been chosen,
                // so after a single press of "Use Claude" or "Use" on a custom
                // endpoint, moving this switch changed precisely nothing about
                // where a turn went. The control the user can see has to be the
                // control that decides, so flipping it IS a choice and gets
                // recorded as one.
                //
                // Deliberately inside the isRestoringState guard: load() writes
                // this property while restoring the persisted value, and firing
                // there would overwrite the user's explicit provider choice with
                // a derived one on every single launch.
                ModelRegistry.shared.setActiveProvider(offlineMode ? .local : .anthropic)
            }
            if offlineMode {
                Task { await ModelRegistry.shared.discoverLocal() }
            }
        }
    }
    // Guards offlineMode.didSet during load() so restoring the persisted value
    // doesn't re-persist or fire a spurious toggle-telemetry event at launch.
    private var isRestoringState = false

    // The last recoverable chat failure, surfaced as an actionable banner above
    // the composer. nil clears it. Set by ChatService.send()'s catch block when
    // the caught error classifies as a limit hit, a network failure, or an
    // offline-with-no-local-model dead end. Transient (never persisted): a
    // banner is only relevant to the live session that just failed.
    @Published var chatRecovery: ChatRecovery? = nil

    static let shared = AppState()

    private init() {
        load()
        // Best-effort local-model discovery at launch so ModelRegistry.active()
        // can route offline chat the moment the user flips the toggle. Failure is
        // silent (local stays nil; active() falls back to anthropic).
        Task { await ModelRegistry.shared.discoverLocal() }
    }

    // Keychain-backed accessors. Always read live from the Keychain (cheap,
    // <5ms) rather than caching - so a change made in Settings is visible
    // immediately to all readers without any @Published churn. Empty string
    // means "not set" (callers already handle that case).
    var anthropicKey: String { KeychainStore.get(.anthropicApiKey) }
    var elevenLabsKey: String { KeychainStore.get(.elevenLabsApiKey) }
    var braveKey: String { KeychainStore.get(.braveApiKey) }

    func load() {
        let cfg = Persistence.load(GruxConfig.self, from: Persistence.configURL, fallback: .default)
        self.config = cfg
        // Restore the persisted offline switch without re-saving or emitting a
        // toggle event. discoverLocal() still runs (unconditionally below in init),
        // and active() falls back to Anthropic if no local server answers.
        isRestoringState = true
        self.offlineMode = cfg.offlineMode
        isRestoringState = false
        self.tasks = Persistence.load([FocusTask].self, from: Persistence.tasksURL, fallback: [])
        self.events = Persistence.load([FocusEvent].self, from: Persistence.eventsURL, fallback: [])
        self.currentTaskId = tasks.first(where: { $0.priority == .now && !$0.completed })?.id
            ?? tasks.first(where: { !$0.completed })?.id
        // ChatThreadStore.shared migrates any legacy chat.json on init, so by
        // the time we read its index we either see migrated threads, an
        // explicitly-created thread from a previous session, or an empty
        // store that we auto-seed with a fresh thread below.
        let store = ChatThreadStore.shared
        var threadsList = store.list()
        if threadsList.isEmpty {
            let seeded = store.create(title: "New chat")
            threadsList = store.list()
            self.activeThreadId = seeded.id
        } else {
            self.activeThreadId = threadsList.first?.id
        }
        self.threads = threadsList
        if let activeId = self.activeThreadId, let thread = store.load(id: activeId) {
            self.chat = thread.messages
            self.activeThreadSummary = thread.summary
        } else {
            self.chat = []
            self.activeThreadSummary = nil
        }
    }

    func saveAll() {
        Persistence.save(config, to: Persistence.configURL)
        Persistence.save(tasks, to: Persistence.tasksURL)
        Persistence.save(events, to: Persistence.eventsURL)
        // Chat is persisted per-thread through ChatThreadStore - no flat
        // chat.json write here.
    }

    func saveConfig() {
        Persistence.save(config, to: Persistence.configURL)
    }
    func saveTasks() { Persistence.save(tasks, to: Persistence.tasksURL) }
    func saveEvents() { Persistence.save(events, to: Persistence.eventsURL) }

    // MARK: - Chat threads

    // Ensure there's an active thread - called lazily before any chat op
    // when `activeThreadId` hasn't been initialized yet (edge case for
    // callers that touch chat before `load()` ran, e.g. a voice macro
    // firing during early-launch wake listen).
    @discardableResult
    private func ensureActiveThread() -> UUID {
        if let id = activeThreadId { return id }
        let seeded = ChatThreadStore.shared.create(title: "New chat")
        activeThreadId = seeded.id
        chat = []
        activeThreadSummary = nil
        threads = ChatThreadStore.shared.list()
        return seeded.id
    }

    func refreshThreads() {
        threads = ChatThreadStore.shared.list()
    }

    @discardableResult
    func newThread(title: String = "New chat") -> UUID {
        let thread = ChatThreadStore.shared.create(title: title)
        activeThreadId = thread.id
        chat = []
        activeThreadSummary = nil
        threads = ChatThreadStore.shared.list()
        return thread.id
    }

    func switchThread(_ id: UUID) {
        guard id != activeThreadId else { return }
        guard let thread = ChatThreadStore.shared.load(id: id) else { return }
        activeThreadId = id
        chat = thread.messages
        activeThreadSummary = thread.summary
        threads = ChatThreadStore.shared.list()
    }

    func renameThread(_ id: UUID, title: String) {
        _ = ChatThreadStore.shared.rename(id: id, title: title)
        threads = ChatThreadStore.shared.list()
    }

    func toggleThreadStar(_ id: UUID) {
        _ = ChatThreadStore.shared.toggleStar(id: id)
        threads = ChatThreadStore.shared.list()
    }

    func deleteThread(_ id: UUID) {
        ChatThreadStore.shared.delete(id: id)
        threads = ChatThreadStore.shared.list()
        // If we just deleted the active one, hop to the newest remaining
        // thread or seed a fresh one so ChatView never renders orphaned.
        if activeThreadId == id {
            if let next = threads.first {
                switchThread(next.id)
            } else {
                newThread()
            }
        }
    }

    // Task ops
    @discardableResult
    func addTask(
        _ title: String,
        project: String = "",
        priority: TaskPriority = .next,
        parentId: UUID? = nil
    ) -> FocusTask? {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let task = FocusTask(title: title, project: project, priority: priority, parentId: parentId)
        if priority == .now && currentTaskId == nil && parentId == nil { currentTaskId = task.id }
        tasks.insert(task, at: 0)
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
        return task
    }

    // Sub-task helpers. Sub-tasks inherit project (so they live in the parent's
    // section) and default to .next priority since they're not independent
    // focus targets. Parent must exist - we silently no-op otherwise so voice
    // macros / LLM calls can't corrupt the tree with dangling sub-tasks.
    @discardableResult
    func addSubtask(parentId: UUID, title: String) -> FocusTask? {
        guard let parent = tasks.first(where: { $0.id == parentId }) else { return nil }
        return addTask(title, project: parent.project, priority: .next, parentId: parentId)
    }

    // Children of a given task, in the order they appear in the backing array.
    // Active-only; completed sub-tasks drop out of the main render and live
    // in the global COMPLETED section alongside top-level completions.
    func subtasks(of parentId: UUID, includeCompleted: Bool = false) -> [FocusTask] {
        tasks.filter { $0.parentId == parentId && (includeCompleted || !$0.completed) }
    }

    // Top-level (non-sub-task) tasks. Replaces bare `activeTasks` calls in
    // views that shouldn't leak sub-tasks into their top-level lists.
    var topLevelActiveTasks: [FocusTask] {
        tasks.filter { $0.parentId == nil && !$0.completed }
    }

    // Promote a sub-task to top-level (keeps title/project/priority, clears
    // the parent link). Used by the SubtaskRow menu when the user decides a
    // sub-task is actually its own main task.
    func promoteSubtask(_ id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].parentId != nil else { return }
        tasks[idx].parentId = nil
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
    }

    func completeTask(_ id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].completed = true
        tasks[idx].completedAt = Date()
        if currentTaskId == id {
            currentTaskId = tasks.first(where: { !$0.completed && $0.priority == .now })?.id
                ?? tasks.first(where: { !$0.completed })?.id
        }
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
    }

    func uncompleteTask(_ id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].completed = false
        tasks[idx].completedAt = nil
        saveTasks()
    }

    func deleteTask(_ id: UUID) {
        // Cascade: when a parent is deleted, its sub-tasks go with it - sub-
        // tasks without a parent would be orphaned rows in the main list and
        // confuse users. Bulk-remove in one pass to avoid n-squared scans.
        let idsToDrop = Set([id] + tasks.filter { $0.parentId == id }.map { $0.id })
        tasks.removeAll(where: { idsToDrop.contains($0.id) })
        if let c = currentTaskId, idsToDrop.contains(c) {
            currentTaskId = tasks.first(where: { !$0.completed && $0.parentId == nil })?.id
        }
        saveTasks()
    }

    func renameTask(_ id: UUID, title: String, project: String? = nil) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        tasks[idx].title = trimmedTitle
        if let project = project {
            tasks[idx].project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
        if currentTaskId == id {
            NotificationCenter.default.post(name: .gruxActiveTaskChanged, object: nil)
        }
    }

    // Reorder active tasks WITHIN a priority bucket. `source` and `destination`
    // are indices into the filtered list of (active, same-priority) tasks as
    // SwiftUI's List onMove reports them. We translate back to indices in
    // self.tasks so the backing array stays the single source of truth.
    func reorderTasks(within priority: TaskPriority, from source: IndexSet, to destination: Int) {
        let bucketIndices = tasks.indices.filter { tasks[$0].priority == priority && !tasks[$0].completed }
        guard !bucketIndices.isEmpty else { return }
        var ordered = bucketIndices.map { tasks[$0] }
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, origIdx) in bucketIndices.enumerated() {
            tasks[origIdx] = ordered[i]
        }
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
    }

    // Move a task to a different priority bucket (drag across sections). The
    // task lands at the top of the destination bucket; promoting to .now also
    // demotes any other .now tasks to .next and sets currentTaskId, matching
    // the existing setPriority semantics the user expects.
    func moveTask(_ id: UUID, toPriority p: TaskPriority) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        var moved = tasks.remove(at: idx)
        moved.priority = p
        if p == .now {
            for i in tasks.indices where tasks[i].priority == .now && !tasks[i].completed {
                tasks[i].priority = .next
            }
            currentTaskId = id
        }
        if let firstOfPri = tasks.firstIndex(where: { $0.priority == p && !$0.completed }) {
            tasks.insert(moved, at: firstOfPri)
        } else {
            tasks.insert(moved, at: 0)
        }
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
        if p == .now {
            NotificationCenter.default.post(name: .gruxActiveTaskChanged, object: nil)
        }
    }

    // Reorder active tasks WITHIN a project bucket. Mirrors reorderTasks(within:
    // priority:). Task Stack now sections by project, so onMove within a
    // section must preserve project identity while swapping positions.
    func reorderTasks(within project: String, from source: IndexSet, to destination: Int) {
        let key = Self.projectKey(project)
        let bucketIndices = tasks.indices.filter {
            Self.projectKey(tasks[$0].project) == key && !tasks[$0].completed
        }
        guard !bucketIndices.isEmpty else { return }
        var ordered = bucketIndices.map { tasks[$0] }
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, origIdx) in bucketIndices.enumerated() {
            tasks[origIdx] = ordered[i]
        }
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
    }

    // Move a task to a different project bucket (drag between project sections).
    // Lands at the top of the destination bucket. Priority is preserved - the
    // Task Stack now treats priority as a per-row attribute, not a section axis.
    // Empty/whitespace destination maps to the "No Project" fallback (stored
    // as an empty string on the task so existing persistence stays stable).
    func moveTask(_ id: UUID, toProject project: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let normalized = project.trimmingCharacters(in: .whitespacesAndNewlines)
        var moved = tasks.remove(at: idx)
        moved.project = normalized
        let destKey = Self.projectKey(normalized)
        if let firstOfProj = tasks.firstIndex(where: {
            Self.projectKey($0.project) == destKey && !$0.completed
        }) {
            tasks.insert(moved, at: firstOfProj)
        } else {
            tasks.insert(moved, at: 0)
        }
        saveTasks()
        NotificationCenter.default.post(name: .gruxTaskStackChanged, object: nil)
    }

    // Canonical bucket key. Empty / whitespace-only project names collapse to
    // a shared sentinel so "", " ", "\t" all land in the same "No Project"
    // bucket instead of rendering as three separate sections.
    static func projectKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setPriority(_ id: UUID, _ p: TaskPriority) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].priority = p
        if p == .now {
            // demote other NOWs to NEXT
            for i in tasks.indices where tasks[i].id != id && tasks[i].priority == .now {
                tasks[i].priority = .next
            }
            currentTaskId = id
        }
        saveTasks()
        NotificationCenter.default.post(name: .gruxActiveTaskChanged, object: nil)
    }

    func focus(on id: UUID) {
        currentTaskId = id
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].priority = .now
            for i in tasks.indices where tasks[i].id != id && tasks[i].priority == .now {
                tasks[i].priority = .next
            }
        }
        consecutiveDrifts = 0
        saveTasks()
        NotificationCenter.default.post(name: .gruxActiveTaskChanged, object: nil)
    }

    var currentTask: FocusTask? {
        tasks.first(where: { $0.id == currentTaskId && !$0.completed })
    }

    var activeTasks: [FocusTask] {
        tasks.filter { !$0.completed }
    }

    var completedTasks: [FocusTask] {
        tasks.filter { $0.completed }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func appendEvent(_ e: FocusEvent) {
        events.insert(e, at: 0)
        if events.count > 500 { events = Array(events.prefix(500)) }
        saveEvents()
        NotificationCenter.default.post(name: .gruxFocusEvent, object: nil)
    }

    func appendChat(_ m: ChatMessage) {
        let threadId = ensureActiveThread()
        chat.append(m)
        if chat.count > 400 { chat = Array(chat.suffix(400)) }
        _ = ChatThreadStore.shared.append(id: threadId, message: m)
        // Keep the published thread list fresh for the sidebar/strip so the
        // "last message preview" and sort order (most-recent first) update
        // in real time as the user chats.
        threads = ChatThreadStore.shared.list()
        // Fire-and-forget title generation + auto-compaction in the
        // background. Both bail out on missing key, failure, or no-op
        // conditions, so they're safe to call every turn.
        Task { await autoTitleIfNeeded(threadId: threadId) }
        Task { await autoCompactIfNeeded() }
    }

    // The route the background chat calls (auto-titling, rolling compaction)
    // take, or nil when there is nowhere at all to send one.
    //
    // BOTH USED TO READ `anthropicKey` AND `config.model` DIRECTLY. That made
    // the local-only user, whose context window is the smallest of anyone's and
    // who therefore needs compaction most, the one user who never got it: the
    // thread grew without bound until it overflowed into a provider error they
    // could not act on, and every title stayed "New chat" so the sidebar was a
    // wall of them. Asking the router instead is the whole fix.
    //
    // The guard stays, because skipping IS the right answer when nothing is
    // attached, but it asks ChatReadiness, which already knows whether ANY route
    // exists, rather than asking about Anthropic specifically. Inventing a
    // second rule here is how the two answers drift apart.
    func chatBackgroundRouting() -> (backend: ModelBackend, modelId: String, apiKey: String)? {
        let readiness = ChatReadiness.current()
        guard readiness.canSend else { return nil }
        return ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
    }

    // Give a fresh thread a real title after 2+ exchanges. Only runs once
    // per thread - subsequent appends find a non-default title and skip.
    private func autoTitleIfNeeded(threadId: UUID) async {
        guard let thread = ChatThreadStore.shared.load(id: threadId) else { return }
        guard thread.title == "New chat" else { return }
        let userTurns = thread.messages.filter { $0.role == .user }.count
        guard userTurns >= 2 else { return }
        guard let routing = chatBackgroundRouting() else {
            WakeLog.shared.log("title: skipped - no model route")
            return
        }
        guard let title = await ChatCompactor.generateTitle(
            messages: thread.messages,
            backend: routing.backend,
            model: routing.modelId,
            apiKey: routing.apiKey
        ) else { return }
        await MainActor.run {
            _ = ChatThreadStore.shared.rename(id: threadId, title: title)
            self.threads = ChatThreadStore.shared.list()
        }
    }

    // Trigger compaction when the active thread grows past a sensible size.
    // Thresholds live in CompactionPolicy so they're testable + swappable
    // without poking at this method. The single-flight guard sits inside
    // compactActiveThread so manual + auto callers share the same lock.
    private func autoCompactIfNeeded() async {
        guard let id = activeThreadId else { return }
        guard let thread = ChatThreadStore.shared.load(id: id) else { return }
        guard thread.autoCompact else { return }
        guard CompactionPolicy.shouldAutoCompact(
            messageCount: thread.messages.count,
            approximateTokens: thread.approximateTokens
        ) else { return }
        if compactionInFlight { return }
        WakeLog.shared.log("compact: auto trigger (msgs=\(thread.messages.count), tokens≈\(thread.approximateTokens), priorSummary=\(thread.summary?.count ?? 0)c)")
        let started = Date()
        let ok = await compactActiveThread(keepLastN: CompactionPolicy.keepLastN)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        WakeLog.shared.log("compact: auto \(ok ? "success" : "noop/fail") in \(ms)ms")
    }

    func clearChat() {
        let threadId = ensureActiveThread()
        chat = []
        _ = ChatThreadStore.shared.replaceMessages(id: threadId, messages: [])
        threads = ChatThreadStore.shared.list()
    }

    // Run rolling compaction on the active thread's older messages. Called
    // manually from the chat UI's "Compact" action, the compact_thread_now
    // agent tool, or automatically when the thread crosses a size threshold.
    // Keeps the last `keepLastN` messages verbatim and folds everything
    // earlier into a concise summary. Single-flighted via compactionInFlight
    // so concurrent triggers don't double-charge Haiku or race on the write.
    func compactActiveThread(keepLastN: Int = 10) async -> Bool {
        if compactionInFlight { return false }
        compactionInFlight = true
        defer { compactionInFlight = false }
        let threadId = ensureActiveThread()
        guard let thread = ChatThreadStore.shared.load(id: threadId) else { return false }
        guard thread.messages.count > keepLastN + 4 else { return false }
        let priorSummary = thread.summary
        let toCompact = Array(thread.messages.prefix(thread.messages.count - keepLastN))
        let keep = Array(thread.messages.suffix(keepLastN))
        guard let routing = chatBackgroundRouting() else {
            WakeLog.shared.log("compact: skipped - no model route")
            return false
        }
        guard let newSummary = await ChatCompactor.summarize(
            messages: toCompact,
            priorSummary: priorSummary,
            backend: routing.backend,
            model: routing.modelId,
            apiKey: routing.apiKey
        ) else {
            WakeLog.shared.log("compact: summarizer returned nil (network/api)")
            return false
        }
        await MainActor.run {
            _ = ChatThreadStore.shared.replaceMessages(id: threadId, messages: keep, summary: newSummary)
            self.chat = keep
            self.activeThreadSummary = newSummary
            self.threads = ChatThreadStore.shared.list()
        }
        WakeLog.shared.log("compact: folded \(toCompact.count) → kept \(keep.count) (summary=\(newSummary.count)c)")
        return true
    }

    func isWithinActiveHours() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= config.activeHoursStart && hour < config.activeHoursEnd
    }

    func isSnoozed() -> Bool {
        if let until = snoozedUntil, until > Date() { return true }
        return false
    }

    func snooze(minutes: Int) {
        snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }
}
