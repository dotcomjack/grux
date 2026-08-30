import Foundation
import SwiftUI

/// First run. Three gates, then out of the way forever.
///
/// Grux shipped with no onboarding at all. A new user landed on Home, was
/// greeted by the previous owner's name, and the entire new-user experience was
/// one status bar line reading "Add Anthropic API key in Settings". Everything
/// else, 9 credentials and 8 macOS permissions, was discoverable only by
/// hunting through Settings.
///
/// ## Why three gates and not seventeen
///
/// 15 rows of the feature registry name `key.anthropic` in some slot, so there
/// is exactly one thing worth blocking on. Everything else is deferred to the
/// point of use: Calendar permission when Calendar is opened, Screen Recording
/// when the focus loop is switched on. Front-loading 17 prompts produces an
/// abandoned wizard, and a permission prompt is a withdrawal from a trust
/// account that has not been paid into yet. Ask after delivering something, not
/// before.
///
/// **The one thing worth blocking on is A MODEL, not that key.** This paragraph
/// used to say the key and `ModelKeyStep` enforced it literally, which made the
/// local path the README leads with impossible to take on a first run: no key
/// meant no way past screen three, for a user whose Grux already worked. The
/// gate now accepts either a pasted key or a reachable local model, and the
/// registry agrees with it, since CR-32 turned chat's `requires` into
/// `1 of {key.anthropic, endpoint.ollama}`. Two ways to satisfy one gate, which
/// is still one gate.
///
/// The one exception is the third gate, and it earns the exception by GIVING
/// rather than asking: it shows the user one real frame and the exact redacted
/// text Grux would send, before anything leaves the machine. That is
/// `step.first_frame_reviewed` in the contract, and it is simultaneously the
/// product demo and the privacy proof.
///
/// ## Why this is skippable and Settings is not
///
/// Onboarding is a convenience over the feature state machine, never a
/// replacement for it. Every gate here is also reachable from Settings, and a
/// feature whose capability is missing renders `needs-setup` with the same
/// `remediation` string either way. A user who quits halfway through, or who
/// declines Screen Recording, gets a working Grux with one feature in
/// `needs-setup`. They never get a dead end, because the contract forbids one:
/// a missing capability must never surface as an error.
@MainActor
final class OnboardingModel: ObservableObject {

    static let shared = OnboardingModel()

    /// How much of the flow the user asked for, chosen on the first screen.
    ///
    /// Called LEVELS, not tiers, and the collision is the reason. Grux already
    /// has an autonomy ladder called TIER 0 / TIER 1 / TIER 2, and one of the
    /// screens inside this flow explains it. Two different ladders both called
    /// "tier", one nested inside the other, is a naming choice that would have
    /// cost somebody a genuinely confused ten minutes.
    ///
    /// `rawValue` is persisted. Renaming a case orphans an in-flight user.
    enum Level: String, Codable, CaseIterable, Identifiable {
        /// The model key, a name, and how Grux works. Enough to have a Grux.
        case essentials
        /// Plus the macOS permissions, each asked with its reason first.
        case plusPermissions
        /// Plus the accounts: chat, notes, code, and an inbox last.
        case everything

        var id: String { rawValue }

        var title: String {
            switch self {
            case .essentials:      return "Level 1"
            case .plusPermissions: return "Levels 1 and 2"
            case .everything:      return "Levels 1, 2 and 3"
            }
        }

        var summary: String {
            switch self {
            case .essentials:
                return "A model key, your name, and a short explanation of how Grux works."
            case .plusPermissions:
                return "That, plus the macOS permissions. Each one says what it is for before macOS asks."
            case .everything:
                return "That, plus your accounts. Chat, notes, code, and an inbox last."
            }
        }

        /// Deliberately concrete. "About a minute" is a claim somebody can check
        /// against their own experience, where "quick" is not.
        var estimate: String {
            switch self {
            case .essentials:      return "About a minute"
            case .plusPermissions: return "Two to three minutes"
            case .everything:      return "Five minutes or so"
            }
        }

        var includesPermissions: Bool { self != .essentials }
        var includesConnections: Bool { self == .everything }
    }

    /// Ordered. `rawValue` is persisted, so these strings are a storage format:
    /// renaming a case orphans an in-flight user at the step they quit on.
    enum Stage: String, Codable, CaseIterable {
        case level
        case modelKey
        case identity
        case howItWorks
        case permissions
        case firstLook
        case clone
        case connections
        case update
        case done
        // OUTSIDE THE LINEAR FLOW, and appended so no existing rawValue moves.
        //
        // The one honest answer to "a model key exists but onboarding.json does
        // not". That used to resolve straight to `.done`, which is a guess
        // wearing the costume of a fact: onboarding WRITES the key at step 3 of
        // 10, so from the model-key screen onward everybody satisfies the
        // "already set up" test. A reinstall keeps Keychain items and loses
        // Application Support, so the common case for this branch is not a
        // veteran at all, it is somebody who never finished.
        case welcomeBack
    }

    /// The stages a given level actually runs, in order.
    ///
    /// A pure function of the level, which is what makes "level selection works"
    /// something a test can assert rather than something a screenshot suggests.
    /// Everything else about the flow reads from this, so a stage cannot be
    /// reachable at a level that did not ask for it.
    static func stages(for level: Level) -> [Stage] {
        // IDENTITY FIRST, immediately after choosing a level.
        //
        // It used to sit third, behind the model key, so the first thing a new
        // user was asked for was an API key and the app did not learn their name
        // until two screens later. Asking who someone is before asking them to
        // paste a credential is both friendlier and cheaper: the name is free,
        // instant, skippable, and it makes every screen after it address them by
        // name instead of nobody.
        var out: [Stage] = [.level, .identity, .modelKey, .howItWorks]
        if level.includesPermissions {
            // Permissions before the first look, because the first look NEEDS
            // Screen Recording. Reversing these two would show a frame review
            // that cannot capture a frame.
            out.append(.permissions)
            out.append(.firstLook)
            // The clone sits WITH the permission block, and that is a placement
            // on principle rather than convenience. It learns the user's voice
            // from their own iMessages and Apple Notes, which are exactly the
            // two things Full Disk Access and Automation unlock, so it cannot
            // run before them. At a level that asks for no permissions at all it
            // would have nothing to read, and offering a step that can only say
            // "nothing available" is worse than not offering it.
            out.append(.clone)
        }
        // The inbox lives at the end of connections, so this is the last ASK by
        // construction: "offer an inbox as the last skippable step".
        if level.includesConnections { out.append(.connections) }
        // The update phase runs at EVERY level, and after everything else.
        //
        // It asks for nothing, which is why it can sit past the last skippable
        // step without contradicting that promise: it reports what Grux found on
        // this machine rather than requesting anything. Every level gets it
        // because "which models can this Mac actually run" is exactly as true
        // for somebody who chose the one minute path, and arguably matters more
        // to them, since they skipped the screens where it might have come up.
        out.append(.update)
        out.append(.done)
        return out
    }

    struct State: Codable {
        var stage: Stage
        /// Set when the user declined Screen Recording or skipped the first
        /// look. Recorded rather than inferred, so Settings can offer it again
        /// without re-running the whole flow.
        var skippedFirstLook: Bool
        var level: Level
        /// Capability ids the user was OFFERED during onboarding and passed on.
        ///
        /// The distinction this records is the whole of "every skipped step
        /// re-offers in context". A capability that is merely absent has never
        /// been discussed, and the setup card introduces it. A capability the
        /// user already said no to once is a different conversation, and a
        /// surface that cannot tell them apart either nags somebody who declined
        /// or silently drops something they meant to come back to.
        var skipped: Set<String>

        /// NO DEFAULT ARGUMENTS, deliberately, and this is a fix rather than a
        /// style. The previous version defaulted every field but `stage`, which
        /// let `persist()` be written as `State(stage: stage)` and silently
        /// reset `skippedFirstLook` to false on every transition after a skip.
        /// The call site read as complete; the loss was in what it did not
        /// mention. Requiring all four means the compiler catches the next
        /// person who adds a field and forgets a writer, which no test can do as
        /// early.
        init(stage: Stage, skippedFirstLook: Bool, level: Level, skipped: Set<String>) {
            self.stage = stage
            self.skippedFirstLook = skippedFirstLook
            self.level = level
            self.skipped = skipped
        }

        /// A brand new install, before anything has been chosen.
        static let initial = State(stage: .level,
                                   skippedFirstLook: false,
                                   level: .plusPermissions,
                                   skipped: [])

        enum CodingKeys: String, CodingKey { case stage, skippedFirstLook, level, skipped }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stage = try c.decodeIfPresent(Stage.self, forKey: .stage) ?? .level
            skippedFirstLook = try c.decodeIfPresent(Bool.self, forKey: .skippedFirstLook) ?? false
            // An install written before levels existed ran what is now Levels 1
            // and 2, so that is what it decodes to. Defaulting to `essentials`
            // would silently tell such a user they had declined permissions they
            // were never offered a choice about.
            level = try c.decodeIfPresent(Level.self, forKey: .level) ?? .plusPermissions
            skipped = try c.decodeIfPresent(Set<String>.self, forKey: .skipped) ?? []
        }
    }

    @Published private(set) var stage: Stage = .done
    @Published private(set) var level: Level = .plusPermissions
    @Published private(set) var skipped: Set<String> = []

    /// Mirrors `State.skippedFirstLook` so callers outside this file can read it
    /// without decoding the persisted JSON. CapabilityResolver needs it to answer
    /// `step.first_frame_reviewed`: reaching `done` by SKIPPING the first look is
    /// not the same as completing it, and treating the two alike would report a
    /// setup step satisfied that the user deliberately declined.
    @Published private(set) var skippedFirstLook: Bool = false

    /// Non-nil while the key the user pasted has been rejected. Held here
    /// rather than in the view so quitting and reopening does not resurrect a
    /// stale error next to a key that has since been fixed.
    @Published var keyError: String?

    /// True while a pasted key is being checked against the provider.
    @Published var validating = false

    private static var stateURL: URL {
        Persistence.supportDir.appendingPathComponent("onboarding.json")
    }

    private init() {
        // An existing install has no onboarding file, and must not be dragged
        // through a flow it predates. The honest test for "has this person
        // already set Grux up" is whether they already have a working model
        // key, not a flag we only started writing today. That makes the
        // migration free and unfakeable: nobody with a key sees this.
        if FileManager.default.fileExists(atPath: Self.stateURL.path) {
            let loaded = Persistence.load(State.self, from: Self.stateURL, fallback: State.initial)
            stage = loaded.stage
            skippedFirstLook = loaded.skippedFirstLook
            level = loaded.level
            skipped = loaded.skipped
        } else if KeychainStore.exists(.anthropicApiKey) {
            // ASK, DO NOT ASSUME. Resolving this to `.done` did not merely drop
            // somebody in the shell: `.done` with `skippedFirstLook == false` at
            // a level that includes `.firstLook` makes
            // `CapabilityResolver.firstFrameWasReviewed` return true, so Grux
            // recorded that a capture frame had been reviewed and consented to
            // by a person who was never shown one. A guess is not consent.
            stage = .welcomeBack
            persist()
        } else {
            stage = .level
            persist()
        }
    }

    /// Whether the first-run flow should be on screen at all.
    ///
    /// Split out as a pure static for the same reason `stage(after:)` is: this
    /// is the whole of resume. `LaunchRootView` replaces the entire shell when
    /// it is true, so an interrupted run reappears where it stopped, and a test
    /// that had to build a model to check it could not cover the stages the
    /// public transitions cannot reach.
    static func presents(_ stage: Stage) -> Bool { stage != .done }

    var isPresenting: Bool { Self.presents(stage) }

    // MARK: - Transitions

    /// The stage list this user's chosen level actually runs.
    var stages: [Stage] { Self.stages(for: level) }

    /// Choose a level and start. Recorded before anything else so that quitting
    /// on the second screen resumes into the flow that was chosen.
    func chooseLevel(_ chosen: Level) {
        level = chosen
        advance(from: .level)
    }

    /// What comes after `current` at `level`, or nil when the flow is over.
    ///
    /// Pure, and separated from `advance` for one reason: `advance` mutates the
    /// singleton and therefore PERSISTS, and the persisted file is the owner's
    /// own `onboarding.json`. A test that drove the real transitions to prove
    /// "level selection works" would be rewriting somebody's install state as a
    /// side effect of asserting. So the decision lives here, where it can be
    /// checked for free, and `advance` is the thin part that applies it.
    static func stage(after current: Stage, at level: Level) -> Stage? {
        let flow = stages(for: level)
        guard let i = flow.firstIndex(of: current), i + 1 < flow.count else { return nil }
        return flow[i + 1]
    }

    /// What Level 3 offers, in order, inbox LAST.
    ///
    /// A static rather than a private constant inside the view, so that "the
    /// inbox is the last skippable step" is a property a test can assert instead
    /// of a claim in a comment above an array.
    ///
    /// Not every entry is an account. `step.youtube_transcripts_enabled` asks for
    /// no credential at all, because the thing it gates is a public fetch: the
    /// only thing missing is the user's decision, so the row is a switch rather
    /// than a paste field. It sits before the endpoints deliberately. The reason
    /// the inbox is last is that it costs minutes on somebody else's website, and
    /// by the same measure a switch costs one second and belongs early.
    ///
    /// GitHub is deliberately NOT here, and this overrides a settled decision on
    /// evidence that was not available when it was made.
    ///
    /// Decision 10 lists GitHub among what onboarding should ask for. Measured
    /// afterwards: the codebase contains no GitHub API usage at all. Nothing
    /// calls api.github.com, nothing reads the `gitHubToken` Keychain slot
    /// outside the resolver that defines it, and nothing reads
    /// `grux.github.repos`. The PR digest, which looked like the consumer, pulls
    /// `/api/digest/latest` from a configured host and never touches GitHub. So
    /// `key.github` and `endpoint.repo_list` are vestigial contract entries.
    ///
    /// Asking a stranger to paste a GitHub personal access token that nothing
    /// will ever read is not a harmless extra step. The copy for it claimed
    /// Grux would "read your repositories and watch pull requests", which was
    /// simply untrue, and a powerful token sitting unused in a Keychain is risk
    /// with no benefit on the other side of it.
    ///
    /// Reversible the moment a GitHub feature ships: put it back here and give
    /// it a registry row. The contract entries are left alone, since deleting
    /// from a frozen shared contract is a separate deliberate act.
    static let connectionOrder: [SetupRequirement] = [
        .keySlack, .keyNotion, .stepYoutubeTranscriptsEnabled, .endpointOllama, .endpointImap
    ]

    /// What a connection is FOR, written for a screen that already has the paste
    /// field on it.
    ///
    /// Not the contract remediation, and the difference is not pedantry. Every
    /// remediation is written for the setup card and therefore tells the reader
    /// to go to Settings: `key.slack` reads "Connect Slack in Settings so Grux
    /// can read and post in your workspace". Rendered on the connections screen,
    /// above a box that takes the token, it sends somebody to another screen to
    /// do the thing they are already looking at.
    ///
    /// `ModelKeyStep` had worked this out first and says so in a comment, which
    /// makes this a mistake the codebase had already documented before it was
    /// repeated here. It was caught by rendering the screen and reading it, not
    /// by any test that existed at the time.
    ///
    /// These cannot drift from the contract because they are not saying the same
    /// thing. The contract says how to fix a missing capability and remains the
    /// only source for the setup card; these say what the thing does.
    static func connectionPurpose(for req: SetupRequirement) -> String {
        switch req {
        case .keySlack:  return "Lets Grux read and post in your workspace."
        case .keyNotion: return "Lets Grux read and write the Notion database you choose."
        // Everything else keeps the contract's own first sentence. An endpoint
        // has no inline field, so the connections screen prints the instruction
        // half beside it and the instruction is genuinely what to do. A step's
        // switch IS the control, so the reason is all that belongs on the row
        // and the "in Settings" half stays with the setup card it was written
        // for.
        default:         return req.rationale
        }
    }

    /// Move to whatever comes after `current` AT THIS LEVEL.
    ///
    /// Every transition goes through here rather than naming its successor.
    /// Hard-coded successors are what made the old flow impossible to vary:
    /// `completeIdentity` said `stage = .firstLook`, so adding a screen meant
    /// editing the screen before it, and any level that skipped a stage would
    /// have had to be threaded through by hand at every call site. Here a level
    /// that does not include a stage simply never lands on it.
    func advance(from current: Stage) {
        guard let next = Self.stage(after: current, at: level) else {
            finish(skippedFirstLook: skippedFirstLook)
            return
        }
        stage = next
        persist()
    }

    /// Advance past the model key. Separate because this is the one gate with a
    /// network dependency and therefore the one that can fail in a way the user
    /// has to see.
    func completeModelKey() {
        keyError = nil
        advance(from: .modelKey)
    }

    func completeIdentity() { advance(from: .identity) }

    /// Record that the user was offered something and passed on it.
    ///
    /// Takes the capability's own id, so the re-offer surface and the registry
    /// are talking about the same thing rather than two parallel vocabularies.
    func markSkipped(_ requirement: SetupRequirement) {
        skipped.insert(requirement.rawValue)
        persist()
    }

    /// Clear the record once it is satisfied, so a capability that was skipped
    /// and later added does not keep apologising for itself forever.
    func clearSkip(_ requirement: SetupRequirement) {
        guard skipped.contains(requirement.rawValue) else { return }
        skipped.remove(requirement.rawValue)
        persist()
    }

    /// Whether this was offered during onboarding and declined.
    func wasSkipped(_ requirement: SetupRequirement) -> Bool {
        skipped.contains(requirement.rawValue)
    }

    /// The first look was declined. Separate from finishing, because at Level 3
    /// the flow continues to connections afterwards.
    func recordFirstLookSkipped() {
        skippedFirstLook = true
        skipped.insert(SetupRequirement.stepFirstFrameReviewed.rawValue)
        persist()
    }

    func recordFirstLookReviewed() {
        skippedFirstLook = false
        skipped.remove(SetupRequirement.stepFirstFrameReviewed.rawValue)
        persist()
    }

    /// Finish, whether the user reviewed the first frame or declined it.
    /// Declining is a legitimate answer, not a failure: the focus loop simply
    /// stays in `needs-setup` and says why.
    func finish(skippedFirstLook: Bool) {
        stage = .done
        self.skippedFirstLook = skippedFirstLook
        persist()
    }

    /// "I am already set up": leave the flow without walking it.
    ///
    /// `skippedFirstLook: true` is the load-bearing argument and it is the
    /// opposite of what the old silent `.done` recorded. Somebody arriving here
    /// has NOT been shown a captured frame in this install, so claiming they
    /// reviewed one would re-tell exactly the lie this stage exists to stop.
    /// Recording the skip honestly costs them nothing: the focus surface renders
    /// needs-setup and points at the control that walks the flow properly.
    func keepExistingSetup() {
        finish(skippedFirstLook: true)
    }

    /// Settings can put a user back at the start. Without this the one-time
    /// flow is a trap: someone who clicked through it can never see it again,
    /// which is the same defect `RecordingConsent.reset()` exists to avoid.
    ///
    /// Skips are deliberately cleared. Re-running the flow is somebody asking to
    /// be offered these things again, so carrying "you already declined this"
    /// into a run they explicitly started would be answering a question they did
    /// not ask.
    func reset() {
        stage = .level
        keyError = nil
        skipped = []
        persist()
    }

    /// One writer, and it writes EVERY field.
    ///
    /// It used to build `State(stage: stage)` and let the other fields take their
    /// defaults, which silently reset `skippedFirstLook` to false on any
    /// transition after a skip. That is the shape of bug that survives review
    /// because the call site looks complete: the loss is in what the line does
    /// not mention.
    private func persist() {
        Persistence.save(
            State(stage: stage,
                  skippedFirstLook: skippedFirstLook,
                  level: level,
                  skipped: skipped),
            to: Self.stateURL)
    }

    // MARK: - Key validation

    /// Check a pasted key by making the smallest real call to the provider.
    ///
    /// Three outcomes, and the third is the one that gets forgotten. A rejected
    /// key must say so and keep the user here. A network failure must NOT:
    /// being offline on first launch is not the same as having a bad key, and
    /// refusing to proceed would strand someone on a plane behind a check that
    /// is only advisory. So an unreachable provider accepts the key and moves
    /// on, and the real verdict arrives the first time they actually use it.
    /// What a status code means for a pasted key.
    ///
    /// Pure and separate, because the interesting cases are the ones a live
    /// network call cannot be made to produce on demand: nobody can arrange a
    /// 400 from a workspace-scoped key inside a test.
    enum KeyVerdict: Equatable {
        case accept
        case reject(String)
    }

    /// THE 400 IS THE FIX. It used to fall into the catch-all and be waved past
    /// as "provider trouble is not the user's problem", so a key the API had
    /// just refused got saved, the gate reported success, and setup carried on.
    /// The owner finished onboarding believing they were done and found out at the first
    /// message he sent, which is the worst place to learn it: the screen whose
    /// whole job is checking the key had already said the key was fine.
    ///
    /// The request is known good, since `validate` builds it, so a 400 here is a
    /// statement about the CREDENTIAL and belongs in front of the person holding
    /// it. Everything genuinely on the provider's side still passes: a 500 is
    /// not something a user can act on, and refusing their key over it would be
    /// blaming them for an outage.
    nonisolated static func verdict(status: Int, body: Data) -> KeyVerdict {
        switch status {
        case 200..<300:
            return .accept
        case 400:
            return .reject(keyProblem(from: body))
        case 401, 403:
            return .reject("That key was rejected. Check you copied all of it.")
        case 429:
            // The key is valid; the account is rate limited. Rejecting it here
            // would be wrong and would read as "your key is bad".
            return .accept
        default:
            return .accept
        }
    }

    /// Turn the provider's 400 into something the reader can act on.
    ///
    /// The API's own sentence is included because it is often the most precise
    /// thing anybody can say, but it is never the whole message: "send the id of
    /// the workspace this request acts in" is an instruction to a program, not to
    /// a person holding a key they just pasted. The known cases get a human
    /// sentence in front of it.
    nonisolated static func keyProblem(from body: Data) -> String {
        let detail = apiErrorMessage(from: body)
        if detail.contains("anthropic-workspace-id") {
            return "That key belongs to a workspace, so it only works when the app "
                + "names the workspace on every call, and Grux does not. Create a "
                + "standard API key at console.anthropic.com and paste that one. "
                + "You can also skip this and run Grux on a local model instead."
        }
        if detail.isEmpty {
            return "The provider refused that key and did not say why. Check you "
                + "copied all of it, or skip this and run Grux on a local model."
        }
        return "The provider refused that key: \(detail)"
    }

    /// The `error.message` an Anthropic error body carries, or empty.
    nonisolated static func apiErrorMessage(from body: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return "" }
        return message
    }

    func validate(key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyError = "Paste a key to continue."
            return false
        }
        validating = true
        defer { validating = false }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // One token, cheapest model. This is a reachability and credential
        // check, not a generation.
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch Self.verdict(status: code, body: data) {
            case .accept:
                keyError = nil
                return true
            case .reject(let why):
                keyError = why
                return false
            }
        } catch {
            // Offline, DNS failure, captive portal. Advisory check, so proceed.
            keyError = nil
            return true
        }
    }
}
