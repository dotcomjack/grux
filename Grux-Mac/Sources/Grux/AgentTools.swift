import Foundation
import GruxAgentCore

// Claude tools for the agent framework. Registered into ChatService.allTools()
// and dispatched from ChatService.dispatchTool().

enum AgentTools {

    static let toolNames: Set<String> = [
        "agent_swarm_start",
        "agent_list",
        "agent_status",
        "agent_cancel"
    ]

    static func claudeTools() -> [ClaudeTool] {
        return [
            ClaudeTool(
                name: "agent_swarm_start",
                description: """
                Spin up an autonomous swarm of Claude Code worker subprocesses to deliver a multi-step result. THIS IS YOUR DEFAULT FALLBACK whenever the user asks for ANYTHING that would take more than 1-2 tool calls. Workers have full Claude Code tools (Bash, Edit, Write, Read, Grep, WebFetch, WebSearch, plus the Task tool for their own subagents).

                USE THIS FOR (non-exhaustive - when in doubt, spawn a swarm rather than say "I don't have a tool"):
                - Building any code project: iOS apps, websites, scripts, refactors, bug-fix sweeps
                - Content / copywriting: tweet threads, blog posts, X.com posts, brand voice exercises, ad copy, landing-page copy, email sequences, video scripts
                - Research: competitor analysis, market scans, due-diligence dossiers, "find me 20 X" tasks
                - Marketing / brand work: positioning docs, persona briefs, naming exercises, launch-quality polish reviews
                - Strategy / planning: roadmaps, OKR breakdowns, launch checklists
                - Data work: scraping + summarizing, CSV transforms, multi-source synthesis
                - Anything the user would otherwise need to do in 5+ messages

                If the user has not said where output should land, just generate a sensible default path under ~/Documents/Grux/swarms/ - don't ask. If they have not picked a template, default to singleWorker for short tasks, architectImplement for substantial ones, iosAppFull when they are literally building an iOS app.

                Returns a job_id. Swarm runs detached; tell them they can watch the Agents tab.

                Templates:
                - singleWorker: 1 worker. Default for tweets/posts/short copy/quick research.
                - architectImplement: architect produces plan.md → implementor delivers. Default for substantial deliverables.
                - parallelTrio: 3 implementors in parallel - useful for "give me 3 variants of X".
                - iosAppFull: architect → 4 parallel feature implementors → integrator → build-loop → qa. Only for actual iOS apps.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal": [
                            "type": "string",
                            "description": "Plain-English description of what the swarm should produce. Be specific about acceptance criteria. The worker will see this verbatim - write it as a brief to a smart contractor, not as a chat reply to the user."
                        ],
                        "template": [
                            "type": "string",
                            "enum": ["singleWorker", "architectImplement", "parallelTrio", "critiqueLoop", "iosAppFull"],
                            "description": "Plan template. 'singleWorker' for short content tasks. 'architectImplement' (architect→implementor) for substantial deliverables. 'critiqueLoop' (architect→writer→critic→reviser, 4 workers) for highest-quality content/copy/research where a critique pass dramatically lifts quality. 'iosAppFull' only for literal iOS app builds. 'parallelTrio' for 3 parallel variants."
                        ],
                        "root_dir": [
                            "type": "string",
                            "description": "Optional. Absolute path the swarm operates in. If omitted, Grux picks ~/Documents/Grux/swarms/<slug>/ automatically - DO NOT ask the user for this unless they have clearly told you the path matters (e.g., they want the work in a specific repo)."
                        ],
                        "budget_usd": [
                            "type": "number",
                            "description": "Hard cost ceiling across all workers. Default 5.0. Use 0.50 for tiny content tasks, 5.0 for substantial work, 25.0 for full iOS apps."
                        ],
                        "max_parallel": [
                            "type": "integer",
                            "description": "Max workers running concurrently. Default 3."
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional short title for the Agents tab. Auto-derived from goal if omitted."
                        ]
                    ],
                    "required": ["goal"]
                ]
            ),
            ClaudeTool(
                name: "agent_list",
                description: "List recent agent jobs (active + recent terminal). Returns id, status, title, spent, worker counts.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Default 20."]
                    ]
                ]
            ),
            ClaudeTool(
                name: "agent_status",
                description: "Get full status of one job by id, including each worker's status and last result text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "job_id": ["type": "string"]
                    ],
                    "required": ["job_id"]
                ]
            ),
            ClaudeTool(
                name: "agent_cancel",
                description: "Cancel a running job. Sends SIGTERM to all live worker subprocesses.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "job_id": ["type": "string"]
                    ],
                    "required": ["job_id"]
                ]
            )
        ]
    }

    @MainActor
    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "agent_swarm_start":
            let goal = (input["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rootDirInput = (input["root_dir"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let templateRaw = (input["template"] as? String) ?? "singleWorker"
            let budget = (input["budget_usd"] as? Double) ?? (Double((input["budget_usd"] as? Int) ?? 5))
            let maxPar = (input["max_parallel"] as? Int) ?? 3
            let title = (input["title"] as? String)
            guard !goal.isEmpty else { return "error: goal is required" }
            guard let template = SwarmTemplate(rawValue: templateRaw) else {
                return "error: unknown template '\(templateRaw)' - pick singleWorker, architectImplement, parallelTrio, or iosAppFull"
            }
            // Auto-generate root_dir if not supplied. ~/Documents/Grux/swarms/<slug>-<short-uuid>/
            let rootDir: String = {
                if !rootDirInput.isEmpty { return rootDirInput }
                let slug = (title ?? goal)
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                    .prefix(6)
                    .joined(separator: "-")
                let suffix = String(UUID().uuidString.prefix(8)).lowercased()
                let base = NSHomeDirectory() + "/Documents/Grux/swarms"
                let path = "\(base)/\(slug.isEmpty ? "swarm" : slug)-\(suffix)"
                return path
            }()
            try? FileManager.default.createDirectory(atPath: rootDir, withIntermediateDirectories: true)
            let job = await AgentService.shared.startSwarm(
                title: title,
                goal: goal,
                template: template,
                rootDir: rootDir,
                budgetUSD: budget,
                maxParallelWorkers: maxPar
            )
            return """
            ok: started job_id=\(job.id) template=\(template.rawValue) workers=\(job.workers.count) budget=$\(String(format: "%.2f", budget))
            root_dir: \(rootDir)
            track: open the Agents tab in Grux, or call agent_status with this job_id.
            """

        case "agent_list":
            let limit = (input["limit"] as? Int) ?? 20
            await AgentService.shared.refreshJobs()
            let jobs = AgentService.shared.jobs.prefix(limit)
            if jobs.isEmpty { return "(no agent jobs yet)" }
            let lines = jobs.map { j -> String in
                let workersDone = j.workers.filter { $0.status == .done }.count
                let workersFailed = j.workers.filter { $0.status == .failed }.count
                return "- \(j.id.prefix(8)) [\(j.status.rawValue)] \(j.title) - \(workersDone)/\(j.workers.count) done\(workersFailed > 0 ? ", \(workersFailed) failed" : "") - $\(String(format: "%.4f", j.spentUSD))"
            }
            return lines.joined(separator: "\n")

        case "agent_status":
            let jobId = (input["job_id"] as? String) ?? ""
            guard !jobId.isEmpty else { return "error: job_id required" }
            await AgentService.shared.refreshJobs()
            // Fuzzy match by prefix if user passed a short id.
            let match = AgentService.shared.jobs.first { $0.id == jobId || $0.id.hasPrefix(jobId) }
            guard let j = match else { return "error: no job matching '\(jobId)'" }
            var lines: [String] = []
            lines.append("job: \(j.id)")
            lines.append("title: \(j.title)")
            lines.append("status: \(j.status.rawValue)")
            lines.append("budget: $\(String(format: "%.4f", j.spentUSD)) / $\(String(format: "%.2f", j.budgetUSD))")
            if let err = j.errorMessage { lines.append("error: \(err)") }
            lines.append("workers (\(j.workers.count)):")
            for w in j.workers {
                var line = "  - \(w.label) [\(w.role.rawValue)] → \(w.status.rawValue) ($\(String(format: "%.4f", w.spentUSD)))"
                if let e = w.errorMessage { line += " (\(e))" }
                lines.append(line)
                if let result = w.lastResultText, !result.isEmpty {
                    lines.append("    result: \(String(result.prefix(160)))")
                }
            }
            return lines.joined(separator: "\n")

        case "agent_cancel":
            let jobId = (input["job_id"] as? String) ?? ""
            guard !jobId.isEmpty else { return "error: job_id required" }
            let match = AgentService.shared.jobs.first { $0.id == jobId || $0.id.hasPrefix(jobId) }
            guard let j = match else { return "error: no job matching '\(jobId)'" }
            await AgentService.shared.cancel(jobId: j.id)
            return "ok: cancel signal sent to job \(j.id.prefix(8))"

        default:
            return "error: unknown agent tool '\(name)'"
        }
    }
}
