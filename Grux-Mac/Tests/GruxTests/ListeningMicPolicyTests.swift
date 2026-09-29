import XCTest
import CoreAudio
@testable import Grux

final class ListeningMicPolicyTests: XCTestCase {
    private let builtIn = ListeningMicPolicy.Candidate(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    private let airpods = ListeningMicPolicy.Candidate(uid: "08-FF-44-06-EA-EF:input", name: "AirPods", transport: .borrowed)
    private let phone = ListeningMicPolicy.Candidate(uid: "E1692E42", name: "Apple Iphone 8 Microphone", transport: .borrowed)
    private let desk = ListeningMicPolicy.Candidate(uid: "DJI-MIC", name: "DJI Mic Mini", transport: .attached)

    /// The transports are read off CoreAudio, so pin the classification to the
    /// constants rather than to numbers copied into a comment.
    func test_transportClassification() {
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: kAudioDeviceTransportTypeBluetooth), .borrowed)
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: kAudioDeviceTransportTypeBluetoothLE), .borrowed)
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: kAudioDeviceTransportTypeAirPlay), .borrowed)
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: kAudioDeviceTransportTypeContinuityCaptureWired), .borrowed)
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: kAudioDeviceTransportTypeContinuityCaptureWireless), .borrowed)
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: kAudioDeviceTransportTypeUSB), .attached)
        XCTAssertEqual(ListeningMicPolicy.transport(rawValue: 0), .attached)
    }

    func test_airPodsAsDefault_moveToTheBuiltInMic() {
        let to = ListeningMicPolicy.inputToUse(current: airpods, devices: [builtIn, airpods], preferredUID: nil, enabled: true)
        XCTAssertEqual(to, builtIn.uid)
    }

    func test_builtInOrDeskMic_isLeftAlone() {
        XCTAssertNil(ListeningMicPolicy.inputToUse(current: builtIn, devices: [builtIn, airpods], preferredUID: nil, enabled: true))
        XCTAssertNil(ListeningMicPolicy.inputToUse(current: desk, devices: [builtIn, desk], preferredUID: nil, enabled: true))
    }

    func test_aChosenDeskMicWinsOverTheBuiltIn() {
        let to = ListeningMicPolicy.inputToUse(current: phone, devices: [builtIn, desk, phone], preferredUID: desk.uid, enabled: true)
        XCTAssertEqual(to, desk.uid)
    }

    func test_aChosenBorrowedMicIsNotUsedAsTheEscape() {
        let to = ListeningMicPolicy.inputToUse(current: phone, devices: [builtIn, phone, airpods], preferredUID: airpods.uid, enabled: true)
        XCTAssertEqual(to, builtIn.uid, "the escape from a borrowed device cannot be another borrowed device")
    }

    func test_noBuiltIn_staysPutRatherThanGoingDeaf() {
        XCTAssertNil(ListeningMicPolicy.inputToUse(current: airpods, devices: [airpods], preferredUID: nil, enabled: true))
    }

    func test_switchedOff_touchesNothing() {
        XCTAssertNil(ListeningMicPolicy.inputToUse(current: airpods, devices: [builtIn, airpods], preferredUID: nil, enabled: false))
    }

    @MainActor
    func test_guard_movesOnceAndPutsItBackAfterTheLastListener() {
        let g = ListeningMicGuard.shared
        var current = airpods.uid
        var sets: [String] = []
        g.candidates = { [self.builtIn, self.airpods] }
        g.currentUID = { current }
        g.setDefault = { uid in sets.append(uid); current = uid; return true }
        g.preferredUID = { nil }
        g.enabled = { true }
        g.log = { _ in }
        defer { g.release("ambient"); g.release("wake") }

        g.claim("ambient")
        g.claim("wake")
        XCTAssertEqual(sets, [builtIn.uid], "two listeners, one move")
        g.release("ambient")
        XCTAssertEqual(current, builtIn.uid, "still listening, so the mic stays")
        g.release("wake")
        XCTAssertEqual(current, airpods.uid, "the person's device comes back")
    }

    @MainActor
    func test_guard_leavesItAloneIfSomethingElseChangedTheInput() {
        let g = ListeningMicGuard.shared
        var current = airpods.uid
        g.candidates = { [self.builtIn, self.airpods, self.desk] }
        g.currentUID = { current }
        g.setDefault = { uid in current = uid; return true }
        g.preferredUID = { nil }
        g.enabled = { true }
        g.log = { _ in }
        defer { g.release("ambient") }

        g.claim("ambient")
        XCTAssertEqual(current, builtIn.uid)
        current = desk.uid          // the person picked something while Grux listened
        g.release("ambient")
        XCTAssertEqual(current, desk.uid, "their later choice wins over our restore")
    }
}

final class ListeningMicDiscoverabilityTests: XCTestCase {
    /// It ships ON, so the rule that bites is the other half: a person has to
    /// be able to find it and read what turning it off costs.
    func test_theListeningSectionNamesItAndExplainsTheOffState() {
        let copy = ListeningSection.micCopy
        XCTAssertFalse(copy.title.isEmpty)
        for phrase in ["call quality", "plug in", "goes back", "Turn this off"] {
            XCTAssertTrue(copy.body.contains(phrase), "the explanation is missing '\(phrase)': \(copy.body)")
        }
    }

    func test_itIsOnByDefault() {
        XCTAssertTrue(GruxConfig.default.listenOnTheMacsOwnMic)
    }
}
