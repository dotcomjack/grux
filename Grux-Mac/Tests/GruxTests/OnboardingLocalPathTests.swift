import XCTest
@testable import Grux

/// THE FREE PATH THE PROJECT LEADS WITH WAS UNREACHABLE ON A FIRST RUN.
///
/// The README's first paragraph reads "It talks to a model you pay for directly,
/// or to a local model with no key at all", and further down, "If you would
/// rather not send anything to a hosted model at all, install Ollama, pull a
/// model, and Grux will use it." Somebody who did exactly that, and nothing
/// else, could not get past screen three of onboarding:
///
///   1. Continue was disabled while the key field was empty.
///   2. `submit()` required `validate(key:)`, which POSTs to api.anthropic.com.
///   3. The only other way out required `KeychainStore.exists(.anthropicApiKey)`,
///      which is false for exactly this user.
///
/// The flow's own doc comment called that block deliberate, on the grounds that
/// "with no key there is no Grux to leave the flow into". Their Grux worked. The
/// gate was measuring the wrong thing: not whether a model was attached, but
/// whether a particular credential had been bought.
///
/// ## Why these tests are shaped the way they are
///
/// PURE SEAMS, NOT THE REAL KEYCHAIN. `CapabilityResolver.isSatisfied` reads the
/// live Keychain and `ChatReadiness.current()` reads the discovered backend, so
/// on a machine that already has credentials, which includes every machine this
/// is developed on, a test of either can only ever observe the answer that
/// machine happens to give. This repository has been bitten by that exact thing:
/// three `DomainMonitorTests` skip themselves on a configured machine, and an
/// honest skip still leaves the rule unverified. So the rules are driven through
/// `ChatReadiness.evaluate`, `CapabilityResolver.keyIsSatisfied` and
/// `FeatureRegistry.unmetBlocking(of:satisfied:)`, which take the facts as
/// arguments and can therefore be put in states this Mac can never be in.
///
/// THE STAGE IS NEVER DRIVEN. `OnboardingModel.completeModelKey()` persists to
/// the operator's own `onboarding.json`, so a test that called it to prove the
/// gate can be left would rewrite somebody's install state as a side effect of
/// asserting. `OnboardingRenderTests` already records that trap. The transition
/// is checked through the pure `stage(after:at:)` instead, and the branch that
/// reaches it is checked by reading the source, which is the same instrument
/// `ChatReadinessRoutingTests` and `NoTerminalInstructionsInUITests` use for
/// claims about a code path no test can safely execute.
@MainActor
final class OnboardingLocalPathTests: XCTestCase {

    // MARK: - Source access

    private func onboardingViewSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac, the package root
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"),
            encoding: .utf8)
    }

    /// The body of `useLocalModel()`, from its signature to the next declaration
    /// at the same indentation. Extracted rather than searched whole-file,
    /// because a whole-file `contains` would happily pass on a `KeychainStore`
    /// call that lives in `submit()`, which is the one place a write belongs.
    private func useLocalModelBody() throws -> String {
        let src = try onboardingViewSource()
        guard let start = src.range(of: "private func useLocalModel()") else {
            XCTFail("""
                `useLocalModel()` is gone from ModelKeyStep. If the local path was \
                renamed, retarget these tests. If it was REMOVED, the first-run flow \
                has gone back to demanding an Anthropic API key from a user who \
                followed the README and needs none.
                """)
            return ""
        }
        let rest = src[start.lowerBound...]
        guard let end = rest.range(of: "\n    private func ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// Control. If the scan cannot find the file, every assertion below passes on
    /// an empty string, which is the same vacuous shape as a suite that collects
    /// zero tests and exits 0.
    func testTheScanReachesTheFlow() throws {
        let src = try onboardingViewSource()
        XCTAssertTrue(src.contains("struct ModelKeyStep"),
                      "did not find ModelKeyStep in the onboarding flow source")
        XCTAssertGreaterThan(try useLocalModelBody().count, 100,
                             "extracted an implausibly short useLocalModel body, the scan is broken")
    }

    // MARK: - Leaving the gate

    /// The local path leaves gate 1, and writes NOTHING to the Keychain.
    ///
    /// The Keychain half is not incidental. Grux's only sanctioned home for a
    /// secret is `KeychainStore`, and this path holds no secret at all: a local
    /// model needs no credential, which is the entire reason it can be offered
    /// to somebody with no account. A write here would store a placeholder that
    /// `CapabilityResolver` would then read back as a satisfied `key.anthropic`,
    /// marking 15 registry rows configured on the strength of a value that
    /// cannot authenticate anything.
    func testTheLocalPathLeavesTheGateAndWritesNoKeychainEntry() throws {
        let body = try useLocalModelBody()
        XCTAssertTrue(body.contains("model.completeModelKey()"),
                      "the local path never leaves the gate, so it is not a way out")
        XCTAssertFalse(body.contains("KeychainStore"),
                       """
                       the local path touches the Keychain. It holds no secret: a local \
                       model needs no credential, and anything written into the Anthropic \
                       slot reads back as a satisfied key.anthropic for every feature that \
                       names it.
                       """)
    }

    /// And it turns the switch that makes the discovered model the one chat
    /// actually uses.
    func testTheLocalPathTurnsOnTheSwitchThatRoutesToTheModelItFound() throws {
        let body = try useLocalModelBody()
        XCTAssertTrue(body.contains("discoverLocal()"),
                      "the local path never probes for a model, so it cannot know one is there")
        XCTAssertTrue(body.contains("offlineMode = true"),
                      """
                      the local path discovers a model and never routes to it. ModelRegistry \
                      needs the offline switch as well as the discovery before a turn goes \
                      anywhere but Anthropic, so this would leave the user in the state \
                      ChatReadiness calls .localModelFoundButNotRouted: past the gate, and \
                      unable to send.
                      """)
    }

    /// `completeModelKey()` genuinely advances, at every level.
    ///
    /// Driven through the pure `stage(after:at:)` rather than the singleton, for
    /// the reason that function exists: `advance` persists, and the file it
    /// persists to is the operator's own.
    func testTheStageAfterTheModelKeyExistsAtEveryLevel() {
        for level in OnboardingModel.Level.allCases {
            XCTAssertNotNil(OnboardingModel.stage(after: .modelKey, at: level),
                            "\(level.rawValue) has nothing after the model key, so leaving the "
                            + "gate would drop the user out of the flow")
        }
    }

    /// AFTER TAKING THE PATH, CHAT IS READY. The gate must not be leavable into
    /// a state readiness reports as anything else.
    func testTheStateTheLocalPathLeavesTheUserInIsReady() {
        let after = ChatReadiness.evaluate(hasAnthropicKey: false,
                                           localModelAvailable: true,
                                           offlineMode: true)
        XCTAssertEqual(after, .ready,
                       "the local path leaves the user in a state chat refuses to send from")
        XCTAssertTrue(after.canSend)
    }

    /// The half-done version of the same path, named so it cannot be
    /// reintroduced by somebody simplifying the two statements into one.
    /// Discovering a model without turning the switch on is NOT ready.
    func testDiscoveringAModelWithoutTheSwitchWouldNotHaveBeenReady() {
        let halfDone = ChatReadiness.evaluate(hasAnthropicKey: false,
                                              localModelAvailable: true,
                                              offlineMode: false)
        XCTAssertEqual(halfDone, .localModelFoundButNotRouted)
        XCTAssertFalse(halfDone.canSend,
                       "readiness now calls a discovered-but-unrouted model sendable, which "
                       + "would make the local path a dead end with no visible cause")
    }

    // MARK: - When there is no local model

    /// A FAILED PROBE DOES NOT LEAVE THE GATE, and does not tell the user to buy
    /// a key.
    ///
    /// Both halves matter. Leaving on a failed probe would pin offline mode with
    /// nothing to run, which is `ChatReadiness.offlinePinnedButNoLocalModel`: the
    /// user would be past the gate, unable to send, and looking at a switch they
    /// never knowingly touched. And "add a key instead" is the one instruction
    /// that is certainly wrong for somebody who just pressed a button asking for
    /// the opposite, which is the same misdirection `ChatReadiness` records
    /// against `.localModelFoundButNotRouted`.
    func testAFailedProbeStaysOnTheGateAndDoesNotSendTheUserToBuyAKey() throws {
        let body = try useLocalModelBody()

        guard let guardAt = body.range(of: "guard ModelRegistry.shared.local != nil else"),
              let switchAt = body.range(of: "offlineMode = true") else {
            return XCTFail("""
                the local path no longer guards on a discovered model before turning \
                offline mode on. Without that order, a failed probe pins offline mode \
                with nothing to run.
                """)
        }
        XCTAssertLessThan(guardAt.lowerBound, switchAt.lowerBound,
                          "offline mode is set before the discovery result is checked")
        XCTAssertTrue(String(body[guardAt.upperBound..<switchAt.lowerBound]).contains("return"),
                      "the failure branch falls through into the success branch")

        let failureCopy = failureSentence(in: body)
        XCTAssertFalse(failureCopy.lowercased().contains("key"),
                       """
                       the failure message tells a user who explicitly chose the local path \
                       to add an API key. That is the exact wrong instruction for them: \
                       nothing is missing except a running server. Copy: \(failureCopy)
                       """)
        XCTAssertTrue(failureCopy.lowercased().contains("ollama"),
                      "the failure message never names the thing to start. Copy: \(failureCopy)")
        XCTAssertTrue(failureCopy.contains("localHost"),
                      """
                      the failure message does not name the host that was probed, so a user \
                      whose server is on another port cannot tell whether Grux even looked \
                      in the right place. Copy: \(failureCopy)
                      """)
    }

    /// The one string literal assigned to `localError`, so the copy assertions
    /// above are about the sentence a person reads rather than the whole body.
    private func failureSentence(in body: String) -> String {
        guard let assign = body.range(of: "localError = \"") else {
            XCTFail("the local path no longer says anything when the probe fails, which is "
                    + "the silent dead end this whole path exists to remove")
            return ""
        }
        let rest = body[assign.upperBound...]
        guard let close = rest.range(of: "\"") else { return String(rest) }
        return String(rest[..<close.lowerBound])
    }

    /// The button has to be visible on the gate, not reachable only by keyboard
    /// or hidden behind a disclosure. Discoverability IS the fix here: the path
    /// existed in Settings the whole time and a first-run user could not reach
    /// Settings.
    func testTheGateOffersTheLocalPathOnScreen() throws {
        let src = try onboardingViewSource()
        XCTAssertTrue(src.contains("Use a local model instead"),
                      "the gate no longer offers the local path where a first-run user can see it")
    }

    // MARK: - The registry row

    private func chatRow() throws -> FeatureRow {
        try XCTUnwrap(FeatureRegistry.row(id: "chat"), "the chat registry row vanished")
    }

    /// The predicate the row rules are driven through.
    ///
    /// `key.anthropic` goes through `CapabilityResolver.keyIsSatisfied`, the same
    /// pure seam the resolver itself uses, rather than through a bare Bool. That
    /// keeps this test honest about what "has a key" means: a blank value is
    /// absence, which is the convention every credential in this app follows.
    private func satisfying(anthropicKey: Bool, localModel: Bool) -> (SetupRequirement) -> Bool {
        { req in
            switch req {
            case .keyAnthropic:
                return CapabilityResolver.keyIsSatisfied(
                    alternateSaysYes: false,
                    keychainValue: anthropicKey ? "sk-ant-not-a-real-key" : "",
                    companionSaysYes: nil)
            case .endpointOllama:
                return localModel
            default:
                return true
            }
        }
    }

    /// Control for the three tests below. They stub two capabilities and let
    /// everything else pass, so if chat ever gains a third blocking requirement
    /// they would keep passing while saying nothing about it.
    func testChatBlocksOnExactlyTheTwoWaysToReachAModel() throws {
        XCTAssertEqual(try chatRow().blocking, [SetupRequirement.keyAnthropic, .endpointOllama],
                       "chat's blocking set changed, so the stub predicate below no longer "
                       + "covers it and these tests would pass vacuously")
        XCTAssertEqual(try chatRow().anyOf.count, 1, "chat lost its either-or group")
        XCTAssertEqual(try chatRow().anyOf.first?.capabilities,
                       [SetupRequirement.keyAnthropic, .endpointOllama])
        XCTAssertEqual(try chatRow().anyOf.first?.min, 1,
                       "chat's group no longer means any ONE of the two, which is the whole "
                       + "claim: a key OR a local model, never both")
    }

    /// A LOCAL MODEL AND NO KEY IS A SATISFIED CHAT. This is the user the README
    /// leads with, and the row used to report them permanently unfinished.
    func testTheChatRowIsSatisfiedByALocalModelWithNoAnthropicKey() throws {
        let unmet = FeatureRegistry.unmetBlocking(of: try chatRow(),
                                                  satisfied: satisfying(anthropicKey: false,
                                                                        localModel: true))
        XCTAssertTrue(unmet.isEmpty,
                      """
                      a user running a local model with no account anywhere still gets a \
                      needs-setup dot on the default landing tab and a setup card telling \
                      them to buy a key they do not need. Missing: \(unmet.map(\.rawValue))
                      """)
    }

    /// AND A KEY WITH NO LOCAL MODEL IS STILL SATISFIED. The other half of an
    /// either-or, and the half that would break if somebody swapped the
    /// requirement rather than widening it.
    func testTheChatRowIsStillSatisfiedByAnAnthropicKeyWithNoLocalModel() throws {
        let unmet = FeatureRegistry.unmetBlocking(of: try chatRow(),
                                                  satisfied: satisfying(anthropicKey: true,
                                                                        localModel: false))
        XCTAssertTrue(unmet.isEmpty,
                      """
                      the ordinary paying user, key pasted and no local server anywhere, now \
                      reports needs-setup. Missing: \(unmet.map(\.rawValue))
                      """)
    }

    /// AND NEITHER IS STILL UNSATISFIED, so the change widened the requirement
    /// rather than deleting it.
    ///
    /// This is the failure mode the task called out by name. Writing
    /// `requires: []` would have made every assertion above pass while telling a
    /// user with nothing attached that chat was ready, and they would have met
    /// the truth at their first send. Contract section 3 calls a false `ready` a
    /// defect outright, and it is strictly worse than the false `needs-setup`
    /// this change removes.
    func testTheChatRowIsUnsatisfiedWithNeitherAKeyNorALocalModel() throws {
        let unmet = FeatureRegistry.unmetBlocking(of: try chatRow(),
                                                  satisfied: satisfying(anthropicKey: false,
                                                                        localModel: false))
        XCTAssertEqual(unmet, [.keyAnthropic, .endpointOllama],
                       """
                       chat reports ready with nothing attached, or names only one of the two \
                       ways out. Both belong in the card: they are alternatives, and offering \
                       only the paid one is how the free path becomes invisible. \
                       Missing: \(unmet.map(\.rawValue))
                       """)
    }

    /// The row rule and the send rule have to agree, in all four states. A
    /// registry that says ready while readiness refuses to send is a setup card
    /// the user cannot make go away, and the reverse is a green tab that fails
    /// the moment it is used.
    func testTheRowAgreesWithChatReadinessInEveryCombination() throws {
        for hasKey in [false, true] {
            for hasLocal in [false, true] {
                let rowSatisfied = FeatureRegistry
                    .unmetBlocking(of: try chatRow(),
                                   satisfied: satisfying(anthropicKey: hasKey, localModel: hasLocal))
                    .isEmpty
                // The routed reading of the same two facts: offline mode is on
                // exactly when a local model is the thing being used, which is
                // the state the gate's local path leaves behind.
                let canSend = ChatReadiness.evaluate(hasAnthropicKey: hasKey,
                                                     localModelAvailable: hasLocal,
                                                     offlineMode: hasLocal && !hasKey).canSend
                XCTAssertEqual(rowSatisfied, canSend,
                               "key=\(hasKey) local=\(hasLocal): the registry says "
                               + "\(rowSatisfied ? "ready" : "needs-setup") and chat says "
                               + "\(canSend ? "sendable" : "not sendable")")
            }
        }
    }

    // MARK: - Nothing else moved

    /// EVERY OTHER ROW BEHAVES EXACTLY AS IT DID. A group is a new relation in a
    /// frozen contract, so the thing to prove is not only that chat improved but
    /// that nothing else changed shape underneath it.
    func testNoOtherRowUsesAGroupAndTheFlatRuleIsUnchanged() {
        for row in FeatureRegistry.rows where row.id != "chat" {
            XCTAssertTrue(row.anyOf.isEmpty,
                          "\(row.id) grew an either-or group. That may well be right, but it "
                          + "is a contract change and needs a dated amendment, not a quiet edit")
        }
        var checked = 0
        for row in FeatureRegistry.rows where row.anyOf.isEmpty && !row.blocking.isEmpty {
            let first = row.blocking[0]
            let unmet = FeatureRegistry.unmetBlocking(of: row, satisfied: { $0 == first })
            XCTAssertEqual(unmet, row.blocking.filter { $0 != first },
                           "\(row.id) no longer behaves as a flat AND")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10,
                             "control: found almost no rows with blocking requirements, so this "
                             + "proves nothing")
    }

    /// The two ends of the rule, for every row at once. Nothing satisfied means
    /// everything blocking is reported; everything satisfied means nothing is.
    func testTheGroupRuleCollapsesCorrectlyAtBothExtremes() {
        for row in FeatureRegistry.rows {
            XCTAssertEqual(FeatureRegistry.unmetBlocking(of: row, satisfied: { _ in false }),
                           row.blocking,
                           "\(row.id) hides a blocking requirement when nothing is satisfied")
            XCTAssertTrue(FeatureRegistry.unmetBlocking(of: row, satisfied: { _ in true }).isEmpty,
                          "\(row.id) reports something missing when everything is satisfied")
        }
    }
}
