import Foundation

// Claude-tool adapter for deep research. Registered by ChatService.allTools()
// and dispatched by ChatService's tool switch, mirroring NotesTool's shape.
// deep_research runs the full pipeline (plan + gather + synthesize) and
// returns the executive summary plus the on-disk report path; the full cited
// report lives in the Research tab.
enum ResearchTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "deep_research",
                description: "Run a DEEP multi-source research job: decomposes the question into 3-6 angles, searches and reads the live web per angle in parallel, then synthesizes a structured report with inline numbered citations and a sources list. Takes 1-3 minutes and costs real tokens, so use it only when the user explicitly wants a thorough, cited report ('deep research X', 'full report on Y', 'research this properly'). For quick factual lookups keep using research_web. Returns the executive summary and the saved report path; tell them the summary and that the full cited report is in the Research tab.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "question": [
                            "type": "string",
                            "description": "The research question, phrased fully and specifically (audience, scope, timeframe when relevant)."
                        ]
                    ],
                    "required": ["question"]
                ]
            ),
            ClaudeTool(
                name: "list_research_reports",
                description: "List the user's completed deep research reports (newest first) with their ids, titles, and dates. Use when they ask 'what have we researched', 'find that report about X', or before re-running a question that may already have a report.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max rows. Default 10, max 25."]
                    ]
                ]
            )
        ]
    }

    static let toolNames: Set<String> = ["deep_research", "list_research_reports"]

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "deep_research":
            let question = ((input["question"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return "error: empty research question" }
            let jobId = await DeepResearchEngine.shared.runAndWait(question: question)
            return await MainActor.run {
                guard let job = ResearchStore.shared.job(id: jobId) else {
                    return "error: research job lost"
                }
                if job.phase == .failed {
                    return "error: \(job.errorMessage ?? "deep research failed")"
                }
                let summary = ResearchReportAssembler.executiveSummary(from: job.reportMarkdown)
                let path = ResearchStore.reportURL(for: job.id).path
                return """
                ok: deep research complete. \(job.sources.count) sources, report saved.
                Title: \(job.displayTitle)
                Executive summary: \(summary.isEmpty ? "(see report)" : summary)
                Report path: \(path)
                Full cited report is in the Research tab.
                """
            }

        case "list_research_reports":
            let limit = min(25, max(1, (input["limit"] as? Int) ?? 10))
            return await MainActor.run {
                let done = ResearchStore.shared.ordered.filter { $0.phase == .done }
                guard !done.isEmpty else { return "(no completed research reports yet)" }
                let df = DateFormatter()
                df.dateFormat = "MMM d"
                df.timeZone = .current
                let rows = done.prefix(limit).map { job in
                    "- id=\(job.id.uuidString) · \(job.displayTitle) · \(df.string(from: job.createdAt)) · \(job.sources.count) sources"
                }.joined(separator: "\n")
                let suffix = done.count > limit ? "\n(\(done.count - limit) more, raise limit to see)" : ""
                return rows + suffix
            }

        default:
            return "error: unknown research tool '\(name)'"
        }
    }
}
