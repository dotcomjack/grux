import Foundation

// What a Self-Upgrade card tells a person to do next, decided from measured
// inputs and nothing else. The view renders the answer; it never decides.
//
// Why this exists: the card used to show ACCEPT / REJECT / COPY PROMPT while a
// proposal was pending and NOTHING once it was accepted, so an accepted card
// whose build never started (no source checkout, self-upgrade off, signed out)
// sat there forever with no direction. Every gate the real build path has is a
// case here, in the order a person has to clear them.

// The engine's ProposalStatus, mirrored by name for the display layer so the
// card can tell "accepted and idle" from "building" from "shipped". The coarse
// FoundryProposalCardStatus stays for ranking.
enum FoundryProposalStage: String, Codable, CaseIterable, Equatable {
    case proposed, accepted, building, verifying, landed, rejected, rolledBack
}

// Sign-in is three states, not two. AccountSwitcher.liveStatus starts nil and
// stays nil until `claude auth status` has answered once, and reading that as
// "signed out" showed a Max subscriber "Sign in to build it" for the first
// second of every launch.
enum FoundryAuthState: Equatable {
    case checking
    case signedOut
    case signedIn
}

// Everything the primary action depends on. Plain values so a test can hand it
// every combination without touching the CLI, the keychain or the engine.
struct FoundryBuildReadiness: Equatable {
    var auth: FoundryAuthState
    var subscriptionType: String?
    var cliInstalled: Bool
    var foundryEnabled: Bool
    var sourceAvailable: Bool
    var stage: FoundryProposalStage
    var buildInFlight: Bool
    var escalatedJobId: String?
    var approvalPending: Bool
}

enum FoundryPrimaryAction: Equatable {
    /// Signed in on a paid plan, source known, engine on: one click builds.
    case build(power: String)
    /// Same, except the self-upgrade loop is off; one click turns it on and builds.
    case enableAndBuild(power: String)
    /// `claude auth status` has not answered yet this launch.
    case checkingSignIn
    /// Not signed in to Claude; routes to the existing sign-in flow.
    case signIn
    /// Signed in, but on no plan the CLI names as a subscription (free, an API
    /// key, or a value this build does not know). Building would spend
    /// something we cannot describe, so it is not offered.
    case noPaidPlan
    /// The claude CLI is not on this Mac, so sign-in cannot run either.
    case installCLI
    /// Nothing to build from: no source checkout for this install.
    case noSource
    /// A build is running (headless, or as a swarm job when jobId is set).
    case inFlight(stage: FoundryProposalStage, jobId: String?)
    /// Built and verified; the install approval card is pinned above.
    case awaitingApproval
    case shipped
    case notPursued
    case rolledBack

    /// The button label, or the status line when nothing is clickable.
    var title: String {
        switch self {
        case .build: return "Build it"
        case .enableAndBuild: return "Turn on self-upgrade and build it"
        case .checkingSignIn: return "Checking your sign-in"
        case .signIn: return "Sign in to build it"
        case .noPaidPlan: return "No Claude subscription to build with"
        case .installCLI: return "Install Claude Code to build it"
        case .noSource: return "Grux cannot build this here"
        case .inFlight(let stage, _): return stage == .verifying ? "Verifying the build" : "Building now"
        case .awaitingApproval: return "Built and verified"
        case .shipped: return "Shipped"
        case .notPursued: return "Not pursued"
        case .rolledBack: return "Rolled back"
        }
    }

    /// One line under the title saying what powers it or what comes next.
    var subtitle: String {
        switch self {
        case .build(let power), .enableAndBuild(let power): return power
        case .checkingSignIn: return "One moment"
        case .signIn: return "Grux builds with your Claude subscription, on this Mac"
        case .noPaidPlan:
            return "Grux builds with a Claude Pro, Max, Team or Enterprise plan. Sign in to one, or copy the handoff for your agent."
        case .installCLI: return "Or copy the handoff for your agent below"
        case .noSource:
            return "This install has no source checkout. Rebuild with build.sh from the source folder, or copy the handoff for your agent."
        case .inFlight(_, let jobId): return jobId == nil ? "Grux is working in its own checkout" : "Running as an agent job"
        case .awaitingApproval: return "Approve the install at the top of this list"
        case .shipped: return "Installed behind a 24 hour rollback"
        case .notPursued: return ""
        case .rolledBack: return "Reverted by the rollback keeper"
        }
    }

    /// True when the primary control is a button a person can press.
    var isActionable: Bool {
        switch self {
        case .build, .enableAndBuild, .signIn: return true
        case .checkingSignIn, .noPaidPlan, .installCLI, .noSource, .inFlight,
             .awaitingApproval, .shipped, .notPursued, .rolledBack: return false
        }
    }
}

enum FoundryDirection {

    /// The plans `claude auth status --json` reports in `subscriptionType`
    /// and that a build can honestly be said to run on. Anything else (nil
    /// for an API key login, "free", a value added after this build) gets no
    /// line at all rather than a generic one.
    static let paidPlans: [String: String] = [
        "max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise",
    ]

    /// "powered by your Claude Max subscription", or nil when there is no
    /// paid plan to name.
    static func powerLine(subscriptionType: String?) -> String? {
        let raw = (subscriptionType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let plan = paidPlans[raw] else { return nil }
        return "powered by your Claude \(plan) subscription"
    }

    /// AccountSwitcher's two facts folded into the three states the card
    /// needs. A status already in hand counts even before the first check
    /// has been flagged complete; a completed check with nothing in hand is
    /// signed out (the CLI errored or nobody is logged in), never "checking".
    static func authState(checked: Bool, liveStatus: AccountSwitcher.LiveStatus?) -> FoundryAuthState {
        if let liveStatus { return liveStatus.loggedIn ? .signedIn : .signedOut }
        return checked ? .signedOut : .checking
    }

    /// The gates in the order a person has to clear them. Terminal and
    /// in-flight stages win over everything, because no gate matters for a
    /// proposal that is already building or already shipped.
    static func primaryAction(_ r: FoundryBuildReadiness) -> FoundryPrimaryAction {
        switch r.stage {
        case .landed: return .shipped
        case .rejected: return .notPursued
        case .rolledBack: return .rolledBack
        case .building:
            return .inFlight(stage: .building, jobId: r.escalatedJobId)
        case .verifying:
            return r.approvalPending ? .awaitingApproval : .inFlight(stage: .verifying, jobId: r.escalatedJobId)
        case .proposed, .accepted:
            break
        }
        if r.buildInFlight { return .inFlight(stage: .building, jobId: r.escalatedJobId) }
        guard r.cliInstalled else { return .installCLI }
        switch r.auth {
        case .checking: return .checkingSignIn
        case .signedOut: return .signIn
        case .signedIn: break
        }
        guard let power = powerLine(subscriptionType: r.subscriptionType) else { return .noPaidPlan }
        guard r.sourceAvailable else { return .noSource }
        return r.foundryEnabled ? .build(power: power) : .enableAndBuild(power: power)
    }
}

// MARK: - Plain-language labels for the card

extension FoundryFormat {

    /// "About $8 of your subscription". Numeral with the symbol, never words,
    /// and never "estimated (subscription powered)", which is engine speak.
    static func costLine(usd: Double) -> String {
        guard usd > 0 else { return "No measurable subscription cost" }
        if usd < 1 { return "Under $1 of your subscription" }
        return "About $\(Int(usd.rounded())) of your subscription"
    }

    /// "Medium risk", "Protected area".
    static func riskLabel(_ risk: String) -> String {
        switch risk.trimmingCharacters(in: .whitespaces).lowercased() {
        case "protected": return "Protected area"
        case "med", "medium": return "Medium risk"
        case "high": return "High risk"
        case "low": return "Low risk"
        default: return "\(risk.capitalized) risk"
        }
    }

    /// Evidence is stored as "source: detail". The source is an internal
    /// channel name; the card and the handoff read it as where it came from.
    static func evidenceLabel(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let source = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let detail = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // A URL's scheme is not a source. Sources are short words with no
        // spaces or slashes; anything else is left exactly as written.
        guard !source.isEmpty, source.count <= 16, !source.contains(" "), !source.contains("/"),
              !detail.hasPrefix("//") else { return line }
        let label: String
        switch source.lowercased() {
        case "manual": label = "Noted by you"
        case "transcript": label = "From a conversation"
        case "swarm": label = "From an agent run"
        case "crash": label = "From a crash"
        case "screenshot": label = "From a screenshot"
        case "compare": label = "From a comparison"
        case "fs-audit", "fsaudit": label = "From the file audit"
        case "flake": label = "From a flaky test"
        default: label = "From \(source)"
        }
        return "\(label): \(detail)"
    }

    /// What a trust tier means for the person, not the ladder's rung name.
    static func tierPlain(_ tier: Int) -> String {
        switch tier {
        case 0: return "Tier 0: you approve every build"
        case 1: return "Tier 1: builds on its own, you approve the install"
        default: return "Tier 2: installs on its own behind a 24 hour rollback"
        }
    }
}
