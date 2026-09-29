import XCTest
import CoreAudio
@testable import Grux

/// eqMac makes its own VIRTUAL device the default output and plays through a
/// real one. Grux used to read any virtual output as unknown, which keeps echo
/// cancellation on, so AirPods behind eqMac got voice processing and the
/// music lost its quality. The real device is the one eqMac keeps running.
final class VoiceProcessingThroughEqMacTests: XCTestCase {

    private typealias D = VoiceProcessingPolicy.OutputDevice
    private let eqMac = D(name: "eqMac", transport: kAudioDeviceTransportTypeVirtual, dataSource: nil, isRunning: true)
    private let airPods = D(name: "AirPods Max", transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil, isRunning: true)
    private let speakersIdle = D(name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn,
                                 dataSource: VoiceProcessingPolicy.internalSpeakersDataSource, isRunning: false)
    private let speakersRunning = D(name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn,
                                    dataSource: VoiceProcessingPolicy.internalSpeakersDataSource, isRunning: true)

    func test_eqMacIntoAirPodsReadsAsBluetooth_soVoiceProcessingStaysOff() {
        let r = VoiceProcessingPolicy.resolve(defaultDevice: eqMac, others: [airPods, speakersIdle])
        XCTAssertEqual(r.route, .bluetooth)
        XCTAssertEqual(r.through, "AirPods Max")
        XCTAssertFalse(VoiceProcessingPolicy.shouldEnable(settingOn: true, micWhitelisted: false, output: r.route).enable)
    }

    func test_eqMacIntoTheSpeakersReadsAsSpeakers() {
        let r = VoiceProcessingPolicy.resolve(defaultDevice: eqMac, others: [speakersRunning])
        XCTAssertEqual(r.route, .builtInSpeakers)
        XCTAssertTrue(VoiceProcessingPolicy.shouldEnable(settingOn: true, micWhitelisted: false, output: r.route).enable)
    }

    /// No real device running, or two: nothing says where the sound goes, so
    /// the answer is unknown, never a guess.
    func test_noneOrSeveralRunningStaysUnknown() {
        XCTAssertEqual(VoiceProcessingPolicy.resolve(defaultDevice: eqMac, others: [speakersIdle]).route, .unknown)
        XCTAssertEqual(VoiceProcessingPolicy.resolve(defaultDevice: eqMac, others: [airPods, speakersRunning]).route, .unknown)
        let otherVirtual = D(name: "BlackHole", transport: kAudioDeviceTransportTypeVirtual, dataSource: nil, isRunning: true)
        XCTAssertEqual(VoiceProcessingPolicy.resolve(defaultDevice: eqMac, others: [otherVirtual]).route, .unknown,
                       "another virtual device is not where the sound goes")
    }

    /// A real default is read exactly as before; the others are never consulted.
    func test_aRealDefaultIsUnchanged() {
        let r = VoiceProcessingPolicy.resolve(defaultDevice: airPods, others: [speakersRunning])
        XCTAssertEqual(r.route, .bluetooth)
        XCTAssertNil(r.through)
        XCTAssertEqual(VoiceProcessingPolicy.resolve(defaultDevice: speakersIdle, others: [airPods]).route, .builtInSpeakers)
    }

    func test_aRefusalTurnsVoiceProcessingOffEvenOnSpeakers() {
        let d = VoiceProcessingPolicy.shouldEnable(settingOn: true, micWhitelisted: false, output: .builtInSpeakers,
                                                   refusedRecently: true)
        XCTAssertFalse(d.enable)
        XCTAssertTrue(d.reason.contains("would not start"))
        // The Settings switch still wins: off is off, whatever happened.
        XCTAssertEqual(VoiceProcessingPolicy.shouldEnable(settingOn: false, micWhitelisted: false, output: .builtInSpeakers,
                                                          refusedRecently: true).reason, "voice processing off in Settings")
    }

    @MainActor
    func test_theRefusalLastsItsWindowAndNoLonger() {
        defer { VoiceProcessingRefusal.clear() }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        VoiceProcessingRefusal.clear()
        XCTAssertFalse(VoiceProcessingRefusal.isRecent(now: t))
        VoiceProcessingRefusal.markRefused(now: t)
        XCTAssertTrue(VoiceProcessingRefusal.isRecent(now: t))
        XCTAssertTrue(VoiceProcessingRefusal.isRecent(now: t.addingTimeInterval(VoiceProcessingRefusal.window - 1)))
        XCTAssertFalse(VoiceProcessingRefusal.isRecent(now: t.addingTimeInterval(VoiceProcessingRefusal.window + 1)))
    }
}
