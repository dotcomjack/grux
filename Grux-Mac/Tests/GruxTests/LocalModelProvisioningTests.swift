import XCTest
@testable import Grux

/// The free path has to leave somebody on a model that can actually answer.
///
/// The owner, 2026-08-30: "we should've wired up the most efficient local model for
/// them to power grux right off the bat with heavy encouragement for them to
/// connect their own key."
///
/// The button existed and the discovery was sound, but it accepted REACHABILITY
/// as if it were AVAILABILITY, a hole the method's own comment named and left
/// open: "a server that answers while holding zero pulled models satisfies this
/// and still cannot serve a turn". That is the same failure as the
/// workspace-scoped key on the same flow the same day, which is somebody being
/// told setup worked and finding out at the first message that it did not.
final class LocalModelProvisioningTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func useLocalModelBody() throws -> String {
        let lines = try source("Sources/Grux/Onboarding/OnboardingView.swift")
            .components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.contains("private func useLocalModel()")
        }) else {
            throw XCTSkip("useLocalModel was renamed; this file is about that method.")
        }
        guard let end = lines[(start + 1)...].firstIndex(where: {
            $0.hasPrefix("    private func ") || $0.hasPrefix("    private var ")
        }) else { return lines[start...].joined(separator: "\n") }
        return lines[start..<end].joined(separator: "\n")
    }

    /// A reachable server holding nothing must not pass for a working setup.
    func testTheGateChecksThatAModelIsActuallyInstalled() throws {
        let body = try useLocalModelBody()
        // THE EXACT CONDITIONAL, not the word.
        //
        // Asserting that "installedTags" appears anywhere in the method passed
        // against a plant that replaced the whole branch with `if false {`,
        // because the string survived inside the now-dead block. A source scan
        // cannot see dead code, so it has to pin the line that does the work.
        XCTAssertTrue(
            body.contains("if GruxConfig.usableLocalModels(OllamaManager.shared.installedTags).isEmpty {"),
            "The gate no longer branches on whether a USABLE model is installed. Plain "
                + "`installedTags.isEmpty` is not enough: a server holding only the "
                + "superseded model passes it and cannot serve a turn.")
        XCTAssertTrue(body.contains("await OllamaManager.shared.refreshInstalled()"),
                      "Nothing refreshes the installed list, so the check reads stale state.")
    }

    /// And the check has to happen BEFORE the gate reports success.
    ///
    /// Ordering is the whole assertion: a tag check that runs after
    /// `completeModelKey()` would satisfy the test above and still ship the bug.
    func testTheModelCheckHappensBeforeTheGateCompletes() throws {
        let body = try useLocalModelBody()
        guard let check = body.range(of: "installedTags"),
              let complete = body.range(of: "completeModelKey")
        else { return XCTFail("Expected both an installed check and a completion.") }
        XCTAssertLessThan(check.lowerBound, complete.lowerBound,
                          "The gate reports success before checking that a model exists.")
    }

    /// It fetches the best model for THIS Mac, not a fixed tag.
    ///
    /// `Cookbook.headline` scores the catalog against the machine's real memory
    /// budget, which is what "the most efficient local model for them" means.
    func testItFetchesTheHeadlinePickForThisMachine() throws {
        let body = try useLocalModelBody()
        XCTAssertTrue(body.contains("Cookbook.headline"),
                      "The gate no longer picks per machine.")
        XCTAssertTrue(body.contains("HardwareProfile.detect"),
                      "The pick is not scored against this Mac's hardware.")
        // `pullRefusal` CONTAINS "pull", so the loose substring matched a plant
        // that had deleted the fetch entirely. The call has to be named exactly.
        XCTAssertTrue(body.contains("await OllamaManager.shared.pull(pick.id)"),
                      "Nothing actually fetches a model, so a bare Ollama still dead-ends.")
    }

    /// Disk is checked before a multi-gigabyte download starts.
    func testItRefusesToStartAPullThatCannotFit() throws {
        let body = try useLocalModelBody()
        XCTAssertTrue(body.contains("pullRefusal"),
                      "A pull can start with no room for it.")
    }

    /// The spinner stops on every exit, including the failures.
    ///
    /// Regression guard on a bug introduced while fixing this one: moving the
    /// reset below the first guard left the post-condition failure returning
    /// with the spinner still turning. There are six exits; a `defer` is the
    /// only shape that does not depend on remembering all of them.
    func testTheSpinnerIsClearedOnEveryPath() throws {
        let body = try useLocalModelBody()
        XCTAssertTrue(body.contains("defer { probingLocal = false }"),
                      "The spinner reset is back to being per-exit, which has already been "
                        + "wrong once.")
    }

    /// The dead end that assumed the reader knows what Ollama is.
    func testTheMissingServerMessageTellsAStrangerWhatToDo() throws {
        let body = try useLocalModelBody()
        XCTAssertTrue(body.contains("ollama.com"),
                      "The failure does not say where to get the thing it needs.")
        XCTAssertTrue(body.lowercased().contains("free app")
                        || body.lowercased().contains("a free"),
                      "The failure names Ollama without saying what it is.")
        // DELIBERATELY NOT "and you could paste a key instead".
        //
        // OnboardingLocalPathTests already pins that, with a rationale worth
        // keeping: somebody who pressed this button has told Grux which path
        // they want, and sending them to buy a key is the one instruction that
        // is certainly wrong for them. An earlier draft of this message added it
        // and that test caught it. The fix a stranger needs here is what Ollama
        // IS and where to get it, not a different product.
        XCTAssertFalse(body.contains("Pasting a key above"),
                       "The local failure pushes the user off the path they chose.")
    }

    /// The encouragement the owner asked for, on the screen where the choice is made.
    func testTheScreenEncouragesAddingAKey() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        XCTAssertTrue(src.contains("A key is worth adding when you have one."),
                      "The local path no longer says a key is better, so somebody judges "
                        + "Grux by a small local model and never learns there is more.")
        XCTAssertTrue(src.contains("Settings, Models"),
                      "The encouragement does not say where to add one later.")
    }

    /// A multi-gigabyte download has to say what it is doing.
    func testTheDownloadNamesTheModelAndItsSize() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        XCTAssertTrue(src.contains("private var pullLabel"),
                      "There is no label for the download.")
        XCTAssertTrue(src.contains("Downloading"),
                      "The spinner still says only that it is looking.")
        XCTAssertTrue(src.contains("pulling.diskGB"),
                      "The download does not say how big it is.")
    }
}
