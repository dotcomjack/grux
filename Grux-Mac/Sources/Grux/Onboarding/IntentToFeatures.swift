import Foundation

/// P-F-1, Task F2: the answer to "What do you want to do with Grux?", turned
/// into the registry rows that serve it.
///
/// ## The keyless path is the default path
///
/// A stranger on a clean Mac has no key, so the on-device answer is the one
/// almost everybody gets, and it has to be sensible on its own: the floor
/// everybody gets, plus every row whose words the answer uses. A key makes it
/// better by adding rows the words missed. It never removes one, so the
/// on-device answer is always the lower bound of what a key returns.
///
/// ## Nobody gets zero
///
/// An onboarding that concludes "nothing for you" is a bug, so the floor is
/// unconditional: an empty answer, a joke or a refusal still gets Chat, Mail,
/// Calendar, Notes and Tasks, plus the rows everything else is found through.
///
/// ## No second source of truth
///
/// This picks FEATURES. What each one needs, and whether that is satisfied,
/// stays with `FeatureRegistry` and `CapabilityResolver`; `SetupOrder` reads
/// them. The Developer door is unlocked by the rows behind it, read from
/// their dispositions, never from a list kept here.
@MainActor
enum IntentToFeatures {

    /// The gate's name on the engine and in the ledger.
    static let surface = "onboarding.intent"

    /// Chosen on the 16 in-sample answers, where 0.80 kept the recall of 0.70
    /// with fewer false picks. What the app returns (the words plus what Jev
    /// adds) scored precision 0.95 and recall 0.95 in-sample, and 0.80 and
    /// 0.89 on the 8 held-out answers, against 0.88 and 0.78 for the words
    /// alone. `docs/superpowers/evidence/2026-09-21-p-f-1/calibration-2026-09-21.txt`.
    static let threshold = 0.80

    /// Everybody gets these, whatever they said.
    static let floor = ["chat", "mailbox", "calendar", "notes", "tasks"]

    /// Where everything else is found, and where risky actions stop. No answer
    /// turns these off, because a Grux without Today, Approvals or Settings has
    /// nowhere to put anything the answer did select.
    static let always = ["home", "approvals", "settings"]

    /// "I write code" and its variants select these, which is what shows the
    /// Developer door.
    static let codeRows = ["commands", "agents"]

    /// Words that name a row beyond its label, for the keyless path.
    ///
    /// Matching is by whole word (see `matches`), so a short cue like `ui` or
    /// `ads` cannot fire inside "build" or "roads". A cue of six letters or
    /// more is a stem and matches any ending, which is how "transcrib" covers
    /// transcribe, transcribing and transcription.
    static let cues: [String: [String]] = [
        "documents": ["document", "docs", "pdf", "files", "contract", "paperwork", "spreadsheet"],
        "contacts": ["contact", "people", "crm", "client", "customer", "relationship", "follow up"],
        "meetings": ["meeting", "zoom", "standup", "transcrib", "interview", "record calls", "my calls"],
        "speakers": ["who said", "speaker"],
        "schedules": ["schedul", "remind", "recurring", "routine", "every morning", "every day", "daily", "weekly"],
        "workflows": ["workflow", "automat", "pipeline"],
        "research": ["research", "look up", "look things up", "search the web", "sources", "read up on"],
        "design.studio": ["design", "mockup", "wireframe", "figma", "layout", "ui", "landing page", "website"],
        "creative": ["image", "picture", "photo", "photograph", "video", "illustrat", "artwork", "thumbnail"],
        "integrations": ["slack", "notion", "integrat", "zapier", "connect my"],
        "integrations.webhooks": ["webhook"],
        "mailbox.compose": ["reply", "replies", "send email", "send emails", "write email", "draft email", "respond"],
        "projects": ["project", "client work"],
        "folders": ["folder", "downloads"],
        "skills": ["skill"],
        "focus": ["focus", "distract", "procrastinat", "on track", "productiv", "screen time"],
        "social": ["social", "instagram", "twitter", "threads", "tiktok", "linkedin", "post", "audience"],
        "meta.ads": ["ads", "advertis", "ad campaign", "facebook ads"],
        "phone": ["iphone", "my phone", "on the go", "away from my mac"],
        "cookbook": ["local model", "ollama", "offline", "private model", "on device", "no cloud"],
        "compare": ["compare models", "which model", "benchmark"],
        "agents": ["agent", "claude code", "codex", "terminal"],
        "reactor": ["under the hood", "what grux is doing", "live panel"],
        "jax.hq": ["inbox agent", "triage", "support inbox", "customer support", "support email"],
        "jax.command": ["goals", "on its own", "autonomous", "autonomously", "agentic"],
        "cognition.map": ["why it decided", "reasoning", "transparen"],
        "feature.review": ["review its work", "code review", "what reaches main"],
        "self.upgrade": ["improve itself", "upgrade itself", "self upgrade", "self improving"],
    ]

    /// Words that mean the person writes software.
    static let codeCues = [
        "code", "coding", "coder", "program", "developer", "software", "engineer", "repo", "repository",
        "github", "git", "script", "debug", "deploy", "pull request", "commit", "xcode", "swift",
        "python", "javascript", "typescript", "rust", "ios app", "ship apps", "build apps",
    ]

    /// Words that ask for one thing on screen at a time.
    static let oneAtATimeCues = [
        "adhd", "overwhelm", "one thing at a time", "one at a time", "step by step", "keep it simple",
    ]

    /// One line on what each row does, for the engine's questions. Rows not
    /// listed are asked about by label alone.
    static let purposes: [String: String] = [
        "documents": "reads and summarises documents and files on this Mac",
        "contacts": "keeps track of people and what you last said to them",
        "meetings": "records and transcribes meetings on this Mac",
        "speakers": "names who said what in a recorded meeting",
        "schedules": "runs things on a schedule and reminds you",
        "workflows": "chains steps into automations",
        "research": "searches the web and writes up what it found",
        "design.studio": "designs screens and pages and critiques them",
        "creative": "generates images and video",
        "integrations": "connects Slack, Notion and other services",
        "integrations.webhooks": "sends events to your own services",
        "mailbox.compose": "writes and sends email replies",
        "projects": "groups work by project",
        "folders": "watches folders you choose",
        "skills": "reusable instructions for chat",
        "focus": "notices when you drift off what you meant to do",
        "social": "drafts and schedules social posts for a brand",
        "meta.ads": "runs Meta ad campaigns for a brand",
        "phone": "talks to Grux from an iPhone",
        "cookbook": "runs models locally on this Mac",
        "compare": "compares answers from different models",
        "agents": "runs coding agents for you",
        "commands": "voice macros: a phrase you say that runs a set of steps",
        "reactor": "a live panel of what Grux is doing",
        "jax.hq": "an agent that triages a support inbox",
        "jax.command": "goals Grux pursues on its own",
        "cognition.map": "why Grux decided what it did",
        "feature.review": "reviews Grux's own changes before they land",
        "self.upgrade": "Grux proposes and builds improvements to itself",
    ]

    // MARK: - The keyless answer

    /// Floor, the always rows, and every row the answer's words name, with
    /// anything a picked row depends on, in registry order. Pure.
    static func keyless(answer: String) -> [String] {
        let said = words(answer)
        var picked = Set(floor + always)
        for (id, list) in cues where list.contains(where: { uses($0, in: said) }) {
            picked.insert(id)
        }
        if codeCues.contains(where: { uses($0, in: said) }) {
            picked.formUnion(codeRows)
        }
        return ordered(withDependencies(picked))
    }

    /// True when any picked row lives behind the Developer door.
    static func unlocksDeveloper(_ ids: [String]) -> Bool {
        ids.contains { FeatureRegistry.disposition(for: $0) == .developer }
    }

    /// Opens the Developer door when the selection needs it. Only ever raises:
    /// an answer that says nothing about code does not close a door somebody
    /// already opened.
    static func apply(_ ids: [String], to config: inout GruxConfig) {
        if unlocksDeveloper(ids) { config.developerSurfacesUnlocked = true }
    }

    static func asksForOneAtATime(_ answer: String) -> Bool {
        let said = words(answer)
        return oneAtATimeCues.contains { uses($0, in: said) }
    }

    // MARK: - The keyed answer

    /// The keyless answer, plus what a decision provider judges the answer
    /// plainly asks for at or above `threshold`, in one call.
    ///
    /// Without a key nothing is asked and nothing is recorded. A provider that
    /// failed and fell back on device does not get a vote, because the
    /// on-device fallback cannot judge a free-text answer and the keyless
    /// answer already holds everything the words say.
    static func select(answer: String, engine: DecisionEngine, threshold: Double) async -> [String] {
        let base = keyless(answer: answer)
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard engine.hasRemoteKey, !trimmed.isEmpty else { return base }
        let open = FeatureRegistry.rows.filter { !base.contains($0.id) }
        guard !open.isEmpty else { return base }
        var questions: [String: DecisionQuestion] = [:]
        for row in open { questions[questionKey(for: row.id)] = question(for: row) }
        let result = await engine.decide(surface: surface, state: state(answer: trimmed), questions: questions)
        guard result.provider == .jev else { return base }
        var picked = Set(base)
        for row in open {
            if case .noul(let p)? = result.answers[questionKey(for: row.id)], p >= threshold {
                picked.insert(row.id)
            }
        }
        return ordered(withDependencies(picked))
    }

    static func state(answer: String) -> String {
        "A person setting up Grux, a Mac assistant, was asked what they want to do with it and answered: \(answer)"
    }

    /// Calibrated 2026-09-21 against jev-latest (grux-ecosystem key), 24
    /// answers asked about all 30 rows outside the floor
    /// (`docs/superpowers/evidence/2026-09-21-p-f-1/`). The first wording,
    /// "Their answer asks for X, or plainly needs it", said yes to Workflows,
    /// Skills, Agents and Commands for nearly every answer: precision 0.26 at
    /// 0.70. A plain statement about what the answer MENTIONS, with the row's
    /// purpose beside its name, is what Jev reads literally and well.
    static func question(for row: FeatureRow) -> DecisionQuestion {
        let purpose = purposes[row.id] ?? row.label
        return .noul(instructions: "The answer mentions something that \(row.label) is for. \(row.label): \(purpose).")
    }

    /// Registry ids carry dots, and a question name is a JSON property, so the
    /// name is the id with its dots as underscores.
    static func questionKey(for id: String) -> String {
        id.replacingOccurrences(of: ".", with: "_")
    }

    // MARK: - Matching

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// A cue of one or more words is used when its words appear in order in
    /// the answer, each matching one word.
    static func uses(_ cue: String, in said: [String]) -> Bool {
        let parts = words(cue)
        guard !parts.isEmpty, parts.count <= said.count else { return false }
        for start in 0...(said.count - parts.count) {
            let window = said[start..<(start + parts.count)]
            if zip(parts, window).allSatisfy({ matches(cue: $0, word: $1) }) { return true }
        }
        return false
    }

    /// The word itself or a regular ending of it; a cue of six letters or more
    /// is a stem and matches any ending.
    static func matches(cue: String, word: String) -> Bool {
        if word == cue { return true }
        if ["s", "es", "d", "ed", "r", "er", "ers", "ing"].contains(where: { word == cue + $0 }) { return true }
        return cue.count >= 6 && word.hasPrefix(cue)
    }

    // MARK: - Shape

    /// A row that depends on another brings it along: Speakers with no
    /// Meetings is a screen with nothing to show.
    static func withDependencies(_ ids: Set<String>) -> Set<String> {
        var out = ids
        for id in ids {
            for need in FeatureRegistry.row(id: id)?.dependsOn ?? [] { out.insert(need) }
        }
        return out
    }

    static func ordered(_ ids: Set<String>) -> [String] {
        FeatureRegistry.rows.map(\.id).filter { ids.contains($0) }
    }
}
