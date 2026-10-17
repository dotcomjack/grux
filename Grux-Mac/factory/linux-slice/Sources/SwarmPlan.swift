import Foundation

// SwarmWorkerSpec - the static description of a worker (role + prompt + deps).
// SwarmWorker (separate file) is the runtime actor that executes the spec.
public struct SwarmWorkerSpec: Codable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case architect      // produces plan/PRD/file layout
        case implementor    // writes code modules
        case integrator     // wires modules together
        case buildLoop      // runs build/test until green
        case qa             // runs e2e tests, screenshots
        case brand          // visual/brand polish review
        case generic        // anything else
    }

    public enum Status: String, Codable, Sendable {
        case queued
        case running
        case done
        case failed
        case cancelled
        case skipped
        // Worker hit Anthropic's monthly usage limit on the active claude
        // account. Distinct from .failed because the work isn't broken - it's
        // waiting on a (manual or automated) account switch. The orchestrator
        // re-queues these workers when the user picks an account in the
        // Resume sheet and AccountSwitcher confirms the swap.
        case pausedForAuth
    }

    public let id: String
    public var role: Role
    public var label: String           // short display name ("architect", "build-loop", "feature-chat")
    public var goal: String            // the prompt for this worker
    public var cwd: String             // working dir
    public var dependsOn: [String]     // ids of workers that must finish first
    public var model: String           // coding model, e.g. "claude-opus-4-8"
    public var maxTurns: Int?          // optional hard cap, unset = unbounded
    public var budgetUSD: Double       // hard stop on cost
    public var allowedTools: [String]?  // nil = default; explicit list narrows
    public var status: Status
    public var startedAt: Date?
    public var completedAt: Date?
    public var spentUSD: Double
    public var sessionId: String?      // claude --session-id, for resume
    public var lastResultText: String? // assistant final text (for next workers)
    public var errorMessage: String?
    // Set when status == .pausedForAuth (or any future pausing condition).
    // Records why the worker is parked + checkpoint context for the resume
    // sheet's UI copy. Cleared when the worker is re-queued by resumeJob().
    public var interruption: WorkerInterruption?

    public init(
        id: String = UUID().uuidString,
        role: Role,
        label: String,
        goal: String,
        cwd: String,
        dependsOn: [String] = [],
        model: String = "claude-opus-4-8",
        maxTurns: Int? = nil,
        budgetUSD: Double = 1.0,
        allowedTools: [String]? = nil,
        status: Status = .queued,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        spentUSD: Double = 0,
        sessionId: String? = nil,
        lastResultText: String? = nil,
        errorMessage: String? = nil,
        interruption: WorkerInterruption? = nil
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.goal = goal
        self.cwd = cwd
        self.dependsOn = dependsOn
        self.model = model
        self.maxTurns = maxTurns
        self.budgetUSD = budgetUSD
        self.allowedTools = allowedTools
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.spentUSD = spentUSD
        self.sessionId = sessionId
        self.lastResultText = lastResultText
        self.errorMessage = errorMessage
        self.interruption = interruption
    }

    public var isTerminal: Bool {
        switch status {
        case .done, .failed, .cancelled, .skipped: return true
        case .queued, .running, .pausedForAuth: return false
        }
    }
}

// MARK: - Plan templates
//
// Canned plans. The conductor expands these into concrete workers given a
// goal + rootDir. Adding a new template = adding one case + one factory.

public enum SwarmTemplate: String, Codable, Sendable {
    case singleWorker         // 1 worker - simplest case (smoke test)
    case architectImplement   // architect → implementor (chain of 2)
    case parallelTrio         // 3 implementors run in parallel, no deps
    case critiqueLoop         // architect → writer → critic → reviser (4 workers, sequential)
    case iosAppFull           // full iOS app pipeline
}

public enum SwarmPlanFactory {

    public static func expand(
        template: SwarmTemplate,
        goal: String,
        rootDir: String,
        // Every coding/build role runs on Opus 4.8. (Audited 2026-06-16: Grux's
        // coding was split across Opus 4.7 + Sonnet 4.6; consolidated to 4.8.)
        // One model param; a caller may still override it per job.
        codeModel: String = "claude-opus-4-8"
    ) -> [SwarmWorkerSpec] {
        switch template {
        case .singleWorker:
            return [
                SwarmWorkerSpec(
                    role: .generic,
                    label: "solo",
                    goal: goal,
                    cwd: rootDir,
                    model: codeModel,
                    budgetUSD: 1.0
                )
            ]

        case .architectImplement:
            let arch = SwarmWorkerSpec(
                role: .architect,
                label: "architect",
                goal: """
                You are the ARCHITECT. Your only output is a plan.md file in \(rootDir) describing:
                - The goal in your own words
                - File map (paths + responsibilities)
                - Build/test commands

                Goal: \(goal)

                Write plan.md and exit. Do NOT write any other code yet.
                """,
                cwd: rootDir,
                model: codeModel,
                budgetUSD: 0.50
            )
            let impl = SwarmWorkerSpec(
                role: .implementor,
                label: "implementor",
                goal: """
                You are the IMPLEMENTOR. Read plan.md in \(rootDir), then implement everything it describes.
                Goal context: \(goal)
                Verify by running the build/test commands plan.md specifies. Do not stop until they pass.
                """,
                cwd: rootDir,
                dependsOn: [arch.id],
                model: codeModel,
                budgetUSD: 3.0
            )
            return [arch, impl]

        case .parallelTrio:
            return (1...3).map { i in
                SwarmWorkerSpec(
                    role: .implementor,
                    label: "worker-\(i)",
                    goal: "\(goal)\n\nYou are worker \(i) of 3. Work in your own sub-directory \(rootDir)/worker-\(i)/ and don't touch files outside it.",
                    cwd: rootDir,
                    model: codeModel,
                    budgetUSD: 0.5
                )
            }

        case .critiqueLoop:
            // 4-stage pipeline. Each stage reads the prior stage's artifact in
            // rootDir. Designed for content/copy/research where a critic pass
            // dramatically lifts quality.
            //
            // Per-worker budgets calibrated from real runs: writer + reviser
            // are the heavy stages. Total ≈ $2.50 worst-case.
            // CRITICAL: every worker is told to write to brief.md/draft.md/critique.md/final.md
            // ONLY. The user's goal text may demand a different output filename, but
            // the staged pipeline filenames are the contract between workers - the
            // reviser's `final.md` is the user's deliverable.
            let arch = SwarmWorkerSpec(
                role: .architect,
                label: "architect",
                goal: """
                You are the BRIEF WRITER stage of a 4-stage swarm. Your ONLY output is a single file: \(rootDir)/brief.md. Do NOT write any other file. Do NOT attempt to deliver the user's final artifact yet - later stages do that.

                Read the user goal below and produce \(rootDir)/brief.md - a tight, opinionated 1-page brief covering:
                - Target audience (who reads this?)
                - Voice & tone (3-5 specific descriptors + 2 anti-patterns to avoid)
                - Format spec (length, structure, count)
                - Themes / topic surface area (5-8 bullets)
                - 3 example "north-star" reference posts/passages (paraphrased - do not invent fake quotes)

                User goal: \(goal)

                Write brief.md and exit.
                """,
                cwd: rootDir,
                model: codeModel,
                budgetUSD: 0.40
            )
            let writer = SwarmWorkerSpec(
                role: .implementor,
                label: "writer",
                goal: """
                You are the WRITER stage of a 4-stage swarm. Your ONLY output is \(rootDir)/draft.md. Do NOT write final.md or any user-facing filename - the reviser stage produces the final deliverable.

                Read \(rootDir)/brief.md. Produce \(rootDir)/draft.md fully delivering what the brief specifies.
                Original user goal (for context): \(goal)

                Do NOT critique your own work - just deliver the strongest first draft you can. Stay in your lane.
                """,
                cwd: rootDir,
                dependsOn: [arch.id],
                model: codeModel,
                budgetUSD: 2.50
            )
            let critic = SwarmWorkerSpec(
                role: .qa,
                label: "critic",
                goal: """
                You are the CRITIC stage of a 4-stage swarm. Your ONLY output is \(rootDir)/critique.md.

                Read \(rootDir)/brief.md AND \(rootDir)/draft.md. Produce \(rootDir)/critique.md with:
                - 1-line overall verdict (e.g. "B+: voice is sharp but 4 of 15 posts feel generic")
                - Per-item review: rate each item 1-5, name the weakness, propose a specific concrete fix (not vague - say what to change)
                - Top-5 worst items called out with the exact rewrite direction
                - 3 transferable principles the reviser should apply across the whole set

                Be HARSH but useful. The reviser will use this to push quality up. No sycophancy.
                """,
                cwd: rootDir,
                dependsOn: [writer.id],
                model: codeModel,
                budgetUSD: 0.50
            )
            let reviser = SwarmWorkerSpec(
                role: .integrator,
                label: "reviser",
                goal: """
                You are the REVISER stage of a 4-stage swarm - the final stage. Your output \(rootDir)/final.md IS the user's deliverable.

                Read all three: \(rootDir)/brief.md, \(rootDir)/draft.md, \(rootDir)/critique.md.
                Produce \(rootDir)/final.md - a complete, revised deliverable that incorporates every concrete fix the critic proposed and applies the transferable principles to the whole set.
                Same format as the draft. Do NOT just copy the draft - every weak item flagged by the critic MUST be rewritten or replaced. Strong items may stay.

                Original user goal (for context): \(goal)
                """,
                cwd: rootDir,
                dependsOn: [critic.id],
                model: codeModel,
                budgetUSD: 1.80
            )
            return [arch, writer, critic, reviser]

        case .iosAppFull:
            // Real iOS app build pipeline. Architect → 4 parallel feature
            // implementors → integrator → build-loop → qa screenshots.
            //
            // Snapshot at run start per Rule X - conventions doc version captured per-job, not refetched per-worker.
            // The conventions doc is the user's own file, so there is no default
            // path worth guessing. Empty means "not configured" and the block
            // below falls back to common-sense defaults, same as a missing file.
            //   defaults write com.gruxai.grux grux.conventions.path /path/to/conventions.md
            let conventionsPath = (UserDefaults.standard.string(forKey: "grux.conventions.path") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let conventionsBody: String
            if !conventionsPath.isEmpty,
               let txt = try? String(contentsOfFile: conventionsPath, encoding: .utf8) {
                conventionsBody = txt
            } else {
                conventionsBody = """
                <!-- TODO: conventions doc was missing at runtime, apply common-sense iOS polish defaults; report this in build_summary.md as a known_issue. -->
                """
            }
            let conventionsBlock = """


            ## Mobile App Conventions (canonical pre-submission checklist)

            Every rule below is a HARD requirement. The convention-audit gate phase
            in the ship-ios-app Commands V2 workflow will fail your build if any
            numbered rule fails its audit. Reference these rules by number in your
            brief.md and your build_summary.md.

            \(conventionsBody)

            ## END Mobile App Conventions
            """

            let arch = SwarmWorkerSpec(
                role: .architect,
                label: "architect",
                goal: """
                You are the ARCHITECT for an iOS app. Goal: \(goal)

                Your only output is plan.md in \(rootDir) with:
                - Product overview + 1-line elevator pitch
                - Feature breakdown (chat, tasks, voice memos, focus summary, brand) - keep to that fixed feature set so downstream workers know their lanes
                - Bundle prefix + project name suggestion
                - Design system tokens (color hex codes, font sizes, corner radii)
                - File map under <projectName>/Sources/

                Use the Bash tool to call `ios_doctor`-style preflight only via the Grux Bash tool patterns if needed; otherwise just write plan.md and exit.
                """ + conventionsBlock,
                cwd: rootDir,
                model: codeModel,
                budgetUSD: 0.50
            )
            let features: [(String, String)] = [
                ("feature-chat", "Implement the chat feature module per plan.md"),
                ("feature-tasks", "Implement the tasks feature module per plan.md"),
                ("feature-voice", "Implement the voice memos feature module per plan.md"),
                ("feature-focus", "Implement the focus summary feature module per plan.md")
            ]
            let featureWorkers: [SwarmWorkerSpec] = features.map { (label, lane) in
                SwarmWorkerSpec(
                    role: .implementor,
                    label: label,
                    goal: """
                    You are the \(label.uppercased()) implementor. Read plan.md in \(rootDir).
                    Lane: \(lane). Stay in your lane.
                    Goal context: \(goal)
                    """ + conventionsBlock,
                    cwd: rootDir,
                    dependsOn: [arch.id],
                    model: codeModel,
                    budgetUSD: 2.0
                )
            }
            let integrator = SwarmWorkerSpec(
                role: .integrator,
                label: "integrator",
                goal: """
                You are the INTEGRATOR. All feature implementors are done. Wire them into a working SwiftUI app shell with TabView, navigation, and a brand-consistent design system. Use plan.md as the source of truth.
                """ + conventionsBlock,
                cwd: rootDir,
                dependsOn: featureWorkers.map(\.id),
                model: codeModel,
                budgetUSD: 1.0
            )
            let buildLoop = SwarmWorkerSpec(
                role: .buildLoop,
                label: "build-loop",
                goal: """
                You are the BUILD-LOOP. Run xcodebuild for the project in \(rootDir). On any error, fix the file/line and rebuild. Loop until errors=0.
                """ + conventionsBlock,
                cwd: rootDir,
                dependsOn: [integrator.id],
                model: codeModel,
                budgetUSD: 1.0
            )
            let qa = SwarmWorkerSpec(
                role: .qa,
                label: "qa",
                goal: """
                You are QA. Boot an iPhone simulator, install the app, screenshot every screen. Use Bash with simctl. Save screenshots to \(rootDir)/screenshots/.
                """ + conventionsBlock,
                cwd: rootDir,
                dependsOn: [buildLoop.id],
                model: codeModel,
                budgetUSD: 0.50
            )
            return [arch] + featureWorkers + [integrator, buildLoop, qa]
        }
    }
}
