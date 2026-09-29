import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// CoreAudio input-device enumeration + HAL defaults.
//
// Why this module exists: macOS silently degrades ALL system output (Music,
// Safari, YouTube) to a narrow-band "communications" codec whenever the
// (DISPROVEN 2026-09-23. Output is unaffected; the real cost is another
// app's MICROPHONE capture stopping dead. See VoiceProcessingPolicy.)
// active audio unit uses VoiceProcessingIO (kAudioUnitSubType_VoiceProcessingIO).
// AVAudioEngine.inputNode.setVoiceProcessingEnabled(true) is exactly that
// path. Fine for laptop built-in mics (echo cancel is worth it) but
// catastrophic on high-quality external mics like the DJI Mic Mini - the mic
// already has onboard DSP, and losing full-fidelity speaker output makes
// Ambient mode unusable while music is playing.
//
// The fix: per-mic whitelist. For whitelisted UIDs, AmbientListener and
// VoiceInput skip the VPIO enable call and fall through to a plain HAL path,
// so the output chain stays in full 44.1/48kHz stereo.
//
// We key on the device UID (stable string - persists across reboots and
// reconnects of the same physical device) rather than name (which can drift
// across OS updates and duplicates between USB ports).
@MainActor
enum MicDevices {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Enumerate every device that exposes input streams.
    static func listInputs() -> [Device] {
        var out: [Device] = []
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }

        for id in ids {
            guard hasInputStreams(deviceID: id) else { continue }
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "(unnamed)"
            let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? "unknown-\(id)"
            out.append(Device(uid: uid, name: name))
        }
        return out
    }

    /// UID of the system-wide default input device (what Audio MIDI Setup shows).
    static func systemDefaultInputUID() -> String? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        ) == noErr else { return nil }
        return stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Resolve a Device UID → AudioDeviceID (CoreAudio's runtime handle).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return nil }
        for id in ids {
            if stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) == uid {
                return id
            }
        }
        return nil
    }

    /// Set the system-wide default input device. Used by the "make this my
    /// permanent mic" toggle so the user does not have to visit Sound prefs.
    @discardableResult
    static func setSystemDefaultInput(toUID uid: String) -> Bool {
        guard let id = deviceID(forUID: uid) else { return false }
        var target = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &target
        )
        return status == noErr
    }

    /// Every input device with the transport class always-on listening cares
    /// about. See `ListeningMicPolicy`.
    static func listeningCandidates() -> [ListeningMicPolicy.Candidate] {
        listInputs().map { dev in
            ListeningMicPolicy.Candidate(uid: dev.uid, name: dev.name,
                                         transport: ListeningMicPolicy.transport(rawValue: transportRaw(uid: dev.uid)))
        }
    }

    /// Raw CoreAudio transport type, 0 when it cannot be read.
    static func transportRaw(uid: String) -> UInt32 {
        guard let id = deviceID(forUID: uid) else { return 0 }
        return uint32Property(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) ?? 0
    }

    /// The address a listener watches to hear the default OUTPUT device change
    /// (AirPods connecting, headphones unplugged).
    static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Where the system default OUTPUT goes right now, for
    /// `VoiceProcessingPolicy`. Property reads only: nothing is opened.
    /// `.unknown` when the device cannot be read.
    static func defaultOutputRoute() -> VoiceProcessingPolicy.OutputRoute {
        var addr = defaultOutputDeviceAddress
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        ) == noErr, id != kAudioObjectUnknown else { return .unknown }
        let defaultDevice = outputDevice(id)
        // A virtual default (eqMac) forwards to a real device; see
        // VoiceProcessingPolicy.resolve. Only then are the others read.
        let isVirtual = defaultDevice.transport == kAudioDeviceTransportTypeVirtual
            || defaultDevice.transport == kAudioDeviceTransportTypeAggregate
        let others = isVirtual ? allDeviceIDs().filter { $0 != id && hasOutput($0) }.map(outputDevice) : []
        let resolved = VoiceProcessingPolicy.resolve(defaultDevice: defaultDevice, others: others)
        if isVirtual {
            WakeLog.shared.log("audio: the default output \(defaultDevice.name) is virtual; "
                + (resolved.through.map { "it plays through \($0), read as \(resolved.route)" }
                   ?? "cannot tell what it plays through, read as unknown"))
        }
        return resolved.route
    }

    private static func outputDevice(_ id: AudioDeviceID) -> VoiceProcessingPolicy.OutputDevice {
        let transport = uint32Property(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) ?? 0
        // Only a built-in device switches between speakers and the headphone
        // port by data source; nothing else needs it read.
        let dataSource = transport == kAudioDeviceTransportTypeBuiltIn
            ? uint32Property(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
            : nil
        let running = uint32Property(id, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal) ?? 0
        return VoiceProcessingPolicy.OutputDevice(
            name: stringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "device \(id)",
            transport: transport, dataSource: dataSource, isRunning: running != 0)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// Points an engine's input at ONE device, by UID, instead of letting it
    /// pick. Returns false if the device or the unit cannot be found or the
    /// call fails, and the caller logs that.
    ///
    /// WHY. Without voice processing, `AVAudioEngine`'s input unit is not
    /// guaranteed to follow the device Grux chose. Measured 2026-09-21 with a
    /// standalone probe, AirPods Max as the output: an engine created with
    /// nothing bound opened the AirPods' own microphone (24 kHz mono, the
    /// Bluetooth call profile), which is exactly the "music goes to call
    /// quality" bug this whole path exists to prevent, and ambient heard
    /// nothing (every VAD tick `buf=0.0s rms=0.0000`). Bound to the MacBook Pro
    /// Microphone it opened at 48 kHz and delivered 96000 frames in 2 seconds.
    /// Voice processing had been hiding this: it builds its own pairing of the
    /// current defaults, so it never ran into it. Do not call this on an input
    /// with voice processing enabled; that unit manages its own devices.
    @discardableResult
    static func bindInput(_ node: AVAudioInputNode, toUID uid: String) -> Bool {
        guard !uid.isEmpty, var id = deviceID(forUID: uid), let unit = node.audioUnit else { return false }
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// The format to tap an input in. After `bindInput` the node's output
    /// format still describes the device the engine was created on, and a tap
    /// in that format receives nothing; the bound device's own input format is
    /// the one that delivers.
    static func tapFormat(for node: AVAudioInputNode, bound: Bool) -> AVAudioFormat {
        bound ? node.inputFormat(forBus: 0) : node.outputFormat(forBus: 0)
    }

    /// The device an engine's input unit is actually on, by name, for the log.
    static func boundInputName(_ node: AVAudioInputNode) -> String {
        // With voice processing on, the unit's current device is the OUTPUT
        // it pairs with, and the mic is the system default input. Measured
        // 2026-09-21: every voice processing start logged "MacBook Pro
        // Speakers" while it captured the MacBook Pro Microphone.
        if node.isVoiceProcessingEnabled {
            let mic = systemDefaultInputUID()
                .flatMap { deviceID(forUID: $0) }
                .flatMap { stringProperty(deviceID: $0, selector: kAudioObjectPropertyName) }
            return "\(mic ?? "the default input") (voice processing)"
        }
        guard let unit = node.audioUnit else { return "(no unit)" }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, &size) == noErr else { return "(unreadable)" }
        return stringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "(device \(id))"
    }

    /// UID of the Apple-internal built-in mic, used by "Revert to MacBook
    /// default". Matches on kAudioDevicePropertyTransportType == built-in;
    /// falls back to any device whose UID starts with "BuiltInMicrophone".
    static func builtInMicUID() -> String? {
        for dev in listInputs() {
            guard let id = deviceID(forUID: dev.uid) else { continue }
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr,
               transport == kAudioDeviceTransportTypeBuiltIn {
                return dev.uid
            }
        }
        return MicDevices.listInputs().first(where: { $0.uid.hasPrefix("BuiltInMicrophone") })?.uid
    }

    // MARK: - Private helpers

    private static func uint32Property(_ id: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector,
                                       _ scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: CFString?.self, capacity: 1) { cfPtr in
                AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, cfPtr)
            }
        }
        guard status == noErr, let value = cf?.takeRetainedValue() else { return nil }
        return value as String
    }
}

/// Persistent whitelist of input-device UIDs for which Grux will SKIP
/// VoiceProcessingIO. Lives in UserDefaults (tiny payload, survives app
/// rebuilds, no Codable churn in GruxConfig). Default behavior (empty
/// whitelist): current VPIO behavior for every mic - nothing changes.
@MainActor
enum MicWhitelist {
    private static let storeKey = "grux.micWhitelistUIDs"
    private static let optOutKey = "grux.micWhitelistAutoOptOutUIDs"
    private static let preferredInputKey = "grux.preferredInputMicUID"

    /// Is this UID marked "full fidelity - don't enable VPIO"?
    static func isWhitelisted(uid: String) -> Bool {
        current().contains(uid)
    }

    static func current() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
    }

    /// UIDs the user has explicitly un-checked in Settings. Auto-whitelist
    /// honors this set so a manual de-select survives launch/reconnect
    /// cycles instead of being silently re-added by pattern match.
    private static func optOuts() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: optOutKey) ?? [])
    }

    private static func setOptOut(_ uid: String, _ optedOut: Bool) {
        var set = optOuts()
        if optedOut { set.insert(uid) } else { set.remove(uid) }
        UserDefaults.standard.set(Array(set), forKey: optOutKey)
    }

    static func setWhitelisted(_ uid: String, _ on: Bool) {
        var set = current()
        if on {
            set.insert(uid)
            setOptOut(uid, false)   // explicit opt-in clears any prior opt-out
        } else {
            set.remove(uid)
            setOptOut(uid, true)    // explicit opt-out persists across launches
        }
        UserDefaults.standard.set(Array(set), forKey: storeKey)
        WakeLog.shared.log("micWhitelist: \(uid) → \(on ? "BYPASS VPIO" : "use VPIO")")
        NotificationCenter.default.post(name: .gruxMicWhitelistChanged, object: nil)
    }

    /// Preferred permanent input mic UID. When set, Grux forces the system
    /// default input to this device on launch and whenever Ambient/Wake
    /// starts, so the user does not have to pick the mic in Sound prefs every
    /// time it reconnects. nil = leave system default alone.
    static var preferredInputUID: String? {
        get { UserDefaults.standard.string(forKey: preferredInputKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: preferredInputKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredInputKey)
            }
        }
    }

    /// Apply preferredInputUID to the OS. Called on launch and whenever a
    /// listener (ambient/wake) starts up. No-op if the preference is nil or
    /// the device isn't currently connected.
    static func applyPreferredInputIfPossible() {
        guard let uid = preferredInputUID else { return }
        if MicDevices.setSystemDefaultInput(toUID: uid) {
            WakeLog.shared.log("micWhitelist: forced system default input → \(uid)")
        } else {
            WakeLog.shared.log("micWhitelist: preferred input \(uid) not connected - leaving system default as-is")
        }
    }

    /// External mics that ship with their own on-device DSP. Stacking
    /// macOS's VoiceProcessingIO on top of them is the worst of both
    /// worlds: speakers flip to comm-mode codec (tinny mono) for no real
    /// echo-cancellation gain, since the external mic already noise-gates
    /// and AGCs internally. Auto-bypass VPIO whenever one of these is
    /// connected so Music/Safari/YouTube stay full fidelity.
    ///
    /// Name match is case-insensitive substring; extend as the user adopts new
    /// external mics.
    private static let autoFidelityPatterns: [String] = [
        "DJI Mic",
        "Shure MV",
        "Blue Yeti",
        "Audio-Technica",
        "Rode NT-USB",
        "HyperX",
        "Elgato Wave"
    ]

    /// Scan currently-connected input devices and whitelist any whose
    /// name matches `autoFidelityPatterns`. Idempotent: skips UIDs already
    /// in the whitelist, AND skips UIDs the user has explicitly opted out
    /// of (un-checked in Settings) so a manual de-select survives launch
    /// and reconnect cycles. Safe to call on every launch and every
    /// listener start.
    static func autoWhitelistKnownExternalMics() {
        let connected = MicDevices.listInputs()
        let known = current()
        let optedOut = optOuts()
        for dev in connected {
            guard !known.contains(dev.uid), !optedOut.contains(dev.uid) else { continue }
            for pattern in autoFidelityPatterns
            where dev.name.range(of: pattern, options: .caseInsensitive) != nil {
                setWhitelisted(dev.uid, true)
                WakeLog.shared.log("micWhitelist: auto-whitelisted '\(dev.name)' (matches '\(pattern)')")
                break
            }
        }
    }

    /// Revert system default input to the MacBook's built-in mic AND clear
    /// the preferred-UID preference (so we don't re-force it next launch).
    static func revertToBuiltIn() {
        preferredInputUID = nil
        if let built = MicDevices.builtInMicUID() {
            _ = MicDevices.setSystemDefaultInput(toUID: built)
            WakeLog.shared.log("micWhitelist: REVERTED system default input → built-in mic (\(built))")
        } else {
            WakeLog.shared.log("micWhitelist: REVERTED preference but built-in mic UID not found")
        }
    }
}

extension Notification.Name {
    /// Posted from MicWhitelist.setWhitelisted whenever the whitelist set
    /// changes (manual toggle or auto-whitelist). SettingsView observes it
    /// so the "Preserve speaker fidelity" toggles redraw when auto-whitelist
    /// adds an entry while the panel is already open.
    static let gruxMicWhitelistChanged = Notification.Name("grux.micWhitelistChanged")
}
