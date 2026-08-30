import Foundation

/// ONE renderer for a bill of capabilities, used by every command that shows one.
///
/// ## Why this exists
///
/// `grux setup` and `grux cost` answer the same question and printed two different screens.
/// `cost` grouped its asks under headings; `setup` printed one flat list of nineteen rows
/// mixing permissions, API keys, mail servers and one-time jobs as though they were the same
/// errand. Two renderings of one fact in one product is how the CLI, the app and the handoff
/// stop using the same words, so there is now one of them and both commands call it.
///
/// The grouping is the same lesson `AgentHandoff` already learned and wrote down: four
/// different KINDS of blocked thing, needing four different actions from the reader, read as
/// a jumble when presented as a single list. That lesson had never been carried across.
public struct BillView {

    public let renderer: Renderer
    public let capabilities: [SetupStatus.Capability]

    public init(renderer: Renderer, capabilities: [SetupStatus.Capability]) {
        self.renderer = renderer
        self.capabilities = capabilities
    }

    private var byID: [String: SetupStatus.Capability] {
        Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })
    }

    private func label(_ id: String) -> String { byID[id]?.label ?? id }

    /// What kind of work a capability is, in the reader's terms rather than the schema's.
    ///
    /// The heading answers "what will this cost me" before the row answers "what is it",
    /// because clicking a dialog, pasting a key and running an installer are three different
    /// decisions and somebody scanning the column is deciding whether to start at all.
    public struct Kind {
        public let id: String
        public let heading: String
        public let aside: String
    }

    public static let kinds: [Kind] = [
        Kind(id: "perm", heading: "macOS permissions",
             aside: "you click these, in a dialog Grux raises"),
        Kind(id: "key", heading: "Credentials",
             aside: "you paste these once each, and they go to the Keychain"),
        Kind(id: "endpoint", heading: "Addresses",
             aside: "a server you already run, or one you sign up for"),
        Kind(id: "step", heading: "One-time jobs",
             aside: "some of these an agent can do for you"),
    ]

    // MARK: - The grid

    /// A block of rows sharing one column width, computed from the widest label PRESENT.
    ///
    /// A fixed width is a guess, and it was wrong: "Install the agent command line tool" is
    /// 35 characters against a hard-coded 30, so that one row's id started four columns right
    /// of every other row's and the block stopped being a grid. Sizing from content means the
    /// column is exactly as wide as it needs to be and never wider.
    public func grid(_ ids: [String], state: RowState, indent: Int = 4) -> [String] {
        guard !ids.isEmpty else { return [] }
        let labels = ids.map(label)
        // Clamped so one very long label cannot push every id off a narrow terminal.
        let width = min(labels.map(\.count).max() ?? 0, max(0, renderer.style.width - indent - 22))
        return zip(ids, labels).map { id, text in
            renderer.row(state: state, label: text, detail: id,
                         labelWidth: width, indent: indent)
        }
    }

    /// Rows grouped by kind, each under a heading that says what kind of work it is.
    ///
    /// A kind with nothing in it prints nothing. An id whose capability is unknown still
    /// prints, under "Other", rather than vanishing: a row silently dropped is how a count
    /// stops matching the list beneath it.
    public func grouped(_ ids: [String], state: RowState, indent: Int = 4) -> [String] {
        guard !ids.isEmpty else { return [] }
        var out: [String] = []
        var placed = Set<String>()

        for kind in Self.kinds {
            let mine = ids.filter { byID[$0]?.kind == kind.id }
            guard !mine.isEmpty else { continue }
            placed.formUnion(mine)
            out.append("")
            out.append(String(repeating: " ", count: indent)
                       + renderer.style.ink(.bold, kind.heading)
                       + "  " + renderer.style.ink(.dim, kind.aside))
            out.append(contentsOf: grid(mine, state: state, indent: indent + 2))
        }

        let orphans = ids.filter { !placed.contains($0) }
        if !orphans.isEmpty {
            out.append("")
            out.append(String(repeating: " ", count: indent) + renderer.style.ink(.bold, "Other"))
            out.append(contentsOf: grid(orphans, state: state, indent: indent + 2))
        }
        return out
    }

    // MARK: - The whole bill

    /// Every ask a selection produces, in the order somebody decides about them.
    ///
    /// Required before optional, because a person deciding whether to bother needs the
    /// blocking cost first. Groups after both, because "either of these" is a different
    /// sentence from "both of these" and printing them together is how somebody pastes a
    /// credential they did not need.
    public func lines(for bill: Cost, selectionCount: Int, totalCapabilities: Int) -> [String] {
        var out: [String] = []
        out.append("")

        if !bill.blocking.isEmpty {
            out.append("  " + renderer.heading("REQUIRED, or the feature does not run"))
            out.append(contentsOf: grouped(bill.blocking, state: .needed))
            out.append("")
        }

        if !bill.choices.isEmpty {
            out.append("  " + renderer.heading("ONE OF EACH GROUP BELOW, never all of it"))
            for g in bill.choices {
                out.append("")
                out.append("    " + renderer.style.ink(.dim,
                    "for \(g.featureLabel), any \(g.min) of:"))
                // INDENTED UNDER THE GROUP. At the top level these read as separate
                // requirements, which is the opposite of what a group means.
                out.append(contentsOf: grid(g.capabilities, state: .needed, indent: 6))
            }
            out.append("")
        }

        if !bill.degrading.isEmpty {
            out.append("  " + renderer.heading("OPTIONAL, the feature runs without them"))
            out.append(contentsOf: grouped(bill.degrading, state: .optional))
            out.append("")
        }

        // THE PROMISE, NAMED. Telling somebody what you will ask for is ordinary. Telling
        // them by name the things you will never ask for, because they did not pick the
        // features that use them, is the part that earns a permission dialog later. It was
        // a count on the setup screen and a list only on `grux cost`, which put the central
        // claim behind a second command somebody has no reason to run.
        if !bill.never.isEmpty {
            out.append("  " + renderer.heading("NEVER ASKED FOR, because nothing you picked uses it"))
            out.append(renderer.style.ink(.dim,
                renderer.prose(renderer.list(bill.never.map(label)) + ".", indent: 4)))
            out.append("")
        }

        if !bill.unmetDependencies.isEmpty {
            out.append("  " + renderer.heading("PICKED, but something it needs was not"))
            for d in bill.unmetDependencies {
                out.append("    " + renderer.style.ink(.attention, "! ") + d.featureLabel
                           + renderer.style.ink(.dim, " needs " + renderer.list(d.needs)))
            }
            out.append("")
            out.append(renderer.style.ink(.dim, renderer.prose(
                "Nothing will be corrected for you. A selection that cannot do what you "
                + "asked is allowed to exist while you think about it.", indent: 4)))
            out.append("")
        }

        return out
    }

    /// The one-line summary above the bill. The counts here MUST reconcile with the rows
    /// below, so they are derived from the same arrays rather than counted separately.
    public func summary(for bill: Cost, selectionCount: Int, totalCapabilities: Int) -> String {
        let n = selectionCount
        return renderer.prose("\(n) feature\(n == 1 ? "" : "s"). "
            + "\(bill.blocking.count) required, \(bill.degrading.count) optional, and "
            + "\(bill.never.count) of \(totalCapabilities) things will never be asked for.")
    }
}
