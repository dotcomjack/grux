import XCTest
@testable import Grux

/// D142 item 3 (sense pass 16, `logs/fr85/modelKey-1.png`): with a model found
/// on the Mac, Connect a model offered "Use the model on this Mac" and "Use a
/// local model instead", two buttons that run the same `useLocalModel()`, and
/// said under Skip "Chat will ask for one" beside the model it had just found.
/// Its local lines also promised "nothing leaves this Mac", which a weather ask
/// (D141) and the update check make untrue: what stays on the Mac is the chat.
@MainActor
final class FirstRunModelStepOneChoiceTests: XCTestCase {

    func testTheSecondLocalButtonShowsOnlyWhenNothingWasFound() {
        XCTAssertTrue(ModelGate.showsLocalPath(.none))
        XCTAssertFalse(ModelGate.showsLocalPath(.found("qwen3.5:4b")))
    }

    /// 3.3 merge review: the loop's D142 rule hid the local button whenever a
    /// model was found, and 3.2.0's button by then fetched Grux Local, a
    /// different choice from "Use the model on this Mac". It stays for a Grux
    /// Local that is not here yet; the plain duplicate stays hidden.
    func testGruxLocalIsStillOfferedBesideAFoundModel() throws {
        let four = try XCTUnwrap(Cookbook.catalog.first { $0.id == "gruxai.com/grux/grux-local:4b" })
        XCTAssertTrue(ModelGate.showsLocalButton(.found("llama3.2:3b"), recommended: four, recommendedInstalled: false))
        XCTAssertFalse(ModelGate.showsLocalButton(.found("llama3.2:3b"), recommended: four, recommendedInstalled: true))
        XCTAssertFalse(ModelGate.showsLocalButton(.found("llama3.2:3b"), recommended: nil, recommendedInstalled: false),
                       "the plain local button beside a found model is the D142 duplicate")
        XCTAssertFalse(ModelGate.showsLocalButton(.looking, recommended: four, recommendedInstalled: false))
        XCTAssertTrue(ModelGate.showsLocalButton(.none, recommended: nil, recommendedInstalled: false))
        XCTAssertTrue(ModelGate.showsLocalButton(.none, recommended: four, recommendedInstalled: true))
    }

    func testSkipSaysWhatSkippingDoesWithAModelFound() {
        // W43-FIX P2-3: with no key and a model found, chat routes to it anyway
        // (`ModelRegistry.anthropicRoute(hasKey: false, hasLocal: true)` is `.local`).
        XCTAssertEqual(ModelRegistry.anthropicRoute(hasKey: false, hasLocal: true), .local)
        // So "Chat will ask for one" never sits beside a found model: since
        // D146 item 14 Skip is not offered then at all, and its note is only
        // the no-model one.
        XCTAssertFalse(ModelGate.offersSkip(.found("qwen3.5:4b"), localFailed: false))
        XCTAssertTrue(ModelGate.offersSkip(.none, localFailed: false))
        XCTAssertEqual(ModelGate.skipNote, "You can connect a model any time; Chat will ask for one.")
    }

    func testTheLocalLinesPromiseWhatIsTrue() {
        for line in [ModelGate.localLine, ModelGate.foundDetail(model: "Qwen 3.5 4B")] {
            XCTAssertFalse(line.lowercased().contains("nothing leaves"), line)
            XCTAssertTrue(line.contains("your chats stay"), line)
        }
    }

    func testTheScreenDrawsBehindTheRules() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"), encoding: .utf8)
        XCTAssertEqual(src.components(separatedBy: "if ModelGate.showsLocalPath(probe) {").count - 1, 1,
                       "the local line sits behind the rule")
        XCTAssertEqual(src.components(separatedBy: "ModelGate.showsLocalButton(probe,").count - 1, 2,
                       "the button and the Grux Local line each sit behind the button's rule")
        let rule = try XCTUnwrap(src.range(of: "if ModelGate.showsLocalButton(probe,"))
        let button = try XCTUnwrap(src.range(of: "Button(ModelGate.localButton("))
        XCTAssertTrue(rule.lowerBound < button.lowerBound)
        XCTAssertEqual(src.components(separatedBy: "Button(ModelGate.localButton(").count - 1, 1)
        let skipRule = try XCTUnwrap(src.range(of: "if ModelGate.offersSkip(probe, localFailed: localError != nil) {"))
        let note = try XCTUnwrap(src.range(of: "Text(ModelGate.skipNote)"))
        XCTAssertTrue(skipRule.lowerBound < note.lowerBound, "the no-model note draws only behind the Skip rule")
        XCTAssertEqual(src.components(separatedBy: "Text(ModelGate.skipNote)").count - 1, 1)
    }
    /// W45-P3 round 1 item 4: Skip, "Use a local model instead" and "Get
    /// Ollama" drew while the probe was still looking, then vanished when it
    /// found a model a moment later. Nothing that the answer can take away
    /// draws until the probe has answered; the screen says it is looking.
    func testNothingTheProbeCanTakeAwayDrawsWhileItLooks() {
        XCTAssertFalse(ModelGate.offersSkip(.looking, localFailed: false))
        XCTAssertFalse(ModelGate.showsLocalPath(.looking))
        XCTAssertFalse(ModelGate.offersOllamaLink(.looking))
        XCTAssertNil(ModelGate.Probe.looking.model)
        // Once it answered, each is back exactly as before.
        XCTAssertTrue(ModelGate.offersSkip(.none, localFailed: false))
        XCTAssertTrue(ModelGate.showsLocalPath(.none))
        XCTAssertTrue(ModelGate.offersOllamaLink(.none))
        XCTAssertEqual(ModelGate.lookingLine, "Looking for a model already on this Mac")
    }

    func testTheScreenStartsLookingAndAlwaysSettles() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("@State private var probe: ModelGate.Probe = .looking"),
                      "the first frame is drawn before the probe starts, so it must already be looking")
        let probe = try XCTUnwrap(src.range(of: "private func probeForLocalModel() async {"))
        let settle = try XCTUnwrap(src.range(of: "defer { if mine == probeGeneration, probe == .looking { probe = .none } }"),
                                   "every way out of the probe settles it, so Skip comes back when nothing is found")
        XCTAssertTrue(probe.upperBound < settle.lowerBound)
        XCTAssertTrue(src.contains("if probe == .looking {"), "the screen says it is looking")
        XCTAssertTrue(src.contains("Text(ModelGate.lookingLine)"))
    }

    /// W46-P3 item 7: SwiftUI runs `.task` again when the screen comes back,
    /// and a cancelled probe keeps going, so two probes could overlap: the
    /// first settled to nothing found (Skip drew) while the second was about
    /// to find the model (Skip vanished). The newest run is the only one that
    /// settles or names a model. A "running" flag was not enough (wave 48
    /// review): a cancelled first probe ends at once with no server read and
    /// settled to nothing found, while the second had already stepped aside.
    func testOnlyTheNewestProbeSettlesTheScreen() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "private func probeForLocalModel() async {"))
        let end = try XCTUnwrap(src.range(of: "\n    }\n", range: start.upperBound..<src.endIndex))
        let body = src[start.upperBound..<end.lowerBound]
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(Array(lines.prefix(3)), ["probeGeneration += 1",
                                                "let mine = probeGeneration",
                                                "defer { if mine == probeGeneration, probe == .looking { probe = .none } }"],
                       "the newest run is fixed before anything the probe settles")
        let writes = lines.filter { $0.contains("probe = ") && !$0.hasPrefix("//") }
        XCTAssertEqual(writes, ["defer { if mine == probeGeneration, probe == .looking { probe = .none } }",
                                "probe = .looking",
                                "if mine == probeGeneration { probe = .found(usable) }"],
                       "every write after an await belongs to the newest run")
        XCTAssertTrue(src.contains("@State private var probeGeneration = 0"))
        XCTAssertFalse(src.contains("probeRunning"))
    }
}
