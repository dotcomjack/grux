import AVFoundation
import XCTest
@testable import Grux

/// The W4 build 11 clean-VM walk (2026-10-14): what build 12 fixes.
private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// BLOCKER. The microphone prompt fired about 2 s after the first chat reply,
/// with no mic control pressed (W4 build 11). Measured on the clean VM, whose one
/// audio device has inputs and outputs: ANY sound played in a process holding the
/// audio-input entitlement made coreaudiod ask for the microphone, an output-only
/// engine included. So before the microphone question no sound plays in Grux.
@MainActor
final class SpeakingOpensNoInputTests: XCTestCase {
    private var savedStatus: (() -> AVAuthorizationStatus)!
    private var savedRequest: (() async -> Bool)!
    private var savedDetached: ((URL, Float, @escaping @Sendable () -> Void) -> (() -> Void)?)!
    private var savedSystemSound: ((URL) -> Void)!

    override func setUp() {
        savedStatus = MicController.authorizationStatus
        savedRequest = MicController.requestAccess
        savedDetached = AudioOutput.playDetached
        savedSystemSound = AudioOutput.playSystemSound
    }

    override func tearDown() {
        MicController.authorizationStatus = savedStatus
        MicController.requestAccess = savedRequest
        AudioOutput.playDetached = savedDetached
        AudioOutput.playSystemSound = savedSystemSound
        AudioOutput.soundAllowedUnderTest = false
    }

    func test_aReplyBeforeTheMicQuestionPlaysOutsideGrux() async throws {
        var asked = 0
        MicController.authorizationStatus = { .notDetermined }
        MicController.requestAccess = { asked += 1; return false }
        var played: [(frames: AVAudioFramePosition, volume: Float)] = []
        AudioOutput.playDetached = { url, volume, ended in
            // Read before the end: the speaker deletes the file once playback ends.
            let frames = (try? AVAudioFile(forReading: url))?.length ?? 0
            played.append((frames, volume))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ended() }
            return {}
        }
        var started = false
        var stopped = false
        let a = NotificationCenter.default.addObserver(forName: .gruxSpeechDidStart, object: nil, queue: .main) { _ in started = true }
        let b = NotificationCenter.default.addObserver(forName: .gruxSpeechDidStop, object: nil, queue: .main) { _ in stopped = true }
        defer { NotificationCenter.default.removeObserver(a); NotificationCenter.default.removeObserver(b) }

        let engines = AudioFactory.enginesBuilt
        let utterance = AVSpeechUtterance(string: "One, two, three.")
        utterance.volume = 0
        Speaker.shared.play(utterance)
        let deadline = Date().addingTimeInterval(15)
        while !stopped && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }

        XCTAssertTrue(started, "speaking never began")
        XCTAssertTrue(stopped, "speaking never ended, so a listener paused for it would never resume")
        XCTAssertFalse(Speaker.shared.isSpeaking)
        XCTAssertEqual(played.count, 1, "the reply played in Grux, which raises the microphone prompt")
        XCTAssertGreaterThan(played.first?.frames ?? 0, 0, "the detached player got an empty file")
        XCTAssertEqual(played.first?.volume, 0)
        XCTAssertEqual(AudioFactory.enginesBuilt - engines, 0, "speaking built an audio engine in Grux")
        XCTAssertEqual(asked, 0, "speaking a reply asked macOS for the microphone")
    }

    func test_theRuleIsOnlyWhileTheMicIsUndecided() {
        for (status, outside) in [(AVAuthorizationStatus.notDetermined, true), (.authorized, false),
                                  (.denied, false), (.restricted, false)] {
            MicController.authorizationStatus = { status }
            XCTAssertEqual(AudioOutput.outputWouldAskForMic, outside, "\(status.rawValue)")
        }
    }

    func test_aChimeBeforeTheMicQuestionIsASystemSound() {
        AudioOutput.soundAllowedUnderTest = true
        MicController.authorizationStatus = { .notDetermined }
        var sounds: [String] = []
        AudioOutput.playSystemSound = { sounds.append($0.path) }
        AudioOutput.chime([.tink, .glass], source: "Build12Tests")
        XCTAssertEqual(sounds, ["/System/Library/Sounds/Tink.aiff"], "the chime played in Grux")
    }

    /// The detached player is its own responsible process, so coreaudiod's microphone
    /// check is charged to it, not to Grux. Without the disclaim a child's is Grux's
    /// (a child `say` prompted for the probe app on the VM).
    func test_theDetachedProcessAnswersForItself() async throws {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let sym = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
        let responsibleFor = unsafeBitCast(sym, to: Responsible.self)
        final class Flag: @unchecked Sendable { var on = false }
        let done = Flag()
        let pid = try XCTUnwrap(AudioOutput.spawnOwnResponsibility(["/bin/sleep", "5"]) { done.on = true })
        XCTAssertEqual(responsibleFor(pid), pid, "the player is charged to Grux")
        XCTAssertNotEqual(responsibleFor(getpid()), pid)
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while !done.on && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(done.on, "the end of the player was never noticed, so the speaker never stops")
    }

    func test_bothVoicesWaitForTheMicQuestion() throws {
        let speaker = try macSource("Sources/Grux/Speaker.swift")
        XCTAssertTrue(speaker.contains("if AudioOutput.outputWouldAskForMic {\n            playDetached(utt)"))
        XCTAssertTrue(speaker.contains("stopDetached = AudioOutput.playDetached(url, volume)"))
        let engine = try macSource("Sources/Grux/SpeechEngine.swift")
        XCTAssertEqual(engine.components(separatedBy: "&& !AudioOutput.outputWouldAskForMic").count - 1, 2,
                       "a cloud voice plays in Grux before the microphone question")
    }

    /// MusicKit plays in Grux too. Before the microphone question the music
    /// tool skips it for Music.app, and the diagnostic probe stops.
    func test_musicKitWaitsForTheMicQuestion() throws {
        let tool = try macSource("Sources/Grux/MusicTool.swift")
        XCTAssertTrue(tool.contains("UserDefaults.standard.bool(forKey: \"musicKitEnabled\"),\n           !AudioOutput.outputWouldAskForMic,"),
                      "MusicKit plays in Grux before the microphone question")
        let kit = try macSource("Sources/Grux/MusicKitPlayer.swift")
        XCTAssertTrue(kit.contains("guard !AudioOutput.outputWouldAskForMic else {"), "the MusicKit probe plays before the microphone question")
    }

    /// A clip shown before the microphone question plays its picture with no audio
    /// track. Muting is not enough: a muted player still starts audio output.
    func test_aClipBeforeTheMicQuestionHasNoSound() async throws {
        let clip = try await Self.clipWithSound()
        defer { try? FileManager.default.removeItem(at: clip) }
        let source = AVURLAsset(url: clip)
        let sourceSound = try await source.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(sourceSound, 1, "the fixture has no sound to strip")

        MicController.authorizationStatus = { .notDetermined }
        let player = AudioOutput.videoPlayer(url: clip, source: "Build12Tests")
        let deadline = Date().addingTimeInterval(10)
        while player.currentItem == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let picture = try XCTUnwrap(player.currentItem?.asset, "the clip never loaded")
        let pictureSound = try await picture.loadTracks(withMediaType: .audio).count
        let pictureVideo = try await picture.loadTracks(withMediaType: .video).count
        XCTAssertEqual(pictureSound, 0, "the clip carries sound into Grux")
        XCTAssertEqual(pictureVideo, 1, "the picture was lost")

        MicController.authorizationStatus = { .authorized }
        let answered = try XCTUnwrap(AudioOutput.videoPlayer(url: clip, source: "Build12Tests").currentItem?.asset)
        let answeredSound = try await answered.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(answeredSound, 1, "after the question the clip lost its sound")
    }

    /// A second of black 64x64 picture and a second of silence, in one .mov.
    private static func clipWithSound() async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("b12-clip-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: picture, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
        ])
        writer.add(picture)
        writer.add(sound)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for frame in 0...10 {
            while !picture.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(frames.pixelBufferPool), &buffer)
            frames.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        picture.markAsFinished()

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        silence.frameLength = 44100
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: description, sampleCount: 44100, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        let samples = try XCTUnwrap(sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(samples, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                       flags: 0, bufferList: silence.audioBufferList)
        while !sound.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(sound.append(samples))
        sound.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return out
    }

    /// The class: only the listeners, each behind listening and consent,
    /// touch an input node or voice processing.
    func test_onlyTheListenersTouchTheInput() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var touching: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".inputNode") || text.contains("setVoiceProcessingEnabled") { touching.append(url.lastPathComponent) }
        }
        XCTAssertEqual(touching.sorted(), ["AmbientListener.swift", "MeetingMicCapture.swift", "MicDevices.swift",
                                           "SmokeTest.swift", "VoiceInput.swift", "WakeWord.swift"],
                       "something new reaches the microphone side; it must wait for listening and consent")
    }
}

/// LOW. After the model was installed, "Connect a model to send this" stayed
/// under the kept text (41-c).
final class HeldLineClearsTests: XCTestCase {
    func test_theHeldLineGoesOnceChatCanSend() throws {
        XCTAssertTrue(PanelInput.showsConnectLine(held: true, canSend: false))
        XCTAssertFalse(PanelInput.showsConnectLine(held: true, canSend: true), "the line outlives the reason for it")
        XCTAssertFalse(PanelInput.showsConnectLine(held: false, canSend: false))
        let src = try macSource("Sources/Grux/Shell/CommandPanel/PanelInput.swift")
        XCTAssertTrue(src.contains("if Self.showsConnectLine(held: heldForModel, canSend: ChatReadiness.current().canSend) {"))
        XCTAssertTrue(src.contains("@ObservedObject private var registry = ModelRegistry.shared"),
                      "the panel does not redraw when a model arrives")
    }
}

/// LOW. Listening was passed by in setup, and Tuning said "Always on" (25),
/// against the first screen's "Listening is off until you turn it on".
@MainActor
final class ListeningStaysOffTests: XCTestCase {
    func test_passingListeningByLeavesItOff() throws {
        let saved = AppState.shared.config
        defer { AppState.shared.config = saved }
        AppState.shared.config.listeningMode = .alwaysOn
        Setup.leaveListeningOff()
        XCTAssertEqual(AppState.shared.config.listeningMode, .off, "Tuning still reads Always on")
        let src = try macSource("Sources/Grux/Onboarding/FirstRunScreens.swift")
        let moveOn = try XCTUnwrap(src.components(separatedBy: "private func moveOn() {").dropFirst().first?.prefix(500))
        XCTAssertTrue(moveOn.contains("if itemsOnScreen.contains(where: Setup.isListening), !listeningChosen { Setup.leaveListeningOff() }"),
                      "skipping the listening card leaves it Always on")
        XCTAssertTrue(src.contains("Button(Setup.keepListeningOff) { listen(.off, walking: walking) }"))
    }
}
