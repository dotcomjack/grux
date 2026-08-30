import XCTest
@testable import Grux

/// A structural audit of the twelve surfaces a stranger can open on a machine
/// where nothing is configured.
///
/// ## The distinction this file exists to hold
///
/// A tab that is EMPTY is fine. A tab that looks BROKEN is not, and on a first
/// run those two are one line of copy apart. Broken is a blank pane, a heading
/// standing over nothing, a control whose only explanation is a tooltip, a
/// count of zero with no context, an instruction the reader cannot follow.
/// Empty is "No tasks yet. Add one with the button above."
///
/// Every Tier 1 feature is on by default, so all twelve of these are reachable
/// in the first ten minutes with no key, no permission and no data anywhere.
///
/// ## Why this is structural rather than a render test
///
/// Standing up twelve SwiftUI views under XCTest is not practical, and a test
/// that only rendered them would assert they do not crash, which is not the
/// defect. The defect is a surface that draws fine and says nothing. So each
/// view exposes the sentence it draws as a `static`, this file reads those
/// twelve statics, and the assertions are about the WORDS. A surface whose
/// empty state cannot be reached at all says so in writing instead of getting a
/// sentence invented for it, because a fabricated empty state is a second
/// source of truth that no user will ever see and no future reader can check.
///
/// ## Why the list is here and not derived
///
/// There is no Tier 1 roster in the tree to derive from yet. So the list is
/// written out, its length is asserted, and every id in it is checked against
/// `FeatureRegistry`. A thirteenth Tier 1 surface therefore cannot land
/// silently: it fails `testTierOneIsExactlyTwelveSurfacesAndAllOfThemAreHere`
/// until somebody adds its empty state here too.
@MainActor
final class EmptyStateAuditTests: XCTestCase {

    // MARK: - The model

    /// What the audit knows about one surface's empty state.
    enum EmptyStateUnderAudit {
        /// The exact sentence a stranger reads, taken from the view that draws
        /// it rather than retyped here. Retyping would make this file agree with
        /// itself forever while the screen drifted.
        case reads(String)
        /// The surface genuinely cannot be empty, and why not.
        case unreachable(because: String)
    }

    struct Surface {
        let featureId: String
        let drawnBy: String
        let state: EmptyStateUnderAudit
    }

    /// A stand-in for `config.assistantName`, passed in rather than read.
    ///
    /// Reading the live setting would drag `AppState.shared` into an audit of
    /// pure strings, and it would also mean the copy could stop following the
    /// setting without this file noticing, because a default that happens to
    /// match is indistinguishable from a hardcode. A name nothing ships with
    /// makes the difference visible.
    static let standInAssistantName = "Ada"

    static var tierOne: [Surface] {
        let assistant = standInAssistantName
        let projects = ProjectsView.emptyCopy(registryMissing: true)
        let skills = SkillsView.emptyCopy(assistantName: assistant)

        return [
            Surface(featureId: "home", drawnBy: "HomeView.allQuietCopy",
                    state: .reads(HomeView.allQuietCopy.headline + " " + HomeView.allQuietCopy.detail)),

            // Chat's empty state was lifted out of the 1000 line ChatView into
            // its own type precisely so it could be read like this.
            Surface(featureId: "chat", drawnBy: "ChatEmptyState.blurb",
                    state: .reads(ChatEmptyState.blurb(isFirstRun: true, wakeWordOn: false))),

            Surface(featureId: "projects", drawnBy: "ProjectsView.emptyCopy",
                    state: .reads([projects.title, projects.body, projects.note ?? ""]
                        .joined(separator: " "))),

            Surface(featureId: "tasks", drawnBy: "TasksDetailView.emptyCopy",
                    state: .reads(TasksDetailView.emptyCopy(assistantName: assistant))),

            Surface(featureId: "notes", drawnBy: "NotesView.emptyDetailCopy",
                    state: .reads(NotesView.emptyDetailCopy(hasNotes: false, hasMatches: false))),

            Surface(featureId: "documents", drawnBy: "DocumentLibraryView.emptyCopy",
                    state: .reads(DocumentLibraryView.emptyCopy(unfiltered: true))),

            // MEASURED, NOT ASSUMED. `FolderStore.seedSystemFoldersIfNeeded()`
            // runs from `init` whenever the list is empty and writes Work,
            // Personal and Projects, and `FolderStore.delete(id:)` returns nil
            // for any folder with `isSystem` true, so those three cannot be
            // removed. The list this tab draws therefore has at least three rows
            // on every machine that has ever launched Grux, and the empty branch
            // does not exist to write copy for. Inventing one would put a
            // sentence in this file that no user can ever reach.
            Surface(featureId: "folders", drawnBy: "FoldersManagementView",
                    state: .unreachable(because:
                        "FolderStore seeds three system folders on first init and refuses to delete "
                        + "any folder with isSystem true, so the Folders list is never empty.")),

            Surface(featureId: "skills", drawnBy: "SkillsView.emptyCopy",
                    state: .reads(skills.line + " " + skills.detail)),

            Surface(featureId: "commands", drawnBy: "CommandsView.emptyCopy",
                    state: .reads(CommandsView.emptyCopy.headline + " " + CommandsView.emptyCopy.detail)),

            // Two states, both of them a first run. Nothing installed at all is
            // the common one; nothing fitting the live budget is the one a
            // small Mac under memory pressure lands in.
            Surface(featureId: "cookbook", drawnBy: "CookbookView.ollamaMissingCopy",
                    state: .reads(CookbookView.ollamaMissingCopy + " " + CookbookView.nothingFitsCopy)),

            // Settings has no empty DATA state, it has an empty RESULT state,
            // and it was the worst of the twelve: a search term the keyword
            // registry does not know hid every section and rendered nothing.
            Surface(featureId: "settings", drawnBy: "SettingsView.noMatchesCopy",
                    state: .reads(SettingsView.noMatchesCopy(query: "qqzz"))),

            Surface(featureId: "approvals", drawnBy: "JaxApprovalsSection.emptyCopy",
                    state: .reads(JaxApprovalsSection.emptyCopy(assistantName: assistant))),
        ]
    }

    /// Every sentence under audit, ignoring the unreachable ones.
    private static var readableCopy: [(surface: Surface, text: String)] {
        tierOne.compactMap { surface in
            if case .reads(let text) = surface.state { return (surface, text) }
            return nil
        }
    }

    // MARK: - The roster

    /// The count is the guard. A thirteenth Tier 1 surface has to be described
    /// here before it can ship, which is the only way an empty state gets
    /// written at all: whoever adds the tab is looking at a screen full of their
    /// own data and never sees the state a stranger sees.
    func testTierOneIsExactlyTwelveSurfacesAndAllOfThemAreHere() {
        XCTAssertEqual(Self.tierOne.count, 12,
                       "Tier 1 ships twelve features on by default. If that number changed, add the "
                       + "new surface's empty state to this list rather than raising the number, "
                       + "or a tab reaches a stranger with nothing on it and nothing catches it.")

        let ids = Self.tierOne.map(\.featureId)
        XCTAssertEqual(Set(ids).count, ids.count, "two entries claim the same feature id: \(ids)")
    }

    /// The ids are real. A typo here would quietly audit nothing.
    func testEverySurfaceNamedHereIsARealFeatureRegistryRow() {
        for surface in Self.tierOne {
            XCTAssertNotNil(FeatureRegistry.row(forTab: surface.featureId),
                            "\(surface.featureId) is not a row in FeatureRegistry, so this entry "
                            + "audits a surface that does not exist")
        }
    }

    /// Tier 1 is what somebody gets before they have opted into anything, so
    /// nothing in it may be declared experimental.
    func testNothingInTierOneIsMarkedLabs() {
        for surface in Self.tierOne {
            XCTAssertFalse(FeatureRegistry.isLabs(forTab: surface.featureId),
                           "\(surface.featureId) is a labs row but ships on by default, so a "
                           + "stranger meets an unsanded surface with no warning")
        }
    }

    // MARK: - The copy

    /// The whole point. A surface that renders and says nothing is the defect.
    func testEveryReachableEmptyStateActuallySaysSomething() {
        for (surface, text) in Self.readableCopy {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.isEmpty,
                           "\(surface.featureId) draws an empty string as its empty state")
            XCTAssertGreaterThanOrEqual(
                trimmed.split(separator: " ").count, 8,
                "\(surface.featureId) (\(surface.drawnBy)) says \"\(trimmed)\", which is a label "
                + "rather than an explanation. An empty state has to say what the surface is for "
                + "and what to do next.")
        }
    }

    /// A missing capability, an empty store and an unmatched filter are all
    /// NORMAL. The setup contract says this in stronger words for capabilities
    /// and the rule is the same here: nothing is broken, so nothing may read as
    /// though it is.
    func testNoEmptyStateReportsItselfAsAFailure() {
        for (surface, text) in Self.readableCopy {
            for word in Self.failureVocabulary where Self.containsWord(word, in: text) {
                XCTFail("\(surface.featureId) (\(surface.drawnBy)) says \"\(word)\" in its empty "
                        + "state: \"\(text)\". Nothing has failed on a first run, and copy that "
                        + "claims otherwise turns an ordinary blank surface into a bug report.")
            }
        }
    }

    /// Placeholder copy is the loudest possible signal that a surface was never
    /// finished, and it is the exact thing this wave exists to keep out.
    func testNoEmptyStateIsAPlaceholder() {
        for (surface, text) in Self.readableCopy {
            for phrase in Self.placeholderVocabulary where text.lowercased().contains(phrase) {
                XCTFail("\(surface.featureId) (\(surface.drawnBy)) still carries placeholder copy "
                        + "(\"\(phrase)\"): \"\(text)\"")
            }
        }
    }

    /// House style, on the one set of strings a stranger is guaranteed to read.
    /// The repo-wide dash sweep covers the tree; this covers the deliverable and
    /// adds the tone rule, which nothing else checks.
    func testEveryEmptyStateIsWrittenInTheHouseVoice() {
        for (surface, text) in Self.readableCopy {
            XCTAssertFalse(text.contains("\u{2014}"),
                           "\(surface.featureId) uses an em dash")
            XCTAssertFalse(text.contains("\u{2013}"),
                           "\(surface.featureId) uses an en dash")
            XCTAssertFalse(text.contains("!"),
                           "\(surface.featureId) shouts at somebody whose screen is empty: \"\(text)\"")
        }
    }

    // MARK: - The unreachable ones

    /// An exemption has to be an argument, not a shrug. The reason must name
    /// the mechanism that makes the state impossible, so the next reader can go
    /// and check it rather than trust it.
    func testAnUnreachableEmptyStateHasToJustifyItselfInWriting() {
        for surface in Self.tierOne {
            guard case .unreachable(let because) = surface.state else { continue }
            XCTAssertGreaterThanOrEqual(
                because.split(separator: " ").count, 12,
                "\(surface.featureId) is exempted from this audit with \"\(because)\", which is "
                + "an assertion rather than a reason. Name the code that makes the state "
                + "impossible or write the copy.")
        }
    }

    // MARK: - The assistant's name

    /// Three of the twelve describe the ASSISTANT acting, and the assistant is
    /// renameable. A hardcoded name there describes somebody else's assistant
    /// the moment a user changes theirs, which measured 2026-08-22 was true of
    /// 28 strings at once.
    func testEmptyStatesThatNameTheAssistantFollowTheSetting() {
        let named: [(String, (String) -> String)] = [
            ("tasks", { TasksDetailView.emptyCopy(assistantName: $0) }),
            ("skills", { SkillsView.emptyCopy(assistantName: $0).detail }),
            ("approvals", { JaxApprovalsSection.emptyCopy(assistantName: $0) }),
        ]
        for (id, copy) in named {
            XCTAssertTrue(copy("Ada").contains("Ada"),
                          "\(id) ignores the configured assistant name")
            XCTAssertFalse(copy("Ada").contains("Jax"),
                           "\(id) still carries the default assistant name alongside the configured one")
        }
    }

    // MARK: - Controls
    //
    // Every scan in this repo has, at least once, been green because it was
    // checking nothing. These prove the checks above can fail.

    func testTheFailureVocabularyCheckActuallyFires() {
        XCTAssertTrue(Self.containsWord("unreachable", in: "The registry is unreachable."),
                      "control: the failure check cannot see the word it exists to catch")
        XCTAssertFalse(Self.containsWord("nil", in: "Nothing here is broken."),
                       "control: word matching is not bounded, so ordinary prose would fail")
        XCTAssertFalse(Self.containsWord("error", in: "No terrorem here"),
                       "control: a substring inside another word must not count")
    }

    func testTheRosterIsNotVacuous() {
        XCTAssertGreaterThanOrEqual(Self.readableCopy.count, 11,
                                    "control: almost every surface should be audited by its words, "
                                    + "so a roster that is mostly exemptions proves nothing")
    }

    // MARK: - Vocabulary

    /// Words that mean SOMETHING WENT WRONG. None of them is true of a machine
    /// that is merely new.
    static let failureVocabulary = [
        "error", "failed", "failure", "unavailable", "unreachable",
        "invalid", "crash", "exception", "nil", "null", "undefined",
    ]

    /// Words that mean NOBODY FINISHED THIS.
    static let placeholderVocabulary = [
        "lorem", "ipsum", "coming soon", "todo", "tbd",
        "placeholder", "not implemented", "work in progress",
    ]

    /// Case-insensitive whole-word containment.
    ///
    /// Bounded, because the unbounded version of this check is how a guard ends
    /// up failing on correct code: "nil" sits inside plenty of ordinary words
    /// and "error" sits inside more, and a test that cries wolf gets muted by
    /// the next person rather than fixed.
    static func containsWord(_ word: String, in text: String) -> Bool {
        let hay = Array(text.lowercased())
        let needle = Array(word.lowercased())
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        var i = 0
        while i + needle.count <= hay.count {
            if Array(hay[i..<(i + needle.count)]) == needle {
                let beforeOK = i == 0 || !(hay[i - 1].isLetter || hay[i - 1].isNumber)
                let after = i + needle.count
                let afterOK = after >= hay.count || !(hay[after].isLetter || hay[after].isNumber)
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    /// The three states behind one pane must not share a sentence. Keying on
    /// the UNFILTERED store collapsed two of them: notes on disk plus a
    /// search matching none drew "Select a note" over an empty list, which is
    /// an instruction the reader cannot follow. Same rule DocumentLibraryView
    /// already holds for its filter.
    func testTheNotesDetailPaneSaysADifferentThingInEachOfItsThreeStates() {
        let firstRun = NotesView.emptyDetailCopy(hasNotes: false, hasMatches: false)
        let filtered = NotesView.emptyDetailCopy(hasNotes: true, hasMatches: false)
        let selectable = NotesView.emptyDetailCopy(hasNotes: true, hasMatches: true)

        XCTAssertEqual(Set([firstRun, filtered, selectable]).count, 3,
            "two of the three states share a sentence, so at least one reader is being "
            + "told to do something the pane in front of them cannot do")
        XCTAssertFalse(filtered.contains("Select a note"),
            "a search hiding every note told the reader to select one: \(filtered)")
        XCTAssertFalse(filtered.contains("No notes yet"),
            "a filter hiding notes claimed there are none, which sends the reader "
            + "looking for a bug instead of clearing the search: \(filtered)")
    }
}
