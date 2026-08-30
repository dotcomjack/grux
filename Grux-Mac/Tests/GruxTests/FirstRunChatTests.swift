import XCTest
import SwiftUI
@testable import Grux

/// The first minute of using Grux, which had no test coverage at all.
///
/// Chat is the default landing tab, so everything here is on the shortest path
/// between installing the app and forming an opinion of it.
@MainActor
final class FirstRunChatTests: XCTestCase {

    // MARK: - Suggestion chips

    /// THE BUG, pinned. Every chip the old empty state offered needed data a
    /// fresh install does not have, so the most inviting thing on screen was
    /// also the thing most likely to disappoint.
    ///
    /// Asserting the absence of the exact old strings is deliberate. A test that
    /// only checked "there are three chips" passes against the code that shipped
    /// the bug, which makes it decoration.
    func testFirstRunNeverOffersSomethingThatNeedsDataThatDoesNotExist() {
        let chips = ChatEmptyState.suggestions(isFirstRun: true, hasTasks: false)

        XCTAssertFalse(chips.contains("Roast my task stack"),
                       "the task stack is empty on a fresh install, so this roasts nothing")
        XCTAssertFalse(chips.contains("What should I work on?"),
                       "there are no projects or tasks yet, so there is nothing to rank")
        XCTAssertFalse(chips.contains("Plan today"),
                       "calendar permission is usually not granted yet, so this plans against nothing")
        XCTAssertFalse(chips.isEmpty, "a first run user must still be offered somewhere to start")
    }

    /// The other half, and the reason the first half is not simply "offer
    /// nothing": what IS offered has to move a new user toward operating.
    func testFirstRunOffersSomethingThatWorksWithNoDataAtAll() {
        let chips = ChatEmptyState.suggestions(isFirstRun: true, hasTasks: false)
        XCTAssertTrue(chips.contains(where: { $0.lowercased().contains("what can you") }),
                      "the likeliest first question a person types must be one tap away")
        XCTAssertTrue(chips.contains(where: { $0.lowercased().contains("set up") }),
                      "a new user needs a route into configuring the thing")
        XCTAssertTrue(chips.contains(where: { $0.lowercased().contains("project") }),
                      "and a route into doing real work, not just chatting")
    }

    /// The general rule, applied to the returning user too: a chip that cannot
    /// work is absent rather than disappointing.
    func testRoastIsOfferedOnlyWhenThereIsAStackToRoast() {
        XCTAssertFalse(ChatEmptyState.suggestions(isFirstRun: false, hasTasks: false)
                        .contains("Roast my task stack"),
                       "no tasks means no roast, even for a returning user")
        XCTAssertTrue(ChatEmptyState.suggestions(isFirstRun: false, hasTasks: true)
                        .contains("Roast my task stack"),
                      "with a real stack it is exactly the right offer")
    }

    /// Guards the case that produced the bug in the first place: a returning
    /// user whose stack happens to be empty is NOT a first run user, and used to
    /// get the same broken chip.
    func testReturningUserWithAnEmptyStackStillGetsWorkingSuggestions() {
        let chips = ChatEmptyState.suggestions(isFirstRun: false, hasTasks: false)
        XCTAssertFalse(chips.isEmpty)
        for chip in chips {
            XCTAssertNotEqual(chip, "Roast my task stack")
        }
    }

    // MARK: - What Grux can do

    /// THE OTHER GAP. The live system prompt described who Grux is across
    /// hundreds of words and never once said what Grux can DO, so the likeliest
    /// opening question had nothing behind it but the persona header.
    func testTheCapabilityBlockNamesRealSurfacesAndNotInventedOnes() {
        let block = FeatureRegistry.systemPromptBlock()

        // Same escape hatch the render tests use. Asserting on the shape of this
        // block is necessary and not sufficient: somebody has to be able to READ
        // the paragraph the model is actually handed.
        //     GRUX_SHOT_DIR=/tmp/x swift test --filter FirstRunChatTests
        if let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? block.write(to: URL(fileURLWithPath: dir).appendingPathComponent("capability-block.txt"),
                             atomically: true, encoding: .utf8)
        }

        XCTAssertFalse(block.isEmpty)
        XCTAssertTrue(block.contains("WHAT_YOU_CAN_DO"),
                      "the block needs a stable header the prompt can be reasoned about by")

        // POSITIVE CONTROL. Chat, Approvals and Task Stack have no blocking
        // requirements in the registry, so they are ready on ANY machine
        // including a bare CI runner. If the generator silently produced an
        // empty list, this fails, which is the point: a block that lists nothing
        // is worse than no block, because the model then believes it can do
        // nothing.
        XCTAssertTrue(block.contains("Task Stack"),
                      "a feature with zero blocking requirements must always be listed as ready")
        XCTAssertTrue(block.contains("WORKING RIGHT NOW"))

        // NEGATIVE CONTROL. Every name in the block has to come from the
        // registry. This catches a future hand-edit that adds a surface the app
        // does not have, which is exactly how an assistant starts promising
        // features that were cut.
        //
        // MATCHED BY PREFIX, NOT BY CLEANING SUFFIXES OFF. `systemPromptBlock`
        // composes a name as `label`, plus " (labs)" for a labs row, plus
        // " (home)" when the feature is not a tab of its own. The old version
        // stripped only " (labs)", so any row carrying a home hint could never
        // match, and one of those hints contains a comma besides.
        //
        // It passed here and failed on a clean runner, which is the part worth
        // keeping in mind. ONLY the pending lines start with "- ": ready rows
        // are comma-joined into a single line this loop never looked at. On a
        // machine where the mail, registrar and phone capabilities all resolve,
        // those three rows are ready and invisible to this check; on CI they are
        // pending, so they get "- " lines with their home hints and the
        // assertion fires. Measured 2026-08-23: three failures on GitHub
        // Actions, green locally, same commit.
        let known = FeatureRegistry.rows.map(\.label)
        func isReal(_ name: String) -> Bool {
            known.contains { name == $0 || name.hasPrefix($0 + " (") }
        }

        // CONTROL, and the reason this fix is provable HERE rather than only on
        // a runner where the right rows happen to be pending. Compose every name
        // the generator can emit, exactly as it composes them, and require the
        // matcher to accept all of them. Whichever rows are ready on this
        // machine is then irrelevant.
        for row in FeatureRegistry.rows {
            let labs = row.tier == .labs ? " (labs)" : ""
            let home = FeatureRegistry.homes[row.id].map { " (\($0))" } ?? ""
            XCTAssertTrue(isReal(row.label + labs + home),
                          "the matcher rejects a name the generator itself produces: "
                          + "\(row.label + labs + home)")
        }
        XCTAssertFalse(isReal("Telepathy"),
                       "control: an invented surface must still be rejected, or this proves nothing")
        XCTAssertFalse(isReal("Task"),
                       "control: a bare prefix of a real label is not a real surface")

        for line in block.split(separator: "\n") where line.hasPrefix("- ") {
            let name = line.dropFirst(2).split(separator: ":").first.map(String.init) ?? ""
            XCTAssertTrue(isReal(name),
                          "\(name) is named to the model but is not in the feature registry")
        }

        // AND THE READY HALF, which nothing checked. It is the half that is
        // populated on a developer's machine and empty-ish on a bare runner, so
        // between the two of them the loop above and this block cover the
        // registry wherever the test happens to run.
        let readyLine = block.split(separator: "\n").first { $0.hasPrefix("WORKING RIGHT NOW") }
        let ready = try? XCTUnwrap(readyLine, "the block lost its WORKING RIGHT NOW line")
        for row in FeatureRegistry.rows where FeatureRegistry.state(of: row) == .ready {
            XCTAssertTrue(ready?.contains(row.label) ?? false,
                          "\(row.label) resolves as ready but is not named in the ready line")
        }
    }

    /// Labs rows have to stay marked. A user is entitled to know which surfaces
    /// have unsanded edges before they rely on one, and the sidebar badge exists
    /// for that reason; the prompt should not quietly drop the distinction.
    func testLabsFeaturesStayLabelledInThePrompt() {
        let block = FeatureRegistry.systemPromptBlock()
        let labs = FeatureRegistry.rows.filter { $0.tier == .labs }
        XCTAssertFalse(labs.isEmpty, "the registry should carry labs rows; this test is vacuous otherwise")
        XCTAssertTrue(block.contains("(labs)"),
                      "labs rows must be marked so the model does not present them as finished")
    }

    /// The instruction is the half that makes the data useful. Without it the
    /// model has a list and no reason to prefer it over its own imagination.
    func testTheBlockTellsTheModelToAnswerFromItAndNotInvent() {
        let block = FeatureRegistry.systemPromptBlock()
        XCTAssertTrue(block.contains("Never claim a surface that is not named here"),
                      "a capability list with no instruction attached is a list the model may ignore")
    }

    /// EVERY FEATURE THE MODEL IS TOLD ABOUT MUST BE SOMEWHERE THE USER CAN GO.
    ///
    /// Five registry rows have no matching case in `LaunchRootView.Tab`, and the
    /// first version of the capability block listed all 39 as though each were a
    /// place you could open. A model reading that tells somebody to "go to
    /// Approvals" and there is no Approvals tab: it is a section inside Jax HQ.
    /// Misdirecting a user reads as the app being broken rather than the answer
    /// being wrong, which is the more expensive failure.
    func testEveryFeatureIsEitherATabOrSaysWhereItLives() throws {
        let lrv = try String(contentsOf: launchRootSource, encoding: .utf8)
        guard let range = lrv.range(of: #"enum Tab: Hashable \{ case [^}]+\}"#, options: .regularExpression) else {
            return XCTFail("could not find the Tab enum; the scan anchor moved")
        }
        let tabs = Set(lrv[range]
            .replacingOccurrences(of: "enum Tab: Hashable { case ", with: "")
            .replacingOccurrences(of: "}", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })

        // Control: the parse has to have found real cases, or every row below
        // looks like a non-tab and the test passes for the wrong reason.
        XCTAssertGreaterThan(tabs.count, 20, "control: the Tab enum parse found almost nothing")
        XCTAssertTrue(tabs.contains("chat"), "control: chat is a tab and the parse missed it")

        let reverseAlias = Dictionary(uniqueKeysWithValues:
            FeatureRegistry.tabAliases.map { ($0.value, $0.key) })

        var homeless: [String] = []
        for row in FeatureRegistry.rows {
            let tabKey = reverseAlias[row.id] ?? row.id
            if tabs.contains(tabKey) { continue }
            if FeatureRegistry.homes[row.id] != nil { continue }
            homeless.append("\(row.id) (\(row.label))")
        }
        XCTAssertEqual(homeless, [],
                       "these are named to the model but are not tabs and do not say where they live, so it "
                       + "will send users to a tab that does not exist: \(homeless.joined(separator: ", "))")

        // And the other direction, so the table cannot describe rows that are
        // now real tabs.
        let stale = FeatureRegistry.homes.keys.filter { id in
            tabs.contains(reverseAlias[id] ?? id)
        }.sorted()
        XCTAssertEqual(stale, [],
                       "these have a stated home but ARE tabs now, so the annotation is wrong: \(stale.joined(separator: ", "))")
    }

    private var launchRootSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/LaunchRootView.swift")
    }

    // MARK: - Never promise a feature that is switched off

    /// The returning-user blurb told EVERY user to say "hey grux" from
    /// anywhere. `config.wakeWordEnabled` ships FALSE, and measured 2026-08-22
    /// the wake word is named ZERO times in the entire onboarding flow, so the
    /// app instructed people to use a feature that was off and that nobody had
    /// ever told them existed.
    ///
    /// Same rule as the suggestion chips one screen up: never offer, or
    /// instruct, something that cannot work right now.
    func testTheBlurbNeverTellsYouToSayAWakeWordThatIsOff() {
        let off = ChatEmptyState.blurb(isFirstRun: false, wakeWordOn: false)
        XCTAssertFalse(off.lowercased().contains("hey grux"),
                       "the wake word ships off, so telling the user to say it is an instruction that fails")
        XCTAssertFalse(off.isEmpty)

        let on = ChatEmptyState.blurb(isFirstRun: false, wakeWordOn: true)
        XCTAssertTrue(on.lowercased().contains("hey grux"),
                      "with the listener actually running it is the most useful thing to tell them")
    }

    /// THE HALF THE FIRST FIX MISSED. `wakeWordOn` is documented as "whether the
    /// wake word listener is actually running" and the view handed it
    /// `state.config.wakeWordEnabled`, which is only the SAVED PREFERENCE.
    ///
    /// The app pulls those two apart itself, in two ordinary situations:
    ///
    ///   - `AmbientState.enable()` in focus mode calls
    ///     `WakeWordListener.shared.stop()` and takes the microphone, and never
    ///     touches `wakeWordEnabled`;
    ///   - `MicController` stops both listeners when the user mutes the orb,
    ///     same thing.
    ///
    /// In either state Grux told the user to say "hey grux" at a listener that
    /// was not running. That is precisely the "never instruct something that
    /// cannot work right now" failure this empty state was rebuilt to remove,
    /// reached by a different route, which is how the first fix passed its own
    /// tests while still shipping the bug.
    func testTheEmptyStateReadsTheLiveListenerAndNotTheSavedPreference() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chatView = try String(
            contentsOf: root.appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)

        XCTAssertTrue(chatView.contains("ChatEmptyState("),
                      "ChatView no longer builds a ChatEmptyState, so this test is stale")

        // The argument itself, not a fixed-size window around the call. A window
        // measures how long the comment above the line happens to be, which is
        // not a fact about the wiring.
        let args = chatView.components(separatedBy: "\n").filter { $0.contains("wakeWordOn:") }
        XCTAssertEqual(args.count, 1, "expected exactly one wakeWordOn call site, found \(args.count)")

        XCTAssertTrue(args.first?.contains("wake.isListening") ?? false,
                      "the empty state must be handed the LIVE listener state. Got: \(args)")
        XCTAssertFalse(chatView.contains("wakeWordOn: state.config.wakeWordEnabled"),
                       "wakeWordEnabled is the saved preference, not whether anything is listening")
    }

    /// The control for the test above, so it is not asserting on a spelling.
    /// The preference and the listener really are two independent facts, and
    /// this proves it at runtime: the test host has never started a listener,
    /// and the preference can be true anyway.
    func testThePreferenceAndTheListenerAreGenuinelyDifferentFacts() {
        let saved = AppState.shared.config.wakeWordEnabled
        defer { AppState.shared.config.wakeWordEnabled = saved }
        AppState.shared.config.wakeWordEnabled = true

        XCTAssertFalse(WakeWordListener.shared.isListening,
                       "control: nothing has started the listener in this process")
        XCTAssertTrue(AppState.shared.config.wakeWordEnabled,
                      "control: and the preference is on, so the two disagree")

        // The sentence a user in this state must be shown is the one with no
        // wake word in it, and it is the LISTENER that decides.
        let shown = ChatEmptyState.blurb(isFirstRun: false,
                                         wakeWordOn: WakeWordListener.shared.isListening)
        XCTAssertFalse(shown.lowercased().contains("hey grux"),
                       "with the listener stopped the copy still promised the wake word")
    }

    /// The listener stop that creates the divergence is real and in production,
    /// not a hypothetical. Focus-mode ambient takes the microphone and stops the
    /// wake listener without clearing the preference.
    func testAmbientFocusModeReallyStopsTheListenerWithoutClearingThePreference() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ambient = try String(
            contentsOf: root.appendingPathComponent("Sources/Grux/Ambient/AmbientState.swift"),
            encoding: .utf8)

        XCTAssertTrue(ambient.contains("WakeWordListener.shared.stop()"),
                      "control: ambient mode no longer stops the wake listener, so the divergence "
                      + "this fix is about would no longer exist and these tests need revisiting")
        XCTAssertFalse(ambient.contains("config.wakeWordEnabled = false"),
                       "control: if ambient cleared the preference the two facts would agree")
    }

    /// THE COPY AND THE MATCHER ARE CHECKED AGAINST EACH OTHER, not against
    /// somebody's memory of what the wake word is.
    ///
    /// The previous version of this test asserted the OPPOSITE and passed: that
    /// the phrase follows `assistantName`. It was wrong, and it was wrong in the
    /// most expensive way, because a green test said the bug was the intended
    /// behaviour. `WakeWordListener`'s regex matches "gr" plus vowels and never
    /// reads the assistant's name, and `assistantName` defaults to "Jax", so the
    /// copy told EVERY user out of the box to say "hey jax" at a listener that
    /// could not hear it.
    ///
    /// Taking the phrase out of the rendered sentence and feeding it to the real
    /// matcher is the only version of this that cannot drift.
    func testTheWakePhraseInTheCopyActuallyFiresTheRealMatcher() throws {
        let blurb = ChatEmptyState.blurb(isFirstRun: false, wakeWordOn: true)
        let quoted = blurb.split(separator: "\"")
        let phrase = try XCTUnwrap(quoted.first(where: { WakeWordListener.wouldTrigger(String($0)) }),
                                   "no quoted phrase in the blurb fires the wake word matcher: \(blurb)")
        XCTAssertTrue(WakeWordListener.wouldTrigger(String(phrase)))
    }

    /// The bug itself, pinned. If the copy ever goes back to the assistant's
    /// name, this fails.
    ///
    /// It now drives the REAL name, `AppState.shared.config.assistantName`,
    /// rather than a parameter. The parameter version passed for a reason that
    /// was not the reason it claimed: `blurb` ignored `assistantName` in all
    /// three branches, so the test was feeding a string into a hole and
    /// asserting the string did not come out the other side. Removing the dead
    /// parameter took that false comfort with it, so the assertion had to be
    /// re-pointed at the path a renamed assistant actually travels.
    func testTheWakePhraseIsNotTheAssistantsName() {
        let saved = AppState.shared.config.assistantName
        defer { AppState.shared.config.assistantName = saved }

        for name in ["Jax", "Ada", "Hal"] {
            AppState.shared.config.assistantName = name
            XCTAssertEqual(UserIdentity.assistantName, name, "control: the rename did not take")

            let blurb = ChatEmptyState.blurb(isFirstRun: false, wakeWordOn: true)
            XCTAssertFalse(blurb.lowercased().contains("hey \(name.lowercased())"),
                           "the copy tells the user to say \"hey \(name)\", and the matcher cannot hear it")
            XCTAssertTrue(blurb.contains(WakeWordListener.spokenPhrase),
                          "renaming the assistant must not change the phrase, which is the app's name")
        }
    }

    /// And the name is no longer even IN SCOPE where the wake phrase is written.
    ///
    /// `assistantName` was threaded from `ChatView` into `ChatEmptyState` and on
    /// into `blurb`, and read by nothing: every branch ignored it. That is worse
    /// than ordinary dead weight. The phrase is composed in that exact function,
    /// and the assistant's name was sitting right there in scope, which is how
    /// "hey jax" got written the first time. Taking it out of the room is what
    /// stops the next editor reaching for it.
    func testTheAssistantsNameIsNotInScopeWhereTheWakePhraseIsWritten() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Grux/Chat/ChatEmptyState.swift"),
            encoding: .utf8)

        // Comments MAY name it: the doc comment records why the phrase is the
        // app's and not the assistant's, and that history is the reason the
        // rule holds. Only executable lines are the subject here.
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("assistantName"),
                       "the assistant's name is back in the file that writes the wake phrase")
    }

    /// And the matcher really is the narrow thing this depends on, so the test
    /// above is not passing for an accidental reason.
    func testTheMatcherHearsTheAppNameAndNotAnAssistantName() {
        XCTAssertTrue(WakeWordListener.wouldTrigger("hey grux"), "control: the real phrase must fire")
        XCTAssertTrue(WakeWordListener.wouldTrigger("hey groks"), "control: documented mishearings must fire")
        XCTAssertFalse(WakeWordListener.wouldTrigger("hey jax"),
                       "control: the DEFAULT assistant name must not fire, which is the whole bug")
        XCTAssertFalse(WakeWordListener.wouldTrigger("hey ada"), "control: nor a renamed one")
    }

    /// The leak the first version of this fix left open. A user whose tasks are
    /// ALL COMPLETED has a non-empty `tasks` array and an empty `activeTasks`
    /// one. The chip logic read the former and the model is handed the latter,
    /// so they were offered "Roast my task stack" against a stack the model sees
    /// as "(empty)": the exact shrug this change exists to prevent, reached by a
    /// different route.
    ///
    /// Asserted at the boundary the view actually passes, since `suggestions` is
    /// pure and cannot see AppState: what matters is that "has tasks" means
    /// "has ACTIVE tasks".
    func testAStackOfOnlyCompletedTasksIsNotAStackToRoast() {
        let chips = ChatEmptyState.suggestions(isFirstRun: false, hasTasks: false)
        XCTAssertFalse(chips.contains("Roast my task stack"),
                       "with nothing active there is nothing to roast, however many completed rows exist")

        let source = try? String(contentsOf: chatViewSource, encoding: .utf8)
        XCTAssertNotNil(source)
        XCTAssertTrue(source?.contains("hasTasks: !state.activeTasks.isEmpty") ?? false,
                      "ChatView must pass ACTIVE tasks; state.tasks includes completed ones and the model never sees those")
        XCTAssertFalse(source?.contains("hasTasks: !state.tasks.isEmpty") ?? true,
                       "the raw tasks array counts completed rows the model is never shown")
    }

    private var chatViewSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatView.swift")
    }

    // MARK: - The name the user gave us

    /// ONBOARDING ASKS FOR A NAME ON SCREEN TWO AND THE CHAT NEVER LEARNED IT.
    ///
    /// `UserIdentity.systemPromptLine()` was written for exactly this, and
    /// `JaxProfile`'s own comment states that the user's name "enters the prompt
    /// once via UserIdentity.systemPromptLine()". It did not. The only caller in
    /// the entire tree was the cold email composer, so a person typed their name
    /// into the second screen of first run and Grux never once used it.
    ///
    /// `OnboardingModel` moved identity ahead of the model key specifically
    /// because "it makes every screen after it address them by name instead of
    /// nobody", so the missing wire cost that step most of its point.
    ///
    /// A SOURCE SCAN rather than a prompt assertion, and that is a real
    /// tradeoff rather than laziness: the builder is private and needs a live
    /// `AppState`, so the alternative is no coverage at all. It catches the
    /// exact regression that happened here, which is the wiring silently absent
    /// while a doc comment claims it is present.
    func testTheUsersNameActuallyReachesTheChatPrompt() throws {
        let src = try String(contentsOf: chatServiceSource, encoding: .utf8)

        // CONTROL, both directions. A reader that silently returned the wrong
        // file, or an empty string, would make every assertion below pass.
        XCTAssertTrue(src.contains("private func buildSystemBlocks"),
                      "control: this is not ChatService.swift, so the rest of this test is meaningless")
        XCTAssertFalse(src.contains("thisStringIsNotInChatService"),
                       "control: the reader claims to find text that is not there")

        XCTAssertTrue(src.contains("UserIdentity.systemPromptLine()"),
                      "the chat prompt must read the name onboarding collected")
        XCTAssertTrue(src.contains("\\(identityLine)"),
                      "reading the name is not enough, it has to be interpolated into the stable block")
    }

    /// The other half: an unnamed user must add NOTHING rather than a
    /// placeholder. "The user's name is ." is worse than silence.
    func testAnUnsetNameContributesNothingToThePrompt() {
        // Exercises the real accessor rather than restating its implementation.
        let line = UserIdentity.systemPromptLine()
        if UserIdentity.hasName {
            XCTAssertTrue(line.contains(UserIdentity.name))
            XCTAssertFalse(line.isEmpty)
        } else {
            XCTAssertTrue(line.isEmpty,
                          "with no name set the prompt must not carry a naming sentence at all")
        }
    }

    private var chatServiceSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift")
    }

    // MARK: - Render

    /// Renders both states so somebody can LOOK at the first sentence Grux says.
    ///
    ///     GRUX_SHOT_DIR=/tmp/chat swift test --filter FirstRunChatTests
    func testEmptyStateRenders() {
        for (name, view) in [
            ("firstRun", ChatEmptyState(isFirstRun: true, hasTasks: false,
                                        wakeWordOn: false, onPick: { _ in })),
            ("returning", ChatEmptyState(isFirstRun: false, hasTasks: true,
                                         wakeWordOn: false, onPick: { _ in })),
            ("returningEmptyStack", ChatEmptyState(isFirstRun: false, hasTasks: false,
                                                   wakeWordOn: false, onPick: { _ in })),
            // The state the wake-word wiring fix is about: a listener that is
            // genuinely running, which is the only time the phrase is offered.
            ("returningWakeListening", ChatEmptyState(isFirstRun: false, hasTasks: true,
                                                      wakeWordOn: true, onPick: { _ in }))
        ] {
            // The 840pt window floor, minus the sidebar rail, is roughly the
            // width the chat pane actually gets. Rendering at the full window
            // width would measure a layout no user ever sees.
            for (label, size) in [("560x360", CGSize(width: 560, height: 360)),
                                  ("1600x500", CGSize(width: 1600, height: 500))] {
                let wrapped = ZStack {
                    GruxTheme.base
                    view.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: size.width, height: size.height)
                .tint(GruxTheme.accentPrimary)

                let host = NSHostingView(rootView: wrapped)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.height, 0, "\(name) at \(label) produced no layout")

                guard let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"],
                      let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: dir)
                    .appendingPathComponent("chat-\(name)-\(label).png"))
            }
        }
    }
}
