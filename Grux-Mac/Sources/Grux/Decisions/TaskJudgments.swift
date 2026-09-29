import Foundation
import Combine

/// P-R-6: a new task is ONE judged event with up to two gates on it,
/// `task.priority` (a score) and `project.attribution` (a choice), answered in
/// one provider call.
///
/// THE CREATOR'S VALUES ARE THE FLOOR. Whoever made the task (the chat tool,
/// the ambient extractor, a meeting import, a terminal suggestion, the person)
/// already chose a priority and maybe a project. The engine may only RAISE the
/// priority and only FILL an empty project with a project that already exists.
/// It never lowers a priority, never replaces a project, never invents one.
/// Without a key nothing is asked and the task stays exactly as it was made.
///
/// NOW IS CAPPED BY FOCUS. Moving a task to `.now` makes it the focused task
/// and demotes any other `.now` (`AppState.setPriority`). The judgment may only
/// produce a state the creator could have produced by passing the higher
/// priority to `addTask`, which focuses a `.now` task only when nothing is in
/// focus. So `.now` is reachable only when no task is in focus and no other
/// task is `.now`; otherwise a "now" answer raises to `.next` at most.
///
/// Judged ONCE per new task id, when the task list changes, never per render or
/// per list read. The tasks present when the observer starts are marked seen
/// and never judged.
///
/// Calibrated 2026-09-21 against jev-latest (grux-ecosystem key), 19 invented
/// tasks over two rounds, both questions on one call as the app sends them:
/// every priority landed in its expected band (the four due today or tomorrow
/// at 1.99 to 2.00, confidence 0.99 to 1.00; the rest at 0.00 to 0.84), at 336
/// to 455 ms for about 590 input tokens.
@MainActor
final class TaskJudgments {
    static let shared = TaskJudgments()

    static let prioritySurface = "task.priority"
    static let priorityInstructions =
        "How soon does this task need the person's attention? Judge only from what the task itself says. "
        + "A task that names no deadline and nothing waiting on it is later or next, never now."
    /// Low to high, the same order as `rank`.
    static let priorityLevels = [
        "later: no deadline and nothing waiting on it",
        "next: should be done within the next few days",
        "now: due today or tomorrow, or something is lost if it waits",
    ]
    /// A change that brings more than this many new tasks at once is a load
    /// (a restore, an import), not someone adding work, and is not paid for.
    static let maxJudgedPerChange = 3

    /// What the judgment adds on top of the creator's values. Nil keeps the floor.
    struct Raise: Equatable {
        var priority: TaskPriority?
        var project: String?
        static let none = Raise()
    }

    // Seams. Defaults reach the real surfaces; a test builds its own instance.
    var engine: () -> DecisionEngine = { .shared }
    var threshold: () -> Double = { AppState.shared.config.listeningThreshold }
    var projectOptions: () -> [ProjectAttribution.Option] = { ProjectAttribution.liveOptions() }
    var tasks: () -> [FocusTask] = { AppState.shared.tasks }
    var focusedTaskId: () -> UUID? = { AppState.shared.currentTask?.id }
    var setPriority: (UUID, TaskPriority) -> Void = { AppState.shared.setPriority($0, $1) }
    var setProject: (UUID, String) -> Void = { id, project in
        guard let t = AppState.shared.tasks.first(where: { $0.id == id }) else { return }
        AppState.shared.renameTask(id, title: t.title, project: project)
    }

    private var seen: Set<UUID> = []
    private var subscription: AnyCancellable?
    /// Judgments still out, by task id. Each removes itself when it lands.
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    /// Starts watching the task stack. Needs one call at launch; see the plan
    /// under P-R-6 for where it is wired.
    func start() {
        guard subscription == nil else { return }
        seen = Set(tasks().map(\.id))
        subscription = AppState.shared.$tasks.dropFirst().sink { [weak self] list in
            self?.consider(list)
        }
    }

    /// Judges every task in `list` not seen before, once.
    func consider(_ list: [FocusTask]) {
        let fresh = list.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { seen.insert($0.id) }
        let judged = fresh.filter { $0.parentId == nil && !$0.completed }
        guard judged.count <= Self.maxJudgedPerChange else {
            WakeLog.shared.log("decisions: \(judged.count) tasks arrived at once, treated as a load and not judged")
            return
        }
        for task in judged {
            inFlight[task.id] = Task { @MainActor [weak self] in
                defer { self?.inFlight[task.id] = nil }
                await self?.judgeAndApply(task)
            }
        }
    }

    /// Waits for every judgment started so far. For tests.
    func waitForJudgments() async {
        for t in Array(inFlight.values) { await t.value }
    }

    private func judgeAndApply(_ task: FocusTask) async {
        let e = engine()
        guard e.hasRemoteKey else { return }
        let raise = await Self.judge(task, options: projectOptions(), nowAllowed: nowAllowed(besides: task.id),
                                     engine: e, threshold: threshold())
        guard raise != .none, let current = tasks().first(where: { $0.id == task.id }),
              !current.completed else { return }
        // Only on top of the values the judgment was made against. Someone who
        // changed the task in the meantime has decided, and that wins.
        if var priority = raise.priority, current.priority == task.priority {
            if priority == .now && !nowAllowed(besides: task.id) { priority = .next }
            if Self.rank(priority) > Self.rank(current.priority) { setPriority(task.id, priority) }
        }
        if let project = raise.project, current.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setProject(task.id, project)
        }
    }

    private func nowAllowed(besides id: UUID) -> Bool {
        focusedTaskId() == nil
            && !tasks().contains { $0.id != id && !$0.completed && $0.parentId == nil && $0.priority == .now }
    }

    // MARK: - The judgment (pure apart from the one engine call)

    static func rank(_ p: TaskPriority) -> Int {
        switch p {
        case .later: return 0
        case .next: return 1
        case .now: return 2
        }
    }

    static func state(_ task: FocusTask, today: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d yyyy"
        var s = "Today is \(f.string(from: today)).\nA task was just added to the person's list: \(task.title)"
        let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { s += "\nNotes: \(notes)" }
        return s
    }

    /// One call for everything worth asking about this task. Priority is asked
    /// only when there is room above the floor, the project only when the
    /// creator left it blank and the person has projects to choose from.
    static func judge(_ task: FocusTask, options: [ProjectAttribution.Option], nowAllowed: Bool,
                      engine: DecisionEngine, threshold: Double, today: Date = Date()) async -> Raise {
        guard engine.hasRemoteKey else { return .none }
        let projectQuestion = task.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ProjectAttribution.question(noun: "task", options: options) : nil
        let askPriority = rank(task.priority) < rank(nowAllowed ? .now : .next)
        guard askPriority || projectQuestion != nil else { return .none }

        var covering: Set<String> = []
        if askPriority { covering.insert(prioritySurface) }
        if projectQuestion != nil { covering.insert(ProjectAttribution.surface) }
        let event = engine.open(origin: "task", state: state(task, today: today), covering: covering)
        if askPriority {
            event.ask(prioritySurface, ["urgency": .score(instructions: priorityInstructions, levels: priorityLevels)])
        }
        if let projectQuestion { event.ask(ProjectAttribution.surface, ["project": projectQuestion]) }
        await engine.resolve(event)
        engine.close(event)

        var raise = Raise.none
        if askPriority {
            raise.priority = raisedPriority(floor: task.priority, answer: event.answer(prioritySurface, "urgency"),
                                            provider: event.provider, threshold: threshold, nowAllowed: nowAllowed)
        }
        if projectQuestion != nil {
            raise.project = ProjectAttribution.chosen(event.answer(ProjectAttribution.surface, "project"),
                                                      provider: event.provider, options: options,
                                                      threshold: threshold)
        }
        return raise
    }

    /// A higher priority than the floor, or nil. On device a score answers 0
    /// at confidence 0, which is "cannot judge", so it never raises.
    static func raisedPriority(floor: TaskPriority, answer: DecisionAnswer?, provider: DecisionProviderKind?,
                               threshold: Double, nowAllowed: Bool) -> TaskPriority? {
        guard let provider, provider != .local,
              case .score(let score, let confidence)? = answer, confidence >= threshold else { return nil }
        let levels: [TaskPriority] = [.later, .next, .now]
        var judged = levels[max(0, min(levels.count - 1, Int(score.rounded())))]
        if judged == .now && !nowAllowed { judged = .next }
        return rank(judged) > rank(floor) ? judged : nil
    }
}
