import XCTest
@testable import Grux

/// D138 item 5 (sense pass 15, `fr80/update-1.png`). First run's last screen read
/// "Ollama is running, 7 models installed." over "Grux Local 4B runs here (great
/// fit), and 7 more.", which reads as 8 installed models, and said "runs here" of a
/// model that was not downloaded. The catalog line now says which model fits this
/// Mac best, whether it is on this Mac yet, and counts the other catalog models as
/// catalog models. Its sibling named "the Developer door", a word the sidebar never
/// shows; it now names the sidebar's own Developer row.
@MainActor
final class FirstRunBestFitLineTests: XCTestCase {

    private let mini = HardwareProfile(chipName: "Apple M4", physicalMemoryBytes: 16 * 1_073_741_824,
                                       gpuWorkingSetBytes: 12 * 1_073_741_824, cpuCoreCount: 10,
                                       hasUnifiedMemory: true, isAppleSilicon: true)

    private func report(running: Bool = true, tags: [String]) -> ModelUpdateReport {
        ModelUpdateReport.build(profile: mini, hasCloudModel: false, routesToCloud: false,
                                localServerRunning: running, installedTags: tags)
    }

    private var headline: CookbookModel { report(tags: []).headline! }
    private var others: Int { report(tags: []).runnable.count - 1 }

    func test_aHeadlineNotDownloaded_saysSo() {
        let line = report(tags: ["qwen3.5:4b"]).capabilitySummary
        XCTAssertFalse(line.contains("runs here"), line)
        XCTAssertEqual(line, "\(headline.displayName) \(headline.parameterLabel) fits this Mac best (great fit), "
                       + "not downloaded yet. \(others) more models in the catalog also fit.")
    }

    func test_aHeadlineOnThisMac_saysItIsDownloaded() {
        XCTAssertEqual(report(tags: [headline.id, "qwen3.5:4b"]).capabilitySummary,
                       "\(headline.displayName) \(headline.parameterLabel) fits this Mac best (great fit), "
                       + "downloaded. \(others) more models in the catalog also fit.")
        // As Ollama lists a bare name, and in another case.
        XCTAssertTrue(report(tags: [headline.id.uppercased() + ":latest"]).capabilitySummary.contains("downloaded."))
    }

    /// Installed means a running server lists it; with Ollama off nothing is claimed either way.
    func test_withOllamaOff_claimsNeither() {
        let line = report(running: false, tags: [headline.id]).capabilitySummary
        XCTAssertFalse(line.contains("downloaded"), line)
        XCTAssertEqual(line, "\(headline.displayName) \(headline.parameterLabel) fits this Mac best (great fit). "
                       + "\(others) more models in the catalog also fit.")
    }

    /// The count is never read as installed models: zero, one and many others.
    func test_theOtherCount_isCatalogModels() {
        func line(_ n: Int) -> String {
            let r = report(tags: [])
            return ModelUpdateReport(headline: r.headline, runnable: Array(r.runnable.prefix(n + 1)),
                                     headlineFit: r.headlineFit, profile: mini, hasCloudModel: false,
                                     routesToCloud: false, localServerRunning: true,
                                     installedTags: []).capabilitySummary
        }
        XCTAssertTrue(line(0).hasSuffix("not downloaded yet."), line(0))
        XCTAssertTrue(line(1).hasSuffix(" 1 more model in the catalog also fits."), line(1))
        XCTAssertTrue(line(2).hasSuffix(" 2 more models in the catalog also fit."), line(2))
        for n in 0...2 { XCTAssertFalse(line(n).contains("and \(n) more"), line(n)) }
    }

    func test_theScreenLabelsTheLineAsTheBestFit() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift"))
        XCTAssertTrue(src.contains("line(\"Best fit for this Mac\", report.capabilitySummary)"))
        XCTAssertFalse(src.contains("\"What runs here\""))
    }

    func test_anOpenDeveloperRow_isNamedAsTheSidebarShowsIt() {
        let line = HowItWorksCopy.localModelsLine(door: .developer, developerUnlocked: true)
        XCTAssertFalse(line.contains("door"), line)
        XCTAssertEqual(line, "Local Models, under Developer in the sidebar, has the full list and can download any of them.")
    }
}
