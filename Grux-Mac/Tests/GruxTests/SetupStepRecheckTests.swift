import XCTest
@testable import Grux

/// "Set up what you picked" printed "Grux checks again when you come back" and never did.
///
/// Measured on the setup step: the card re-read an item only right after its button, which
/// is before anybody could have granted anything, and never on return or on a timer. It
/// never refreshed Automation's observation, so Automation could not read as done there,
/// and never refreshed the Notifications cache. And a prompt-style permission macOS had
/// already refused kept saying "Allow", a button that returns at once with no dialog. For
/// somebody who cannot use a mouse or keyboard freely, each of those is a dead end.
@MainActor
final class SetupStepRecheckTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Whole-line comments dropped, then EVERY whitespace character removed, so a pin holds
    /// the order of the tokens and nothing about line breaks, indentation or a formatter.
    /// `pin` squashes its needle the same way, so needles stay readable here.
    private func collapsed(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
            .filter { !$0.isWhitespace }
    }

    private func squashed(_ needle: String) -> String { needle.filter { !$0.isWhitespace } }

    private func pin(_ haystack: String, _ needle: String, _ message: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(haystack.contains(squashed(needle)), message, file: file, line: line)
    }

    /// From a declaration to the first `closing` after it, scoped so a neighbour cannot
    /// satisfy an assertion. Runs on the raw source, before any whitespace is removed.
    private func body(of declaration: String, in source: String, closing: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration), "\(declaration) is gone")
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: closing) else { return String(rest) }
        return String(rest[rest.startIndex..<end.lowerBound])
    }

    private func setupStep() throws -> String {
        try body(of: "struct SetupStep", in: source("Sources/Grux/Onboarding/FirstRunScreens.swift"),
                 closing: "\n}\n")
    }

    // MARK: - The re-check, wired

    /// Coming back from System Settings re-checks the item on screen.
    func testTheSetupStepRechecksWhenTheAppComesBack() throws {
        pin(collapsed(try setupStep()),
            ".onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) "
            + "{ _ in Task { await recheck() } }",
            "setup does not re-check when the person comes back, so its printed promise is false")
    }

    /// And it polls while the screen is up, because a grant lands whether or not they return.
    func testTheSetupStepPollsWhileItIsUp() throws {
        pin(collapsed(try setupStep()),
            ".task { while !Task.isCancelled { await recheck() try? await Task.sleep(for: .seconds(2)) } }",
            "setup does not poll, so a grant made in System Settings is noticed only on return")
    }

    /// And on every new screen, so a refusal macOS recorded shows the honest button at once
    /// rather than "Allow" until the next poll tick.
    func testTheSetupStepRechecksOnEveryNewScreen() throws {
        pin(collapsed(try setupStep()),
            ".onChange(of: index) { _, _ in Task { await recheck() } }",
            "walking onto a refused Notifications card shows Allow for up to one poll")
    }

    /// The re-check refreshes the stale answers before deciding, and finishes the item.
    func testTheRecheckRefreshesThenFinishesTheItem() throws {
        let step = try setupStep()
        let recheck = collapsed(try body(of: "private func recheck() async", in: step, closing: "\n    }\n"))
        pin(recheck, "await CapabilityRequest.isSatisfiedAfterRefresh(req)",
            "the re-check reads the resolver's cached answers without refreshing them")
        pin(recheck, "for item in SetupRecheck.worthRechecking(itemsOnScreen, isDone: done)",
            "the re-check is not driven by the items on screen")
        pin(recheck, "SetupRecheck.outcome(nowDone: done(item), showing: currentItem == item,",
            "the re-check decides from a flag captured before the probe, not from what is showing now")
        pin(recheck, "case .advance: model.clearSkip(req) advanceAfterAction(true) return",
            "a granted item is not cleared from the skip ledger and moved past")
        pin(recheck, "if redraw { tick += 1 }",
            "the whole list never redraws, so its rows cannot flip to Done")

        let shared = collapsed(try body(
            of: "static func isSatisfiedAfterRefresh",
            in: source("Sources/Grux/Onboarding/CapabilityRequest.swift"), closing: "\n    }\n"))
        pin(shared, "await refreshedNotificationAuthorization()",
            "the Notifications cache is not refreshed before it is read")
        pin(shared, "await CapabilityResolver.refreshAutomationObservationInBackground()",
            "Automation's observation is not refreshed here, or is refreshed on the main actor")
    }

    /// The button's label comes from the decision, and a refusal macOS already recorded
    /// counts, so the button is honest on first render.
    func testTheButtonConsultsTheDeclinedStateAndTheRecordedDenial() throws {
        let step = collapsed(try setupStep())
        pin(step, "Setup.permissionControl( style: CapabilityRequest.style(for: req), "
            + "declined: declined.contains(req) || CapabilityRequest.recordedDenial(req))",
            "the label ignores a refusal, so Allow stays on a prompt that will not appear")
        pin(step, "isDone: { done(item) }, isShowing: { currentItem == item })",
            "the button does not ask where the person is after the prompt comes back")
        pin(step, "if result.declined { declined.insert(req) }",
            "a request that comes back refused does not change the button")
        pin(step, "if result.outcome == .advance { next() } else { tick += 1 }",
            "the button advances on something other than the decision")
        pin(step, "Button(control.label)", "the button no longer shows the decided label")
    }

    // MARK: - The prompt and the person, in either order

    /// THE SKIP DURING A PROMPT. The person says "Click Allow", the macOS dialog comes up,
    /// they press "Skip for now" in Grux, and then answer the dialog. The old Task advanced
    /// again on the answer, passing a screen they never saw. Stubbed: the request moves the
    /// person on while it is out, then grants.
    func testSkippingWhileThePromptIsUpDoesNotAdvanceASecondTime() async {
        var showing = true
        var granted = false
        let result = await SetupAsk.press(
            .permCalendar, control: Setup.permissionControl(style: .prompt, declined: false),
            request: { _ in showing = false; granted = true; return true },
            openSettings: { _ in XCTFail("a prompt-style ask opened System Settings") },
            isDone: { granted }, isShowing: { showing })
        XCTAssertEqual(result, SetupAsk.Result(declined: false, outcome: .redraw),
                       "the answer to a prompt advanced a screen the person had already left")
    }

    func testAGrantWhileStillOnTheCardAdvances() async {
        var granted = false
        let result = await SetupAsk.press(
            .permCalendar, control: Setup.permissionControl(style: .prompt, declined: false),
            request: { _ in granted = true; return true },
            openSettings: { _ in }, isDone: { granted }, isShowing: { true })
        XCTAssertEqual(result, SetupAsk.Result(declined: false, outcome: .advance))
    }

    func testARefusedRequestIsReportedAsDeclined() async {
        let result = await SetupAsk.press(
            .permContacts, control: Setup.permissionControl(style: .prompt, declined: false),
            request: { _ in false }, openSettings: { _ in }, isDone: { false }, isShowing: { true })
        XCTAssertEqual(result, SetupAsk.Result(declined: true, outcome: .redraw))
    }

    func testOpenSystemSettingsOpensThePaneAndNeverAsks() async {
        var opened: [SetupRequirement] = []
        let result = await SetupAsk.press(
            .permAutomation, control: Setup.permissionControl(style: .systemSettingsOnly, declined: false),
            request: { _ in XCTFail("a pane-only permission raised a request"); return false },
            openSettings: { opened.append($0) }, isDone: { false }, isShowing: { true })
        XCTAssertEqual(opened, [.permAutomation])
        XCTAssertEqual(result, SetupAsk.Result(declined: false, outcome: .nothing))
    }

    // MARK: - Key cards on the whole list

    /// ONE DRAFT PER ITEM. The whole list draws several key cards together, and one shared
    /// string put a key dictated into the Notion field into the Replicate field as well.
    func testTwoKeyCardsKeepIndependentDrafts() {
        var drafts = SetupDrafts()
        drafts[.keyNotion] = "  notion-draft  "
        XCTAssertEqual(drafts[.keyReplicate], "", "typing into one key card filled another")
        XCTAssertEqual(drafts.trimmed(.keyNotion), "notion-draft")
        drafts[.keyReplicate] = "replicate-draft"
        drafts.clear(.keyNotion)
        XCTAssertEqual(drafts[.keyNotion], "")
        XCTAssertEqual(drafts[.keyReplicate], "replicate-draft", "saving one card cleared another")
        drafts.clearAll()
        XCTAssertEqual(drafts, SetupDrafts())
    }

    /// And each field and Save is named after its item, starting with the words on screen.
    func testTwoKeyCardsExposeDistinctNames() {
        let notion = SetupOrder.Item(requirement: .keyNotion, neededBy: ["chat"])
        let replicate = SetupOrder.Item(requirement: .keyReplicate, neededBy: ["chat"])
        XCTAssertNotEqual(Setup.saveName(notion), Setup.saveName(replicate))
        XCTAssertNotEqual(Setup.fieldName(notion), Setup.fieldName(replicate))
        XCTAssertEqual(Setup.saveName(notion), "Save the " + Setup.title(of: notion))
        XCTAssertEqual(Setup.fieldName(notion), "Paste it here, " + Setup.title(of: notion))
        // LABEL IN NAME. Voice Control matches what the person reads on screen, and the
        // field shows "Paste it here", so the name has to start with exactly that.
        XCTAssertTrue(Setup.fieldName(notion).hasPrefix("Paste it here"),
                      "\"Click Paste it here\" no longer reaches the key field by voice")
    }

    /// Repeated pane buttons on the list say which pane; walking, the button stands alone.
    func testRepeatedPaneButtonsNameTheirItemOnTheWholeList() {
        let automation = SetupOrder.Item(requirement: .permAutomation, neededBy: ["commands"])
        let notifications = SetupOrder.Item(requirement: .permNotifications, neededBy: ["schedules"])
        XCTAssertEqual(Setup.actionName("Open System Settings", for: automation, walking: false),
                       "Open System Settings for Automation")
        XCTAssertNotEqual(Setup.actionName("Open System Settings", for: automation, walking: false),
                          Setup.actionName("Open System Settings", for: notifications, walking: false))
        XCTAssertEqual(Setup.actionName("Open System Settings", for: automation, walking: true),
                       "Open System Settings")
    }

    /// The view actually binds and names them that way.
    func testTheKeyCardBindsItsOwnDraftAndNamesItsControls() throws {
        let step = collapsed(try setupStep())
        pin(step, "SecureField(\"Paste it here\", text: $drafts[req])",
            "the key field is bound to a shared draft again")
        pin(step, ".accessibilityLabel(Setup.fieldName(item))", "the key field has no name of its own")
        pin(step, ".accessibilityLabel(Setup.saveName(item))", "every key card's Save is just \"Save\"")
        pin(step, ".accessibilityLabel(Setup.actionName(control.label, for: item, walking: walking))",
            "repeated pane buttons on the list cannot be told apart")
        XCTAssertFalse(step.contains(squashed("text: $draft)")), "a shared draft binding is back")
    }

    // MARK: - The pinned bar runs the screen that is showing

    /// THE PREMISE. The bar keeps an action until one arrives that READS differently, since
    /// closures cannot be compared. Two cards on one stage that both say "Skip for now"
    /// are the same bar.
    func testTwoBarsThatReadTheSameAreEqualWhateverTheyRun() {
        var ran = ""
        let first = OnboardingPrimaryAction(title: "", enabled: false, secondaryTitle: "Skip for now",
                                            run: { ran = "first" }, runSecondary: { ran = "first" },
                                            stage: .setup)
        let second = OnboardingPrimaryAction(title: "", enabled: false, secondaryTitle: "Skip for now",
                                             run: { ran = "second" }, runSecondary: { ran = "second" },
                                             stage: .setup)
        XCTAssertEqual(first, second, "if this changes, the bar stops reusing closures and the pin below can relax")
        first.runSecondary?()
        XCTAssertEqual(ran, "first")
    }

    /// ACROSS STAGES IT MAY NEVER BE THE SAME BAR. A stale closure from the stage before
    /// runs `advance(from:)` for a stage that is no longer showing.
    func testTwoStagesThatReadTheSameAreDifferentBars() {
        let yourGrux = OnboardingPrimaryAction(title: "Continue", enabled: true, secondaryTitle: nil,
                                               run: {}, runSecondary: nil, stage: .yourGrux)
        let identity = OnboardingPrimaryAction(title: "Continue", enabled: true, secondaryTitle: nil,
                                               run: {}, runSecondary: nil, stage: .identity)
        XCTAssertNotEqual(yourGrux, identity, "the next stage would inherit this stage's Continue")
    }

    /// And every publisher declares its stage, so none can be forgotten.
    func testEveryBarNamesItsStage() throws {
        let files = ["Sources/Grux/Onboarding/FirstRunScreens.swift",
                     "Sources/Grux/Onboarding/OnboardingSteps.swift",
                     "Sources/Grux/Onboarding/OnboardingView.swift"]
        var calls = 0
        for f in files {
            let src = collapsed(try source(f))
            var rest = Substring(src)
            while let r = rest.range(of: ".onboardingPrimary(") {
                calls += 1
                XCTAssertTrue(rest[r.upperBound...].prefix(60).contains("stage:."),
                              "\(f) publishes a bar without its stage: \(rest[r.upperBound...].prefix(60))")
                rest = rest[r.upperBound...]
            }
        }
        XCTAssertEqual(calls, 6, "the scan found a different number of bars than exist")
    }

    /// So no setup bar may capture its screen. Measured on a live first run: four "Skip for
    /// now" presses and a whole-list Continue over five unfinished items left the skip
    /// ledger empty, because every press ran the first card's closure.
    func testEverySetupBarReadsTheScreenWhenPressed() throws {
        let step = collapsed(try setupStep())
        pin(step, "secondary: skip, runSecondary: moveOn, run: moveOn)",
            "the bar runs a closure built for one screen")
        XCTAssertFalse(step.contains(squashed("private func nextRow(primary: String?, skip: String? = nil, _ go")),
                       "nextRow takes a per-screen closure again, which the bar will reuse on the next screen")
        let move = collapsed(try body(of: "private func moveOn()", in: try setupStep(), closing: "\n    }\n"))
        pin(move, "for item in itemsOnScreen where !done(item) { model.markSkipped(item.requirement) } next()",
            "moving on does not record what is on screen now as skipped")
        var rest = Substring(step)
        var rows = 0
        while let r = rest.range(of: "nextRow(primary:") {
            rows += 1
            let after = rest[r.upperBound...].prefix(80)
            let close = try XCTUnwrap(after.firstIndex(of: ")"))
            XCTAssertFalse(after[after.index(after: close)...].hasPrefix("{"),
                           "a nextRow call passes its own closure: \(after)")
            rest = rest[r.upperBound...]
        }
        XCTAssertEqual(rows, 5, "the scan found a different number of bars than exist (4 calls and the declaration)")
    }

    /// The whole-list switch exposed no name of its own, so it could not be named by voice.
    func testTheWholeListSwitchHasAnAccessibilityName() throws {
        pin(collapsed(try setupStep()),
            ".toggleStyle(.switch).controlSize(.small).font(GruxTheme.Font.caption) "
            + ".accessibilityLabel(Setup.wholeList)",
            "the whole-list switch is unnamed again")
    }

    // MARK: - One mapping to System Settings

    /// The setup card kept its own copy of the pane mapping, still sending Notifications to
    /// Privacy & Security after the shared one was fixed.
    func testTheSetupCardUsesTheSharedPaneMapping() throws {
        let card = collapsed(try source("Sources/Grux/Onboarding/CapabilitySetupCard.swift"))
        pin(card, "CapabilityRequest.openSystemSettings(for: requirement)",
            "the setup card does not open panes through the shared mapping")
        XCTAssertFalse(card.contains("preference.security"), "the setup card builds its own pane URLs again")
    }

    // MARK: - The Automation probe, off the main actor

    /// The probe blocks while the screen is locked. From a 2 s poll it must not block main.
    func testTheBackgroundRefreshProbesOffTheMainActorAndWritesTheVerdict() async {
        let key = CapabilityResolver.automationObservedKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let onMain = ProbeLog()
        let verdict = await CapabilityResolver.refreshAutomationObservationInBackground(probe: { _ in
            onMain.record(Thread.isMainThread)
            return OSStatus(noErr)
        })
        XCTAssertTrue(verdict)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true, "the verdict was not written")
        XCTAssertEqual(onMain.values.count, CapabilityResolver.automationTargets.count,
                       "the refresh did not ask about every target")
        XCTAssertFalse(onMain.values.contains(true), "a probe ran on the main thread")
    }

    // MARK: - The decisions, behaviourally

    func testANewlyGrantedItemAdvancesWhileItIsShowing() {
        XCTAssertEqual(SetupRecheck.outcome(nowDone: true, showing: true, declinedChanged: false), .advance)
    }

    func testANewlyGrantedRowRedrawsWhenItIsNotTheOneItemShowing() {
        XCTAssertEqual(SetupRecheck.outcome(nowDone: true, showing: false, declinedChanged: false), .redraw)
    }

    func testANewRefusalRedrawsAndNothingElseDoesNothing() {
        XCTAssertEqual(SetupRecheck.outcome(nowDone: false, showing: true, declinedChanged: true), .redraw)
        XCTAssertEqual(SetupRecheck.outcome(nowDone: false, showing: true, declinedChanged: false), .nothing,
                       "a poll with nothing new must not redraw, or it resets focus every two seconds")
    }

    func testOnlyUnfinishedPermissionsAreRechecked() {
        let mic = SetupOrder.Item(requirement: .permMicrophone, neededBy: ["meetings"])
        let auto = SetupOrder.Item(requirement: .permAutomation, neededBy: ["terminal"])
        let key = SetupOrder.Item(requirement: .keySlack, neededBy: ["slack"])
        let picked = SetupRecheck.worthRechecking([mic, auto, key]) { $0.requirement == .permMicrophone }
        XCTAssertEqual(picked, [auto])
    }

    // MARK: - The declined state

    /// THE DEAD ALLOW. After a request comes back refused, the button opens System Settings
    /// and the card says where the switch is.
    func testAfterARefusalThePromptBecomesOpenSystemSettingsWithTheHowTo() {
        let refused = Setup.permissionControl(style: .prompt, declined: true)
        XCTAssertEqual(refused.label, "Open System Settings")
        XCTAssertTrue(refused.showsHowTo, "the card sends them away without saying where the switch is")
        XCTAssertTrue(refused.opensSettings, "the button still asks macOS for a prompt it will not show")
    }

    func testBeforeARefusalAPromptStillSaysAllow() {
        let fresh = Setup.permissionControl(style: .prompt, declined: false)
        XCTAssertEqual(fresh, Setup.PermissionControl(label: "Allow", showsHowTo: false, opensSettings: false))
    }

    func testAPaneOnlyPermissionAlwaysOpensSettingsWithTheHowTo() {
        for declined in [false, true] {
            XCTAssertEqual(Setup.permissionControl(style: .systemSettingsOnly, declined: declined),
                           Setup.PermissionControl(label: "Open System Settings", showsHowTo: true, opensSettings: true))
        }
    }

    /// The how-to shown under that button promises the re-check this screen now performs.
    func testTheHowToPromisesTheRecheck() {
        for req in CapabilityRequest.onboardingOrder {
            XCTAssertTrue(CapabilityRequest.howToGrant(req).contains("Grux checks again when you come back"))
        }
    }
}

/// Which threads the stubbed probe ran on, collected safely from a detached task.
private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    func record(_ onMain: Bool) { lock.lock(); seen.append(onMain); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return seen }
}
