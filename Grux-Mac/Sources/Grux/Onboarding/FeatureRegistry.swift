import Foundation

/// Which capabilities each feature needs, transcribed from the frozen
/// `docs/feature-registry.md`.
///
/// Generated from that file rather than typed, for the reason phase B
/// demonstrated: a hand copy drifts, and drift can sit for months behind a doc
/// comment asserting it cannot. `FeatureRegistryContractTests` re-parses the
/// registry and compares it row by row, so this file cannot quietly disagree
/// with the document it claims to transcribe.
///
/// The contract splits requirements four ways. `requires` and `steps` BLOCK: a
/// feature missing either is `needs-setup`. `optional` and `optionalSteps`
/// DEGRADE: the feature works, on a lesser path.
///
/// A fifth relation, `anyOf`, says how few of the blocking capabilities are
/// actually enough. See `CapabilityGroup`.
struct FeatureRow: Equatable {
    enum Tier: String, Equatable { case core, labs }

    let id: String
    let label: String
    let tier: Tier
    /// Every blocking capability NAMED in the registry's `requires` cell.
    ///
    /// A flat AND unless an `anyOf` group below covers some of these ids, in
    /// which case the group decides how many of its members have to resolve.
    let requires: [SetupRequirement]
    /// Non-blocking capabilities. Missing any means degraded.
    let optional: [SetupRequirement]
    /// Blocking setup steps.
    let steps: [SetupRequirement]
    /// Non-blocking setup steps.
    let optionalSteps: [SetupRequirement]
    /// Either-or relations over ids that ALSO appear in `requires`.
    ///
    /// THE DOUBLE LISTING IS DELIBERATE AND IT IS NOT A SECOND SOURCE OF TRUTH.
    /// The registry writes a group as `min of {id, id}` inside the same cell as
    /// the flat list, which contract section 6 chose so the ids stay scannable
    /// by the reconciler without widening every table. So the ids are in the
    /// `requires` cell, and `FeatureRegistryContractTests` compares this array
    /// against exactly those ids. `anyOf` carries the one thing the cell's id
    /// list cannot: how they combine. Transcribing the ids anywhere else would
    /// put them somewhere the row-by-row contract test cannot see, which is the
    /// drift that test exists to catch.
    let anyOf: [CapabilityGroup]

    /// Features that must be ON for this one to do anything, by feature id.
    ///
    /// ADDED BY CR-35, 2026-08-28, and it exists because the relation is NOT derivable
    /// from capabilities. `speakers` declares no requirement at all: it names the voices in
    /// a meeting, so with Meetings off it is a working screen with nothing to show, and
    /// every capability-based check calls it ready. A person who picks Speakers and not
    /// Meetings has produced a selection that cannot do what they asked for, and nothing in
    /// the four capability lists can notice.
    ///
    /// Deliberately NOT a new column in the section 5 table. Contract section 6 already
    /// chose to keep that table narrow, which is why `anyOf` is encoded inside the requires
    /// cell rather than widening all thirty nine rows. These are FEATURE ids, not capability
    /// ids, so they cannot share a capability cell at all and get their own small table in
    /// section 5.6 instead.
    ///
    /// Empty for every row but one today. The default keeps the other thirty eight
    /// declarations untouched, which is the same reason `anyOf` has one.
    let dependsOn: [String]

    /// Everything the registry declares as blocking, before any group is
    /// applied. Ask `FeatureRegistry.unmetBlocking(of:)` for what is actually
    /// missing, because that one honours the groups.
    var blocking: [SetupRequirement] { requires + steps }

    init(id: String,
         label: String,
         tier: Tier,
         requires: [SetupRequirement],
         optional: [SetupRequirement],
         steps: [SetupRequirement],
         optionalSteps: [SetupRequirement],
         anyOf: [CapabilityGroup] = [],
         dependsOn: [String] = []) {
        self.id = id
        self.label = label
        self.tier = tier
        self.requires = requires
        self.optional = optional
        self.steps = steps
        self.optionalSteps = optionalSteps
        self.anyOf = anyOf
        self.dependsOn = dependsOn
    }
}

/// An either-or relation over blocking capabilities: `min` of these resolving
/// is enough, and the rest are excused.
///
/// THE DEFECT THIS CLOSES. `requires` is a flat AND and `CapabilityResolver
/// .missing(from:)` filters a flat list, so a feature that two different
/// credentials can each satisfy on their own had to over-declare one of them.
/// Chat did: it required `key.anthropic` outright while `ChatReadiness.evaluate`
/// has treated a routed local model as `.ready` since the day it was written.
/// The result was that somebody running Ollama with no account anywhere, which
/// is the setup the README leads with, got a permanent needs-setup dot on the
/// default landing tab and a setup card telling them to buy a key they did not
/// need. The feature worked the whole time.
///
/// Deleting the id from `requires` instead would have been a different bug and a
/// quieter one: `min` of zero declares nothing, so a user with NEITHER a key nor
/// a local model would have been told chat was ready and met the failure at
/// their first send, which contract section 3 calls a defect outright. The
/// signal has to survive, it just has to be an OR rather than an AND. Hence
/// `1 <= min < capabilities.count`, which contract section 6 states as a
/// constraint and `scripts/check-contract.py` rule 8 enforces on the document.
struct CapabilityGroup: Equatable {
    let capabilities: [SetupRequirement]
    /// How many of `capabilities` must resolve. Never zero, never all of them.
    let min: Int
}

@MainActor
enum FeatureRegistry {

    /// Sidebar tab key to feature id, for the eight that differ. Every other id
    /// equals its sidebar key. Transcribed from feature-registry.md section 2.2.
    static let tabAliases: [String: String] = [
        "cognitionMap": "cognition.map",
        "designStudio": "design.studio",
        "featureReview": "feature.review",
        "jaxCommand": "jax.command",
        "jaxHQ": "jax.hq",
        "metaAds": "meta.ads",
        "selfUpgrade": "self.upgrade",
        "terminalFocus": "terminal.focus",
    ]

    static let rows: [FeatureRow] = [
        FeatureRow(id: "home", label: "Home", tier: .core,
                   requires: [],
                   optional: [.permCalendar, .keyAnthropic, .keyElevenlabs],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "reactor", label: "Reactor", tier: .labs,
                   requires: [],
                   optional: [.permMicrophone, .permCalendar, .keyElevenlabs, .endpointImap],
                   steps: [],
                   optionalSteps: []),
        // CR-32 turned the flat `key.anthropic` into a group and moved
        // `endpoint.ollama` out of `optional` to join it. Chat has two ways to
        // reach a model and only ever declared one, so the free path the project
        // leads with rendered as an unfinished setup forever. The id could not
        // stay in both cells: `optional` means absence merely degrades, and
        // absence of BOTH halves of this group leaves chat with nothing to talk
        // to at all.
        FeatureRow(id: "chat", label: "Chat", tier: .core,
                   requires: [.keyAnthropic, .endpointOllama],
                   // CR-31 removed .keyOpenai and .keyOpenrouter. Chat never read
                   // either Keychain slot and there is no api.openai.com call in
                   // the tree at all. OpenRouter is reachable, but through the
                   // generic CustomEndpointStore, which holds its own per-endpoint
                   // key, so the dedicated slot was a second place to type a
                   // credential that nothing would ever load.
                   optional: [.keySlack, .keyNotion, .keyResend, .keyBrave, .permMicrophone, .keyElevenlabs, .permScreenRecording, .permAccessibility, .permAutomation, .permCalendar, .permContacts, .endpointImap, .keyReplicate, .endpointMediaService],
                   steps: [],
                   optionalSteps: [.stepAgentCliInstalled, .stepYoutubeTranscriptsEnabled, .stepTerminalSessionsExplained],
                   anyOf: [CapabilityGroup(capabilities: [.keyAnthropic, .endpointOllama], min: 1)]),
        FeatureRow(id: "jax.command", label: "Jax Command", tier: .labs,
                   requires: [],
                   optional: [.keyAnthropic, .permFullDiskAccess],
                   steps: [.stepAgentCliInstalled, .stepCorpusSourcesConfirmed, .stepTerminalSessionsExplained],
                   optionalSteps: []),
        FeatureRow(id: "approvals", label: "Approvals", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "cognition.map", label: "Cognition Map", tier: .core,
                   requires: [],
                   optional: [.keyAnthropic],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "feature.review", label: "Feature Review", tier: .labs,
                   requires: [],
                   optional: [.keyAnthropic],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "projects", label: "Projects", tier: .core,
                   requires: [],
                   optional: [.endpointRegistry],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "tasks", label: "Task Stack", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "agents", label: "Agents", tier: .labs,
                   requires: [],
                   optional: [],
                   steps: [.stepAgentCliInstalled, .stepTerminalSessionsExplained],
                   optionalSteps: []),
        FeatureRow(id: "mailbox", label: "Mailbox", tier: .core,
                   requires: [.endpointImap],
                   optional: [.endpointMicrosoftGraph],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "mailbox.compose", label: "Compose and send", tier: .labs,
                   requires: [.keyResend, .endpointImap],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "calendar", label: "Calendar", tier: .core,
                   requires: [.permCalendar],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "notes", label: "Notes", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "documents", label: "Documents", tier: .core,
                   requires: [],
                   optional: [.keyAnthropic],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "contacts", label: "Contacts", tier: .core,
                   requires: [.permContacts],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "schedules", label: "Schedules", tier: .core,
                   requires: [],
                   optional: [.permNotifications],
                   steps: [],
                   optionalSteps: [.stepAgentCliInstalled, .stepTerminalSessionsExplained]),
        FeatureRow(id: "folders", label: "Folders", tier: .core,
                   requires: [],
                   optional: [.keyAnthropic, .endpointOllama],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "research", label: "Research", tier: .core,
                   requires: [.keyBrave, .keyAnthropic],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "skills", label: "Skills", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "compare", label: "Compare", tier: .core,
                   requires: [.keyAnthropic, .endpointOllama],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "cookbook", label: "Local Models", tier: .core,
                   requires: [],
                   optional: [.endpointOllama],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "creative", label: "Media Studio", tier: .labs,
                   requires: [.keyReplicate],
                   optional: [.endpointMediaService, .endpointRegistry],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "design.studio", label: "Design Studio", tier: .core,
                   requires: [.keyAnthropic],
                   optional: [.endpointOllama, .endpointRegistry],
                   steps: [],
                   optionalSteps: [.stepAgentCliInstalled, .stepTerminalSessionsExplained]),
        FeatureRow(id: "meetings", label: "Meetings", tier: .core,
                   requires: [.permMicrophone, .permSystemAudio],
                   optional: [.keyAnthropic],
                   steps: [.stepRecordingConsentAcknowledged, .stepSpeechModelDownloaded],
                   optionalSteps: []),
        FeatureRow(id: "speakers", label: "Speakers", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: [],
                   dependsOn: ["meetings"]),
        FeatureRow(id: "commands", label: "Commands", tier: .core,
                   requires: [],
                   optional: [.permAutomation, .keyAnthropic],
                   steps: [],
                   optionalSteps: []),
        // CR-31 added this row. `social` is a real tab wired to SocialView and
        // capabilityGated("social"), and it had no registry row at all, so the
        // gate no-opped and the beta badge could not find it. Telegram is the one
        // credential the surface genuinely reads (SocialOpsCoordinator), and it is
        // optional because the tab renders without it.
        FeatureRow(id: "social", label: "Social", tier: .labs,
                   requires: [],
                   optional: [.keyTelegram],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "workflows", label: "Workflows", tier: .labs,
                   requires: [],
                   // CR-31 removed .keyAppstoreconnect. App Store Connect IS used,
                   // by ASCStateMonitor, but it mints its ES256 JWT from a keyId,
                   // issuerId and .p8 path in a ship-config file. Nothing reads the
                   // Keychain slot this capability names, so the Settings field for
                   // it accepted a credential that went nowhere.
                   optional: [.permNotifications],
                   steps: [],
                   optionalSteps: [.stepAgentCliInstalled, .stepTerminalSessionsExplained]),
        FeatureRow(id: "focus", label: "Focus log", tier: .core,
                   requires: [.permScreenRecording, .keyAnthropic],
                   optional: [.permAccessibility, .permNotifications],
                   steps: [.stepFirstFrameReviewed, .stepCaptureExclusionsConfirmed],
                   optionalSteps: []),
        FeatureRow(id: "terminal.focus", label: "Terminal Focus", tier: .labs,
                   requires: [.permScreenRecording],
                   optional: [.permAutomation],
                   steps: [.stepTerminalFocusHookInstalled],
                   optionalSteps: []),
        FeatureRow(id: "self.upgrade", label: "Self-Upgrade", tier: .labs,
                   requires: [],
                   optional: [],
                   steps: [.stepAgentCliInstalled, .stepTerminalSessionsExplained],
                   optionalSteps: []),
        FeatureRow(id: "integrations", label: "Integrations", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "integrations.webhooks", label: "Outbound Webhooks", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "jax.hq", label: "Jax HQ", tier: .labs,
                   requires: [.endpointImap],
                   optional: [.keyAnthropic, .keyResend],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "meta.ads", label: "Meta Ads", tier: .labs,
                   requires: [],
                   optional: [.keyAnthropic, .keyTelegram],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "domains", label: "Domain monitor", tier: .labs,
                   requires: [.keyGodaddy],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
        FeatureRow(id: "phone", label: "Phone companion", tier: .labs,
                   requires: [],
                   optional: [.keyElevenlabs],
                   steps: [.stepPhonePaired],
                   optionalSteps: []),
        FeatureRow(id: "settings", label: "Settings", tier: .core,
                   requires: [],
                   optional: [],
                   steps: [],
                   optionalSteps: []),
    ]

    static func row(id: String) -> FeatureRow? {
        rows.first { $0.id == id }
    }

    /// Looks a feature up by SIDEBAR key, applying the alias map.
    static func row(forTab tabKey: String) -> FeatureRow? {
        row(id: tabAliases[tabKey] ?? tabKey)
    }

    /// What a row is actually missing, as a pure function of one predicate.
    ///
    /// PURE ON PURPOSE, and for the reason `ChatReadiness.evaluate` and
    /// `CapabilityResolver.keyIsSatisfied` were both split out before it: the
    /// live resolver reads the real Keychain and the discovered backend, so on
    /// any machine that already has credentials, which includes every machine
    /// this is developed on, a test of the group rule can only ever observe the
    /// answer that machine happens to give. Handed a predicate, the rule itself
    /// is checkable for free and in every combination, including the ones the
    /// developer's own Mac can never be in.
    ///
    /// A satisfied group EXCUSES every one of its members, including the ones
    /// that did not resolve, because that is what "any 1 of these" means. A
    /// short group reports only its unsatisfied members, so the setup card names
    /// the things the user could actually do next rather than the whole group.
    /// Order follows `blocking`, which is contract order, so a card reads the
    /// same way every time.
    static func unmetBlocking(of row: FeatureRow,
                              satisfied: (SetupRequirement) -> Bool) -> [SetupRequirement] {
        var excused = Set<SetupRequirement>()
        for group in row.anyOf where group.capabilities.filter(satisfied).count >= group.min {
            excused.formUnion(group.capabilities)
        }
        return row.blocking.filter { !excused.contains($0) && !satisfied($0) }
    }

    /// The same rule, answered against this machine right now.
    static func unmetBlocking(of row: FeatureRow) -> [SetupRequirement] {
        unmetBlocking(of: row, satisfied: { CapabilityResolver.isSatisfied($0) })
    }

    /// The state a feature is in right now.
    ///
    /// Only `ready` and `needsSetup` are produced today, which is a deliberate
    /// scope decision rather than an oversight. `degraded` collapses into
    /// `ready` because the feature genuinely works, and `unavailable` collapses
    /// into `needsSetup` because telling somebody a thing cannot be fixed is
    /// worse than showing them how to try. When the degraded note and the
    /// unavailable treatment are built, this is the one function that changes.
    static func state(of row: FeatureRow) -> FeatureState {
        // SELECTION FIRST. A feature the owner turned off has no capability state worth
        // computing, and reporting it as needs-setup would put it in every list of things
        // waiting on somebody who has already answered.
        guard FeatureSelection.isOn(row.id) else { return .notChosen }
        return capabilityState(of: row)
    }

    /// What this feature's state WOULD be if it were chosen.
    ///
    /// Split out from `state(of:)` when CR-36 made selection part of the answer. Two callers
    /// need the question without the selection: the COST screen, which prices features
    /// nobody has picked yet, and the contract tests, which are about capabilities and would
    /// otherwise depend on whatever the last test left in UserDefaults.
    static func capabilityState(of row: FeatureRow) -> FeatureState {
        unmetBlocking(of: row).isEmpty ? .ready : .needsSetup
    }

    static func state(forTab tabKey: String) -> FeatureState {
        guard let row = row(forTab: tabKey) else { return .ready }
        return state(of: row)
    }

    /// Whether the tab's feature is declared `labs` in the frozen registry.
    ///
    /// This is the consumer `tier` never had. The field was transcribed from the
    /// contract, checked against it row by row, and read by nothing, so every
    /// labs feature rendered exactly like a core one.
    ///
    /// A tab with no registry row is NOT labs. That is the same default
    /// `state(forTab:)` takes and the same one `capabilityGated` documents: an
    /// unknown key is treated as making no claims rather than as experimental.
    /// Marking a row-less tab beta would put the badge on anything anyone forgot
    /// to register, which turns the badge into noise instead of information.
    static func isLabs(forTab tabKey: String) -> Bool {
        row(forTab: tabKey)?.tier == .labs
    }

    /// Every capability any shipping feature declares, in any of the four slots.
    static var claimedByAFeature: Set<SetupRequirement> {
        var out = Set<SetupRequirement>()
        for row in rows {
            out.formUnion(row.requires)
            out.formUnion(row.optional)
            out.formUnion(row.steps)
            out.formUnion(row.optionalSteps)
        }
        return out
    }

    /// The credentials Settings should offer a paste field for, in contract order.
    ///
    /// Lives here rather than in the view because it is a question about the
    /// registry, and because a private computed property on a SwiftUI View is
    /// untestable. `keyIsSatisfied` was pulled out of `isSatisfied` for the same
    /// reason and the same lesson applies.
    ///
    /// Settings used to offer every `key.` capability in the contract, all
    /// fourteen, which put a live paste field in front of a stranger for five
    /// credentials nothing in the app reads. A powerful token sitting unused in a
    /// Keychain is risk with nothing on the other side of it.
    ///
    /// Blueprints deliberately do not count as claimants. They declare
    /// capabilities too, and `docs/blueprints/index.md` states plainly that they
    /// are specification only and nothing there is implemented, so counting them
    /// would restore exactly the fields this removes.
    static var credentialsToOffer: [SetupRequirement] {
        let claimed = claimedByAFeature
        return SetupRequirement.allCases.filter { $0.kind == .key && claimed.contains($0) }
    }

    /// Every blocking capability a feature is missing, in registry order, for the
    /// setup card to list.
    static func missing(forTab tabKey: String) -> [SetupRequirement] {
        guard let row = row(forTab: tabKey) else { return [] }
        return unmetBlocking(of: row)
    }

    /// Features currently needing setup, for the sidebar count.
    static var featuresNeedingSetup: [FeatureRow] {
        rows.filter { state(of: $0) == .needsSetup }
    }

    /// What Grux can actually do ON THIS MACHINE, for the chat system prompt.
    ///
    /// THE GAP THIS CLOSES. The live system prompt described who Grux IS at
    /// length and never once said what Grux can DO. "What can you do?" is the
    /// most likely first sentence a new user types, and the model had nothing to
    /// answer it from but the persona header, so it either spoke in generalities
    /// or invented surfaces. A registry of 39 real features existed the whole
    /// time and no prompt read it.
    ///
    /// GENERATED, NEVER HAND WRITTEN, and that is the point. A capability list
    /// typed into a prompt string is wrong the first time a feature lands and
    /// nothing tells anybody. This reads the same rows the sidebar reads, so it
    /// cannot describe a Grux that does not exist.
    ///
    /// It reports READY and NEEDS SETUP separately because those are different
    /// answers to the user. Claiming a feature that is one missing key away from
    /// working is how an assistant promises something it cannot deliver, and
    /// hiding it entirely is how a user never discovers what they nearly have.
    /// The split lets Grux say "I can do these now, and these the moment you add
    /// a key", which is the honest and the more useful sentence.
    ///
    /// Labs rows are marked inline rather than filtered out. The badge exists in
    /// the sidebar for the same reason: a user is entitled to know which surfaces
    /// have unsanded edges BEFORE they rely on one, not after.
    /// Where a feature lives when it is NOT a tab of its own.
    ///
    /// Five registry rows have no matching case in `LaunchRootView.Tab`, and
    /// until this existed the prompt block listed all 39 as though each were a
    /// place you could open. A model reading that will tell somebody to "go to
    /// Approvals", and there is no Approvals tab: it is a section inside Jax HQ.
    /// Sending a user to a tab that does not exist is worse than not mentioning
    /// the feature, because it reads as the app being broken rather than the
    /// answer being wrong.
    ///
    /// `domains` says plainly that it has no page. That is not a placeholder, it
    /// is the measured truth: every call site of `openEmpireDashboardWindow()`
    /// is a file watcher trigger in GruxApp, there is no menu item and no
    /// button, so a user has no way to reach it. Saying so is better than naming
    /// a window they cannot open.
    static let homes: [String: String] = [
        "approvals": "a section inside the Jax HQ tab",
        "mailbox.compose": "inside the Mailbox tab",
        "integrations.webhooks": "a section inside the Integrations tab",
        "phone": "a section in Settings",
        "domains": "no page of its own yet, so do not send anyone looking for it",
    ]

    static func systemPromptBlock() -> String {
        var ready: [String] = []
        var pending: [String] = []
        for row in rows {
            var name = row.label + (row.tier == .labs ? " (labs)" : "")
            if let home = homes[row.id] { name += " (\(home))" }
            if state(of: row) == .ready {
                ready.append(name)
            } else {
                let missing = unmetBlocking(of: row)
                    .map(\.label).joined(separator: ", ")
                pending.append("\(name): needs \(missing)")
            }
        }
        var out = ["WHAT_YOU_CAN_DO (the real surfaces in this build, generated from the feature registry, not a guess):"]
        out.append("")
        out.append("WORKING RIGHT NOW (\(ready.count)): " + (ready.isEmpty ? "(none yet)" : ready.joined(separator: ", ")))
        if !pending.isEmpty {
            out.append("")
            out.append("ONE STEP AWAY (\(pending.count), name the missing piece if the user asks for one of these):")
            for line in pending { out.append("- " + line) }
        }
        out.append("")
        out.append("When the user asks what you can do, answer from THIS list and nothing else. Never claim a surface that is not named here. Pick the few that fit what they are actually trying to get done rather than reciting the list.")
        return out.joined(separator: "\n")
    }
}
