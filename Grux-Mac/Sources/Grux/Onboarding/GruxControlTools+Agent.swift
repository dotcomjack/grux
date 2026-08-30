import Foundation
import GruxAgentCore
import GruxMCPCore

// MARK: - grux_agent

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// Hand the agent a task, list what has been handed over, or read one back.
    ///
    /// ## It answers with an id and does not wait, and that decides everything else
    ///
    /// A worker runs until it finishes or until its TTL, which `SwarmWorker.run` defaults to
    /// 1800 seconds, and `ControlClient` stops listening after ten. A handler that waited for
    /// the swarm would therefore report a failure for work that was running perfectly, and
    /// the caller would have no id to find it with afterwards. So starting returns the id,
    /// and every later question about that job is its own call.
    ///
    /// ## Three shapes, and the third is what makes the id worth having
    ///
    /// A task starts one. Nothing lists them. A job id reads one back. Without the listing an
    /// id that scrolled off the screen is a job nobody can find again, so it is not optional.
    static func agent(text: String?, job: String?) async -> [String: Any] {
        let task = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = (job ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // BOTH AT ONCE IS A REFUSAL, NOT A PREFERENCE. "Start this and also show me that
        // one" has two readings, and either silent choice is wrong in a way that costs
        // money: pick the read and a task the caller meant to start never runs, pick the
        // start and they get a job they did not ask for on top of the answer they wanted.
        guard task.isEmpty || wanted.isEmpty else {
            return MCPWire.textFailure("grux_agent starts a task or reads one job back, not "
                + "both in one call. Send the task on its own, then ask for the job id.")
        }

        if !wanted.isEmpty { return await agentRead(idOrPrefix: wanted) }
        if task.isEmpty { return await agentList() }
        return await agentStart(task: task)
    }

    // MARK: - Starting one

    private static func agentStart(task: String) async -> [String: Any] {
        let rootDir = agentRootDir(for: task)
        do {
            try FileManager.default.createDirectory(atPath: rootDir,
                                                    withIntermediateDirectories: true)
        } catch {
            // REFUSE RATHER THAN START. `AgentTools` creates this folder with `try?` and
            // starts the swarm regardless, which spawns a worker whose working directory
            // does not exist: the run dies inside the subprocess and reads as the model
            // refusing the work rather than as a folder that could not be made.
            return MCPWire.textFailure("Could not make \(rootDir), which is where this job "
                + "would do its work, so nothing was started. \(error.localizedDescription)")
        }

        // ONE WORKER. The tool takes a sentence of task and nothing that says how to divide
        // it, and every template that divides work spends twice over on a task that may be a
        // single edit. The chat tool surface has the templated form for a caller that wants
        // an architect and an implementor, and it can say which it wants.
        let job = await AgentService.shared.startSwarm(title: agentTitle(for: task),
                                                       goal: task,
                                                       template: .singleWorker,
                                                       rootDir: rootDir)

        return MCPWire.textResult(jsonText([
            "started": true,
            "job": agentSummary(job, detailed: true),
            "log_path": agentLogPath(job.id),
            "read_back": "grux agent --job \(job.id)",
        ]))
    }

    /// Where a job works, and it is not a free choice.
    ///
    /// `SwarmWorker.isSanctionedWritableRoot` carves write access in the sandbox profile for
    /// `~/Documents/Grux/swarms`, `~/Projects/GruxApps`, the two Design Studio roots and a
    /// `.worktrees` checkout, and for nothing else. A job rooted anywhere else spawns with
    /// its write carve DENIED and only the temp directory to write in, which surfaces as a
    /// worker that produced nothing rather than as a folder that was never allowed.
    ///
    /// A folder per job, because two jobs sharing one root overwrite each other's files and
    /// neither of them knows the other is there.
    private static func agentRootDir(for task: String) -> String {
        let slug = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let base = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/Grux/swarms")
        return (base as NSString)
            .appendingPathComponent("\(slug.isEmpty ? "task" : slug)-\(suffix)")
    }

    /// A title somebody can pick out of a list of ten.
    ///
    /// `AgentService.startSwarm` titles an untitled job "swarm: singleWorker", which is the
    /// same two words for every job it will ever start from here, so a list of them names
    /// nothing and the ids become the only way to tell two jobs apart.
    private static func agentTitle(for task: String) -> String {
        let firstLine = task.split(separator: "\n").first.map(String.init) ?? task
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 60 else { return trimmed }
        return String(trimmed.prefix(59)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Listing them

    private static func agentList() async -> [String: Any] {
        await AgentService.shared.refreshJobs()
        // Newest first is stated here rather than inherited. `AgentStore.listJobs` sorts by
        // createdAt today, and `AgentService.jobs` is also written by the orchestrator
        // bridge, which inserts an unknown job at the front whatever its date.
        let jobs = AgentService.shared.jobs.sorted { $0.createdAt > $1.createdAt }
        return MCPWire.textResult(jsonText([
            "jobs": jobs.prefix(agentListWindow).map { agentSummary($0) },
            "count": jobs.count,
        ]))
    }

    /// How many jobs a listing carries. The reply crosses the socket as one line, and the
    /// count comes back whole beside it so a caller can say "showing 25 of 40" rather than
    /// present a window as though it were everything.
    private static var agentListWindow: Int { 25 }

    // MARK: - Reading one back

    private static func agentRead(idOrPrefix wanted: String) async -> [String: Any] {
        await AgentService.shared.refreshJobs()
        let jobs = AgentService.shared.jobs

        // A PREFIX RESOLVES. Every id here is a UUID, every surface that prints a list shows
        // the leading characters, and asking somebody to type thirty six of them back is
        // asking them to make a mistake.
        let hits: [AgentJob]
        if let exact = jobs.first(where: { $0.id == wanted }) {
            hits = [exact]
        } else {
            let needle = wanted.lowercased()
            hits = jobs.filter { $0.id.lowercased().hasPrefix(needle) }
        }

        guard let job = hits.first else {
            return MCPWire.textFailure(jobs.isEmpty
                ? "No agent job has ever run on this Mac, so there is nothing called \(wanted)."
                : "No job here has an id starting \(wanted). Run grux agent to see the ones "
                  + "there are.")
        }
        guard hits.count == 1 else {
            // THE COUNT AND THE LIST HAVE TO RECONCILE. Measured on this Mac: 214 jobs, 14
            // of them starting `0`, and `--job 0` claimed 14 while naming four, so ten
            // matches existed that the sentence gave the reader no way to know about. Eight
            // shown and the remainder said out loud is what the sibling resolver in
            // GruxCLI/Commands/Approvals.swift already does for queue ids.
            let shown = hits.prefix(8).map { String($0.id.prefix(12)) }
            let rest = hits.count - shown.count
            return MCPWire.textFailure("\(hits.count) jobs have an id starting \(wanted): "
                + shown.joined(separator: ", ")
                + (rest > 0 ? " and \(rest) more" : "")
                + ". Type more of the one you mean.")
        }

        // Read one past the window so "there are older steps" is a fact rather than the
        // guess that count == window would be.
        let read = await AgentService.shared.loadSteps(jobId: job.id,
                                                       limit: agentStepWindow + 1)
        let truncated = read.count > agentStepWindow
        let steps = truncated ? Array(read.suffix(agentStepWindow)) : read

        return MCPWire.textResult(jsonText([
            "job": agentSummary(job, detailed: true),
            "steps": steps.map { agentStep($0) },
            "steps_truncated": truncated,
            "log_path": agentLogPath(job.id),
        ]))
    }

    /// How many steps a read hands back.
    ///
    /// A step's text is whatever the worker said, and an assistant turn runs to thousands of
    /// characters, so an unwindowed reply is the whole run in one socket line for a question
    /// that was "what is it doing". The tail is the part that answers it, and `log_path`
    /// comes back beside it so the rest is findable rather than lost.
    private static var agentStepWindow: Int { 60 }

    // MARK: - Shapes

    /// One job, as the CLI lays it out.
    ///
    /// STRUCTURED, NOT PROSE, and the money keys are the reason. `spent_usd` is not a bill:
    /// `SwarmOrchestrator` records it from the worker's own `total_cost_usd` for display and
    /// there is no hard stop, because workers run on the account's Claude subscription
    /// rather than metered API. A sentence written here would have to say that once per
    /// call and would still leave the reader nothing to sort by.
    private static func agentSummary(_ job: AgentJob,
                                     detailed: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "id": job.id,
            "title": job.title,
            "status": job.status.rawValue,
            "finished": job.isTerminal,
            "created_at": agentStamp.string(from: job.createdAt),
            "workers": job.workers.count,
            "workers_done": job.workers.filter { $0.status == .done }.count,
            "workers_failed": job.workers.filter { $0.status == .failed }.count,
            "spent_usd": job.spentUSD,
            "budget_usd": job.budgetUSD,
        ]
        // WHY IT STOPPED IS A SEPARATE FACT FROM THAT IT STOPPED. A job waiting on an
        // account limit and a job waiting on an approval both read `waiting`, and they want
        // opposite things from the person: one wants a sign in, the other wants a click.
        if let reason = job.pausedReason { row["waiting_on"] = reason.rawValue }
        if let error = job.errorMessage { row["error"] = error }
        if let started = job.startedAt { row["started_at"] = agentStamp.string(from: started) }
        if let done = job.completedAt { row["completed_at"] = agentStamp.string(from: done) }
        if detailed {
            row["goal"] = job.goal
            row["root_dir"] = job.rootDir
        }
        return row
    }

    private static func agentStep(_ step: AgentStep) -> [String: Any] {
        // The text arrives WHOLE. Clipping belongs to the surface that knows whether a
        // person or a pipe is reading, and a handler that clipped would take that choice
        // away from every caller at once.
        var row: [String: Any] = [
            "at": agentStamp.string(from: step.ts),
            "kind": step.kind.rawValue,
            "text": step.text,
        ]
        if let worker = step.workerId { row["worker"] = worker }
        if let tool = step.toolName { row["tool"] = tool }
        if let cost = step.costUSD { row["cost_usd"] = cost }
        return row
    }

    private static func agentLogPath(_ jobId: String) -> String {
        AgentService.shared.jobFolderURL(jobId: jobId)
            .appendingPathComponent("log.ndjson").path
    }

    /// ISO 8601, because these cross a process boundary. "12 minutes ago" is a sentence and
    /// sentences are the reader's end of this, not the wire's.
    private static let agentStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
