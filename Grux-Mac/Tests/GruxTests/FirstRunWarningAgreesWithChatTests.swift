import XCTest
@testable import Grux

/// W38-FIX P3 3. First run's last screen could read "Chat uses: mistral:7b, on
/// this Mac." directly above "There is no cloud key and no local model this
/// machine can run, so Grux cannot think yet." on a Mac whose memory fits no
/// catalog model while chat runs on one the person installed themselves. With a
/// key on file and chat routed local, the same paragraph opened "There is no
/// cloud key" under "Cloud model: Configured". Every combination is walked so no
/// pair of lines on the screen can disagree about what chat runs on.
final class FirstRunWarningAgreesWithChatTests: XCTestCase {

    private func mac(gb: Double) -> HardwareProfile {
        let bytes = UInt64(gb * 1_073_741_824)
        return HardwareProfile(chipName: "Apple M1", physicalMemoryBytes: bytes,
                               gpuWorkingSetBytes: UInt64(Double(bytes) * 0.75), cpuCoreCount: 8,
                               hasUnifiedMemory: true, isAppleSilicon: true)
    }

    private func report(gb: Double, key: Bool, routesToCloud: Bool, server: Bool,
                        installed: [String], chat: String?) -> ModelUpdateReport {
        ModelUpdateReport.build(profile: mac(gb: gb), hasCloudModel: key, routesToCloud: routesToCloud,
                                localServerRunning: server, installedTags: installed, chatModel: chat)
    }

    func test_aSmallMacChattingOnItsOwnModel_isNotToldGruxCannotThink() {
        let r = report(gb: 2, key: false, routesToCloud: false, server: true,
                       installed: ["mistral:7b"], chat: "mistral:7b")
        XCTAssertNil(r.headline, "precondition: nothing in the catalog fits 2 GB")
        XCTAssertEqual(r.chatSummary, "mistral:7b, on this Mac.")
        XCTAssertFalse(r.qualityWarning.contains("cannot think yet"), r.qualityWarning)
        XCTAssertTrue(r.qualityWarning.contains("already on this Mac"), r.qualityWarning)
    }

    func test_aKeyOnFile_isNeverCalledMissing() {
        let r = report(gb: 2, key: true, routesToCloud: false, server: true,
                       installed: ["mistral:7b"], chat: "mistral:7b")
        XCTAssertFalse(r.qualityWarning.contains("no cloud key"), r.qualityWarning)
        XCTAssertTrue(r.qualityWarning.contains("Your key is still on file"), r.qualityWarning)
    }

    /// Every combination, against the rule in plain words: when the screen says
    /// chat uses a model on this Mac, nothing says Grux cannot think or that no
    /// local model runs; when a key is configured, nothing says there is none;
    /// with no key, nothing says one is on file or in use.
    func test_everyCombination_linesAgree() {
        for gb in [2.0, 16.0] {
            for key in [false, true] {
                for routesToCloud in [false, true] {
                    for server in [false, true] {
                        for installed in [[], ["mistral:7b"]] {
                            for chat in [nil, "mistral:7b"] as [String?] {
                                let r = report(gb: gb, key: key, routesToCloud: routesToCloud,
                                               server: server, installed: installed, chat: chat)
                                let screen = [r.cloudSummary, r.localServerSummary, r.capabilitySummary,
                                              r.chatSummary ?? "", r.qualityWarning].joined(separator: " | ")
                                let at = "gb \(gb) key \(key) cloud \(routesToCloud) server \(server) "
                                    + "installed \(installed) chat \(chat ?? "nil"): \(screen)"
                                if r.chatSummary != nil {
                                    for claim in ["cannot think yet", "no local model this machine can run",
                                                  "Chat waits", "no local model Grux can use"] {
                                        XCTAssertFalse(screen.contains(claim), "\(claim) | \(at)")
                                    }
                                }
                                if key {
                                    XCTAssertFalse(r.qualityWarning.lowercased().contains("no cloud key"), at)
                                } else {
                                    for claim in ["still on file", "Grux uses it by default"] {
                                        XCTAssertFalse(screen.contains(claim), "\(claim) | \(at)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
