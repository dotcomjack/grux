import Foundation
import CoreAudio

/// Which microphone always-on listening is allowed to open.
///
/// Measured 2026-09-20: with AirPods connected, macOS made them the default
/// input and the ambient listener opened them
/// (`VoiceProcessingIO ENABLED ... for 08-FF-44-06-EA-EF:input`). Opening a
/// Bluetooth input puts the headset into its hands-free profile, so
/// everything the person hears through it, including Grux's own reply, drops
/// to a call codec. The same shape applies to a phone borrowed over
/// Continuity and to an AirPlay receiver: the device belongs to something
/// else, and an always-on listener quietly holding it costs the person
/// audio quality (or their phone's microphone) for as long as Grux is on.
///
/// So always-on listening uses the Mac's own microphone. A wired or USB desk
/// microphone is still honoured, because the person plugged it in on purpose
/// and it costs nothing to use. Deliberate acts (dictation, meeting capture)
/// are NOT governed by this: choosing to record through a headset is a choice.
enum ListeningMicPolicy {
    enum Transport: Equatable {
        case builtIn
        /// Belongs to another device or a wireless link: Bluetooth, AirPlay,
        /// a phone over Continuity.
        case borrowed
        /// Plugged in here: USB, Thunderbolt, aggregate, virtual.
        case attached
    }

    struct Candidate: Equatable {
        let uid: String
        let name: String
        let transport: Transport
    }

    static func transport(rawValue: UInt32) -> Transport {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .borrowed
        default:
            return .attached
        }
    }

    /// The device always-on listening should open, or nil to leave the
    /// system default alone.
    ///
    /// - `enabled` false: never touches anything.
    /// - The current default is the Mac's own microphone, or something
    ///   plugged into it: leave it alone.
    /// - The current default is borrowed: move to the person's preferred
    ///   input if they set one and it is not itself borrowed, else the
    ///   built-in microphone. If neither exists, stay where we are rather
    ///   than go deaf.
    static func inputToUse(current: Candidate?,
                           devices: [Candidate],
                           preferredUID: String?,
                           enabled: Bool) -> String? {
        guard enabled, let current, current.transport == .borrowed else { return nil }
        if let preferredUID,
           let preferred = devices.first(where: { $0.uid == preferredUID }),
           preferred.transport != .borrowed {
            return preferred.uid
        }
        return devices.first(where: { $0.transport == .builtIn })?.uid
    }

    /// One line for the log and for the Listening section.
    static func explanation(movedFrom: Candidate, to: Candidate) -> String {
        "Listening moved off \(movedFrom.name) to \(to.name): holding it open would put it in call quality for as long as Grux is listening."
    }
}
