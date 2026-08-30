import Foundation

// Fan-out point for Grux's TTS audio. SpeechEngine calls `feedPCM24(_:)`
// with every chunk of ElevenLabs-decoded PCM_24000 Int16 before it goes to
// AVAudioPlayerNode. PhoneReceiverService subscribes and ships the PCM to
// the iPhone for playback.
//
// Also emits START / END markers so the phone can mute its mic while TTS
// is playing (cheap echo prevention - we don't want Grux transcribing
// itself in a loop).
@MainActor
final class TTSBroadcaster {
    static let shared = TTSBroadcaster()

    typealias PCMHandler = (Data, Int) -> Void    // (pcm16LE bytes, sampleRate)
    typealias EventHandler = (Bool) -> Void        // true = start, false = end

    private var pcmSubscribers: [UUID: PCMHandler] = [:]
    private var eventSubscribers: [UUID: EventHandler] = [:]

    private init() {}

    @discardableResult
    func subscribePCM(_ handler: @escaping PCMHandler) -> UUID {
        let id = UUID()
        pcmSubscribers[id] = handler
        return id
    }
    @discardableResult
    func subscribeEvents(_ handler: @escaping EventHandler) -> UUID {
        let id = UUID()
        eventSubscribers[id] = handler
        return id
    }
    func unsubscribe(_ id: UUID) {
        pcmSubscribers[id] = nil
        eventSubscribers[id] = nil
    }

    // Called from SpeechEngine.streamElevenLabs after fetching PCM_24000 bytes.
    func feedPCM24(_ data: Data) {
        guard !pcmSubscribers.isEmpty else { return }
        for h in pcmSubscribers.values { h(data, PhoneWire.ttsSampleRate) }
    }

    func speakStart() { for h in eventSubscribers.values { h(true) } }
    func speakEnd()   { for h in eventSubscribers.values { h(false) } }
}
