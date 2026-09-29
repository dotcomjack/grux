import Foundation

/// Which tools ride on a turn. Measured 2026-09-20 on this install: 116 tool
/// schemas, 79,725 characters, 61 percent of a 130k character prompt, on a
/// turn that asked the time. Every tool a turn cannot use is cost, latency
/// and, for a small model, a distraction. The core set (tasks, memory, music,
/// mail, calendar, notes, documents, contacts, files, web search, macros,
/// modes, MCP) always rides; the six heavy groups ride when the words call
/// for them or when one of their tools ran within the last fifteen minutes,
/// so a loop that started keeps its tools across turns.
enum ToolRelevance {
    enum Group: String, CaseIterable, Sendable { case core, developer, meetings, research, export, creative, screen }

    struct Signals {
        var utterance: String
        var recentToolNames: [String] = []
        var hasImage: Bool = false
    }

    static func group(for toolName: String) -> Group {
        let n = toolName.lowercased()
        let prefixes: [(String, Group)] = [
            ("ios_", .developer), ("agent_swarm", .developer), ("shell_", .developer), ("design_", .developer),
            ("foundry_", .developer), ("start_workflow", .developer), ("save_skill", .developer), ("backup_", .developer),
            ("compare_", .developer),
            ("start_meeting", .meetings), ("end_meeting", .meetings), ("enroll_speaker", .meetings), ("rename_speaker", .meetings),
            ("rename_cluster", .meetings), ("list_meetings", .meetings), ("search_meetings", .meetings), ("get_meeting", .meetings),
            ("summarize_meeting", .meetings), ("move_meeting", .meetings), ("classify_meeting", .meetings), ("export_audio", .meetings),
            ("create_folder", .meetings), ("rename_folder", .meetings), ("delete_folder", .meetings), ("list_folders", .meetings),
            ("research_web", .research), ("deep_research", .research), ("youtube_transcript", .research), ("list_research", .research),
            ("slack_", .export), ("notion_", .export), ("export_memory", .export), ("import_memory", .export),
            ("creative_", .creative),
            ("read_screen", .screen), ("control_screen", .screen), ("run_focus_check", .screen),
        ]
        for (p, g) in prefixes where n.hasPrefix(p) { return g }
        return .core
    }

    static let keywords: [Group: Set<String>] = [
        .developer: ["build", "builds", "code", "coding", "repo", "repository", "app", "apps", "ios", "iphone", "xcode", "swift",
                     "simulator", "scaffold", "ship", "testflight", "deploy", "publish", "release", "swarm", "agent", "agents",
                     "worker", "workers", "shell", "terminal", "script", "compile", "compiles", "bug", "bugs", "error", "errors",
                     "test", "tests", "git", "github", "pull request", "commit", "design", "mockup", "mock up", "prototype",
                     "landing page", "website", "site", "html", "css", "brand kit", "logo", "skill", "skills", "workflow",
                     "workflows", "backup", "upgrade", "foundry", "compare", "project", "projects", "localize", "run it"],
        .meetings: ["meeting", "meetings", "capture", "transcript", "transcripts", "speaker", "speakers", "enroll", "recording",
                    "record", "standup", "who said", "folder", "folders", "diarize", "export the audio"],
        .research: ["research", "deep dive", "look into", "investigate", "report", "reports", "youtube", "video", "article",
                    "paper", "study", "sources", "summarize this", "what does the internet"],
        .export: ["slack", "notion", "push", "sync", "export", "import", "channel", "workday log", "post to"],
        .creative: ["image", "images", "picture", "pictures", "photo", "render", "generate", "art", "thumbnail", "poster",
                    "illustration", "hero shot", "visual", "visuals", "creative", "bundle"],
        .screen: ["screen", "look at", "what's on", "read that", "click", "type", "scroll", "press", "control", "see this",
                  "seeing", "cursor", "button", "form", "fill", "am i focused", "focus check", "what app"],
    ]

    static let recencyWindow: TimeInterval = 15 * 60

    static func groups(for s: Signals) -> Set<Group> {
        var out: Set<Group> = [.core]
        let text = s.utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return Set(Group.allCases) }
        if s.hasImage { out.insert(.screen) }
        for (g, words) in keywords where ChatIntentClassifier.containsAnyWord(text, keywords: words) { out.insert(g) }
        for name in s.recentToolNames { out.insert(group(for: name)) }
        return out
    }

    static func filter(_ tools: [ClaudeTool], signals: Signals) -> [ClaudeTool] {
        let active = groups(for: signals)
        return tools.filter { active.contains(group(for: $0.name)) }
    }

    /// The prompt sections that only make sense on a code-shaped turn ride
    /// together with the developer tools.
    static func developerContextRides(signals: Signals) -> Bool {
        groups(for: signals).contains(.developer)
    }
}

/// In-memory record of which tools ran recently, for ToolRelevance's
/// recency rule. Names only, never arguments.
@MainActor
final class RecentToolUse {
    static let shared = RecentToolUse()
    private var uses: [(name: String, at: Date)] = []

    func record(_ name: String, at: Date = Date()) {
        uses.append((name, at))
        if uses.count > 64 { uses.removeFirst(uses.count - 64) }
    }

    func names(within window: TimeInterval = ToolRelevance.recencyWindow, now: Date = Date()) -> [String] {
        uses.filter { now.timeIntervalSince($0.at) <= window }.map(\.name)
    }
}
