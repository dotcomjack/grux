import XCTest
@testable import Grux

/// Acceptance criterion 5: level selection works, and every skipped step is
/// re-offered in context.
///
/// Everything here is asserted against PURE functions, and that constraint
/// shaped the code rather than the other way round. `OnboardingModel` is a
/// singleton whose every transition persists to
/// `~/Library/Application Support/Grux/onboarding.json`, which is the owner's
/// own install state. Driving the real flow to prove it works would rewrite that
/// file as a side effect of testing, so the decisions were lifted out into
/// `stages(for:)`, `stage(after:at:)` and `connectionOrder`, and the mutating
/// methods became the thin part that applies them.
@MainActor
final class OnboardingLevelTests: XCTestCase {

    private typealias Level = OnboardingModel.Level
    private typealias Stage = OnboardingModel.Stage

    // MARK: - The levels differ, which is the entire point

    /// Level 1 is a working Grux and nothing else. If this ever includes a
    /// permission screen then the level meant nothing.
    func testLevelOneAsksForNoPermissionsAndNoAccounts() {
        let flow = OnboardingModel.stages(for: .essentials)

        // Identity moved ahead of the model key on 2026-08-17: asking who somebody
        // is should come before asking them to paste a credential.
        XCTAssertEqual(flow, [.level, .identity, .modelKey, .howItWorks, .update, .done])
        XCTAssertFalse(flow.contains(.permissions), "Level 1 must not ask for permissions")
        XCTAssertFalse(flow.contains(.connections), "Level 1 must not ask for accounts")
        // The first look needs Screen Recording, so it belongs with permissions.
        XCTAssertFalse(flow.contains(.firstLook))
    }

    func testLevelTwoAddsPermissionsButNotAccounts() {
        let flow = OnboardingModel.stages(for: .plusPermissions)

        XCTAssertTrue(flow.contains(.permissions))
        XCTAssertTrue(flow.contains(.firstLook))
        XCTAssertFalse(flow.contains(.connections), "accounts are Level 3")
    }

    func testLevelThreeAddsAccounts() {
        let flow = OnboardingModel.stages(for: .everything)

        XCTAssertTrue(flow.contains(.permissions))
        XCTAssertTrue(flow.contains(.connections))
    }

    /// Each level is a strict superset of the one below. If a level ever DROPS a
    /// stage that a lower level runs, "1, then 1 and 2, then 1 2 and 3" has
    /// stopped being true and the first screen is lying about what it offers.
    func testEachLevelContainsEverythingTheLevelBelowDoes() {
        let one = OnboardingModel.stages(for: .essentials)
        let two = OnboardingModel.stages(for: .plusPermissions)
        let three = OnboardingModel.stages(for: .everything)

        for stage in one { XCTAssertTrue(two.contains(stage), "\(stage) lost at Level 2") }
        for stage in two { XCTAssertTrue(three.contains(stage), "\(stage) lost at Level 3") }
        XCTAssertGreaterThan(two.count, one.count)
        XCTAssertGreaterThan(three.count, two.count)
    }

    // MARK: - Ordering that the flow depends on

    /// The first look captures a frame, so Screen Recording has to have been
    /// offered first. Reversed, the privacy demo is a demo of a black rectangle.
    func testPermissionsComeBeforeTheFirstLook() {
        for level in [Level.plusPermissions, .everything] {
            let flow = OnboardingModel.stages(for: level)
            let perms = flow.firstIndex(of: .permissions)
            let look = flow.firstIndex(of: .firstLook)
            XCTAssertNotNil(perms)
            XCTAssertNotNil(look)
            XCTAssertLessThan(perms!, look!, "at \(level)")
        }
    }

    /// Every flow starts by asking which flow this is, and ends at done.
    func testEveryLevelStartsWithTheChoiceAndEndsDone() {
        for level in Level.allCases {
            let flow = OnboardingModel.stages(for: level)
            XCTAssertEqual(flow.first, .level, "at \(level)")
            XCTAssertEqual(flow.last, .done, "at \(level)")
            XCTAssertEqual(Set(flow).count, flow.count, "a stage repeats at \(level)")
        }
    }

    // MARK: - Advancing cannot land on a stage the level excluded

    /// The property that makes level selection real rather than decorative:
    /// walking the flow from the start must never arrive at a screen this level
    /// did not ask for, and must terminate.
    func testWalkingTheFlowNeverReachesAnExcludedStage() {
        for level in Level.allCases {
            let allowed = Set(OnboardingModel.stages(for: level))
            var seen: [Stage] = [.level]
            var current = Stage.level
            var guardCount = 0

            while let next = OnboardingModel.stage(after: current, at: level) {
                XCTAssertTrue(allowed.contains(next),
                              "\(level) reached \(next), which its own flow excludes")
                seen.append(next)
                current = next
                guardCount += 1
                XCTAssertLessThan(guardCount, 50, "the flow does not terminate at \(level)")
                if guardCount >= 50 { break }
            }

            XCTAssertEqual(current, .done, "\(level) did not end at done")
            XCTAssertEqual(seen, OnboardingModel.stages(for: level))
        }
    }

    /// Level 1 must not be able to reach the permission screen even if something
    /// asks it to advance from there. This is the defensive half: `advance` is
    /// called from views, and a view for an excluded stage should never be on
    /// screen, but a wrong answer here would strand the user rather than skip.
    func testAdvancingFromAnExcludedStageDoesNotContinueTheFlow() {
        XCTAssertNil(OnboardingModel.stage(after: .permissions, at: .essentials),
                     "Level 1 has no permissions stage, so there is nothing after it")
        XCTAssertNil(OnboardingModel.stage(after: .connections, at: .plusPermissions))
    }

    // MARK: - The inbox is last

    /// "Offer an inbox as the LAST skippable step of onboarding." The inbox
    /// wants a server, an address and an app password, which is minutes of
    /// somebody else's website, so anywhere but last means the people who stall
    /// on it never reach the connections that take five seconds.
    func testInboxIsTheLastConnectionOffered() {
        XCTAssertEqual(OnboardingModel.connectionOrder.last, .endpointImap,
                       "got \(OnboardingModel.connectionOrder.map(\.rawValue))")
    }

    /// The inbox is the last thing ASKED FOR, which is not the same as the last
    /// screen. `update` runs after it at every level and requests nothing: it
    /// reports what Grux found on the machine. Asserting connections is simply
    /// last would have forbidden any closing screen, however passive.
    func testConnectionsIsTheLastStageThatAsksForAnything() {
        let flow = OnboardingModel.stages(for: .everything)
        let asking = flow.filter { $0 != .update && $0 != .done }

        XCTAssertEqual(asking.last, .connections,
                       "the inbox lives at the end of connections, so this is what makes it "
                       + "the last ask in the whole flow")
        XCTAssertEqual(flow.dropLast().last, .update, "the update phase closes every flow")
    }

    /// Every level ends with the update phase, including the one minute path.
    /// Somebody who chose Level 1 skipped the screens where local models might
    /// have come up, so they need this more, not less.
    func testEveryLevelEndsWithTheUpdatePhase() {
        for level in Level.allCases {
            let flow = OnboardingModel.stages(for: level)
            XCTAssertEqual(flow.dropLast().last, .update, "at \(level)")
        }
    }

    // MARK: - Copy that matches the screen it is on

    /// A row with a paste field must not tell the reader to go to Settings.
    ///
    /// This shipped once and was caught by looking at a render: the Slack row
    /// read "Connect Slack in Settings so Grux can read and post in your
    /// workspace" directly above the box that takes the token. The contract
    /// remediations are written for the setup card, where "in Settings" is
    /// exactly right, and reusing them on a screen that already has the field is
    /// how one correct sentence becomes a wrong one.
    func testConnectionsWithAFieldDoNotSendTheReaderToSettings() {
        for req in OnboardingModel.connectionOrder where req.kind == .key {
            let purpose = OnboardingModel.connectionPurpose(for: req)
            XCTAssertFalse(purpose.contains("in Settings"),
                           "\(req.rawValue) has a paste field on this screen, so telling the "
                           + "reader to go to Settings sends them away from it; got '\(purpose)'")
            XCTAssertFalse(purpose.isEmpty)
        }
    }

    /// GitHub is not offered, and the reason is a measurement rather than an
    /// opinion. Nothing in the codebase calls the GitHub API, reads the
    /// `gitHubToken` Keychain slot outside the resolver, or reads
    /// `grux.github.repos`. Offering a personal access token that nothing will
    /// ever read is a real cost with no benefit on the other side of it.
    ///
    /// This test is the tripwire for putting it back: whoever ships a GitHub
    /// feature should add the row, add the capability here, and delete this.
    func testGithubIsNotOfferedWhileNothingConsumesIt() {
        XCTAssertFalse(OnboardingModel.connectionOrder.contains(.keyGithub),
                       "nothing in Grux reads a GitHub token, so onboarding must not ask for one")
    }

    /// The endpoints keep the contract's sentence, because they have no inline
    /// field and the instruction really is what to do. If one ever gains a
    /// field, the test above should start covering it.
    func testEndpointConnectionsStillUseTheContractSentence() {
        for req in OnboardingModel.connectionOrder where req.kind == .endpoint {
            XCTAssertEqual(OnboardingModel.connectionPurpose(for: req), req.rationale,
                           "\(req.rawValue)")
        }
    }

    // MARK: - Every skipped step has somewhere to be re-offered

    /// The second half of criterion 5, and it is a real constraint rather than a
    /// restatement: onboarding must not offer something it can never raise
    /// again. A step that can be skipped into permanent silence is worse than
    /// one that was never offered, because the user remembers declining it and
    /// then cannot find it.
    ///
    /// There are exactly two re-offer surfaces and a capability needs one of
    /// them:
    ///
    ///  - a feature registry row, so the tab renders the setup card, which is
    ///    the "in context" case the decision asks for;
    ///  - the generated Settings credentials section, which covers every
    ///    `key.*` whether or not a feature consumes it.
    ///
    /// The distinction is not academic. `key.github` is offered during
    /// onboarding and is in NO registry row, so it has no tab and the first
    /// version of this test called it a hole. It is not: it is a credential, it
    /// has a generated field, and that field now says "skipped in setup". What
    /// would be a genuine hole is a `perm.*` or `endpoint.*` with neither.
    func testEveryOfferedCapabilityCanBeReOffered() {
        var offered = CapabilityRequest.onboardingOrder
        offered += OnboardingModel.connectionOrder
        offered.append(.stepFirstFrameReviewed)

        let inARegistryRow = Set(FeatureRegistry.rows.flatMap {
            $0.requires + $0.optional + $0.steps + $0.optionalSteps
        })

        for req in offered {
            // Credentials always have a generated Settings field.
            let hasCredentialField = req.kind == .key
                && CapabilityResolver.keychainKey(for: req) != nil
            let hasTab = inARegistryRow.contains(req)

            XCTAssertTrue(hasTab || hasCredentialField,
                          "\(req.rawValue) is offered during onboarding but no feature uses it "
                          + "and it has no credentials field, so skipping it would silence it "
                          + "permanently")
        }
    }

    /// Anything offered that is NOT a credential must be in a registry row,
    /// because Settings has no generated field for it. This is the assertion
    /// that would actually catch the failure the test above describes.
    func testOfferedPermissionsAndEndpointsAllBelongToAFeature() {
        let inARegistryRow = Set(FeatureRegistry.rows.flatMap {
            $0.requires + $0.optional + $0.steps + $0.optionalSteps
        })
        var offered = CapabilityRequest.onboardingOrder
        offered += OnboardingModel.connectionOrder
        offered.append(.stepFirstFrameReviewed)

        for req in offered where req.kind != .key {
            XCTAssertTrue(inARegistryRow.contains(req),
                          "\(req.rawValue) has no credentials field, so a feature must claim it "
                          + "or it can never be re-offered after a skip")
        }
    }

    // MARK: - Persisted shape

    /// Every field survives a save and load. The bug this replaces built
    /// `State(stage: stage)` and let the other three take defaults, silently
    /// resetting a recorded skip on the next transition.
    func testStateRoundTripsEveryField() throws {
        let original = OnboardingModel.State(
            stage: .connections,
            skippedFirstLook: true,
            level: .everything,
            skipped: ["perm.contacts", "endpoint.imap"])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OnboardingModel.State.self, from: data)

        XCTAssertEqual(decoded.stage, .connections)
        XCTAssertTrue(decoded.skippedFirstLook)
        XCTAssertEqual(decoded.level, .everything)
        XCTAssertEqual(decoded.skipped, ["perm.contacts", "endpoint.imap"])
    }

    /// An install written before levels existed ran what is now Levels 1 and 2.
    /// Decoding it as Level 1 would tell that user they had declined permissions
    /// they were never given a choice about, and would then suppress the
    /// permission screens on any re-run.
    func testAnInstallFromBeforeLevelsDecodesAsLevelsOneAndTwo() throws {
        let legacy = #"{"stage":"firstLook","skippedFirstLook":true}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OnboardingModel.State.self, from: legacy)

        XCTAssertEqual(decoded.level, .plusPermissions,
                       "the old flow included permissions and the first look")
        XCTAssertEqual(decoded.stage, .firstLook, "an in-flight user resumes where they were")
        XCTAssertTrue(decoded.skippedFirstLook)
        XCTAssertTrue(decoded.skipped.isEmpty)
    }

    /// The clone step learns the user's voice from their own iMessages and
    /// Apple Notes, which are exactly what Full Disk Access and Automation
    /// unlock. So it belongs with the permission block and cannot exist at a
    /// level that grants none: there it could only ever say "nothing readable",
    /// which is a worse screen than no screen.
    func testTheCloneStepRunsWithPermissionsAndNotAtLevelOne() {
        let one = OnboardingModel.stages(for: .essentials)
        let two = OnboardingModel.stages(for: .plusPermissions)
        let three = OnboardingModel.stages(for: .everything)

        XCTAssertFalse(one.contains(.clone),
                       "Level 1 grants no permissions, so the clone would have nothing to read")
        XCTAssertTrue(two.contains(.clone))
        XCTAssertTrue(three.contains(.clone))

        // Order matters: the sources it reads are unlocked by the screen before
        // it. Reversed, every source reports itself unavailable.
        for flow in [two, three] {
            guard let p = flow.firstIndex(of: .permissions),
                  let c = flow.firstIndex(of: .clone) else {
                return XCTFail("permissions and clone must both be present")
            }
            XCTAssertLessThan(p, c, "permissions must come before the clone step")
        }

        // Connections still ends the asking at Level 3, which is a promise the
        // first screen makes about the inbox being the last thing requested.
        if let c = three.firstIndex(of: .clone), let n = three.firstIndex(of: .connections) {
            XCTAssertLessThan(c, n, "the inbox stays the last ask")
        }
    }

    /// Stage rawValues are a storage format. Renaming one orphans anybody who
    /// quit on that screen, so the strings are pinned here.
    func testStageRawValuesArePinned() {
        // "clone" added 2026-08-22. APPENDING a case is safe for anyone
        // mid-flow, because nothing they could have persisted refers to it;
        // renaming or reordering an existing one is what orphans them, and that
        // is what this assertion is really guarding.
        XCTAssertEqual(Stage.allCases.map(\.rawValue),
                       ["level", "modelKey", "identity", "howItWorks",
                        "permissions", "firstLook", "clone", "connections",
                        "update", "done", "welcomeBack"])
        XCTAssertEqual(Level.allCases.map(\.rawValue),
                       ["essentials", "plusPermissions", "everything"])
    }
}

/// What the clone step does to the flow and to the setup contract.
///
/// The screen's two buttons are the whole feature: one records a decision and
/// starts work, the other records a decision and starts none. Both must leave
/// onboarding somewhere sensible, and a step that advanced to the wrong stage
/// would strand a user in a flow they cannot finish.
@MainActor
final class CloneStepFlowTests: XCTestCase {
    private typealias Stage = OnboardingModel.Stage

    /// Anti-vacuity: if the stage is ever removed, every assertion below passes
    /// by being unreachable rather than by being true.
    func testTheCloneStageExists() {
        XCTAssertTrue(Stage.allCases.contains(.clone))
        XCTAssertEqual(Stage.clone.rawValue, "clone")
    }

    func testAdvancingFromCloneLandsOnTheRightNextStage() {
        // Level 2 has no accounts screen, so the clone is the last ASK and the
        // model report follows it.
        XCTAssertEqual(OnboardingModel.stage(after: .clone, at: .plusPermissions), .update)
        // Level 3 still ends its asking with the inbox.
        XCTAssertEqual(OnboardingModel.stage(after: .clone, at: .everything), .connections)
    }

    /// Whichever button is pressed, the flow continues. A dead end here is a
    /// user who cannot finish setup.
    func testCloneIsNeverTheLastStage() {
        for level in [OnboardingModel.Level.plusPermissions, .everything] {
            let flow = OnboardingModel.stages(for: level)
            guard let i = flow.firstIndex(of: .clone) else {
                return XCTFail("clone missing at \(level)")
            }
            XCTAssertLessThan(i, flow.count - 1, "clone must never be the final stage at \(level)")
            XCTAssertEqual(flow.last, .done)
        }
    }

    /// The step is backed by a real setup requirement, which is what lets the
    /// capability system re-offer it in context after a skip instead of either
    /// nagging or silently dropping it.
    func testTheStepIsBackedByASetupRequirement() {
        XCTAssertEqual(SetupRequirement.stepCorpusSourcesConfirmed.kind, .step,
                       "the clone step records a step, not a key or a permission")
        XCTAssertFalse(SetupRequirement.stepCorpusSourcesConfirmed.label.isEmpty)
    }
}
