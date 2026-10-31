import Foundation

/// Which tools ride on a turn. Measured 2026-09-20 on this install: 116 tool
/// schemas, 79,725 characters, 61 percent of a 130k character prompt, on a
/// turn that asked the time. Every tool a turn cannot use is cost, latency
/// and, for a small model, a distraction. The core set (tasks, memory, music,
/// mail, calendar, notes, documents, contacts, files, macros,
/// modes, MCP) always rides; the six heavy groups ride when the words call
/// for them or when one of their tools ran within the last fifteen minutes,
/// so a loop that started keeps its tools across turns.
///
/// The tools that bring another app to the front (Chrome, YouTube, any app) are a
/// group of their own: measured 2026-10-22, llama3.2:3b answered "what is two plus
/// two" by calling play_on_youtube, and Grux opened YouTube. They ride when the words
/// ask to open, watch, play or search for something, or name a web address, and after
/// a music tool ran (play_music_track's miss falls back to play_on_youtube).
/// search_web is one of them: it opens Google in Chrome and returns no results.
enum ToolRelevance {
    enum Group: String, CaseIterable, Sendable { case core, developer, meetings, research, export, creative, screen, otherApps }

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
            ("open_url", .otherApps), ("open_app", .otherApps), ("play_on_youtube", .otherApps), ("search_web", .otherApps),
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
        .otherApps: ["launch", "open", "opens", "opening", "pull up", "bring up", "go to", "show me", "fire up", "boot up",
                     "start", "switch to", "visit", "navigate", "youtube", "video", "videos", "watch", "play", "playing",
                     "put on", "throw on", "queue up", "hear", "listen", "listening", "song", "songs", "music", "album",
                     "playlist", "track", "chrome", "safari", "firefox", "browser", "tab", "website", "site", "page",
                     "url", "link", "app", "google", "search", "search for", "look up", "online", "web", "http",
                     "https", "www"],
    ]

    /// A web address in the words ("github.com", "docs.swift.org/x") asks for a page.
    private static let webAddress = try? NSRegularExpression(
        pattern: "(?:^|[^a-z0-9.-])[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.(?:com|org|net|io|dev|app|ai|co|edu|gov|me|tv|us|uk)(?:[^a-z0-9-]|$)")

    static let recencyWindow: TimeInterval = 15 * 60

    /// Music tools whose miss falls back to play_on_youtube.
    static let musicTools: Set<String> = ["play_music_track", "list_library_tracks"]

    /// The tools in `.otherApps`, named for the wake.log line.
    static let otherAppsTools = ["open_url", "open_app", "play_on_youtube", "search_web"]

    static func groups(for s: Signals) -> Set<Group> {
        var out: Set<Group> = [.core]
        let text = s.utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return Set(Group.allCases) }
        if s.hasImage { out.insert(.screen) }
        for (g, words) in keywords where ChatIntentClassifier.containsAnyWord(text, keywords: words) { out.insert(g) }
        let lowered = text.lowercased()
        if webAddress?.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil {
            out.insert(.otherApps)
        }
        for name in s.recentToolNames {
            out.insert(group(for: name))
            if musicTools.contains(name) { out.insert(.otherApps) }
        }
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

    /// Forget every use. For tests, which share this one record.
    func clear() { uses.removeAll() }
}
