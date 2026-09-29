import Foundation
import AVFoundation

// PLAYBACK ONLY. No microphone in this process at all. Plays a 10s tone and
// reports every AVAudioEngineConfigurationChange it receives plus whether the
// engine was still running at the end. This is the stand-in for Apple Music /
// a YouTube tab: an app that is only making sound and never touches the mic.
let dur = 10.0, sr = 48000.0
let engine = AVAudioEngine(); let player = AVAudioPlayerNode(); engine.attach(player)
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
engine.connect(player, to: engine.mainMixerNode, format: fmt)
let n = AVAudioFrameCount(sr * dur)
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; buf.frameLength = n
for ch in 0..<2 { let p = buf.floatChannelData![ch]
    for i in 0..<Int(n) { p[i] = Float(0.15 * sin(2 * .pi * 440.0 * Double(i)/sr)) } }

let t0 = Date()
var changes = [Double]()
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                       object: engine, queue: nil) { _ in
    changes.append(Date().timeIntervalSince(t0))
    print(String(format: "  !! AVAudioEngineConfigurationChange at t=%.2fs  (engine.isRunning=%@)",
                 Date().timeIntervalSince(t0), engine.isRunning ? "true" : "false"))
    fflush(stdout)
}
do { try engine.start() } catch { print("start failed \(error)"); exit(1) }
var finished = false
player.scheduleBuffer(buf, at: nil, options: []) { finished = true }
player.play()
print("PLAYBACK: started, \(dur)s tone, no microphone in this process")
fflush(stdout)
let deadline = Date().addingTimeInterval(dur + 1.0)
while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
print(String(format: "PLAYBACK: done. configChanges=%d  engine.isRunning=%@  playerPlaying=%@  bufferCompleted=%@",
             changes.count, engine.isRunning ? "true" : "false",
             player.isPlaying ? "true" : "false", finished ? "true" : "false"))
if !changes.isEmpty { print("PLAYBACK: change times: \(changes.map { String(format: "%.2f", $0) }.joined(separator: ", "))") }
