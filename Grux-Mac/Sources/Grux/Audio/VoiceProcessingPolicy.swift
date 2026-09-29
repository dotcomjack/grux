import Foundation
import AVFoundation
import CoreAudio

/// When a listening engine turns on Apple's voice processing (VoiceProcessingIO).
///
/// Voice processing exists for ONE reason worth its cost here: echo
/// cancellation, taking the Mac's own output (music, Grux's spoken reply) back
/// out of the microphone. Its cost is real and measured on 2026-09-21 with the
/// output on AirPods Max: the IO thread spent about 10% of a core in the neural
/// echo canceller for as long as ambient listening was armed.
///
/// WHAT THE COST IS, MEASURED 2026-09-23 ON BUILT-IN SPEAKERS. An earlier note
/// here, and the Settings copy that quoted it, said enabling VPIO moves every
/// other app's audio onto the narrow-band communications path. On this Mac
/// (macOS 26) that is NOT what happens, and it was never measured before it
/// was written down. Three findings, each with its own control:
///
/// - Output fidelity is UNCHANGED. A 12 kHz tone played while a separate
///   process held VPIO came back 73 dB above the silence floor, and the output
///   device stayed 48000 Hz 2ch 32bit lpcm throughout. A narrow-band codec
///   cannot pass 12 kHz at all, so this is not one.
/// - A playback-only app is UNDISTURBED. A process that plays a tone and never
///   opens the microphone saw zero `AVAudioEngineConfigurationChange`
///   notifications and ran its buffer to completion while VPIO came up and
///   went away underneath it.
/// - ANOTHER APP'S MICROPHONE CAPTURE DIES. This is the real harm. A separate
///   process capturing from the same input stopped receiving tap buffers at
///   the exact moment VPIO started in another process, and did not recover.
///
/// So the thing to protect is not the person's music, it is any other app that
/// is RECORDING while Grux listens: a call, a screen recording, a browser
/// holding getUserMedia. Grux already knows this hazard from the inside;
/// `SpeechEngine` carries its own handler for the configuration change that
/// stops an engine rendering. Enabling VPIO inflicts that same change on every
/// other app, and they do not all handle it.
///
/// NOT TESTED: Bluetooth output. The classic narrow-band downgrade is the
/// A2DP to HFP switch on a Bluetooth link, which needs the headphones
/// connected to reproduce. The table below already keeps VPIO off for
/// Bluetooth, so that path is guarded either way.
///
/// So it only runs when the microphone can actually HEAR the output:
///
/// | Setting | Mic whitelisted | Output              | Voice processing |
/// |---------|-----------------|---------------------|------------------|
/// | off     | any             | any                 | off              |
/// | on      | yes             | any                 | off              |
/// | on      | no              | built-in speakers   | ON               |
/// | on      | no              | external speakers   | ON               |
/// | on      | no              | unknown             | ON (as before)   |
/// | on      | no              | built-in headphones | off              |
/// | on      | no              | Bluetooth           | off              |
///
/// WHY BLUETOOTH COUNTS AS HEADPHONES. Bluetooth output on a Mac is
/// overwhelmingly headphones (AirPods, a headset), which the microphone cannot
/// hear. Echo cancellation against Bluetooth is poor even when it does run,
/// because the link adds a large and variable delay between what the canceller
/// is told was played and what comes out. And a misclassified Bluetooth
/// SPEAKER costs little: lyrics reach a pipeline that already gates music out
/// of command dispatch with the SoundAnalysis singing classifier
/// (`SingingDetector`), so the worst case is a transcript line, not an action.
///
/// UNKNOWN STAYS ON. Anything this cannot classify keeps today's behaviour,
/// because the failure it guards against (Grux hearing itself through
/// speakers and answering its own reply) is worse than the one it causes.
/// USB is read as speakers for the same reason: a USB headset exists, but so do
/// USB desk speakers, and the transport cannot tell them apart.
enum VoiceProcessingPolicy {

    enum OutputRoute: Equatable, CaseIterable, CustomStringConvertible {
        case builtInSpeakers
        /// The built-in headphone port (data source `hdpn`).
        case builtInHeadphones
        /// Bluetooth Classic or Bluetooth LE.
        case bluetooth
        /// HDMI, DisplayPort, USB, AirPlay, Thunderbolt and other wired or
        /// networked outputs. The microphone may hear these.
        case externalSpeakers
        case unknown

        var description: String {
            switch self {
            case .builtInSpeakers: return "built-in speakers"
            case .builtInHeadphones: return "built-in headphones"
            case .bluetooth: return "Bluetooth"
            case .externalSpeakers: return "external speakers"
            case .unknown: return "unknown output"
            }
        }

        /// Whether the microphone can pick this output up acoustically.
        var micCanHearIt: Bool {
            switch self {
            case .builtInHeadphones, .bluetooth: return false
            case .builtInSpeakers, .externalSpeakers, .unknown: return true
            }
        }
    }

    struct Decision: Equatable {
        let enable: Bool
        /// Short, for the WakeLog line.
        let reason: String
    }

    /// `refusedRecently`: Core Audio refused to start voice processing a
    /// moment ago (`VoiceProcessingRefusal`), so a start with it would come up
    /// deaf again. Listening without echo cancellation beats not listening.
    ///
    /// `holdsMicWhileGruxSpeaks`: whether this listener's microphone is still
    /// OPEN while Grux's own voice is playing. It is a fact about the calling
    /// code, not a preference. Echo cancellation exists to take Grux's reply
    /// back out of the microphone, so a listener that closes the microphone
    /// for the duration of that reply has nothing for it to cancel, and pays
    /// the cost below for no benefit at all.
    static func shouldEnable(settingOn: Bool, micWhitelisted: Bool, output: OutputRoute,
                             refusedRecently: Bool = false,
                             holdsMicWhileGruxSpeaks: Bool = true) -> Decision {
        guard settingOn else {
            return Decision(enable: false, reason: "voice processing off in Settings")
        }
        guard holdsMicWhileGruxSpeaks else {
            return Decision(enable: false, reason: "this listener drops the mic while Grux speaks, so there is no echo to cancel")
        }
        guard !micWhitelisted else {
            return Decision(enable: false, reason: "whitelisted mic")
        }
        guard !refusedRecently else {
            return Decision(enable: false, reason: "voice processing would not start a moment ago, listening without it")
        }
        guard output.micCanHearIt else {
            return Decision(enable: false, reason: "output is \(output), the mic cannot hear it")
        }
        if output == .unknown {
            return Decision(enable: true, reason: "output route unknown, keeping echo cancellation")
        }
        return Decision(enable: true, reason: "output is \(output), the mic can hear it")
    }

    /// What other apps' audio does while voice processing runs. Both listening
    /// sites apply this whenever they enable it: left unset, macOS applies its
    /// default ducking and lowers every other app for as long as Grux listens.
    /// `.min` with advanced ducking off is the least ducking the API offers.
    /// (Lowering Apple Music while Grux SPEAKS is a separate, deliberate
    /// feature in `AudioDucker`; this does not touch it.)
    static let otherAudioDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: false,
        duckingLevel: .min
    )

    /// `kAudioDevicePropertyDataSource` values on a built-in output.
    static let headphonesDataSource = fourCC("hdpn")
    static let internalSpeakersDataSource = fourCC("ispk")

    /// Classify an output device from its CoreAudio transport type and, for a
    /// built-in device, its output data source. Pure, so it is testable
    /// without opening anything.
    ///
    /// Measured 2026-09-21 on a MacBook Pro: AirPods Max read transport
    /// `blue` with no data source, and "MacBook Pro Speakers" read `bltn`
    /// with data source `ispk`.
    static func route(transport: UInt32, dataSource: UInt32?) -> OutputRoute {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn:
            if dataSource == headphonesDataSource { return .builtInHeadphones }
            if dataSource == internalSpeakersDataSource { return .builtInSpeakers }
            return .unknown
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB:
            return .externalSpeakers
        default:
            // Aggregate, virtual (loopback drivers), unreadable (0): cannot
            // tell what is on the other end.
            return .unknown
        }
    }

    /// An output device and what it is, for resolving a virtual default.
    struct OutputDevice: Equatable {
        let name: String
        let transport: UInt32
        let dataSource: UInt32?
        let isRunning: Bool
    }

    /// The route when the default output may be a VIRTUAL device that
    /// forwards to a real one.
    ///
    /// eqMac is the case in hand, measured 2026-09-21 on the operator's Mac:
    /// while it runs, its own virtual device is the system default output and
    /// it plays everything through the device picked inside eqMac, the AirPods
    /// Max in that session. `route(transport:)` reads a virtual transport as
    /// unknown, and unknown keeps echo cancellation ON, which is exactly the
    /// headphones-plus-voice-processing state that costs the music its
    /// quality. The real device eqMac forwards to is the one it keeps running,
    /// so: exactly one real output running is where the sound goes. None, or
    /// several, and the answer stays unknown rather than a guess.
    static func resolve(defaultDevice: OutputDevice, others: [OutputDevice]) -> (route: OutputRoute, through: String?) {
        guard defaultDevice.transport == kAudioDeviceTransportTypeVirtual
                || defaultDevice.transport == kAudioDeviceTransportTypeAggregate else {
            return (route(transport: defaultDevice.transport, dataSource: defaultDevice.dataSource), nil)
        }
        let real = others.filter {
            $0.isRunning
                && $0.transport != kAudioDeviceTransportTypeVirtual
                && $0.transport != kAudioDeviceTransportTypeAggregate
                && $0.transport != 0
        }
        guard real.count == 1, let target = real.first else { return (.unknown, nil) }
        return (route(transport: target.transport, dataSource: target.dataSource), target.name)
    }

    static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// Core Audio sometimes refuses to start the voice processing IO: measured
/// 2026-09-21, `HALC_ProxyIOContext::_StartIO(): Start failed -
/// StartAndWaitForState returned error 35` on three starts running, with
/// `engine.start()` returning normally and no buffer ever arriving, while
/// plain capture from the same microphone delivered 96000 frames in two
/// seconds. A listener that sees a voice processing start deliver nothing
/// records it here, and every listener skips voice processing for `window`.
@MainActor
enum VoiceProcessingRefusal {
    static let window: TimeInterval = 600
    private(set) static var at: Date?

    static func markRefused(now: Date = Date()) { at = now }
    static func clear() { at = nil }
    static func isRecent(now: Date = Date()) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) < window
    }
}
