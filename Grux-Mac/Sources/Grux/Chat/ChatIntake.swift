import Foundation

// Conversational intake before a Commands V2 workflow fires.
//
// Trigger: user says "ship the iOS app" with no project named. Without intake,
// ChatService used to fire ship-ios-app immediately with empty params, the
// workflow's brainstorm agent would whisper a question into the workflow log
// where the chat thread never showed it, and the user would approve a void they
// could not see, leading to the agent guessing a project from disk and
// rewriting an existing app's source.
//
// With intake, ChatService routes the next user replies through a small state
// machine instead of straight to Claude. Each stage knows which question it
// just asked and how to interpret the answer.

struct ChatIntakeState: Codable, Equatable {
    enum Flow: String, Codable {
        case shipIOSApp
    }
    enum Stage: String, Codable {
        case askedNewOrExisting
        case askedIdea
        case askedName
        case awaitingPlanApproval
        case askedExistingChoice
    }
    var flow: Flow
    var stage: Stage
    var collected: [String: String]
    var startedAt: Date

    init(flow: Flow, stage: Stage, collected: [String: String] = [:], startedAt: Date = Date()) {
        self.flow = flow
        self.stage = stage
        self.collected = collected
        self.startedAt = startedAt
    }
}

// What the intake handler tells ChatService to do next.
enum IntakeOutcome {
    case reply(String)                                                    // post assistant message, save updated intake
    case fireWorkflow(definitionId: String, params: [String: String], confirmation: String)  // clear intake, start V2 run
    case cancel(reply: String)                                            // clear intake, post message
}

@MainActor
enum IntakeHandler {
    /// Process one user reply within an active intake. Returns the outcome
    /// + the intake state that should be persisted (nil → clear intake).
    static func step(intake: ChatIntakeState, userText: String)
        -> (outcome: IntakeOutcome, nextIntake: ChatIntakeState?)
    {
        let raw = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        if lower == "cancel" || lower == "abort" || lower == "stop" || lower == "nvm" {
            return (.cancel(reply: "Cancelled the ship intake. Say 'ship the iOS app' to start over."), nil)
        }

        switch (intake.flow, intake.stage) {
        case (.shipIOSApp, .askedNewOrExisting):
            return handleNewOrExisting(intake: intake, raw: raw, lower: lower)
        case (.shipIOSApp, .askedIdea):
            return handleIdea(intake: intake, raw: raw)
        case (.shipIOSApp, .askedName):
            return handleName(intake: intake, raw: raw)
        case (.shipIOSApp, .awaitingPlanApproval):
            return handlePlanApproval(intake: intake, lower: lower)
        case (.shipIOSApp, .askedExistingChoice):
            return handleExistingChoice(intake: intake, raw: raw, lower: lower)
        }
    }

    // MARK: - Stage handlers

    private static func handleNewOrExisting(intake: ChatIntakeState, raw: String, lower: String)
        -> (IntakeOutcome, ChatIntakeState?)
    {
        if matchesNew(lower) {
            var next = intake
            next.stage = .askedIdea
            return (.reply("Sweet - what's the idea? A one-liner is fine (e.g. \"a daily mood tracker with a widget\", \"a habit timer that nags me at 9pm\")."), next)
        }
        if matchesExisting(lower) {
            let projects = ProjectRegistryStore.gruxCreatedProjects()
            if projects.isEmpty {
                var next = intake
                next.stage = .askedIdea
                return (.reply("I haven't created any iOS apps for you yet, so there's nothing to re-ship. Let's build a new one - what's the idea?"), next)
            }
            var next = intake
            next.stage = .askedExistingChoice
            let bullet = projects.map { "  • **\($0.displayName)** (`\($0.name)`)" }.joined(separator: "\n")
            return (.reply("Which one?\n\(bullet)\n\nReply with the name."), next)
        }
        return (.reply("Got it - but I need to know: are we **building a new app**, or **shipping an existing one**? (Reply 'new' or 'existing'.)"), intake)
    }

    private static func handleIdea(intake: ChatIntakeState, raw: String)
        -> (IntakeOutcome, ChatIntakeState?)
    {
        guard raw.count >= 4 else {
            return (.reply("Need a bit more - even one short sentence. What's the app supposed to do?"), intake)
        }
        var next = intake
        next.collected["idea"] = raw
        next.stage = .askedName
        return (.reply("Got it. What should I call it? **One word, alphanumeric only** (e.g. MoodLog, HabitNag, BeatPad)."), next)
    }

    private static func handleName(intake: ChatIntakeState, raw: String)
        -> (IntakeOutcome, ChatIntakeState?)
    {
        let cleaned = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        let allowed = CharacterSet.alphanumerics
        let isAlnum = !cleaned.isEmpty && cleaned.unicodeScalars.allSatisfy { allowed.contains($0) }

        guard isAlnum, cleaned.count >= 2, cleaned.count <= 30 else {
            return (.reply("Name must be 2-30 alphanumeric chars (no spaces, dashes, or punctuation). Try again."), intake)
        }
        if ProjectRegistryStore.find(name: cleaned) != nil {
            return (.reply("**\(cleaned)** is already in your project registry. Pick a different name."), intake)
        }
        // Also refuse if the canonical scaffold path already has a directory
        // with this name - that's a real app of the user's that Grux didn't create.
        let candidatePath = ProjectRegistryStore.defaultRoot(forName: cleaned)
        if FileManager.default.fileExists(atPath: candidatePath) {
            return (.reply("There's already a directory at `\(candidatePath)` and Grux didn't create it. Pick a different name (we don't touch projects Grux didn't author)."), intake)
        }

        var next = intake
        next.collected["name"] = cleaned
        next.stage = .awaitingPlanApproval

        let idea = intake.collected["idea"] ?? "(no idea recorded)"
        let bundle = ProjectRegistryStore.defaultBundleId(forName: cleaned)
        let summary = """
        Plan:
        • Name: **\(cleaned)**
        • Bundle ID: `\(bundle)`
        • Idea: \(idea)
        • Will scaffold at: `\(candidatePath)`
        • Then: brainstorm → build (5-agent swarm) → install → walkthrough → publish to ASC

        Reply **`go`** to start, **`cancel`** to abort.
        """
        return (.reply(summary), next)
    }

    private static func handlePlanApproval(intake: ChatIntakeState, lower: String)
        -> (IntakeOutcome, ChatIntakeState?)
    {
        if lower == "go" || lower == "approved" || lower == "ship it" || lower == "yes" || lower == "yep" || lower == "sure" {
            let name = intake.collected["name"] ?? ""
            let idea = intake.collected["idea"] ?? ""
            return (.fireWorkflow(
                definitionId: "ship-ios-app",
                params: ["project": name, "freshly_brainstormed": "true", "idea": idea],
                confirmation: "Approved. Scaffolding **\(name)** and starting the ship-ios-app workflow. Track in the Workflows tab."
            ), nil)
        }
        return (.reply("Reply **`go`** to start, or **`cancel`** to abort."), intake)
    }

    private static func handleExistingChoice(intake: ChatIntakeState, raw: String, lower: String)
        -> (IntakeOutcome, ChatIntakeState?)
    {
        let projects = ProjectRegistryStore.gruxCreatedProjects()
        if let match = projects.first(where: {
            $0.name.lowercased() == lower || $0.displayName.lowercased() == lower
        }) {
            return (.fireWorkflow(
                definitionId: "ship-ios-app",
                params: ["project": match.name],
                confirmation: "Shipping **\(match.displayName)**. Track in the Workflows tab."
            ), nil)
        }
        return (.reply("Couldn't find that one. Try a name from the list, or 'cancel' to abort."), intake)
    }

    // MARK: - Lexical helpers

    private static func matchesNew(_ lower: String) -> Bool {
        let tokens = ["new", "build", "create", "fresh", "from scratch", "brand new"]
        return tokens.contains(where: { lower.contains($0) })
    }

    private static func matchesExisting(_ lower: String) -> Bool {
        let tokens = ["existing", "ship", "publish", "update", "release", "old", "already"]
        return tokens.contains(where: { lower.contains($0) })
    }

    // MARK: - Public entry: start a new shipIOSApp intake

    static func startShipIOSApp() -> (intake: ChatIntakeState, firstReply: String) {
        let intake = ChatIntakeState(
            flow: .shipIOSApp,
            stage: .askedNewOrExisting,
            collected: [:],
            startedAt: Date()
        )
        let reply = "Are we **building a new iOS app** from scratch, or **shipping an existing one** I've created?\n\nReply 'new' or 'existing'."
        return (intake, reply)
    }
}
