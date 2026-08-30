import XCTest
@testable import Grux

/// The update phase, which reports what Grux found on THIS machine and warns
/// honestly about what a local model costs in quality.
///
/// Every machine here is fabricated. Asserting against the Mac this runs on
/// would produce a test whose result depends on whoever executes it, and worse,
/// one that silently stops covering the interesting cases: the developer machine
/// has plenty of memory, so the "this Mac cannot run one" branch would never
/// execute and could rot to nonsense unnoticed.
final class ModelUpdateReportTests: XCTestCase {

    private func mac(gb: Double, chip: String = "Apple M3 Pro") -> HardwareProfile {
        let bytes = UInt64(gb * 1_073_741_824)
        return HardwareProfile(
            chipName: chip,
            physicalMemoryBytes: bytes,
            // Apple Silicon reports roughly 75 percent of RAM as the GPU
            // working set, which is what the Cookbook budgets against.
            gpuWorkingSetBytes: UInt64(Double(bytes) * 0.75),
            cpuCoreCount: 12,
            hasUnifiedMemory: true,
            isAppleSilicon: true)
    }

    private func report(gb: Double,
                        cloud: Bool,
                        server: Bool = false,
                        installed: [String] = []) -> ModelUpdateReport {
        ModelUpdateReport.build(profile: mac(gb: gb),
                                hasCloudModel: cloud,
                                localServerRunning: server,
                                installedTags: installed)
    }

    // MARK: - The report is about this machine, not a template

    /// The summary has to carry numbers a reader can check against About This
    /// Mac, or it is a generic sentence pretending to be a measurement.
    func testTheMachineSummaryNamesTheRealChipAndMemory() {
        let r = report(gb: 36, cloud: true)

        XCTAssertTrue(r.machineSummary.contains("Apple M3 Pro"), r.machineSummary)
        XCTAssertTrue(r.machineSummary.contains("36GB"), r.machineSummary)
    }

    /// A bigger machine must actually be told it can run more. If these two
    /// agree, the "machine-specific" claim is decoration.
    func testABiggerMacIsOfferedMoreThanASmallerOne() {
        let air = report(gb: 8, cloud: true)
        let studio = report(gb: 128, cloud: true)

        XCTAssertGreaterThan(studio.runnable.count, air.runnable.count,
                             "8GB got \(air.runnable.count), 128GB got \(studio.runnable.count)")
        XCTAssertNotEqual(air.capabilitySummary, studio.capabilitySummary)
    }

    /// The headline is the best model that FITS, never merely the biggest.
    func testTheHeadlineModelFitsTheMachine() {
        for gb in [8.0, 16.0, 36.0, 64.0, 128.0] {
            let r = report(gb: gb, cloud: true)
            guard let headline = r.headline, let fit = r.headlineFit else { continue }
            XCTAssertNotEqual(fit, .tooBig,
                              "\(Int(gb))GB was told to run \(headline.id), which does not fit")
            XCTAssertLessThanOrEqual(headline.estimatedMemoryGB, r.profile.modelBudgetGB,
                                     "\(Int(gb))GB headline \(headline.id)")
        }
    }

    /// A machine too small for anything in the catalog must say so rather than
    /// recommending something it cannot run.
    func testATinyMacIsToldNothingFits() {
        let r = report(gb: 2, cloud: true)

        XCTAssertNil(r.headline)
        XCTAssertTrue(r.runnable.isEmpty)
        XCTAssertFalse(r.offersLocalOption)
        XCTAssertTrue(r.capabilitySummary.contains("No local model"), r.capabilitySummary)
    }

    // MARK: - The honest warning

    /// Four situations, four different truths. If any two produce the same
    /// sentence then one of them is being told something that is not about them.
    func testEachSituationGetsItsOwnWarning() {
        let warnings = [
            report(gb: 36, cloud: true).qualityWarning,    // cloud + local
            report(gb: 2, cloud: true).qualityWarning,     // cloud only
            report(gb: 36, cloud: false).qualityWarning,   // local only
            report(gb: 2, cloud: false).qualityWarning     // neither
        ]

        XCTAssertEqual(Set(warnings).count, 4, "two situations share a warning")
        for w in warnings { XCTAssertFalse(w.isEmpty) }
    }

    /// The decision asked for an honest statement that local models lower
    /// quality. Where a local model is genuinely an option, the warning must say
    /// so in words rather than implying it.
    func testTheWarningSaysOutrightThatLocalIsWeaker() {
        for cloud in [true, false] {
            let w = report(gb: 36, cloud: cloud).qualityWarning
            let admits = w.contains("worse") || w.contains("weaker")
            XCTAssertTrue(admits,
                          "a local model is offered and the warning does not concede the "
                          + "quality cost; got: \(w)")
        }
    }

    /// With no cloud key the local model is not a downgrade, it is the only
    /// option, so telling that person it is worse than a cloud model they do not
    /// have would be advice they cannot act on.
    func testAMachineWithNoCloudKeyIsNotToldToPreferTheCloudModel() {
        let r = report(gb: 36, cloud: false)

        XCTAssertFalse(r.qualityWarning.contains("Grux keeps using your cloud model"),
                       r.qualityWarning)
        XCTAssertTrue(r.qualityWarning.contains("add a key"), r.qualityWarning)
    }

    /// The worst case has to be stated plainly rather than softened, because a
    /// user in it has a Grux that cannot think and needs to know why.
    func testWithNeitherOptionTheReportSaysGruxCannotThinkYet() {
        let r = report(gb: 2, cloud: false)

        XCTAssertTrue(r.qualityWarning.contains("cannot think yet"), r.qualityWarning)
        XCTAssertTrue(r.qualityWarning.contains("Adding a key"), r.qualityWarning)
    }

    /// A machine that cannot run a local model must not be handed a warning
    /// about local model quality. It is not a choice they have.
    func testAMachineThatCannotRunOneIsNotWarnedAboutQuality() {
        let r = report(gb: 2, cloud: true)

        XCTAssertFalse(r.qualityWarning.contains("worse"), r.qualityWarning)
        XCTAssertTrue(r.qualityWarning.contains("does not have the memory"), r.qualityWarning)
    }

    // MARK: - The lines on screen must not contradict each other

    /// A screenshot of an 8GB Mac with no key showed "Cloud model: Not set yet"
    /// and, two lines below it, "Ollama is not running. Grux can still use your
    /// cloud model." Both lines were individually reasonable and together they
    /// were nonsense, because the second was hardcoded in the view and could not
    /// see the first.
    func testTheLocalServerLineDoesNotPromiseACloudModelThatIsNotThere() {
        let neither = report(gb: 8, cloud: false, server: false)

        XCTAssertFalse(neither.localServerSummary.contains("your cloud model"),
                       "there is no cloud model to fall back on; got: "
                       + neither.localServerSummary)
        XCTAssertTrue(neither.localServerSummary.contains("no cloud key"),
                      neither.localServerSummary)

        // With a key, the fallback sentence is true and should stay.
        let withKey = report(gb: 8, cloud: true, server: false)
        XCTAssertTrue(withKey.localServerSummary.contains("your cloud model"),
                      withKey.localServerSummary)
    }

    /// No pair of lines on the screen may disagree about whether a cloud key
    /// exists. This is the general form of the bug above.
    func testNoLineClaimsACloudModelWhenNoneIsConfigured() {
        for gb in [2.0, 8.0, 36.0, 128.0] {
            let r = report(gb: gb, cloud: false, server: false)
            let lines = [r.cloudSummary, r.localServerSummary,
                         r.capabilitySummary, r.qualityWarning]
            for line in lines {
                XCTAssertFalse(line.contains("Grux uses it by default"),
                               "\(Int(gb))GB with no key: \(line)")
                XCTAssertFalse(line.contains("can still use your cloud model"),
                               "\(Int(gb))GB with no key: \(line)")
            }
        }
    }

    // MARK: - Availability is reported, not assumed

    func testInstalledModelsAndServerStateAreCarried() {
        let r = report(gb: 36, cloud: true, server: true, installed: ["llama3.1:8b"])

        XCTAssertTrue(r.localServerRunning)
        XCTAssertEqual(r.installedTags, ["llama3.1:8b"])
    }

    /// House rule, and this screen is prose-heavy enough to be worth checking.
    func testNoBannedDashesInAnyGeneratedCopy() {
        for gb in [2.0, 8.0, 36.0, 128.0] {
            for cloud in [true, false] {
                let r = report(gb: gb, cloud: cloud)
                for text in [r.machineSummary, r.capabilitySummary, r.qualityWarning] {
                    XCTAssertFalse(text.contains("\u{2014}"), "em dash in: \(text)")
                    XCTAssertFalse(text.contains("\u{2013}"), "en dash in: \(text)")
                }
            }
        }
    }
}
