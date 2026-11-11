import XCTest
@testable import GruxSetupCore

/// `grux doctor` and `grux next` give one answer, and the rail never steps backwards.
///
/// Sense pass 8 (D93): on this Mini, with Mailbox on and no mail server, `grux next` said
/// "Mail server is the one thing blocking the most: 1 feature you turned on cannot run
/// without it, namely Mailbox." while `grux doctor` said "Everything this command can check
/// is in order." And `next` marked PROVE in its top rail and HAND OFF in its bottom one.
final class DoctorAgreesWithNextTests: XCTestCase {

    // MARK: - Fixtures

    private func cap(_ id: String, kind: String, label: String,
                     satisfied: Bool = false) -> SetupStatus.Capability {
        .init(id: id, kind: kind, label: label, satisfied: satisfied, selfAttested: false,
              remediation: satisfied ? nil : "Set up \(label).")
    }

    private func feature(_ id: String, _ label: String, chosen: Bool = true,
                         requires: [String] = [], optional: [String] = [],
                         anyOf: [SetupStatus.Feature.Group] = [],
                         dependsOn: [String] = []) -> SetupStatus.Feature {
        .init(id: id, label: label, tier: "core", state: "needsSetup", chosen: chosen,
              missing: [], requires: requires, optional: optional, steps: [],
              optionalSteps: [], anyOf: anyOf, dependsOn: dependsOn)
    }

    private func status(_ caps: [SetupStatus.Capability],
                        _ features: [SetupStatus.Feature]) -> SetupStatus {
        SetupStatus(schema: SetupStatus.supportedSchema, generatedAt: "", appVersion: "3.1.0",
                    capabilities: caps, features: features,
                    summary: .init(capabilities: caps.count, satisfied: 0, selfAttested: 0,
                                   featuresReady: 0, featuresNeedingSetup: 0,
                                   featuresChosen: features.filter(\.chosen).count))
    }

    // MARK: - The decision

    /// The Mini's own shape: Mailbox on, no mail server, an optional key missing elsewhere.
    func testTheMinisMailServerIsTheNextStep() {
        let s = status([cap("endpoint.imap", kind: "endpoint", label: "Mail server"),
                        cap("key.anthropic", kind: "key", label: "Anthropic API key")],
                       [feature("mailbox", "Mailbox", requires: ["endpoint.imap"]),
                        feature("chat", "Chat", optional: ["key.anthropic"])])
        guard case .unblock(let c, let blocking, _) = NextStep.pick(s) else {
            return XCTFail("expected Mail server, got \(NextStep.pick(s))")
        }
        XCTAssertEqual(c.id, "endpoint.imap")
        XCTAssertEqual(blocking.map(\.id), ["mailbox"])
        XCTAssertFalse(NextStep.pick(s).isClear)
    }

    /// Most features unblocked wins; on a tie the cheaper kind wins (perm before key).
    func testTheChoiceCountsFeaturesThenEffort() {
        let s = status([cap("key.a", kind: "key", label: "A key"),
                        cap("perm.mic", kind: "perm", label: "Microphone"),
                        cap("endpoint.x", kind: "endpoint", label: "X server")],
                       [feature("f1", "F1", requires: ["key.a", "perm.mic"]),
                        feature("f2", "F2", requires: ["key.a"]),
                        feature("f3", "F3", requires: ["perm.mic", "endpoint.x"])])
        // key.a and perm.mic each block two; perm is cheaper to grant than a key.
        guard case .unblock(let c, _, _) = NextStep.pick(s) else { return XCTFail() }
        XCTAssertEqual(c.id, "perm.mic")
    }

    private let model: [SetupStatus.Feature.Group] =
        [.init(capabilities: ["key.anthropic", "endpoint.ollama"], min: 1)]

    /// A capability inside a SATISFIED any-of group is not blocking, and an OFF feature asks
    /// nothing: the other member is only an optional improvement.
    func testASatisfiedGroupAndOffFeaturesDoNotBlock() {
        let s = status([cap("key.anthropic", kind: "key", label: "Anthropic API key"),
                        cap("endpoint.ollama", kind: "endpoint", label: "Local model",
                            satisfied: true)],
                       [feature("chat", "Chat", requires: ["key.anthropic", "endpoint.ollama"],
                                anyOf: model),
                        feature("mailbox", "Mailbox", chosen: false,
                                requires: ["key.anthropic"])])
        guard case .nothingRequired(let optional) = NextStep.pick(s) else {
            return XCTFail("expected nothing required, got \(NextStep.pick(s))")
        }
        XCTAssertEqual(optional.map(\.id), ["key.anthropic"])
        XCTAssertTrue(NextStep.pick(s).isClear)
    }

    /// W25a: a group with NO member satisfied blocks. Chat with neither the key nor a local
    /// model read as "Nothing you have to do" in next and "in order" in doctor.
    func testAnUnmetGroupBlocksAndOffersEachOption() {
        let s = status([cap("key.anthropic", kind: "key", label: "Anthropic API key"),
                        cap("endpoint.ollama", kind: "endpoint", label: "Local model")],
                       [feature("chat", "Chat", requires: ["key.anthropic", "endpoint.ollama"],
                                anyOf: model),
                        feature("mailbox", "Mailbox", chosen: false,
                                requires: ["key.anthropic"])])
        guard case .chooseOne(let options, let needed, let blocking) = NextStep.pick(s) else {
            return XCTFail("expected a choice of model, got \(NextStep.pick(s))")
        }
        XCTAssertEqual(options.map(\.id), ["endpoint.ollama", "key.anthropic"],
                       "both options, the cheaper kind first")
        XCTAssertEqual(needed, 1)
        XCTAssertEqual(blocking.map(\.id), ["chat"], "an OFF feature is never named")
        XCTAssertFalse(NextStep.pick(s).isClear)
    }

    /// The Research shape after CR-40: the web key set, no model at all.
    func testResearchWithTheWebKeyAndNoModelIsBlocked() {
        let s = status([cap("key.brave", kind: "key", label: "Web search API key", satisfied: true),
                        cap("key.anthropic", kind: "key", label: "Anthropic API key"),
                        cap("endpoint.ollama", kind: "endpoint", label: "Local model")],
                       [feature("research", "Research",
                                requires: ["key.brave", "key.anthropic", "endpoint.ollama"],
                                anyOf: model)])
        guard case .chooseOne(_, _, let blocking) = NextStep.pick(s) else {
            return XCTFail("Research with no model read as \(NextStep.pick(s))")
        }
        XCTAssertEqual(blocking.map(\.id), ["research"])
    }

    /// One unmet group shared by three features outranks a key blocking one; on equal
    /// counts the group competes by its cheapest option, so a permission still wins.
    func testAGroupIsRankedLikeAnyOtherBlocker() {
        let caps = [cap("key.anthropic", kind: "key", label: "Anthropic API key"),
                    cap("endpoint.ollama", kind: "endpoint", label: "Local model"),
                    cap("key.brave", kind: "key", label: "Web search API key"),
                    cap("perm.mic", kind: "perm", label: "Microphone")]
        let three = status(caps, [
            feature("chat", "Chat", requires: ["key.anthropic", "endpoint.ollama"], anyOf: model),
            feature("design.studio", "Design Studio", requires: ["key.anthropic", "endpoint.ollama"],
                    anyOf: model),
            feature("research", "Research", requires: ["key.brave", "key.anthropic", "endpoint.ollama"],
                    anyOf: model)])
        guard case .chooseOne(_, _, let blocking) = NextStep.pick(three) else {
            return XCTFail("three blocked features lost to one: \(NextStep.pick(three))")
        }
        XCTAssertEqual(blocking.map(\.id), ["chat", "design.studio", "research"])

        // One each: the group's cheapest option is an endpoint, cheaper than a key...
        let versusKey = status(caps, [
            feature("chat", "Chat", requires: ["key.anthropic", "endpoint.ollama"], anyOf: model),
            feature("x", "X", requires: ["key.brave"])])
        guard case .chooseOne = NextStep.pick(versusKey) else {
            return XCTFail("a key beat a choice whose cheapest option is an endpoint")
        }
        // ...and dearer than a permission.
        let versusPerm = status(caps, [
            feature("chat", "Chat", requires: ["key.anthropic", "endpoint.ollama"], anyOf: model),
            feature("m", "M", requires: ["perm.mic"])])
        guard case .unblock(let c, _, _) = NextStep.pick(versusPerm) else {
            return XCTFail("expected the permission, got \(NextStep.pick(versusPerm))")
        }
        XCTAssertEqual(c.id, "perm.mic")
    }

    /// Exactly on the bar: a 2 of 3 group with two met is clear, with one met it needs one
    /// more and offers the two left.
    func testAGroupIsClearExactlyAtItsMinimum() {
        let three: [SetupStatus.Feature.Group] = [.init(capabilities: ["a", "b", "c"], min: 2)]
        let met2 = status([cap("a", kind: "key", label: "A", satisfied: true),
                           cap("b", kind: "key", label: "B", satisfied: true),
                           cap("c", kind: "key", label: "C")],
                          [feature("f", "F", requires: ["a", "b", "c"], anyOf: three)])
        XCTAssertTrue(NextStep.pick(met2).isClear)
        let met1 = status([cap("a", kind: "key", label: "A", satisfied: true),
                           cap("b", kind: "key", label: "B"),
                           cap("c", kind: "key", label: "C")],
                          [feature("f", "F", requires: ["a", "b", "c"], anyOf: three)])
        guard case .chooseOne(let options, let needed, _) = NextStep.pick(met1) else {
            return XCTFail("one short of the bar read as \(NextStep.pick(met1))")
        }
        XCTAssertEqual(options.map(\.id), ["b", "c"])
        XCTAssertEqual(needed, 1)
    }

    /// W25 round 2: a key that completes Chat's group AND blocks Focus log on its own
    /// unblocks two features; the model choice unblocks one. The key wins, naming both.
    func testASingleCountsTheGroupsItCompletes() {
        let s = status([cap("perm.screen_recording", kind: "perm", label: "Screen Recording",
                            satisfied: true),
                        cap("key.anthropic", kind: "key", label: "Anthropic API key"),
                        cap("endpoint.ollama", kind: "endpoint", label: "Local model")],
                       [feature("chat", "Chat", requires: ["key.anthropic", "endpoint.ollama"],
                                anyOf: model),
                        feature("focus", "Focus log",
                                requires: ["perm.screen_recording", "key.anthropic"])])
        guard case .unblock(let c, let blocking, let orUnblocks) = NextStep.pick(s) else {
            return XCTFail("expected the key for both, got \(NextStep.pick(s))")
        }
        XCTAssertEqual(c.id, "key.anthropic")
        // W25 round 3: Chat runs on a local model too, so it is not "cannot run without it".
        XCTAssertEqual(blocking.map(\.id), ["focus"])
        XCTAssertEqual(orUnblocks.map(\.id), ["chat"])
    }

    /// Compare needs both; Research needs one of them. The local model clears Compare's
    /// half and Research's group, so it is named for both.
    func testTheCountNamesEveryFeatureAStepUnblocks() {
        let s = status([cap("key.brave", kind: "key", label: "Web search API key", satisfied: true),
                        cap("key.anthropic", kind: "key", label: "Anthropic API key"),
                        cap("endpoint.ollama", kind: "endpoint", label: "Local model")],
                       [feature("compare", "Compare", requires: ["key.anthropic", "endpoint.ollama"]),
                        feature("research", "Research",
                                requires: ["key.brave", "key.anthropic", "endpoint.ollama"],
                                anyOf: model)])
        guard case .unblock(let c, let blocking, let orUnblocks) = NextStep.pick(s) else {
            return XCTFail("got \(NextStep.pick(s))")
        }
        XCTAssertEqual(c.id, "endpoint.ollama")
        XCTAssertEqual(blocking.map(\.id), ["compare"])
        XCTAssertEqual(orUnblocks.map(\.id), ["research"], "Research runs on the key instead")
    }

    /// The words never say "cannot run without it" about a feature with another way to run,
    /// nor that a feature "can run" with a step while it may still lack something else
    /// (W25 round 4: Research also needs the web search key).
    func testTheWordsKeepNeedsApartFromOneWayToRun() {
        let list: ([String]) -> String = { $0.joined(separator: " and ") }
        XCTAssertEqual(NextStep.unblockClauses(blocking: ["Focus log"], orUnblocks: ["Research"], list: list),
                       "Focus log cannot run without it, and Research needs it or another option")
        XCTAssertEqual(NextStep.unblockClauses(blocking: ["Mailbox"], orUnblocks: [], list: list),
                       "Mailbox cannot run without it")
        XCTAssertEqual(NextStep.unblockClauses(blocking: [], orUnblocks: ["Chat", "Research"], list: list),
                       "Chat and Research need it or another option")
        for words in [NextStep.unblockClauses(blocking: ["A"], orUnblocks: ["B", "C"], list: list),
                      NextStep.unblockClauses(blocking: [], orUnblocks: ["B"], list: list)] {
            XCTAssertFalse(words.contains("can run"), "a promise the step alone cannot keep: \(words)")
        }
    }

    func testNothingChosenAndAnUnmetDependency() {
        XCTAssertEqual(NextStep.pick(status([], [feature("a", "A", chosen: false)])),
                       .chooseFeatures)
        let s = status([], [feature("brief", "Brief", dependsOn: ["calendar"]),
                            feature("calendar", "Calendar", chosen: false)])
        guard case .turnOn(let needs, let f) = NextStep.pick(s) else { return XCTFail() }
        XCTAssertEqual(needs, ["calendar"])
        XCTAssertEqual(f.id, "brief")
    }

    // MARK: - The rail

    func testTheRailNeverStepsBackwards() {
        var c = RailCursor()
        XCTAssertTrue(c.draws(.look))
        XCTAssertTrue(c.draws(.look), "the same beat again is not backwards")
        XCTAssertTrue(c.draws(.handOff))
        XCTAssertTrue(c.draws(.prove))
        XCTAssertFalse(c.draws(.handOff), "HAND OFF after PROVE is a step backwards")
        XCTAssertFalse(c.draws(.look))
        XCTAssertTrue(c.draws(.prove))
        XCTAssertEqual(c.furthest, .prove)
    }

    // MARK: - The shipped commands read the one decision

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Doctor cannot say "in order" without asking the decision `next` uses.
    func testDoctorAndNextAskTheSameQuestion() throws {
        let doctor = try source("Sources/GruxCLI/Commands/Doctor.swift")
        let next = try source("Sources/GruxCLI/Commands/Next.swift")
        XCTAssertTrue(doctor.contains("NextStep.pick("),
            "grux doctor ends without asking NextStep, so it can call a Mac in order while "
            + "grux next names something blocking a feature")
        XCTAssertTrue(next.contains("NextStep.pick("),
            "grux next decides on its own instead of through NextStep")
        XCTAssertFalse(next.contains("let effort ="),
            "grux next keeps its own copy of the choice, which is how the two drift")
        if let ok = doctor.range(of: "Everything this command can check is in order") {
            let before = doctor[..<ok.lowerBound]
            XCTAssertTrue(before.contains("case .nothingRequired"),
                "doctor prints \"in order\" without first checking that nothing blocks")
        }
    }

    /// Every rail goes through the cursor, so no command can draw one backwards.
    func testEveryRailIsDrawnThroughTheCursor() throws {
        let frame = try source("Sources/GruxCLI/Frame.swift")
        XCTAssertEqual(frame.components(separatedBy: "renderer.rail(current:").count - 1, 1,
            "Frame draws a rail in more than one place, so one can skip the RailCursor")
        XCTAssertTrue(frame.contains("rails.cursor.draws(beat) ? renderer.rail(current: beat)"),
            "Frame draws its rail without asking the RailCursor, so a rail can mark a beat "
            + "before one already on screen")
        XCTAssertFalse(frame.contains("renderer.rail(current: .handOff)"),
            "the HAND OFF rail is drawn around the cursor")

        // Outside Frame, only the two screens that are not a command's answer: setup's
        // picker clears and redraws the whole terminal, and serve writes its rail to stderr.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GruxCLI/Commands")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(names.count, 40, "read \(names.count) commands")
        var around: [String] = []
        for name in names where !["Setup.swift", "Serve.swift"].contains(name) {
            let code = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            if code.contains(".rail(current:") { around.append(name) }
        }
        XCTAssertEqual(around, [], "these commands draw a rail around Frame's cursor: "
            + around.sorted().joined(separator: ", "))
    }
}
