import Foundation

// What the Command Panel's Now list shows. One pure function over a value
// struct, so the rules in spec section 4.2 are tests and not opinions. The
// panel assembles `RelevanceState` from the stores and never decides anything
// itself.

/// One row of Now. Every row carries an action; there are no informational rows.
struct PanelItem: Equatable, Identifiable {
    /// Ordered by urgency. The raw value is the sort key.
    enum Class: Int, Comparable {
        case needsYou = 0, running, next, suggested
        static func < (a: Class, b: Class) -> Bool { a.rawValue < b.rawValue }
    }
    let id: String
    let cls: Class
    let icon: String
    let title: String
    let detail: String
    let action: PanelAction
}

enum PanelAction: Equatable {
    /// Open a surface by its locked tab key.
    case open(tabKey: String)
    case openApprovals
    /// Expand the Optimize hub on this order.
    case openWorkOrder(id: String)
    /// Open the setup card for a registry row.
    case setup(featureId: String)
    case openOptimize
    /// Open one agent job by its id.
    case openJob(id: String)
    /// Start the Claude sign-in (`ClaudeSignInState.startSignIn`).
    case claudeSignIn
    /// Show `~/.claude/settings.json` in Finder, for a hook Grux left for the person.
    case revealClaudeSettings
}

/// A work order stopped at one of its three reviews.
struct WorkOrderReview: Equatable {
    let id: String
    let request: String
}

/// An agent job, either running or stopped waiting on the person.
struct RunningJob: Equatable {
    let id: String
    let title: String
}

/// A feature the person picked that is missing something.
struct SetupGap: Equatable {
    let featureId: String
    let label: String
    /// The first missing thing, as the registry labels it, verbatim.
    let missing: String
    /// True when the registry row only makes sense once a brand exists.
    var brandScoped: Bool = false
}

/// Everything Now is decided from. Counts and arrays only, no live objects.
struct RelevanceState: Equatable {
    var approvalsPending: Int = 0
    var reviewsWaiting: [WorkOrderReview] = []
    var mail: [TodayModel.MailSummary] = []
    var mailTotal: Int = 0
    /// In start order. One row each.
    var jobsRunning: [RunningJob] = []
    /// In start order. One needsYou row each.
    var jobsWaitingOnYou: [RunningJob] = []
    /// The display name of a CommandsV2 run in flight, if one is.
    var workflowRunning: String? = nil
    var next: TodayModel.Next? = nil
    /// In registry order.
    var setupGaps: [SetupGap] = []
    var proposals: Int = 0
    var hasBrand: Bool = false
    /// The last agent run failed on an expired Claude sign-in.
    var claudeSignInExpired: Bool = false
    /// A Claude Code hook still runs the old Terminal Focus script in a way Grux
    /// will not edit, live from the settings file (`TerminalFocusHookState`).
    var oldHookNeedsRemoval: Bool = false
}

enum Relevance {
    static func now(_ s: RelevanceState, cap: Int = 7) -> [PanelItem] {
        var out: [PanelItem] = []

        // needsYou, in this order: the Claude sign-in, approvals, reviews,
        // jobs waiting, mail. The sign-in leads: no agent runs until it is fixed.
        if s.claudeSignInExpired {
            out.append(PanelItem(id: "claude.signIn", cls: .needsYou, icon: "person.crop.circle.badge.exclamationmark",
                                 title: "Claude sign-in expired", detail: "Agents cannot run until you sign in",
                                 action: .claudeSignIn))
        }
        if s.approvalsPending > 0 {
            out.append(PanelItem(id: "approvals", cls: .needsYou, icon: "checkmark.seal.fill",
                                 title: TodayModel.plural(s.approvalsPending, "approval", "approvals") + " waiting",
                                 detail: "", action: .openApprovals))
        }
        for r in s.reviewsWaiting {
            out.append(PanelItem(id: "review.\(r.id)", cls: .needsYou, icon: "wand.and.stars",
                                 title: "Your review: \(r.request)", detail: "Optimize Grux",
                                 action: .openWorkOrder(id: r.id)))
        }
        for j in s.jobsWaitingOnYou {
            out.append(PanelItem(id: "jobs.waiting.\(j.id)", cls: .needsYou, icon: "pause.circle",
                                 title: j.title, detail: "Waiting on you",
                                 action: .openJob(id: j.id)))
        }
        if s.oldHookNeedsRemoval {
            out.append(PanelItem(id: "terminalFocus.hook", cls: .needsYou, icon: "wrench.and.screwdriver",
                                 title: "Remove an old Grux hook by hand",
                                 detail: "In ~/.claude/settings.json, the entry that runs terminal-focus.sh",
                                 action: .revealClaudeSettings))
        }
        for m in s.mail {
            out.append(PanelItem(id: "mail.\(m.id)", cls: .needsYou, icon: "envelope.fill",
                                 title: "\(m.from): \(m.subject)", detail: "Needs you",
                                 action: .open(tabKey: "mailbox")))
        }

        // running
        for j in s.jobsRunning {
            out.append(PanelItem(id: "jobs.running.\(j.id)", cls: .running, icon: "cpu",
                                 title: j.title, detail: "Agent job",
                                 action: .openJob(id: j.id)))
        }
        if let w = s.workflowRunning {
            out.append(PanelItem(id: "workflow.running", cls: .running, icon: "play.circle.fill",
                                 title: "Running \(w)", detail: "Workflow",
                                 action: .open(tabKey: "workflows")))
        }

        // next
        if let n = s.next {
            out.append(PanelItem(id: "next", cls: .next, icon: n.kind == .event ? "calendar" : "checkmark.circle",
                                 title: n.title, detail: n.when, action: .open(tabKey: n.tab)))
        }

        // suggested
        for g in s.setupGaps where s.hasBrand || !g.brandScoped {
            out.append(PanelItem(id: "setup.\(g.featureId)", cls: .suggested, icon: "circle.dotted",
                                 title: "Set up \(g.label)", detail: g.missing,
                                 action: .setup(featureId: g.featureId)))
        }
        if s.proposals > 0 {
            out.append(PanelItem(id: "proposals", cls: .suggested, icon: "hammer.fill",
                                 title: TodayModel.plural(s.proposals, "improvement", "improvements") + " to review",
                                 detail: "Foundry", action: .open(tabKey: "selfUpgrade")))
        }

        // Stable sort: class first, insertion order inside a class.
        let ordered = out.enumerated().sorted {
            $0.element.cls != $1.element.cls ? $0.element.cls < $1.element.cls : $0.offset < $1.offset
        }.map(\.element)
        return Array(ordered.prefix(max(0, cap)))
    }
}
