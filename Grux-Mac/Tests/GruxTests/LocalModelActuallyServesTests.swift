import XCTest
@testable import Grux

/// Setup finished on a local model that was not installed.
///
/// Found by walking the whole flow on the Mac Mini, 2026-08-30, which is the
/// only way it could have been found. Every gate passed: the server answered,
/// it held two models, the route was written to `.local`, the last screen
/// reported "Ollama is running, 2 model(s) installed", and onboarding recorded
/// `stage: done` with an honest skip ledger.
///
/// Then the first message returned
/// `{"error":"model 'llama3.2:3b' not found"}`, because the config still named
/// the SHIPPED DEFAULT while the machine held `qwen3:8b` and `qwen2.5:7b`.
///
/// Three checks had been added in sequence and each one moved the goalposts by
/// exactly one step: is a server there, does it hold anything, and now, is the
/// thing we are about to ASK FOR one of the things it holds.
final class LocalModelActuallyServesTests: XCTestCase {

    /// Exactly what the Mac Mini had. `qwen3:8b` is the SUPERSEDED model: this
    /// app measured it returning empty content on the endpoint it drives, and
    /// `migratingLocalModel` moves people off it. So the only usable entry here
    /// is `qwen2.5:7b`, and a first version of this fix that adopted `qwen3:8b`
    /// because it was present had its write undone by that migration.
    private let installed = ["qwen3:8b", "qwen2.5:7b"]

    /// The reported case, exactly.
    func testAConfiguredModelThatIsNotInstalledIsReplaced() {
        // GUARD, never assert-then-force-unwrap. XCTAssertNotNil does not halt,
        // so `adopt!` on the next line crashed the whole xctest process when
        // this test was planted against, and a crash reads as "did not run"
        // rather than "failed". A regression would have taken the suite down
        // instead of reporting itself.
        guard let adopt = GruxConfig.installedModelToAdopt(
            configured: "llama3.2:3b", installed: installed, headline: nil)
        else { return XCTFail("The default was kept even though nothing serves it.") }
        XCTAssertTrue(installed.contains(adopt), "Adopted \(adopt), which is not installed.")
    }

    /// A configured model that IS installed is left alone.
    ///
    /// Somebody who deliberately chose qwen2.5 must not be moved off it just
    /// because the cookbook would have picked something else for this Mac.
    func testAnInstalledChoiceIsNeverOverridden() {
        XCTAssertNil(GruxConfig.installedModelToAdopt(
            configured: "qwen2.5:7b", installed: installed, headline: "qwen3:8b"))
    }

    /// The headline pick wins when it is present and usable.
    func testTheHeadlinePickIsPreferredWhenItIsInstalled() {
        XCTAssertEqual(
            GruxConfig.installedModelToAdopt(
                configured: "llama3.2:3b",
                installed: ["qwen2.5:7b", "gemma3:4b"],
                headline: "gemma3:4b"),
            "gemma3:4b")
    }

    /// THE SUPERSEDED MODEL IS NEVER ADOPTED, even as the headline, even when it
    /// is the only thing on the machine.
    ///
    /// This is the correction. Adopting it wrote a value the decode migration
    /// immediately reversed, which left the config and the chat footer naming
    /// different models and fixed nothing.
    func testTheSupersededModelIsNeverAdopted() {
        XCTAssertEqual(
            GruxConfig.installedModelToAdopt(
                configured: "llama3.2:3b", installed: installed, headline: "qwen3:8b"),
            "qwen2.5:7b",
            "Adopted the superseded model, or skipped the usable one beside it.")

        XCTAssertNil(
            GruxConfig.installedModelToAdopt(
                configured: "llama3.2:3b", installed: ["qwen3:8b"], headline: "qwen3:8b"),
            "A server holding only the superseded model must count as holding nothing.")
    }

    /// And that is the same rule the caller uses to decide whether to fetch.
    func testAServerWithOnlyTheSupersededModelCountsAsEmpty() {
        XCTAssertTrue(GruxConfig.usableLocalModels(["qwen3:8b"]).isEmpty)
        XCTAssertEqual(GruxConfig.usableLocalModels(installed), ["qwen2.5:7b"])
    }

    /// A headline that is NOT installed must not be adopted.
    ///
    /// This is the bug one level up: preferring a name over a fact is exactly
    /// what shipped `llama3.2:3b` to a machine that did not have it.
    func testAHeadlineThatIsNotInstalledIsIgnored() {
        guard let adopt = GruxConfig.installedModelToAdopt(
            configured: "llama3.2:3b", installed: installed, headline: "gemma3:27b")
        else { return XCTFail("Nothing was adopted at all.") }
        XCTAssertTrue(installed.contains(adopt),
                      "Adopted the headline \(adopt) without checking it was installed.")
    }

    /// Nothing installed means there is nothing to adopt, and the caller has
    /// already refused to proceed by then.
    func testAnEmptyServerAdoptsNothing() {
        XCTAssertNil(GruxConfig.installedModelToAdopt(
            configured: "llama3.2:3b", installed: [], headline: "qwen3:8b"))
    }

    /// An empty configured value counts as not installed.
    func testAnUnsetModelIsTreatedAsNotInstalled() {
        XCTAssertNotNil(GruxConfig.installedModelToAdopt(
            configured: "", installed: installed, headline: nil))
    }

    /// The local path writes BOTH fields, because they are one idea to a reader.
    ///
    /// Chat reads `offlineLLMModel` through the registry and the background
    /// local path reads `localLLMModel`. Fixing one and not the other leaves
    /// half the app asking for a model that is not there.
    func testTheLocalPathWritesBothModelFields() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingView.swift")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("AppState.shared.config.offlineLLMModel = adopt"),
                      "Chat's model field is not updated, so chat still fails.")
        XCTAssertTrue(body.contains("AppState.shared.config.localLLMModel = adopt"),
                      "The background local path still asks for the old model.")
    }
}


/// The last screen of setup announced the opposite of what setup had just done.
///
/// Same walk, same Mac, 2026-08-30. Two screens after choosing "Use a local
/// model instead", "What Grux found on this Mac" reported "Cloud model:
/// Configured. Grux uses it by default." and went on to say "Grux keeps using
/// your cloud model by default." The route was `.local` at the time.
///
/// The report keyed both sentences off whether a KEY EXISTED, which used to be
/// the same thing as where chat routes and is not any more: the model gate
/// writes the route outright, and no-key-plus-a-local-model now falls forward to
/// local too.
final class UpdateReportTellsTheTruthTests: XCTestCase {

    private func report(hasKey: Bool, routesToCloud: Bool) -> ModelUpdateReport {
        ModelUpdateReport.build(profile: HardwareProfile.detect(),
                                hasCloudModel: hasKey,
                                routesToCloud: routesToCloud,
                                localServerRunning: true,
                                installedTags: ["qwen3:8b"])
    }

    /// The reported case: a key on file, chat routed local.
    func testAKeyOnFileButRoutedLocalDoesNotClaimTheCloudIsInUse() {
        let line = report(hasKey: true, routesToCloud: false).cloudSummary
        XCTAssertFalse(line.contains("uses it by default"),
                       "Still claims the cloud model is in use while chat routes local: \(line)")
        XCTAssertTrue(line.lowercased().contains("local"),
                      "Does not say where chat actually goes: \(line)")
    }

    /// And the paragraph under it must agree with the line above it.
    func testTheAdviceParagraphAgreesWithTheRoute() {
        let warning = report(hasKey: true, routesToCloud: false).qualityWarning
        XCTAssertFalse(warning.contains("keeps using your cloud model"),
                       "The advice contradicts the route: \(warning)")
    }

    /// The paragraph must not open "With no cloud key" when a key is on file.
    ///
    /// The first fix keyed this on the route alone, which put that sentence
    /// directly underneath "Configured, and not in use". Caught by looking at
    /// the rebuilt screen rather than by the tests, which is why the sweep is
    /// worth the time.
    func testTheAdviceDoesNotDenyAKeyThatIsOnFile() {
        let warning = report(hasKey: true, routesToCloud: false).qualityWarning
        XCTAssertFalse(warning.contains("no cloud key"),
                       "Says there is no key while the line above says it is configured: "
                        + warning)
        XCTAssertTrue(warning.contains("still on file"),
                      "Does not tell the reader their key is still there: \(warning)")
    }

    /// And with genuinely no key, the original wording is unchanged.
    func testWithNoKeyTheAdviceStillSaysSo() {
        XCTAssertTrue(report(hasKey: false, routesToCloud: false)
            .qualityWarning.contains("no cloud key"))
    }

    /// The ordinary case is unchanged: key on file and routed to it.
    func testAKeyThatIsActuallyInUseStillReadsThatWay() {
        XCTAssertTrue(report(hasKey: true, routesToCloud: true)
            .cloudSummary.contains("uses it by default"))
    }

    /// No key at all still reads the way it always did.
    func testNoKeyIsUnchanged() {
        XCTAssertTrue(report(hasKey: false, routesToCloud: false)
            .cloudSummary.contains("Not set yet"))
    }
}
