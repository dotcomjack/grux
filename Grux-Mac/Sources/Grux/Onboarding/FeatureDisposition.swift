import Foundation

// MARK: - Disposition
//
// WHERE EACH CAPABILITY LIVES, recorded once.
//
// The lock in CLAUDE.md: a feature that is off and unfindable is not a
// conservative default, it is a deleted feature with dead code behind it. The
// registry is the list of everything Grux can do, so every row in it needs
// exactly one door. A row with two doors is a decision nobody finished making;
// a row with none is the lock being broken.
//
// Deliberately a SEPARATE TABLE rather than a column on `FeatureRow`.
// `FeatureRegistryContractTests` re-parses `docs/feature-registry.md` and
// compares the 38 constructors row by row against it, so widening the
// constructor would put this in the path of a contract that exists to catch
// transcription drift. Disposition is not in that document: it is a 3.0
// decision about presentation, and it gets its own table with its own
// completeness test.

extension FeatureRow {
    enum Disposition: Equatable {
        /// Its own row in the rail.
        case rail
        /// Behind the Studio rail row.
        case studio
        /// Inside a parent surface. The value is a feature id, or one of the
        /// named surfaces in `FeatureRegistry.namedFoldTargets`.
        case folds(into: String)
        /// Behind the Developer door.
        case developer
        /// Behind the Labs door.
        case labs
        /// A row that appears only once a brand exists.
        case brandScoped
        /// Gone, and the code with it.
        case ripped
    }

    /// The one door this capability is reachable through.
    @MainActor
    var disposition: Disposition {
        FeatureRegistry.disposition(for: id)
    }
}

extension FeatureRegistry {
    /// Fold targets that are surfaces rather than registry rows.
    static let namedFoldTargets: Set<String> = ["approvals.tray", "today.card"]

    /// Transcribed from the approved design spec section 3. Counts reconcile
    /// to exactly 38: 12 rail, 3 studio, 9 folds, 5 developer, 7 labs,
    /// 2 brand-scoped. (39 until C13 deleted the one ripped row, domains.)
    ///
    /// THE CLUSTER CALL OVERRIDES THREE PER-ROW ANSWERS. The decision record
    /// answered Cognition Map as a Chat side panel, and Feature Review and
    /// Self-Upgrade as Developer. The spec then decided the whole
    /// app-about-itself cluster together and says so in as many words, so
    /// those three are Labs. The spec is the later artifact. Do not "correct"
    /// this back from the decision record.
    static let dispositions: [String: FeatureRow.Disposition] = [
        // The twelve rail rows, in rail order.
        "home": .rail,
        "chat": .rail,
        "mailbox": .rail,            // relabelled Mail
        "calendar": .rail,
        "notes": .rail,
        "documents": .rail,
        "contacts": .rail,
        "tasks": .rail,
        "meetings": .rail,
        "schedules": .rail,
        "integrations": .rail,
        "settings": .rail,           // last, always

        // The Studio rail row hosts these three.
        "design.studio": .studio,
        "creative": .studio,         // Media Studio
        "research": .studio,

        // Folds into a parent.
        "speakers": .folds(into: "meetings"),
        "workflows": .folds(into: "schedules"),
        "integrations.webhooks": .folds(into: "integrations"),
        "mailbox.compose": .folds(into: "mailbox"),
        "projects": .folds(into: "tasks"),
        "folders": .folds(into: "settings"),
        "skills": .folds(into: "chat"),
        "approvals": .folds(into: "approvals.tray"),
        "focus": .folds(into: "today.card"),

        // Behind the Developer door.
        "commands": .developer,
        "agents": .developer,
        "cookbook": .developer,      // Local Models; the picker also stays in onboarding
        "compare": .developer,

        // Behind the Labs door.
        "reactor": .labs,
        "jax.hq": .labs,
        "jax.command": .labs,
        "cognition.map": .labs,
        "feature.review": .labs,
        "self.upgrade": .labs,
        "phone": .labs,

        // Rows that appear only once a brand exists.
        "meta.ads": .brandScoped,
        "social": .brandScoped,

        // Gone. The Domain monitor was the one ripped row; it is deleted with
        // its registry row (Phase C, C13), so nothing is listed here now.
    ]

    /// A row with no recorded door is the lock being broken, so this fails
    /// loudly in debug rather than quietly defaulting to something plausible.
    static func disposition(for id: String) -> FeatureRow.Disposition {
        guard let d = dispositions[id] else {
            assertionFailure("no door recorded for registry row '\(id)'")
            return .labs
        }
        return d
    }
}

// MARK: - Registry id to tab key
//
// THE TWO VOCABULARIES DIVERGED AND NOBODY NOTICED, because until 3.0 nothing
// had to cross between them. The registry names rows in dotted form
// (`jax.hq`, `meta.ads`, `self.upgrade`), the sidebar names tabs in
// camelCase (`jaxHQ`, `metaAds`, `selfUpgrade`), and twelve of the
// thirty-seven rows do not match by string.
//
// That matters the moment a door's contents are computed from dispositions: a
// missing mapping is a surface listed behind a door that opens onto nothing,
// and `--open-tab` falls through to chat SILENTLY on an unknown key, so
// nothing fails, nothing logs, and the sweep reports success on the wrong tab.
//
// These rows deliberately have NO tab: two are folds into a parent surface,
// one is a global tray, and one opens a window.

extension FeatureRegistry {
    /// Rows that are reachable but are not a tab of their own.
    static let rowsWithoutATab: Set<String> = [
        "approvals",              // a global tray with a badge
        "mailbox.compose",        // inside Mail, behind its own credential
        "integrations.webhooks",  // a section inside Integrations
        "phone",                  // opens a window, see rowsOpeningAWindow
    ]

    /// Rows that open a WINDOW rather than a tab. Reachable, and reachable in
    /// a different way, which a door listing its contents has to know.
    ///
    /// Found by `RegistryTabKeyTests`, not by reading: Phone companion is
    /// dispositioned to Labs and has no tab anywhere in the app. It opens the
    /// Pair iPhone window (`~/.grux/fire-pair-iphone`). Listing it behind the
    /// Labs door as though it were a tab would have produced a row that opens
    /// nothing, and `--open-tab` fails silently to chat, so nothing would have
    /// said so.
    static let rowsOpeningAWindow: [String: String] = [
        "phone": "Pair iPhone",
    ]

    /// The tab key a registry row opens, where the two names differ.
    static let idToTabKey: [String: String] = [
        "jax.hq": "jaxHQ",
        "jax.command": "jaxCommand",
        "cognition.map": "cognitionMap",
        "feature.review": "featureReview",
        "design.studio": "designStudio",
        "self.upgrade": "selfUpgrade",
        "meta.ads": "metaAds",
    ]

    /// The tab a registry row opens, or nil when it is not a tab of its own.
    static func tabKey(forRowId id: String) -> String? {
        if rowsWithoutATab.contains(id) { return nil }
        return idToTabKey[id] ?? id
    }
}
