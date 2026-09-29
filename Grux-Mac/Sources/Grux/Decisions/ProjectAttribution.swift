import Foundation

/// P-R-6, `project.attribution`: which of the person's EXISTING projects a new
/// task or a logged decision belongs to.
///
/// A choice among projects that already exist, plus `none`. It never invents a
/// project: the options are built only from the task stack's own project
/// buckets and the projects `KnownProjects` found on this Mac, and an answer
/// that is not one of those names is dropped. It never overrides a project the
/// creator already gave; it may only fill a blank, which is the "raise only"
/// rule for a label. Without a key nothing is asked.
///
/// Calibrated 2026-09-21 against jev-latest (grux-ecosystem key), invented
/// projects and tasks. The first wording ("Pick none unless the task names one
/// of them or plainly belongs to it. Never pick a project because it is merely
/// possible") picked right 9 of 10 times but at 0.48 to 0.72, so only 2 of 5
/// real attributions cleared the 0.70 threshold. This wording, with each task
/// bucket described by the tasks already in it, picked right 9 of 9 at 0.69 to
/// 1.00 (8 of 9 cleared), and 6 of 6 for logged decisions at 0.71 to 1.00.
enum ProjectAttribution {
    static let surface = "project.attribution"
    static let noneOption = "none"
    /// More options cost tokens and blur the choice. Task buckets come first
    /// because they are the projects the person actually files work under.
    static let maxOptions = 30

    struct Option: Equatable {
        let name: String
        let description: String
    }

    static func instructions(noun: String) -> String {
        "Which of the person's existing projects is this \(noun) part of? A \(noun) is part of a project "
            + "when it names the project, its client or its product, or plainly continues the work "
            + "already in it. Pick none when no project fits."
    }

    /// The person's existing projects: every project bucket on the task stack,
    /// described by up to two of its most recent tasks, then the projects found
    /// on this Mac that are not already a bucket. Pure, so a test can pin it
    /// without the operator's task list or `~/Projects`.
    static func options(tasks: [FocusTask], known: [KnownProjects.Entry]) -> [Option] {
        var order: [String] = []
        var spelled: [String: String] = [:]
        var recent: [String: [FocusTask]] = [:]
        for t in tasks.sorted(by: { $0.createdAt > $1.createdAt }) {
            // The same bucket key `AppState.projectKey` uses.
            let name = t.project.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, key != noneOption else { continue }
            if spelled[key] == nil { spelled[key] = name; order.append(key) }
            if (recent[key]?.count ?? 0) < 2 { recent[key, default: []].append(t) }
        }
        var out: [Option] = order.map { key in
            let titles = (recent[key] ?? []).map(\.title).joined(separator: "; ")
            return Option(name: spelled[key] ?? key, description: "tasks already in it: \(titles)")
        }
        for e in known {
            let name = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, key != noneOption, spelled[key] == nil else { continue }
            spelled[key] = name
            out.append(Option(name: name, description: e.description.isEmpty ? "a project on this Mac" : e.description))
        }
        return Array(out.prefix(maxOptions))
    }

    /// The live roster. Reads the task stack and `~/Projects`, so it is only
    /// ever called by the app, never by a test.
    @MainActor
    static func liveOptions() -> [Option] {
        options(tasks: AppState.shared.tasks, known: KnownProjects.list())
    }

    static func question(noun: String, options: [Option]) -> DecisionQuestion? {
        guard !options.isEmpty else { return nil }
        var criteria: [String: String] = [noneOption: "it belongs to none of these projects"]
        for o in options { criteria[o.name] = o.description }
        return .choice(instructions: instructions(noun: noun), criteria: criteria)
    }

    /// The project to file under, or nil to leave the blank as it is. Only a
    /// provider that can read the item, only at or above the threshold, and
    /// only a name that was offered: an answer outside the options is how a
    /// project would get invented, so it is dropped.
    static func chosen(_ answer: DecisionAnswer?, provider: DecisionProviderKind?,
                       options: [Option], threshold: Double) -> String? {
        guard let provider, provider != .local,
              case .choice(let pick, let confidence, _)? = answer,
              confidence >= threshold, pick != noneOption else { return nil }
        return options.first { $0.name == pick }?.name
    }

    /// ONE call for every blank in a batch, one choice question per item, each
    /// carrying its own item in front of the instructions (`prefixes`). A
    /// project already given is not asked and is returned as it was; a blank
    /// is filled only when `chosen` says so. Without a key the projects come
    /// back exactly as they went in and nothing is recorded. Shared by the
    /// decision log and ambient memories, so the two cannot drift apart.
    @MainActor
    static func fill(projects: [String?], prefixes: [String], noun: String, state: String,
                     options: [Option], engine: DecisionEngine, threshold: Double) async -> [String?] {
        precondition(projects.count == prefixes.count)
        let blanks = projects.indices.filter { (projects[$0] ?? "").isEmpty }
        guard engine.hasRemoteKey, !blanks.isEmpty,
              let base = question(noun: noun, options: options) else { return projects }
        var questions: [String: DecisionQuestion] = [:]
        for i in blanks { questions["d\(i)"] = base.prefixed(with: prefixes[i]) }
        let result = await engine.decide(surface: surface, state: state, questions: questions)
        var out = projects
        for i in blanks {
            if let project = chosen(result.answers["d\(i)"], provider: result.provider,
                                    options: options, threshold: threshold) {
                out[i] = project
            }
        }
        return out
    }
}
