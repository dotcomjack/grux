import XCTest
import AVFoundation
import CoreAudio
@testable import Grux

/// Voice processing runs only when the microphone can hear the Mac's output.
///
/// Measured 2026-09-21: with the output on AirPods Max and ambient armed, the
/// IO thread spent about 10% of a core in the neural echo canceller and every
/// other app's audio was pushed onto the communications path, to cancel an
/// echo the built-in mic could never hear. These pin the rule, the CoreAudio
/// mapping that feeds it, the ducking both sites apply, and that both sites
/// actually use it. Nothing here opens an audio device.
final class VoiceProcessingPolicyTests: XCTestCase {

    private typealias Policy = VoiceProcessingPolicy

    private func decide(_ route: Policy.OutputRoute,
                        settingOn: Bool = true,
                        whitelisted: Bool = false) -> Policy.Decision {
        Policy.shouldEnable(settingOn: settingOn, micWhitelisted: whitelisted, output: route)
    }

    // MARK: - The rule

    func testBluetoothOutputTurnsVoiceProcessingOff() {
        let d = decide(.bluetooth)
        XCTAssertFalse(d.enable, "AirPods or a Bluetooth headset: the mic cannot hear it, so VPIO only costs quality")
        XCTAssertTrue(d.reason.contains("Bluetooth"), "the log line does not say why: \(d.reason)")
    }

    func testBuiltInHeadphonesTurnVoiceProcessingOff() {
        let d = decide(.builtInHeadphones)
        XCTAssertFalse(d.enable, "headphones in the headphone port: the mic cannot hear them")
        XCTAssertTrue(d.reason.contains("headphones"), "the log line does not say why: \(d.reason)")
    }

    func testBuiltInSpeakersKeepVoiceProcessingOn() {
        XCTAssertTrue(decide(.builtInSpeakers).enable,
                      "the built-in mic hears the built-in speakers; echo cancellation is the whole point")
    }

    func testExternalSpeakersKeepVoiceProcessingOn() {
        XCTAssertTrue(decide(.externalSpeakers).enable,
                      "an HDMI, DisplayPort, USB or AirPlay output may be speakers the mic can hear")
    }

    func testUnknownOutputKeepsVoiceProcessingOn() {
        XCTAssertTrue(decide(.unknown).enable,
                      "an output we cannot classify must keep the behaviour from before this rule")
    }

    func testSettingOffWinsOverEveryRoute() {
        for route in Policy.OutputRoute.allCases {
            let d = decide(route, settingOn: false)
            XCTAssertFalse(d.enable, "Settings switch off but VPIO enabled for \(route)")
            XCTAssertTrue(d.reason.contains("Settings"), "reason for \(route) does not name the switch: \(d.reason)")
        }
    }

    func testWhitelistedMicWinsOverEveryRoute() {
        for route in Policy.OutputRoute.allCases {
            let d = decide(route, whitelisted: true)
            XCTAssertFalse(d.enable, "whitelisted mic but VPIO enabled for \(route)")
            XCTAssertTrue(d.reason.contains("whitelisted"), "reason for \(route) does not name the whitelist: \(d.reason)")
        }
    }

    // MARK: - CoreAudio to route

    func testCoreAudioTransportsMapToTheRightRoute() {
        let hdpn = Policy.fourCC("hdpn"), ispk = Policy.fourCC("ispk")
        XCTAssertEqual(hdpn, 0x6864_706E, "fourCC is not big-endian ASCII")
        XCTAssertEqual(ispk, 0x6973_706B)

        XCTAssertEqual(Policy.route(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil), .bluetooth)
        XCTAssertEqual(Policy.route(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil), .bluetooth)
        XCTAssertEqual(Policy.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: hdpn), .builtInHeadphones)
        XCTAssertEqual(Policy.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: ispk), .builtInSpeakers)
        XCTAssertEqual(Policy.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil), .unknown,
                       "a built-in output whose data source cannot be read is not known to be speakers")
        for external in [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
                         kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeAirPlay] {
            XCTAssertEqual(Policy.route(transport: external, dataSource: nil), .externalSpeakers,
                           "transport \(external) should read as speakers the mic may hear")
        }
        XCTAssertEqual(Policy.route(transport: 0, dataSource: nil), .unknown)
        XCTAssertEqual(Policy.route(transport: kAudioDeviceTransportTypeVirtual, dataSource: nil), .unknown)
        XCTAssertEqual(Policy.route(transport: kAudioDeviceTransportTypeAggregate, dataSource: nil), .unknown)
    }

    // MARK: - Ducking

    /// Left unset, macOS applies its default ducking and lowers every other app
    /// for as long as voice processing runs. Ambient never set it.
    func testDuckingIsTheLeastTheApiOffers() {
        let ducking = Policy.otherAudioDucking
        XCTAssertFalse(ducking.enableAdvancedDucking.boolValue, "advanced ducking lowers other audio whenever speech is detected")
        XCTAssertEqual(ducking.duckingLevel, .min, "other apps are ducked more than the minimum")
    }

    // MARK: - Both sites use it

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Grux")

    /// Source with whole-line comments dropped, so prose that NAMES a call is
    /// not mistaken for the call.
    private static func code(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The defect this file exists for shipped because the ambient site had its
    /// own inline logic and no ducking, while dictation had both. A policy
    /// nobody calls proves nothing, so every file that enables voice
    /// processing (bar the SmokeTest probe, which is exempt in
    /// VoiceProcessingGuardTests for its own stated reason) must decide through
    /// the policy and apply its ducking.
    func testEveryVoiceProcessingSiteUsesThePolicyAndItsDucking() throws {
        guard let walker = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(Self.sources.path)")
        }
        var sites: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = try Self.code(at: url)
            if code.contains("setVoiceProcessingEnabled(true)"), url.lastPathComponent != "SmokeTest.swift" {
                sites[url.lastPathComponent] = code
            }
        }
        // Anti-vacuity: a scan that finds nothing passes everything.
        XCTAssertEqual(Set(sites.keys), ["AmbientListener.swift", "VoiceInput.swift"],
                       "the set of files enabling voice processing changed; wire any new one through VoiceProcessingPolicy")
        for (file, code) in sites {
            XCTAssertTrue(code.contains("VoiceProcessingPolicy.shouldEnable("),
                          "\(file) enables voice processing without asking VoiceProcessingPolicy")
            XCTAssertTrue(code.contains("voiceProcessingOtherAudioDuckingConfiguration = VoiceProcessingPolicy.otherAudioDucking"),
                          "\(file) enables voice processing without applying the policy's ducking")
        }
    }

    // MARK: - The route watcher can be removed

    /// A block listener cannot be removed from Swift: the block type imports as
    /// a plain closure, every call wraps it in a new block, and removal matches
    /// on identity. Measured 2026-09-21: the block listener still fired after
    /// its removal and the C proc did not. The first cut of the route watcher
    /// used the block API, so every stop() leaked a listener and every mute and
    /// unmute stacked another.
    func testTheOutputRouteWatcherUsesARemovableListener() throws {
        let code = try Self.code(at: Self.sources.appendingPathComponent("Ambient/AmbientListener.swift"))
        XCTAssertTrue(code.contains("AudioObjectAddPropertyListener("), "the output route watcher is gone")
        XCTAssertTrue(code.contains("AudioObjectRemovePropertyListener("), "the watcher is installed but never removed")
        XCTAssertFalse(code.contains("PropertyListenerBlock("),
                       "a block listener cannot be removed from Swift; use AudioObjectAddPropertyListener with a proc")
    }
}
