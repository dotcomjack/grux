import Foundation
import AVFoundation
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
let engine = AVAudioEngine()
let input = engine.inputNode
do { try input.setVoiceProcessingEnabled(true) } catch { FileHandle.standardError.write("enable failed\n".data(using:.utf8)!); exit(1) }
input.voiceProcessingOtherAudioDuckingConfiguration =
    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
var frames = 0
input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { b, _ in frames += Int(b.frameLength) }
do { try engine.start() } catch { FileHandle.standardError.write("start failed\n".data(using:.utf8)!); exit(1) }
print("HOLDER: VPIO up (\(input.outputFormat(forBus:0).channelCount)ch), holding \(seconds)s")
fflush(stdout)
Thread.sleep(forTimeInterval: seconds)
print("HOLDER: frames=\(frames) (proves VPIO was really running)")
engine.stop()
